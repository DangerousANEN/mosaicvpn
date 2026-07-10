// MosaicVPN — build config for Slint compiler
// The .slint file is compiled at build time by slint-build

fn main() {
    slint_build::compile("src/components/app.slint").unwrap();
}
