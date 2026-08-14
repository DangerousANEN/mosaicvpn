from pathlib import Path
from PIL import Image

path = Path(__file__).resolve().parents[1] / 'assets' / 'icon.png'
image = Image.open(path).convert('RGBA')
alpha = image.getchannel('A')
print(f'path={path}')
print(f'size={image.size}')
print(f'alpha_extrema={alpha.getextrema()}')
print(f'corner_rgba={image.getpixel((0, 0))}')
print(f'center_rgba={image.getpixel((image.width // 2, image.height // 2))}')
print(f'transparent_pixels={sum(1 for value in alpha.getdata() if value == 0)}')
