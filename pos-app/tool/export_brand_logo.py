"""Растровые экспорты знака «Logo Orange» (03 §2.4): 256 / 512 / 1024 px из исходника 8334 px.

Запуск (из pos-app):  python -I -X utf8 tool/export_brand_logo.py <путь к исходному Logo Orange.png>
Пишет assets/brand/logo_orange.png (1024 px — объявлен в pubspec, его декодируют SplashLogo/AuthLogo с
cacheWidth) и assets/brand/export/logo_orange_{256,512}.png (не входят в бандл; для иконок/документов).
Исходник не меняется (каталог resursi/ только читается).
"""
import pathlib
import sys

from PIL import Image

SIZES = (256, 512, 1024)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    src = pathlib.Path(sys.argv[1])
    root = pathlib.Path(__file__).resolve().parent.parent
    out_dir = root / "assets" / "brand"
    (out_dir / "export").mkdir(parents=True, exist_ok=True)
    with Image.open(src) as img:
        img = img.convert("RGBA")
        for size in SIZES:
            resized = img.resize((size, size), Image.LANCZOS)
            target = out_dir / "logo_orange.png" if size == 1024 else out_dir / "export" / f"logo_orange_{size}.png"
            resized.save(target, format="PNG", optimize=True)
            print(f"{target.relative_to(root)}: {size}x{size}, {target.stat().st_size} байт")
    return 0


if __name__ == "__main__":
    sys.exit(main())
