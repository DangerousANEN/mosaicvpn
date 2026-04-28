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
    Manager, RunEvent, WebviewWindow, WindowEvent,
};

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
        // Phase 1: ask the daemon to gracefully disconnect first.
        // sing-box (especially in TUN mode) needs a real shutdown
        // signal to remove the wintun adapter and clean up the routing
        // table; if we just SIGKILL mosaicd via the Job Object, those
        // routes leak and the user can be left without working
        // connectivity until reboot. The HTTP call is short-fused
        // (~1.5 s total) so a wedged daemon doesn't stall app exit.
        graceful_disconnect_best_effort(std::time::Duration::from_millis(1500));

        let mut slot = self.0.lock().expect("daemon mutex poisoned");
        if let Some(mut child) = slot.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// graceful_disconnect_best_effort reads the daemon lockfile and
/// fires a `POST /v1/disconnect` over plain TCP (loopback, bearer
/// auth) so sing-box has a chance to tear down its TUN inbound and
/// route table before the Job Object kills the entire process tree.
/// All errors are silently swallowed — the next step in shutdown is
/// to kill the daemon anyway.
fn graceful_disconnect_best_effort(budget: std::time::Duration) {
    let Some(dir) = data_dir() else { return };
    let lock = dir.join("daemon.lock");
    let raw = match std::fs::read(&lock) {
        Ok(b) if !b.is_empty() => b,
        _ => return,
    };
    let endpoint: DaemonEndpoint = match serde_json::from_slice(&raw) {
        Ok(e) => e,
        Err(_) => return,
    };
    let host = if endpoint.host.is_empty() { "127.0.0.1" } else { endpoint.host.as_str() };
    let addr_str = format!("{}:{}", host, endpoint.port);
    let addrs: Vec<std::net::SocketAddr> = match std::net::ToSocketAddrs::to_socket_addrs(&addr_str) {
        Ok(it) => it.collect(),
        Err(_) => return,
    };
    for addr in addrs {
        if try_disconnect_via_socket(addr, &endpoint.token, budget).is_ok() {
            return;
        }
    }
}

fn try_disconnect_via_socket(
    addr: std::net::SocketAddr,
    token: &str,
    budget: std::time::Duration,
) -> std::io::Result<()> {
    use std::io::{Read, Write};
    use std::net::TcpStream;

    let mut stream = TcpStream::connect_timeout(&addr, budget)?;
    let _ = stream.set_read_timeout(Some(budget));
    let _ = stream.set_write_timeout(Some(budget));
    let request = format!(
        "POST /v1/disconnect HTTP/1.1\r\n\
         Host: {host}\r\n\
         Authorization: Bearer {token}\r\n\
         Content-Length: 0\r\n\
         Connection: close\r\n\
         \r\n",
        host = addr,
        token = token,
    );
    stream.write_all(request.as_bytes())?;
    // Drain the response so the daemon's writer doesn't see an RST
    // mid-handler. We don't actually parse it.
    let mut buf = [0u8; 1024];
    let _ = stream.read(&mut buf);
    Ok(())
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

/// is_admin returns true when the current process is running with
/// administrator privileges (Windows) or root (Unix). The renderer
/// uses this to gate the TUN tunnel mode toggle in Settings —
/// Wintun's TUN inbound only works elevated.
///
/// On Windows the implementation calls `GetTokenInformation` on the
/// process token with `TokenElevation`. On non-Windows we always
/// return true since TUN-vs-proxy is a Windows concept here.
#[tauri::command]
fn is_admin() -> bool {
    #[cfg(target_os = "windows")]
    {
        unsafe {
            use std::mem::size_of;
            #[repr(C)]
            struct TokenElevation {
                token_is_elevated: u32,
            }
            type Handle = *mut std::ffi::c_void;
            type Bool = i32;
            extern "system" {
                fn GetCurrentProcess() -> Handle;
                fn OpenProcessToken(
                    process: Handle,
                    desired: u32,
                    token_handle: *mut Handle,
                ) -> Bool;
                fn GetTokenInformation(
                    token: Handle,
                    class: i32,
                    info: *mut std::ffi::c_void,
                    info_len: u32,
                    return_length: *mut u32,
                ) -> Bool;
                fn CloseHandle(h: Handle) -> Bool;
            }
            const TOKEN_QUERY: u32 = 0x0008;
            const TOKEN_ELEVATION_CLASS: i32 = 20;

            let mut token: Handle = std::ptr::null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return false;
            }
            let mut elevation = TokenElevation { token_is_elevated: 0 };
            let mut ret_len: u32 = 0;
            let ok = GetTokenInformation(
                token,
                TOKEN_ELEVATION_CLASS,
                &mut elevation as *mut _ as *mut std::ffi::c_void,
                size_of::<TokenElevation>() as u32,
                &mut ret_len,
            );
            CloseHandle(token);
            ok != 0 && elevation.token_is_elevated != 0
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        // Best-effort: euid == 0 is root; everything else is unprivileged.
        // Linux/macOS users typically run mosaicvpn unelevated and TUN
        // there isn't bundled, so this branch is largely informational.
        unsafe { libc_geteuid() == 0 }
    }
}

#[cfg(not(target_os = "windows"))]
extern "C" {
    #[link_name = "geteuid"]
    fn libc_geteuid() -> u32;
}

/// restart_as_admin re-launches the GUI with administrator privileges
/// via the standard "runas" Shell verb on Windows. The current
/// instance is told to exit so the user only sees one window after
/// the UAC prompt is accepted.
///
/// On non-Windows the call is a no-op that returns Err so the renderer
/// can keep its UX consistent.
#[tauri::command]
fn restart_as_admin(app: tauri::AppHandle) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::ffi::OsStrExt;
        let exe = std::env::current_exe()
            .map_err(|e| format!("current_exe: {e}"))?;
        let exe_w: Vec<u16> = exe.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
        let verb_w: Vec<u16> = std::ffi::OsStr::new("runas")
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        type Handle = *mut std::ffi::c_void;
        #[repr(C)]
        struct ShellExecuteInfoW {
            cb_size: u32,
            mask: u32,
            hwnd: Handle,
            lp_verb: *const u16,
            lp_file: *const u16,
            lp_parameters: *const u16,
            lp_directory: *const u16,
            n_show: i32,
            h_inst_app: Handle,
            lp_id_list: *mut std::ffi::c_void,
            lp_class: *const u16,
            h_key_class: Handle,
            dw_hot_key: u32,
            h_icon_or_monitor: Handle,
            h_process: Handle,
        }
        extern "system" {
            fn ShellExecuteExW(p: *mut ShellExecuteInfoW) -> i32;
        }
        const SW_SHOWNORMAL: i32 = 1;
        const SEE_MASK_NOCLOSEPROCESS: u32 = 0x40;
        let mut info = ShellExecuteInfoW {
            cb_size: std::mem::size_of::<ShellExecuteInfoW>() as u32,
            mask: SEE_MASK_NOCLOSEPROCESS,
            hwnd: std::ptr::null_mut(),
            lp_verb: verb_w.as_ptr(),
            lp_file: exe_w.as_ptr(),
            lp_parameters: std::ptr::null(),
            lp_directory: std::ptr::null(),
            n_show: SW_SHOWNORMAL,
            h_inst_app: std::ptr::null_mut(),
            lp_id_list: std::ptr::null_mut(),
            lp_class: std::ptr::null(),
            h_key_class: std::ptr::null_mut(),
            dw_hot_key: 0,
            h_icon_or_monitor: std::ptr::null_mut(),
            h_process: std::ptr::null_mut(),
        };
        let ok = unsafe { ShellExecuteExW(&mut info) };
        if ok == 0 {
            return Err("ShellExecuteExW returned 0 — UAC prompt was likely denied".into());
        }
        // Tell the bundled daemon to die first so the new elevated
        // instance can grab the single-instance lock cleanly.
        app.state::<DaemonProcess>().shutdown();
        app.exit(0);
        Ok(())
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = app;
        Err("administrator elevation is only implemented on Windows".into())
    }
}

#[tauri::command]
fn daemon_endpoint() -> Result<DaemonEndpoint, String> {
    let dir = data_dir().ok_or_else(|| "could not determine data dir".to_string())?;
    let lock = dir.join("daemon.lock");

    // The bundled mosaicd is launched concurrently with the GUI in
    // setup(); on a fresh install the renderer often calls this
    // command before mosaicd has had a chance to bind its port and
    // write the lockfile. Poll for ~6s before giving up so the splash
    // screen sees the endpoint as soon as it's ready.
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
            #[cfg(windows)]
            {
                // Tie mosaicd (and any process it spawns — sing-box —
                // by Windows job-inheritance) to a Job Object owned by
                // this UI process. When the UI exits cleanly OR is
                // terminated externally (taskkill, crash, OS shutdown)
                // every process in the job is hard-killed by the
                // kernel. Without this the daemon and sing-box would
                // happily survive a UI crash and accumulate across
                // launches.
                if !job::assign(&child) {
                    eprintln!("mosaic-ui: warning: AssignProcessToJobObject failed; mosaicd will not auto-die when UI exits");
                }
            }
            Some(child)
        }
        Err(err) => {
            eprintln!("mosaic-ui: failed to spawn bundled mosaicd at {exe:?}: {err}");
            None
        }
    }
}

/// Windows job-object integration. The first call to `assign()` lazily
/// creates a single Job Object configured with
/// JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; the only handle to that object
/// is owned by this process and is intentionally leaked so it stays
/// open for the lifetime of the UI. When the UI exits — for any
/// reason — Windows closes the handle, the job has zero references
/// left, and the kernel terminates every process assigned to it.
///
/// On Windows 8+ child processes inherit the job of their creator
/// unless they specifically break away, so once mosaicd is in the
/// job, sing-box (spawned by mosaicd) joins automatically.
#[cfg(windows)]
mod job {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;
    use std::process::Child;
    use std::sync::OnceLock;

    type Handle = *mut c_void;
    type Bool = i32;

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectBasicLimitInformation {
        per_process_user_time_limit: i64,
        per_job_user_time_limit: i64,
        limit_flags: u32,
        minimum_working_set_size: usize,
        maximum_working_set_size: usize,
        active_process_limit: u32,
        affinity: usize,
        priority_class: u32,
        scheduling_class: u32,
    }

    #[repr(C)]
    #[derive(Default)]
    struct IoCounters {
        read_operation_count: u64,
        write_operation_count: u64,
        other_operation_count: u64,
        read_transfer_count: u64,
        write_transfer_count: u64,
        other_transfer_count: u64,
    }

    #[repr(C)]
    #[derive(Default)]
    struct JobObjectExtendedLimitInformation {
        basic_limit_information: JobObjectBasicLimitInformation,
        io_info: IoCounters,
        process_memory_limit: usize,
        job_memory_limit: usize,
        peak_process_memory_used: usize,
        peak_job_memory_used: usize,
    }

    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x0000_2000;
    const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION: i32 = 9;

    extern "system" {
        fn CreateJobObjectW(security: *mut c_void, name: *const u16) -> Handle;
        fn SetInformationJobObject(
            job: Handle,
            info_class: i32,
            info: *const c_void,
            info_len: u32,
        ) -> Bool;
        fn AssignProcessToJobObject(job: Handle, process: Handle) -> Bool;
    }

    // Wrapping the raw HANDLE in a struct so it implements Send/Sync —
    // OnceLock requires the inner type to satisfy those bounds.
    #[derive(Copy, Clone)]
    struct JobHandle(Handle);
    unsafe impl Send for JobHandle {}
    unsafe impl Sync for JobHandle {}

    static JOB: OnceLock<JobHandle> = OnceLock::new();

    fn ensure_job() -> Handle {
        JOB.get_or_init(|| unsafe {
            let job = CreateJobObjectW(std::ptr::null_mut(), std::ptr::null());
            if job.is_null() {
                return JobHandle(std::ptr::null_mut());
            }
            let mut info = JobObjectExtendedLimitInformation::default();
            info.basic_limit_information.limit_flags =
                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let _ = SetInformationJobObject(
                job,
                JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
                &info as *const _ as *const c_void,
                std::mem::size_of::<JobObjectExtendedLimitInformation>() as u32,
            );
            JobHandle(job)
        })
        .0
    }

    pub fn assign(child: &Child) -> bool {
        unsafe {
            let job = ensure_job();
            if job.is_null() {
                return false;
            }
            let handle = child.as_raw_handle() as Handle;
            AssignProcessToJobObject(job, handle) != 0
        }
    }
}

fn main() {
    let daemon = DaemonProcess::new();
    tauri::Builder::default()
        .manage(daemon)
        .invoke_handler(tauri::generate_handler![
            daemon_endpoint,
            is_admin,
            restart_as_admin,
            tray_popup_toggle,
        ])
        .setup(|app| {
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
                        position,
                        ..
                    } = event
                    {
                        toggle_tray_popup(tray.app_handle(), position);
                    }
                })
                .build(app)?;

            // Wire the tray-popup window's blur event to auto-hide.
            // The window is declared in tauri.conf.json so it's
            // already constructed by the time setup() runs.
            if let Some(popup) = app.get_webview_window("tray-popup") {
                let popup_for_listener: WebviewWindow = popup.clone();
                popup.on_window_event(move |ev| {
                    if let WindowEvent::Focused(false) = ev {
                        // Blur → hide. The user can re-open by
                        // clicking the tray icon again.
                        let _ = popup_for_listener.hide();
                    }
                });
            }

            // rc28 (W) — close-to-tray. Pressing the X on the main
            // window minimises Mosaic to the tray icon instead of
            // killing the daemon. The tray "Quit Mosaic" menu item
            // remains the only way to actually exit, which matches
            // the user's mental model of "VPN is always running, the
            // window is just one view onto it".
            if let Some(main_w) = app.get_webview_window("main") {
                let main_for_listener: WebviewWindow = main_w.clone();
                main_w.on_window_event(move |ev| {
                    if let WindowEvent::CloseRequested { api, .. } = ev {
                        api.prevent_close();
                        let _ = main_for_listener.hide();
                    }
                });
            }

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

/// toggle_tray_popup shows or hides the dedicated frameless tray
/// popup window, anchoring it near the supplied screen-space position
/// (typically the cursor / tray icon location). The popup loads the
/// renderer at `#/tray` and behaves as a focusable but non-taskbar
/// utility window — losing focus hides it again so the tray feels
/// native (see the `blur` listener registered in setup()).
fn toggle_tray_popup(app: &tauri::AppHandle, click_pos: tauri::PhysicalPosition<f64>) {
    let Some(w) = app.get_webview_window("tray-popup") else {
        // Should never happen: the popup is declared in tauri.conf.json
        // and instantiated at startup. Fall back to the main window so
        // the user still gets *some* response from a tray click.
        focus_main(app);
        return;
    };
    let visible = w.is_visible().unwrap_or(false);
    if visible {
        let _ = w.hide();
        return;
    }
    // Anchor: by default Windows reports the tray-icon click position
    // in physical pixels. Convert to logical via the popup's own scale
    // factor (good enough for primary monitor) and offset so the popup
    // floats above the cursor with a small gap. The y-offset assumes
    // a bottom-anchored taskbar; on side / top taskbars the popup
    // simply opens above the click which is also acceptable.
    let scale = w.scale_factor().unwrap_or(1.0);
    let size = w.outer_size().ok();
    let popup_w = size.map(|s| s.width as f64).unwrap_or(360.0);
    let popup_h = size.map(|s| s.height as f64).unwrap_or(500.0);
    let mut x = click_pos.x - popup_w / 2.0;
    let mut y = click_pos.y - popup_h - 12.0;
    if y < 0.0 {
        y = click_pos.y + 24.0;
    }
    if x < 8.0 {
        x = 8.0;
    }
    let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
    let _ = w.show();
    let _ = w.set_focus();
    let _ = scale;
}

/// tray_popup_toggle is the renderer-callable wrapper around
/// toggle_tray_popup. The popup itself uses it for "Quit", "Show
/// main window" links so the user can pop the popup closed cleanly.
#[tauri::command]
fn tray_popup_toggle(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(w) = app.get_webview_window("tray-popup") {
        let visible = w.is_visible().unwrap_or(false);
        if visible {
            w.hide().map_err(|e| e.to_string())?;
        } else {
            w.show().map_err(|e| e.to_string())?;
            let _ = w.set_focus();
        }
    }
    Ok(())
}
