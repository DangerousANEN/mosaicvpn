// MosaicVPN — native GUI entry point
// Slint + Rust, Mosaic Atlas visual style

mod api;
mod models;

use api::ApiClient;
use models::Prefs;
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

slint::include_modules!();

fn format_bytes(bytes: u64) -> String {
    if bytes < 1024 {
        format!("{} B", bytes)
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    } else if bytes < 1024 * 1024 * 1024 {
        format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
    } else {
        format!("{:.1} GB", bytes as f64 / (1024.0 * 1024.0 * 1024.0))
    }
}

fn to_slint_sub(sub: &models::Subscription) -> SlintSubscription {
    SlintSubscription {
        id: SharedString::from(&sub.id),
        name: SharedString::from(&sub.name),
        url: SharedString::from(&sub.url),
        format: SharedString::from(&sub.format),
        server_count: sub.server_count,
        last_error: SharedString::from(sub.last_error.as_deref().unwrap_or("")),
        is_expanded: false,
        editing: false,
    }
}

fn to_slint_server(srv: &models::Server) -> SlintServer {
    SlintServer {
        id: SharedString::from(&srv.id),
        name: SharedString::from(&srv.name),
        protocol: SharedString::from(&srv.protocol),
        address: SharedString::from(&srv.address),
        port: srv.port as i32,
        latency_ms: srv.last_test_ms.unwrap_or(0),
        country: SharedString::from(srv.country.as_deref().unwrap_or("")),
        city: SharedString::from(srv.city.as_deref().unwrap_or("")),
    }
}

/// Helper: push updated subscriptions into the Slint UI from a worker thread.
fn reload_subs(app_w: &slint::Weak<App>, api: &ApiClient) {
    if let Ok(subs) = api.list_subscriptions() {
        let slint_subs: Vec<SlintSubscription> = subs.iter().map(to_slint_sub).collect();
        let w = app_w.clone();
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(app) = w.upgrade() {
                app.set_subs(ModelRc::new(VecModel::from(slint_subs)));
            }
        });
    }
}

/// Helper: push updated servers list into the Slint UI from a worker thread.
fn reload_servers(app_w: &slint::Weak<App>, api: &ApiClient) {
    if let Ok(servers) = api.list_servers() {
        let slint_servers: Vec<SlintServer> = servers.iter().map(to_slint_server).collect();
        let w = app_w.clone();
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(app) = w.upgrade() {
                app.set_servers(ModelRc::new(VecModel::from(slint_servers)));
            }
        });
    }
}

/// Helper: push error message into the Slint UI from a worker thread.
fn show_error(app_w: &slint::Weak<App>, msg: String) {
    let w = app_w.clone();
    let _ = slint::invoke_from_event_loop(move || {
        if let Some(app) = w.upgrade() {
            app.set_error_msg(SharedString::from(msg));
        }
    });
}

fn main() {
    let app = App::new().unwrap();
    let app_weak = app.as_weak();

    // Instantiate API Client or log failure
    let api_client = match ApiClient::new() {
        Ok(client) => Some(Arc::new(Mutex::new(client))),
        Err(e) => {
            app.set_error_msg(SharedString::from(format!(
                "Daemon initialization failed: {}",
                e
            )));
            None
        }
    };

    // ── Setup UI Callbacks ──────────────────────────────────

    // Tab changed
    let app_w = app_weak.clone();
    let client_cfg = api_client.clone();
    app.on_tab_changed(move |tab| {
        let app = app_w.upgrade().unwrap();
        app.set_active_tab(tab.clone());

        let client = match &client_cfg {
            Some(c) => c.clone(),
            None => return,
        };
        let app_w = app_w.clone();

        // Reload data depending on tab
        thread::spawn(move || {
            let api = client.lock().unwrap();
            if tab == "pool" {
                reload_subs(&app_w, &api);
            } else if tab == "main" {
                reload_servers(&app_w, &api);
            }
        });
    });

    // Save preferences
    let app_w = app_weak.clone();
    let client_cfg = api_client.clone();
    app.on_save_preferences(move |slint_p| {
        let client = match &client_cfg {
            Some(c) => c.clone(),
            None => return,
        };
        let app_w = app_w.clone();

        thread::spawn(move || {
            let api = client.lock().unwrap();
            let new_prefs = Prefs {
                tunnel_mode: slint_p.tunnel_mode.to_string(),
                socks_addr: "127.0.0.1:1080".to_string(),
                http_addr: "127.0.0.1:1081".to_string(),
                mtu: 1420,
                kill_switch: slint_p.kill_switch,
                allow_lan: slint_p.allow_lan,
                bypass_processes: vec![],
                block_ipv6: slint_p.block_ipv6,
                dns_mode: slint_p.dns_mode.to_string(),
                dns_proxied: "8.8.8.8".to_string(),
                dns_direct: "1.1.1.1".to_string(),
                share_lan: false,
                share_addr: "".to_string(),
                share_allow: vec![],
                auto_start: slint_p.auto_start.to_string(),
                auto_connect: false,
                show_on_launch: true,
                mcp_enabled: slint_p.mcp_enabled,
                mcp_addr: slint_p.mcp_addr.to_string(),
                mcp_permission: "read".to_string(),
                mcp_confirm: false,
            };

            if let Err(e) = api.set_prefs(&new_prefs) {
                show_error(&app_w, format!("Failed to save prefs: {}", e));
            }
        });
    });

    // Add Subscription
    let app_w = app_weak.clone();
    let client_cfg = api_client.clone();
    app.on_add_subscription(move |url| {
        let client = match &client_cfg {
            Some(c) => c.clone(),
            None => return,
        };
        let app_w = app_w.clone();
        let url_str = url.to_string();

        thread::spawn(move || {
            let api = client.lock().unwrap();
            match api.add_subscription(&url_str) {
                Ok(_) => reload_subs(&app_w, &api),
                Err(e) => show_error(&app_w, format!("Failed to add subscription: {}", e)),
            }
        });
    });

    // Delete Subscription
    let app_w = app_weak.clone();
    let client_cfg = api_client.clone();
    app.on_delete_subscription(move |id| {
        let client = match &client_cfg {
            Some(c) => c.clone(),
            None => return,
        };
        let app_w = app_w.clone();
        let id_str = id.to_string();

        thread::spawn(move || {
            let api = client.lock().unwrap();
            match api.delete_subscription(&id_str) {
                Ok(_) => reload_subs(&app_w, &api),
                Err(e) => show_error(&app_w, format!("Failed to delete subscription: {}", e)),
            }
        });
    });

    // Rename Subscription
    let app_w = app_weak.clone();
    let client_cfg = api_client.clone();
    app.on_rename_subscription(move |id, name| {
        let client = match &client_cfg {
            Some(c) => c.clone(),
            None => return,
        };
        let app_w = app_w.clone();
        let id_str = id.to_string();
        let name_str = name.to_string();

        thread::spawn(move || {
            let api = client.lock().unwrap();
            match api.rename_subscription(&id_str, &name_str) {
                Ok(_) => reload_subs(&app_w, &api),
                Err(e) => show_error(&app_w, format!("Failed to rename subscription: {}", e)),
            }
        });
    });

    // Refresh/Sync Subscription
    let app_w = app_weak.clone();
    let client_cfg = api_client.clone();
    app.on_refresh_subscription(move |id| {
        let client = match &client_cfg {
            Some(c) => c.clone(),
            None => return,
        };
        let app_w = app_w.clone();
        let id_str = id.to_string();

        thread::spawn(move || {
            let api = client.lock().unwrap();
            match api.refresh_subscription(&id_str) {
                Ok(_) => reload_subs(&app_w, &api),
                Err(e) => show_error(&app_w, format!("Failed to refresh subscription: {}", e)),
            }
        });
    });

    // Test station latency
    let app_w = app_weak.clone();
    let client_cfg = api_client.clone();
    app.on_test_station(move |id| {
        let client = match &client_cfg {
            Some(c) => c.clone(),
            None => return,
        };
        let app_w = app_w.clone();
        let id_str = id.to_string();

        thread::spawn(move || {
            let api = client.lock().unwrap();
            match api.test_server(&id_str) {
                Ok(_) => reload_servers(&app_w, &api),
                Err(e) => show_error(&app_w, format!("Failed to test station: {}", e)),
            }
        });
    });

    // Connect to server
    let app_w = app_weak.clone();
    let client_cfg = api_client.clone();
    app.on_connect_server(move |server_id| {
        let client = match &client_cfg {
            Some(c) => c.clone(),
            None => return,
        };
        let app_w = app_w.clone();
        let srv_id = server_id.to_string();

        thread::spawn(move || {
            let api = client.lock().unwrap();
            if let Err(e) = api.connect(&srv_id) {
                show_error(&app_w, format!("Connection engagement failed: {}", e));
            }
        });
    });

    // Disconnect tunnel
    let client_cfg = api_client.clone();
    app.on_disconnect_tunnel(move || {
        let client = match &client_cfg {
            Some(c) => c.clone(),
            None => return,
        };
        thread::spawn(move || {
            let api = client.lock().unwrap();
            let _ = api.disconnect();
        });
    });

    // ── Setup Daemon Status Polling Thread ────────────────────
    if let Some(client) = api_client {
        let app_w = app_weak.clone();
        thread::spawn(move || loop {
            {
                let api = client.lock().unwrap();
                if let Ok(status) = api.status() {
                    let state_str = status.state.clone();
                    let server_name = status
                        .server
                        .as_ref()
                        .map(|s| s.name.clone())
                        .unwrap_or_else(|| "—".to_string());
                    let protocol_name = status
                        .server
                        .as_ref()
                        .map(|s| s.protocol.clone())
                        .unwrap_or_else(|| "—".to_string());
                    let lat = status
                        .latency_ms
                        .map(|l| format!("{} ms", l))
                        .unwrap_or_else(|| "—".to_string());
                    let since_str = status.since.clone().unwrap_or_else(|| "—".to_string());
                    let traffic_in_str = format_bytes(status.bytes_in);
                    let traffic_out_str = format_bytes(status.bytes_out);

                    let slint_p = SlintPrefs {
                        tunnel_mode: SharedString::from(&status.tunnel_mode),
                        kill_switch: status.kill_switch,
                        allow_lan: true,
                        block_ipv6: false,
                        dns_mode: SharedString::from("fake-ip"),
                        auto_start: SharedString::from("manual"),
                        mcp_enabled: status.agent_connected,
                        mcp_addr: SharedString::from("127.0.0.1:20128"),
                    };

                    let w = app_w.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(app) = w.upgrade() {
                            app.set_conn_state(SharedString::from(&state_str));
                            app.set_conn_server_name(SharedString::from(&server_name));
                            app.set_conn_server_protocol(SharedString::from(&protocol_name));
                            app.set_conn_latency(SharedString::from(&lat));
                            app.set_conn_traffic_in(SharedString::from(&traffic_in_str));
                            app.set_conn_traffic_out(SharedString::from(&traffic_out_str));
                            app.set_conn_since(SharedString::from(&since_str));
                            app.set_prefs(slint_p);
                        }
                    });
                }
            }
            thread::sleep(Duration::from_millis(500));
        });
    }

    // Run active GUI loop
    app.run().unwrap();
}
