# Tauri sidecar binaries

Tauri's `bundle.externalBin = ["binaries/mosaicd"]` config bundles the
mosaicd daemon next to the GUI executable in release builds. Tauri
expects the per-target file naming convention:

- `binaries/mosaicd-x86_64-pc-windows-msvc.exe` (Windows amd64)
- `binaries/mosaicd-aarch64-pc-windows-msvc.exe` (Windows arm64)
- `binaries/mosaicd-x86_64-apple-darwin` (Intel Mac)
- `binaries/mosaicd-aarch64-apple-darwin` (Apple Silicon)
- `binaries/mosaicd-x86_64-unknown-linux-gnu`
- `binaries/mosaicd-aarch64-unknown-linux-gnu`

The bundler strips the suffix at install time and places `mosaicd[.exe]`
next to the main app exe; the GUI shell finds it via
`std::env::current_exe()` (see `src/main.rs`).

For each platform you ship, build the matching mosaicd:

```bash
GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" \
  -o ui/src-tauri/binaries/mosaicd-x86_64-pc-windows-msvc.exe \
  ./cmd/mosaicd

GOOS=darwin  GOARCH=arm64 go build -ldflags="-s -w" \
  -o ui/src-tauri/binaries/mosaicd-aarch64-apple-darwin \
  ./cmd/mosaicd

# ...and so on
```

CI does this in `.github/workflows/release.yml`.
