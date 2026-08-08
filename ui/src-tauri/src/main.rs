// Mosaic UI — Tauri 2 shell.
//
// The renderer (React + Vite) lives in ../src and talks to the daemon
// over its loopback HTTP API. The shell's only structural job is to
// resolve the daemon's listen address + bearer token from the lockfile
// the daemon writes at startup, and to surface a system-tray icon
// with show / hide / quit. Everything else runs in the webview.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Emitter, Listener, Manager, RunEvent, WindowEvent,
};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Shortcut, ShortcutState};
use tauri_plugin_deep_link::DeepLinkExt;

/// DaemonProcess wraps the mosaicd child process spawned by the shell
/// at startup. We hold it inside the Tauri AppHandle as managed state
/// so we can kill it deterministically when the GUI exits — otherwise
/// the daemon would keep running after the window is closed.
struct DaemonProcess(Mutex<Option<Child>>);

impl DaemonProcess {
    fn new() -> Self {
        Self(Mutex::new(None))
    }

    fn store(&self, child: Child) {
        let mut slot = self.0.lock().expect("daemon mutex poisoned");
        *slot = Some(child);
    }

    fn shutdown(&self) {
        let mut slot = self.0.lock().expect("daemon mutex poisoned");
        if let Some(mut child) = slot.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

#[derive(Serialize, Deserialize, Debug, Clone)]
struct DaemonEndpoint {
    host: String,
    port: u16,
    token: String,
    pid: u32,
    #[serde(default)]
    version: String,
    #[serde(default)]
    started: String,
}

/// data_dir mirrors internal/paths.DataDir on the Go side. We can't link
/// against the Go binary, so we re-derive the same per-OS layout here.
///
/// MOSAIC_DATA_DIR overrides everything — both sides honour it, which is
/// how `scripts/dev.sh` keeps the daemon and the GUI pointed at the same
/// dev sandbox. The variable is taken verbatim (no AppName suffix).
fn data_dir() -> Option<PathBuf> {
    if let Ok(d) = std::env::var("MOSAIC_DATA_DIR") {
        if !d.is_empty() {
            return Some(PathBuf::from(d));
        }
    }
    #[cfg(target_os = "windows")]
    {
        if let Ok(d) = std::env::var("ProgramData") {
            return Some(PathBuf::from(d).join("Mosaic"));
        }
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = dirs::home_dir() {
            return Some(home.join("Library").join("Application Support").join("Mosaic"));
        }
    }
    #[cfg(target_os = "linux")]
    {
        if let Some(d) = dirs::data_dir() {
            return Some(d.join("mosaic"));
        }
    }
    None
}

#[tauri::command]
fn daemon_endpoint() -> Result<DaemonEndpoint, String> {
    let dir = data_dir().ok_or_else(|| "could not determine data dir".to_string())?;
    let lock = dir.join("daemon.lock");

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(6);
    let mut last_err: Option<String> = None;
    loop {
        match std::fs::read(&lock) {
            Ok(raw) if !raw.is_empty() => {
                return serde_json::from_slice::<DaemonEndpoint>(&raw)
                    .map_err(|e| format!("decode lockfile {}: {}", lock.display(), e));
            }
            Ok(_) => last_err = Some(format!("empty lockfile at {}", lock.display())),
            Err(e) => last_err = Some(format!("read {}: {}", lock.display(), e)),
        }
        if std::time::Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(150));
    }
    Err(last_err.unwrap_or_else(|| format!("timed out waiting for {}", lock.display())))
}

/// read_clipboard — Tauri command that reads the system clipboard text.
/// The UI calls this via invoke("read_clipboard") when the user pastes
/// a VPN link, then sends it to the daemon via api.importFromClipboard().
#[tauri::command]
fn read_clipboard(
    app: &tauri::AppHandle,
) -> Result<String, String> {
    app.clipboard()
        .read_text()
        .map_err(|e| format!("clipboard read failed: {e}"))
}

/// parse_deep_link — extract the raw VPN link from a mosaic:// URL.
/// Format: mosaic://import/<base64-encoded-link>
/// Returns the decoded raw link string.
fn parse_deep_link(url: &str) -> Option<String> {
    let prefix = "mosaic://import/";
    let encoded = url.strip_prefix(prefix)?;
    use std::convert::TryFrom;
    // Strip any trailing slash or query params
    let encoded = encoded.split('&').next().unwrap_or(encoded);
    let bytes = base64_decode(encoded)?;
    String::from_utf8(bytes).ok()
}

/// Minimal base64 URL-safe decoder (no external dep).
fn base64_decode(input: &str) -> Option<Vec<u8>> {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let input: String = input.chars().filter(|c| !c.is_whitespace()).collect();
    let input = input.replace('-', "+").replace('_', "/");
    let padded = match input.len() % 4 {
        2 => format!("{input}=="),
        3 => format!("{input}="),
        _ => input,
    };
    let bytes = padded.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    for chunk in bytes.chunks(4) {
        if chunk.len() < 4 { break; }
        let b = |c: u8| -> Option<u8> {
            TABLE.iter().position(|&t| t == c).map(|p| p as u8)
        };
        let b0 = b(chunk[0])?;
        let b1 = b(chunk[1])?;
        let b2 = if chunk[2] != b'=' { b(chunk[2])? } else { 0 };
        let b3 = if chunk[3] != b'=' { b(chunk[3])? } else { 0 };
        out.push((b0 << 2) | (b1 >> 4));
        if chunk[2] != b'=' { out.push((b1 << 4) | (b2 >> 2)); }
        if chunk[3] != b'=' { out.push((b2 << 6) | b3); }
    }
    Some(out)
}

/// resolve_runtime_data_dir returns the directory the daemon should
/// read/write inside, honouring MOSAIC_DATA_DIR if it is already set,
/// otherwise falling back to a per-user dir under Tauri's app-data
/// location. The result is also exported into the env so the spawned
/// mosaicd child sees the same value via os.Getenv.
fn resolve_runtime_data_dir(app: &tauri::AppHandle) -> Option<PathBuf> {
    if let Ok(d) = std::env::var("MOSAIC_DATA_DIR") {
        if !d.is_empty() {
            return Some(PathBuf::from(d));
        }
    }
    let dir = app.path().app_data_dir().ok()?.join("daemon");
    let _ = std::fs::create_dir_all(&dir);
    std::env::set_var("MOSAIC_DATA_DIR", &dir);
    Some(dir)
}

/// locate_bundled_mosaicd returns the path to the mosaicd executable
/// shipped alongside the GUI in release builds. It is bundled via
/// `bundle.externalBin` in tauri.conf.json, which places it next to the
/// main app exe with the target-triple suffix stripped at install time.
fn locate_bundled_mosaicd(app: &tauri::AppHandle) -> Option<PathBuf> {
    // Tauri 2 strips the target-triple suffix at bundle time, so the
    // installed binary is just `mosaicd[.exe]` next to the app exe.
    let exe_name = if cfg!(windows) { "mosaicd.exe" } else { "mosaicd" };

    if let Ok(here) = std::env::current_exe() {
        if let Some(dir) = here.parent() {
            let p = dir.join(exe_name);
            if p.exists() {
                return Some(p);
            }
        }
    }
    if let Ok(res) = app.path().resource_dir() {
        let p = res.join(exe_name);
        if p.exists() {
            return Some(p);
        }
    }
    None
}

/// spawn_bundled_daemon launches the bundled mosaicd as a child process.
/// On dev builds the binary is usually missing — in that case we silently
/// skip and assume the developer has run `scripts/dev.sh` separately.
/// stdout/stderr are redirected to mosaicd.{out,err}.log inside the data
/// dir so failures are diagnosable from a fresh install.
fn spawn_bundled_daemon(app: &tauri::AppHandle) -> Option<Child> {
    let exe = locate_bundled_mosaicd(app)?;
    let data_dir = resolve_runtime_data_dir(app)?;

    let stdout_log = match std::fs::File::create(data_dir.join("mosaicd.out.log")) {
        Ok(f) => f,
        Err(err) => {
            eprintln!("mosaic-ui: cannot create mosaicd.out.log: {err}");
            return None;
        }
    };
    let stderr_log = match std::fs::File::create(data_dir.join("mosaicd.err.log")) {
        Ok(f) => f,
        Err(err) => {
            eprintln!("mosaic-ui: cannot create mosaicd.err.log: {err}");
            return None;
        }
    };

    let mut cmd = Command::new(&exe);
    cmd.arg("-v");
    cmd.env("MOSAIC_DATA_DIR", &data_dir);
    cmd.stdout(stdout_log);
    cmd.stderr(stderr_log);
    cmd.current_dir(&data_dir);
    #[cfg(windows)]
    {
        // Suppress the console window that would otherwise flash when
        // launching a non-GUI subsystem binary.
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    match cmd.spawn() {
        Ok(child) => {
            eprintln!("mosaic-ui: spawned mosaicd pid {} from {exe:?} (data_dir={data_dir:?})", child.id());
            Some(child)
        }
        Err(err) => {
            eprintln!("mosaic-ui: failed to spawn bundled mosaicd at {exe:?}: {err}");
            None
        }
    }
}

fn main() {
    let daemon = DaemonProcess::new();
    tauri::Builder::default()
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .manage(daemon)
        .invoke_handler(tauri::generate_handler![daemon_endpoint, read_clipboard])
        .setup(|app| {
            // ---- Deep-link handler (mosaic://import/<base64>) ----
            // When the OS launches us with a mosaic:// URL, decode it
            // and emit an event the frontend listens for.
            let handle = app.handle().clone();
            app.deep_link().on_open_url(move |event| {
                for url in event.urls() {
                    if let Some(raw) = parse_deep_link(url.as_str()) {
                        let _ = handle.emit("import-link", &raw);
                    }
                }
            });

            // ---- Global shortcuts ----
            // Ctrl+Shift+M — toggle window visibility
            // Ctrl+Shift+D — disconnect (emit to frontend)
            let toggle_keys = "Ctrl+Shift+M";
            let disconnect_keys = "Ctrl+Shift+D";
            let shortcut = |keys: &str| -> Result<Shortcut, String> {
                keys.parse::<Shortcut>()
                    .map_err(|e| format!("invalid shortcut {keys}: {e}"))
            };

            if let Ok(sc) = shortcut(toggle_keys) {
                let h = app.handle().clone();
                let _ = app.global_shortcut().register(sc, move |_app, _hotkey, event| {
                    if event.state == ShortcutState::Pressed {
                        if let Some(w) = h.get_webview_window("main") {
                            if w.is_visible().unwrap_or(false) {
                                let _ = w.hide();
                            } else {
                                let _ = w.show();
                                let _ = w.set_focus();
                            }
                        }
                    }
                });
            }

            if let Ok(sc) = shortcut(disconnect_keys) {
                let h = app.handle().clone();
                let _ = app.global_shortcut().register(sc, move |_app, _hotkey, event| {
                    if event.state == ShortcutState::Pressed {
                        let _ = h.emit("disconnect", ());
                    }
                });
            }

            // In release builds we ship mosaicd alongside the GUI and
            // launch it ourselves; in dev builds the binary is absent
            // and we expect the developer to run `scripts/dev.sh`.
            if let Some(child) = spawn_bundled_daemon(app.handle()) {
                app.state::<DaemonProcess>().store(child);
            } else {
                let _ = resolve_runtime_data_dir(app.handle());
            }

            // Tray menu: Show window · separator · Quit. Connection
            // toggles live in the popup itself; the tray menu is for
            // window/lifecycle controls only.
            let show = MenuItem::with_id(app, "show", "Show window", true, None::<&str>)?;
            let hide = MenuItem::with_id(app, "hide", "Hide window", true, None::<&str>)?;
            let sep = PredefinedMenuItem::separator(app)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Mosaic", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &hide, &sep, &quit])?;

            let icon = app
                .default_window_icon()
                .cloned()
                .ok_or("no default window icon")?;

            let _tray = TrayIconBuilder::with_id("mosaic-tray")
                .tooltip("Mosaic VPN")
                .icon(icon)
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => focus_main(app),
                    "hide" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = w.hide();
                        }
                    }
                    "quit" => {
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        focus_main(tray.app_handle());
                    }
                })
                .build(app)?;

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building mosaic-ui")
        .run(|app, event| match event {
            // When the user closes the last window or quits via the
            // tray menu we have to make sure the bundled mosaicd dies
            // with us — otherwise it stays running with the lockfile
            // taken and the next launch fails the single-instance check.
            RunEvent::ExitRequested { .. } | RunEvent::Exit => {
                app.state::<DaemonProcess>().shutdown();
            }
            RunEvent::WindowEvent {
                event: WindowEvent::Destroyed,
                ..
            } => {
                // No-op: tray keeps the app alive until the user picks
                // "Quit Mosaic" explicitly.
            }
            _ => {}
        });
}

fn focus_main(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}
