// MosaicVPN — native GUI entry point
// Slint + Rust, Mosaic Atlas visual style

slint::include_modules!();

fn main() {
    let app = App::new().unwrap();
    app.run().unwrap();
}
