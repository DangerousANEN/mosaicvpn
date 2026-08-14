from __future__ import annotations

from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'assets' / 'icon.png'


def remove_white_backdrop(source: Image.Image) -> Image.Image:
    """Remove only pure-white backdrop pixels; retain the cream compass disk."""
    cleaned = source.copy()
    pixels = cleaned.load()
    for y in range(cleaned.height):
        for x in range(cleaned.width):
            red, green, blue, alpha = pixels[x, y]
            if alpha and red >= 250 and green >= 250 and blue >= 250:
                pixels[x, y] = (red, green, blue, 0)
    return cleaned


def square_icon(source: Image.Image, size: int, inset: float = 0.08) -> Image.Image:
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    target = max(1, int(size * (1 - inset * 2)))
    logo = source.copy()
    logo.thumbnail((target, target), Image.Resampling.LANCZOS)
    offset = ((size - logo.width) // 2, (size - logo.height) // 2)
    canvas.alpha_composite(logo, offset)
    return canvas


def save_png(image: Image.Image, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination, format='PNG', optimize=True)


def make_monochrome(source: Image.Image, size: int) -> Image.Image:
    alpha = square_icon(source, size, inset=0.14).getchannel('A')
    output = Image.new('RGBA', (size, size), (255, 255, 255, 0))
    output.putalpha(alpha)
    return output


def main() -> None:
    source = Image.open(SOURCE).convert('RGBA')
    source = remove_white_backdrop(source)
    save_png(source, ROOT / 'assets' / 'icon_adaptive.png')

    # Android legacy launcher densities and Android 8+ adaptive-icon layers.
    android = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'
    for density, size in {
        'mipmap-mdpi': 48,
        'mipmap-hdpi': 72,
        'mipmap-xhdpi': 96,
        'mipmap-xxhdpi': 144,
        'mipmap-xxxhdpi': 192,
    }.items():
        save_png(square_icon(source, size), android / density / 'ic_launcher.png')
        save_png(square_icon(source, size), android / density / 'ic_launcher_round.png')
    save_png(square_icon(source, 432, inset=0.14), android / 'drawable' / 'ic_launcher_foreground.png')
    save_png(make_monochrome(source, 432), android / 'drawable' / 'ic_launcher_monochrome.png')

    # Windows icon resource with the standard Explorer size ladder.
    windows_ico = ROOT / 'windows' / 'runner' / 'resources' / 'app_icon.ico'
    windows_ico.parent.mkdir(parents=True, exist_ok=True)
    windows_icon = square_icon(source, 256)
    windows_icon.save(
        windows_ico,
        format='ICO',
        sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    # Keep the shared icon copy used by packaging and documentation aligned.
    shared_ico = ROOT / 'assets' / 'icons' / 'app_icon.ico'
    shared_ico.parent.mkdir(parents=True, exist_ok=True)
    windows_icon.save(
        shared_ico,
        format='ICO',
        sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)],
    )

    # Linux Freedesktop icon theme sizes for a real .desktop launcher.
    linux_root = ROOT / 'assets' / 'icons' / 'hicolor'
    for size in (16, 32, 48, 64, 128, 256, 512):
        save_png(square_icon(source, size), linux_root / f'{size}x{size}' / 'apps' / 'ru.mosaicvpn.client.png')

    # iOS AppIcon set.
    ios = ROOT / 'ios' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'
    ios_sizes = {
        'Icon-App-20x20@1x.png': 20,
        'Icon-App-20x20@2x.png': 40,
        'Icon-App-20x20@3x.png': 60,
        'Icon-App-29x29@1x.png': 29,
        'Icon-App-29x29@2x.png': 58,
        'Icon-App-29x29@3x.png': 87,
        'Icon-App-40x40@1x.png': 40,
        'Icon-App-40x40@2x.png': 80,
        'Icon-App-40x40@3x.png': 120,
        'Icon-App-60x60@2x.png': 120,
        'Icon-App-60x60@3x.png': 180,
        'Icon-App-76x76@1x.png': 76,
        'Icon-App-76x76@2x.png': 152,
        'Icon-App-83.5x83.5@2x.png': 167,
        'Icon-App-1024x1024@1x.png': 1024,
    }
    for name, size in ios_sizes.items():
        save_png(square_icon(source, size, inset=0.06), ios / name)

    # macOS AppIcon set.
    mac = ROOT / 'macos' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'
    for size in (16, 32, 64, 128, 256, 512, 1024):
        save_png(square_icon(source, size, inset=0.06), mac / f'app_icon_{size}.png')

    print('Generated MosaicVPN brand icons for Android, Windows, Linux, iOS and macOS.')


if __name__ == '__main__':
    main()
