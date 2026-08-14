# Icon validation

- `assets/icon.png` is a 512×512 RGBA source with transparent corners.
- The first generated Android launcher PNG uses the MosaicVPN compass, not the Flutter default icon.
- Visual review revealed an opaque near-white rectangular region behind the compass in the source-derived output. This lowers contrast on dark launcher masks and must be removed while preserving the cream compass disk and terracotta needles.
- The next icon-generation pass should convert only pure/near-white connected background pixels to transparent alpha, then regenerate all platform sizes from the cleaned source.
