from pathlib import Path
from collections import Counter
from PIL import Image

path = Path(__file__).resolve().parents[1] / 'assets' / 'icon_adaptive.png'
image = Image.open(path).convert('RGBA')
for point in [(256, 32), (480, 256), (400, 256), (256, 100), (100, 256), (32, 256), (256, 480)]:
    print(f'{point}={image.getpixel(point)}')
colors = Counter(image.getdata())
for color, count in colors.most_common(12):
    print(f'{color}={count}')
