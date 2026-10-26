"""앱 아이콘 만들기 — 팀 로고 심볼(자물쇠 + 집 + 세이프)을 초록 바탕 앱 아이콘으로 (2026-10-26).

원본: `frontend/assets/brand/app_icon_symbol.svg` (팀 로고 오른쪽 초록 테마를 선으로 따라 그린 것 — 글자 없음).
이 파일을 고치고 다시 돌리면 아이콘이 전부 다시 만들어진다.

만드는 것:
- 안드로이드 시연 앱(`src/main/res`) — 적응형 아이콘(바탕색 + 심볼 + 테마 아이콘용 한 색) + 옛 기기용 PNG
- 안드로이드 **개발 앱**('전세AI프 개발', `src/debug/res`) — 같은 아이콘 + 아래에 '개발' 띠 (두 앱이 헷갈리지 않게)
- iOS `AppIcon.appiconset` (투명 없음 — 애플 규칙)

쓰는 법 (저장소 맨 위에서):
    pip install cairosvg pillow
    python scripts/make_app_icon.py
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "frontend"
SYMBOL = APP / "assets/brand/app_icon_symbol.svg"
FONT = APP / "assets/fonts/Pretendard-Bold.otf"

#: 바탕 초록 — 팀 로고 오른쪽 테마에서 뽑은 색
BG = (0x15, 0x41, 0x2E)
GOLD = (0xD2, 0xB0, 0x6C)
INK = (0x0F, 0x2E, 0x20)

#: 적응형 아이콘 크기(108dp 캔버스) · 옛 아이콘(48dp)
ADAPTIVE = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}

#: 심볼 높이 — 적응형은 가운데 66dp만 확실히 보이므로 캔버스의 52%, 옛 아이콘·iOS는 64%
ADAPTIVE_SYMBOL = 0.52
FULL_SYMBOL = 0.64


def symbol(height: int) -> Image.Image:
    png = cairosvg.svg2png(url=str(SYMBOL), output_height=height)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def place(canvas: Image.Image, sym: Image.Image, cy: float) -> None:
    x = (canvas.width - sym.width) // 2
    y = int(canvas.height * cy - sym.height / 2)
    canvas.alpha_composite(sym, (x, y))


def dev_badge(canvas: Image.Image, cy: float, height: float) -> None:
    """아래쪽 '개발' 띠 — 금색 알약 + 진초록 글자."""
    d = ImageDraw.Draw(canvas)
    h = int(canvas.height * height)
    font = ImageFont.truetype(str(FONT), int(h * 0.72))
    text = "개발"
    tw = d.textlength(text, font=font)
    w = int(tw + h * 0.9)
    x0 = (canvas.width - w) // 2
    y0 = int(canvas.height * cy - h / 2)
    d.rounded_rectangle([x0, y0, x0 + w, y0 + h], radius=h // 2, fill=GOLD + (255,))
    d.text((canvas.width / 2, y0 + h / 2), text, font=font, fill=INK + (255,), anchor="mm")


def foreground(size: int, dev: bool) -> Image.Image:
    c = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if dev:
        place(c, symbol(int(size * ADAPTIVE_SYMBOL * 0.86)), 0.46)
        dev_badge(c, 0.75, 0.11)
    else:
        place(c, symbol(int(size * ADAPTIVE_SYMBOL)), 0.5)
    return c


def monochrome(size: int) -> Image.Image:
    """테마 아이콘(안드로이드 13+) — 모양만, 색은 런처가 칠한다."""
    fg = foreground(size, dev=False)
    alpha = fg.getchannel("A")
    out = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


def full(size: int, dev: bool, rounded: bool) -> Image.Image:
    c = Image.new("RGBA", (size, size), BG + (255,))
    if dev:
        place(c, symbol(int(size * FULL_SYMBOL * 0.86)), 0.45)
        dev_badge(c, 0.82, 0.13)
    else:
        place(c, symbol(int(size * FULL_SYMBOL)), 0.5)
    if rounded:
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.22), fill=255)
        c.putalpha(mask)
    return c


def write_android(res: Path, dev: bool) -> None:
    for dpi, px in ADAPTIVE.items():
        folder = res / f"mipmap-{dpi}"
        folder.mkdir(parents=True, exist_ok=True)
        foreground(px, dev).save(folder / "ic_launcher_foreground.png")
        monochrome(px).save(folder / "ic_launcher_monochrome.png")
        full(LEGACY[dpi], dev, rounded=True).save(folder / "ic_launcher.png")
    anydpi = res / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!-- 만든 곳: scripts/make_app_icon.py — 손으로 고치지 말고 스크립트를 다시 돌린다 -->\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
        "</adaptive-icon>\n",
        encoding="utf-8",
    )
    values = res / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '    <color name="ic_launcher_background">#%02X%02X%02X</color>\n' % BG
        + "</resources>\n",
        encoding="utf-8",
    )


def write_ios() -> None:
    folder = APP / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((folder / "Contents.json").read_text(encoding="utf-8"))
    for img in contents.get("images", []):
        name = img.get("filename")
        if not name:
            continue
        pt = float(img["size"].split("x")[0])
        scale = int(img["scale"].rstrip("x"))
        px = round(pt * scale)
        full(px, dev=False, rounded=False).convert("RGB").save(folder / name)


def main() -> None:
    write_android(APP / "android/app/src/main/res", dev=False)
    write_android(APP / "android/app/src/debug/res", dev=True)
    write_ios()
    preview = Image.new("RGBA", (560, 300), (245, 245, 245, 255))
    preview.alpha_composite(full(240, dev=False, rounded=True), (20, 30))
    preview.alpha_composite(full(240, dev=True, rounded=True), (300, 30))
    out = ROOT / "frontend/build/app_icon_preview.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    preview.save(out)
    print(f"아이콘을 만들었어요 — 미리보기: {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
