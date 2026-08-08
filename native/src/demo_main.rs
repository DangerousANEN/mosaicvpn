slint::include_modules!();

use slint::Model;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Use demo.slint instead of app.slint
    let app = App::new()?;

    // Populate with demo servers
    use slint::{Model, ModelRc, VecModel};
    use std::rc::Rc;
    let servers_model = Rc::new(VecModel::from(vec![
        DemoServer { name: "ams-1".into(), city: "Amsterdam".into(), country: "NL".into(), ping: 12, load: 23 },
        DemoServer { name: "fra-1".into(), city: "Frankfurt".into(), country: "DE".into(), ping: 18, load: 45 },
        DemoServer { name: "lon-1".into(), city: "London".into(), country: "UK".into(), ping: 22, load: 31 },
        DemoServer { name: "par-1".into(), city: "Paris".into(), country: "FR".into(), ping: 25, load: 52 },
        DemoServer { name: "nyc-1".into(), city: "New York".into(), country: "US".into(), ping: 89, load: 67 },
        DemoServer { name: "sfo-1".into(), city: "San Francisco".into(), country: "US".into(), ping: 142, load: 34 },
        DemoServer { name: "tok-1".into(), city: "Tokyo".into(), country: "JP".into(), ping: 178, load: 41 },
        DemoServer { name: "sgp-1".into(), city: "Singapore".into(), country: "SG".into(), ping: 195, load: 28 },
        DemoServer { name: "mos-1".into(), city: "Moscow".into(), country: "RU".into(), ping: 8, load: 15 },
        DemoServer { name: "dal-1".into(), city: "Dallas".into(), country: "US".into(), ping: 112, load: 58 },
    ]));
    app.set_servers(ModelRc::from(servers_model.clone()));
    app.set_selected_idx(0);
    app.set_status_text("10 servers available".into());

    let w = app.as_weak();
    app.on_connect(move |idx| {
        if let Some(app) = w.upgrade() {
            app.set_connected(!app.get_connected());
            let servers = app.get_servers();
            let srvs: Vec<_> = servers.iter().collect();
            if (idx as usize) < srvs.len() {
                let srv = &srvs[idx as usize];
                let connected = app.get_connected();
                app.set_status_text(
                    if connected {
                        format!("Connected to {} ({})", srv.city, srv.country)
                    } else {
                        "Disconnected".into()
                    }.into()
                );
            }
        }
    });

    let w2 = app.as_weak();
    app.on_select_station(move |idx| {
        if let Some(app) = w2.upgrade() {
            app.set_selected_idx(idx);
            let servers = app.get_servers();
            let srvs: Vec<_> = servers.iter().collect();
            if (idx as usize) < srvs.len() {
                let srv = &srvs[idx as usize];
                app.set_status_text(format!("Selected {} · {}ms · {}% load", srv.city, srv.ping, srv.load).into());
            }
        }
    });

    app.run()?;
    Ok(())
}
