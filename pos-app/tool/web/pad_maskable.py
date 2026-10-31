"""Maskable-иконки веб-сборки с безопасной зоной: знак «Logo Orange» (03 §2.4) по центру на белом (`surface`).

flutter_launcher_icons (tool/web/flutter_launcher_icons.yaml) кладёт в web/icons/Icon-maskable-*.png знак без полей:
лаунчеры обрезают maskable-иконку по кругу или «капле» (безопасная зона — круг 80 % стороны), и кольцо знака
срезалось бы. Здесь знак занимает 70 % стороны (поле 15 % с каждой стороны) на непрозрачном белом фоне.

Запуск (из pos-app, после генератора иконок):  python -I -X utf8 tool/web/pad_maskable.py
Читает assets/brand/logo_orange.png, пишет web/icons/Icon-maskable-192.png и Icon-maskable-512.png.
"""
import pathlib

from PIL import Image

SIZES = (192, 512)
LOGO_SHARE = 0.70
BACKGROUND = (255, 255, 255, 255)  # tokens.json color.surface #FFFFFF


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent.parent
    src = root / "assets" / "brand" / "logo_orange.png"
    with Image.open(src) as img:
        logo = img.convert("RGBA")
        for size in SIZES:
            inner = round(size * LOGO_SHARE)
            canvas = Image.new("RGBA", (size, size), BACKGROUND)
            mark = logo.resize((inner, inner), Image.LANCZOS)
            offset = (size - inner) // 2
            canvas.alpha_composite(mark, (offset, offset))
            target = root / "web" / "icons" / f"Icon-maskable-{size}.png"
            canvas.save(target, format="PNG", optimize=True)
            print(f"{target.relative_to(root).as_posix()}: {size}x{size}, знак {inner} px, {target.stat().st_size} байт")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
