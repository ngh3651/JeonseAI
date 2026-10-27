"""촬영 품질 검사 (P1-1, 2026-10-22) — **IE·OCR을 부르기 전에** 사진이 읽을 만한지 본다.

픽스처: 선명한 합성 등기부(가짜 글자, Pillow 기본 글꼴 — CI에서도 같은 그림)와, 그것을 **일부러 망친 사본**
(가우시안 흐림 · 어둡게 · 빛 번짐 · 작게 · 새하얗게 · 부분 반사 · 듬성한 마지막 쪽). 기준값의 근거 표는
decisions.md [2026-10-22] 촬영 품질 검사에 있다 — 여기서는 그 표의 대표 칸을 다시 확인한다.

지키는 것:
- 선명한 사진(촬영 크기·화면 캡처 크기·듬성한 마지막 쪽)은 **절대 거절하지 않는다**
- 심하게 흐리거나 어두운 사진은 **분석 전에 거절**한다 — 외부 호출 0회, 분석 횟수도 안 깎는다
- 가벼운 문제는 분석하고 `captureCheck`로 알린다
- 판정(등급)은 바뀌지 않는다
"""

from __future__ import annotations

import io

import numpy as np
import pytest
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps

from app.schemas.contract import CaptureCheck, CapturePageIssue
from app.services import capture_check as cc
from app.services.ocr_layout import OcrPage, group_lines

from tests.test_highlight import PAGE_H, PAGE_W, W

_LINES = (
    "1  2001-03-02  SOYU BOJON   owner KANADA 600101-*******",
    "2  2006-06-23  SOYU IJEON   share 1/2  RAMABA 900101-*******",
    "3  2004-06-25  MORTGAGE     max 36,000,000 KRW  debtor SAAJA",
    "              lender HANA BANK 110111-0015671  No. 41414",
    "4  2024-01-05  SEIZURE      claim 10,000,000 KRW  2024KAHAN123",
)


def registry_page(width: int = 1920, height: int = 2560, text_px: int = 30, *, lines: int | None = None) -> Image.Image:
    """흰 종이에 가짜 등기부 글자 줄 + 세로 줄 + 쪽 번호 (실명 없음)."""
    im = Image.new("L", (width, height), 250)
    d = ImageDraw.Draw(im)
    font = ImageFont.load_default(size=text_px)
    y = int(height * 0.06)
    i = 0
    while y < height - int(height * 0.08) and (lines is None or i < lines):
        d.text((int(width * 0.05), y), _LINES[i % len(_LINES)], font=font, fill=25)
        y += int(text_px * 1.9)
        i += 1
    for x in (0.04, 0.12, 0.30, 0.48):
        d.line([(int(width * x), int(height * 0.05)), (int(width * x), y)], fill=110, width=1)
    d.text((int(width * 0.86), height - int(height * 0.05)), "1/5", font=font, fill=25)
    return im


def camera(im: Image.Image, *, paper: float = 200, ink: float = 45, noise: float = 4, seed: int = 0) -> Image.Image:
    """카메라 사진 흉내 — 회색빛 종이 + 조명 기울기 + 센서 노이즈."""
    a = np.asarray(im, dtype=np.float32)
    t = (a - 25.0) / (250.0 - 25.0)
    h, w = a.shape
    yy, xx = np.mgrid[0:h, 0:w]
    light = 1.0 - 0.18 * (xx / w * 0.6 + yy / h * 0.4)
    v = (ink + t * (paper - ink)) * light + np.random.default_rng(seed).normal(0, noise, a.shape)
    return Image.fromarray(np.clip(v, 0, 255).astype(np.uint8))


def glare_spot(im: Image.Image, r: float) -> Image.Image:
    a = np.asarray(im, dtype=np.float32)
    h, w = a.shape
    yy, xx = np.mgrid[0:h, 0:w]
    d = np.sqrt((xx - 0.6 * w) ** 2 + (yy - 0.35 * h) ** 2) / (r * w)
    return Image.fromarray(np.clip(a + np.clip(1.4 - d, 0, 1) ** 1.2 * 255, 0, 255).astype(np.uint8))


def jpeg(im: Image.Image, quality: int = 90) -> bytes:
    buf = io.BytesIO()
    im.convert("RGB").save(buf, "JPEG", quality=quality)
    return buf.getvalue()


def check_one(im: Image.Image) -> tuple[list[str], bool]:
    m = cc.measure(jpeg(im))
    assert m is not None
    return cc.assess(m)


@pytest.fixture(scope="module")
def base() -> Image.Image:
    return registry_page()


# ══════════════════════════════════════════════════════════════════════════════
# ① 선명한 사진은 통과 — 가장 중요한 쪽 (멀쩡한 사진을 거절하면 시연이 멈춘다)
# ══════════════════════════════════════════════════════════════════════════════


@pytest.mark.parametrize(
    "name,make",
    [
        ("촬영 크기 1920x2560", lambda: registry_page()),
        ("화면 캡처 1080x2340", lambda: registry_page(1080, 2340, 17)),
        ("A4 1240x1754", lambda: registry_page(1240, 1754, 22)),
        ("카메라 — 회색빛 종이·노이즈", lambda: camera(registry_page())),
        ("카메라 — 조금 어두운 방", lambda: camera(registry_page(), paper=150, ink=40)),
        ("글자가 세 줄뿐인 마지막 쪽", lambda: registry_page(lines=3)),
        ("글자가 세 줄뿐인 마지막 쪽(카메라)", lambda: camera(registry_page(lines=3))),
        # 2026-10-22 PR 검토: 폰 다크 모드로 띄운 등기부 캡처(검은 바탕·흰 글자) — 뒤집어 재기 전에는 거절됐다
        ("다크 모드 화면 캡처", lambda: ImageOps.invert(registry_page(1080, 2340, 17))),
        ("다크 모드 — 글자 여섯 줄뿐인 쪽", lambda: ImageOps.invert(registry_page(1080, 2340, 17, lines=6))),
    ],
)
def test_선명한_사진은_문제가_없다(name, make):
    issues, severe = check_one(make())
    assert issues == [] and severe is False, f"{name}: {issues}"


def test_조금_흐린_사진은_지나간다(base):
    """글자 높이의 7%만 번진 정도 — 사람 눈에 멀쩡하다(근거 표: blur 0.40)."""
    issues, _ = check_one(base.filter(ImageFilter.GaussianBlur(2.1)))
    assert issues == []


# ══════════════════════════════════════════════════════════════════════════════
# ② 흐림 · 어두움 · 빛 번짐 · 해상도 · 글자 없음
# ══════════════════════════════════════════════════════════════════════════════


def test_흐린_사진은_확인_필요(base):
    """글자 높이의 9~11% 번짐 — 읽히지만 무르다 → 분석은 하되 알린다."""
    issues, severe = check_one(base.filter(ImageFilter.GaussianBlur(3.0)))
    assert issues == ["blurry"] and severe is False


def test_심하게_흐린_사진은_거절(base):
    """글자 높이의 13% 이상 번짐 — 숫자를 잘못 읽을 수 있다 → 분석하지 않는다."""
    issues, severe = check_one(base.filter(ImageFilter.GaussianBlur(4.0)))
    assert "blurry" in issues and severe is True


def test_어두운_데서_찍어_노이즈가_껴도_흐림을_놓치지_않는다(base):
    """자글자글한 잡티가 '선명함'으로 잡히지 않게 중앙값으로 걷어낸다."""
    issues, _ = check_one(camera(base.filter(ImageFilter.GaussianBlur(3.9)), noise=7))
    assert "blurry" in issues


def test_어두운_사진은_확인_필요_아주_어두우면_거절(base):
    issues, severe = check_one(ImageEnhance.Brightness(base).enhance(0.3))
    assert issues == ["too_dark"] and severe is False
    issues, severe = check_one(ImageEnhance.Brightness(base).enhance(0.2))
    assert "too_dark" in issues and severe is True


def test_빛이_번져_글자가_날아가면_알린다(base):
    washed = ImageEnhance.Brightness(ImageEnhance.Contrast(base).enhance(0.4)).enhance(1.4)
    issues, severe = check_one(washed)
    assert "too_bright" in issues and severe is False


def test_빛이_번져_글자가_아예_없어지면_거절(base):
    gone = ImageEnhance.Brightness(ImageEnhance.Contrast(base).enhance(0.1)).enhance(1.2)
    issues, severe = check_one(gone)
    assert issues == ["no_text"] and severe is True


def test_종이_일부에_반사가_있으면_알린다(base):
    issues, severe = check_one(glare_spot(camera(base), 0.18))
    assert issues == ["too_bright"] and severe is False


def test_흰_종이를_어두운_책상에_놓고_찍어도_반사로_오해하지_않는다(base):
    canvas = Image.new("L", (1920, 2560), 90)
    canvas.paste(base.resize((1300, 1733)), (310, 330))
    issues, _ = check_one(canvas)
    assert issues == []


def test_새하얀_사진은_글자_없음으로_거절():
    issues, severe = check_one(Image.new("L", (880, 1200), 255))
    assert issues == ["no_text"] and severe is True


def test_다크_모드_화면만_뒤집어_재고_어두운_데서_찍은_종이는_그대로_잰다():
    """뒤집기는 '어두운 바탕에 밝은 글자'에만 — 어두운 종이 사진(글자가 종이보다 어둡다)을 살려 주면 안 된다."""
    dark_mode = cc.measure(jpeg(ImageOps.invert(registry_page(1080, 2340, 17))))
    assert dark_mode is not None and dark_mode.inverted is True
    dim_paper = cc.measure(jpeg(camera(registry_page(), paper=50, ink=15, noise=5)))
    assert dim_paper is not None and dim_paper.inverted is False
    issues, severe = cc.assess(dim_paper)
    assert "too_dark" in issues and severe is True
    lens_covered = cc.measure(jpeg(Image.new("L", (1920, 2560), 3)))
    assert lens_covered is not None and lens_covered.inverted is False
    assert cc.assess(lens_covered) == (["no_text"], True)


@pytest.mark.parametrize("width,severe", [(600, False), (360, True)])
def test_너무_작은_사진(width, severe):
    small = registry_page(1240, 1754, 22).resize((width, round(width * 1.414)), Image.Resampling.LANCZOS)
    issues, is_severe = check_one(small)
    assert "low_resolution" in issues and is_severe is severe


def test_사진이_아닌_바이트는_검사하지_않고_넘긴다():
    """뒤 단계(IE)가 원래대로 거절한다 — 검사가 판단할 일이 아니다."""
    assert cc.measure(b"not an image") is None
    assert cc.precheck([("a.jpg", b"not an image")]) == CaptureCheck(ok=True, pages=[])


# ══════════════════════════════════════════════════════════════════════════════
# ③ 문구 · 스위치
# ══════════════════════════════════════════════════════════════════════════════


def test_거절_문구는_몇_쪽이_왜_문제인지_말한다():
    check = CaptureCheck(ok=False, pages=[CapturePageIssue(index=1, issues=["blurry"], severe=True, tip="t")])
    message = cc.rejection_message(check)
    assert message.startswith("2쪽이 흐려요 — 다시 찍어 주세요")
    assert "(글자 테두리가 번져 있어요)" in message


def test_여러_장이면_장마다_한_마디씩():
    check = CaptureCheck(
        ok=False,
        pages=[
            CapturePageIssue(index=0, issues=["too_dark"], severe=True),
            CapturePageIssue(index=2, issues=["blurry"], severe=True),
            CapturePageIssue(index=3, issues=["blurry"], severe=False),  # 가벼운 장은 거절 문구에 안 넣는다
        ],
    )
    message = cc.rejection_message(check)
    assert "1쪽이 너무 어두워요" in message and "3쪽이 흐려요" in message
    assert "4쪽" not in message
    same = CaptureCheck(ok=False, pages=[CapturePageIssue(index=i, issues=["blurry"], severe=True) for i in (0, 1)])
    assert cc.rejection_message(same).startswith("1·2쪽이 흐려요")


def test_안내에는_이유와_다시_찍는_법이_같이_있다():
    tip = cc.tip_for(["cut_off", "blurry"])  # 여럿이면 먼저 고칠 것(흐림) 하나만
    assert tip.startswith("글자 테두리가 번져 있어요.") and "초점" in tip


@pytest.mark.parametrize("value,expected", [("", "on"), ("warn", "warn"), ("OFF", "off"), ("이상한값", "on")])
def test_CAPTURE_CHECK_스위치(monkeypatch, value, expected):
    monkeypatch.setenv("CAPTURE_CHECK", value)
    assert cc.mode() == expected


def test_warn이면_심해도_거절하지_않고_off면_검사하지_않는다(monkeypatch):
    blank = [("a.jpg", jpeg(Image.new("L", (880, 1200), 255)))]
    monkeypatch.setenv("CAPTURE_CHECK", "warn")
    check = cc.precheck(blank)
    assert check is not None and check.pages[0].severe is True
    assert cc.should_reject(check) is False
    monkeypatch.setenv("CAPTURE_CHECK", "off")
    assert cc.precheck(blank) is None


# ══════════════════════════════════════════════════════════════════════════════
# ④ OCR 뒤 — 쪽 번호가 안 보이면 잘림 의심
# ══════════════════════════════════════════════════════════════════════════════


def _ocr_page(index: int, *, footer: bool, words: bool = True) -> OcrPage:
    rows = [W("1", 66, 150, 11), W("근저당권설정", 117, 150, 91)] if words else []
    if footer:
        rows.append(W("3/5", 800, 1150, 24))
    return OcrPage(name=f"p{index}.jpg", index=index, words=rows, lines=group_lines(rows),
                   width=PAGE_W, height=PAGE_H)


def test_쪽_번호가_안_보이면_잘림_의심을_더한다():
    check = cc.add_ocr_findings(CaptureCheck(), [_ocr_page(0, footer=True), _ocr_page(1, footer=False)], 2)
    assert check is not None and check.ok is False
    assert [(p.index, p.issues, p.severe) for p in check.pages] == [(1, ["cut_off"], False)]
    assert "쪽 번호" in check.pages[0].tip


def test_글자를_못_읽은_장은_글자_없음():
    check = cc.add_ocr_findings(CaptureCheck(), [_ocr_page(0, footer=False, words=False)], 1)
    assert check is not None and check.pages[0].issues == ["no_text"]


def test_분석_전_문제와_OCR_뒤_문제를_한_장에_모은다():
    before = CaptureCheck(ok=False, pages=[CapturePageIssue(index=0, issues=["blurry"], severe=False, tip="x")])
    after = cc.add_ocr_findings(before, [_ocr_page(0, footer=False)], 1)
    assert after is not None and after.pages[0].issues == ["blurry", "cut_off"]
    assert before.pages[0].issues == ["blurry"], "원본을 고치지 않는다"


def test_검사를_껐으면_OCR_뒤에도_말하지_않는다():
    assert cc.add_ocr_findings(None, [_ocr_page(0, footer=False)], 1) is None


# ══════════════════════════════════════════════════════════════════════════════
# ⑤ 엔드포인트 — 거절은 IE·OCR 전에 (크레딧 0원)
# ══════════════════════════════════════════════════════════════════════════════

from tests.test_analyze_smoke import (  # noqa: E402,F401 — pytest 픽스처 재사용
    blank_image,
    client,
    no_network,
    raw_ocr_json,
    registry_raw,
)
from tests.test_highlight import gap_gu_page  # noqa: E402

DEVICE = {"X-Device-Id": "capture-test-device-01"}


def _post(client, images: list[bytes], path: str = "/api/analyze"):
    files = [("files", (f"page_{i + 1}.jpg", data, "image/jpeg")) for i, data in enumerate(images)]
    data = {"deposit": "120000000"} if path == "/api/analyze" else None
    return client.post(path, files=files, data=data, headers=DEVICE)


def test_심하게_흐린_장이_있으면_분석_전에_400_외부_호출_0회(client, no_network, base):
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    blurry = jpeg(base.filter(ImageFilter.GaussianBlur(4.0)))
    resp = _post(client, [blank_image(PAGE_W, PAGE_H), blurry])
    assert resp.status_code == 400
    body = resp.json()
    assert body["detail"].startswith("2쪽이 흐려요 — 다시 찍어 주세요")
    pages = body["captureCheck"]["pages"]
    assert [(p["index"], p["severe"]) for p in pages] == [(1, True)]
    assert pages[0]["tip"]
    assert calls == [], f"거절했는데 외부 API를 불렀다: {calls}"


def test_거절도_분석_횟수_1회로_센다_서버_계산_보호(client, no_network, monkeypatch, base):
    """크레딧은 0원이지만 검사 자체가 서버 계산을 쓴다 — 안 세면 흐린 사진을 끝없이 보내 서버를 붙잡을 수 있다.
    상한에 걸린 요청은 **검사도 하지 않고** 429로 끝난다(싸게 거절)."""
    monkeypatch.setenv("RATE_LIMIT_ANALYZE_PER_HOUR", "2")
    calls = no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    blurry = jpeg(base.filter(ImageFilter.GaussianBlur(4.0)))
    assert _post(client, [blurry]).status_code == 400
    assert _post(client, [blank_image(PAGE_W, PAGE_H)]).status_code == 200
    assert _post(client, [blurry]).status_code == 429
    assert sum(1 for u in calls if "information-extraction" in u) == 1


def test_가벼운_문제는_분석하고_리포트에_싣는다(client, no_network, base):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    soft = jpeg(base.filter(ImageFilter.GaussianBlur(3.0)))
    resp = _post(client, [soft])
    assert resp.status_code == 200, resp.text
    check = resp.json()["captureCheck"]
    assert check["ok"] is False
    page = check["pages"][0]
    assert page["index"] == 0 and "blurry" in page["issues"] and page["severe"] is False
    # 합성 OCR 쪽(gap_gu_page)에는 쪽 번호가 없다 → 잘림 의심도 함께 붙는다
    assert "cut_off" in page["issues"]


def test_선명한_사진이면_검사_결과가_ok다(client, no_network):
    from tests.test_highlight import eul_gu_page

    page = eul_gu_page()
    words = list(page.words) + [W("1/1", 800, 1150, 24)]
    footer_page = OcrPage(name="p.jpg", index=0, words=words, lines=group_lines(words), width=PAGE_W, height=PAGE_H)
    no_network(registry_raw(), [raw_ocr_json(footer_page)])
    resp = _post(client, [blank_image(PAGE_W, PAGE_H)])
    assert resp.status_code == 200, resp.text
    assert resp.json()["captureCheck"] == {"ok": True, "pages": []}


def test_잘_안_읽힌_장이_있으면_양호가_나오지_않는다(client, no_network, base, monkeypatch):
    """2026-10-27 바꿈 — 예전에는 '검사가 판정을 바꾸지 않는다'였다. 이제 잘 안 읽힌 장(흐림·잘림 …)이 있으면
    어떤 카드도 '양호'가 될 수 없다(빠진 글자에 근저당이 있을 수 있다 — 보수적 편향 §2-3). '위험'은 그대로 위험이다."""
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))] * 2)
    sharp = _post(client, [blank_image(PAGE_W, PAGE_H)]).json()
    soft = _post(client, [jpeg(base.filter(ImageFilter.GaussianBlur(3.0)))]).json()
    for body in (sharp, soft):  # 합성 쪽엔 쪽 번호가 없어 둘 다 '아래가 잘림' 장이 있다
        assert body["captureCheck"]["pages"]
        assert body["grade"] != "양호"
        assert all(e["grade"] != "양호" for e in body["evidences"])


def test_대조도_같은_검사를_한다(client, no_network, base):
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    rid = _post(client, [blank_image(PAGE_W, PAGE_H)]).json()["id"]
    resp = _post(client, [jpeg(base.filter(ImageFilter.GaussianBlur(4.0)))], path=f"/api/reports/{rid}/compare")
    assert resp.status_code == 400
    assert resp.json()["captureCheck"]["pages"][0]["severe"] is True


def test_warn_모드에서는_심해도_분석한다(client, no_network, monkeypatch, base):
    monkeypatch.setenv("CAPTURE_CHECK", "warn")
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    resp = _post(client, [jpeg(base.filter(ImageFilter.GaussianBlur(4.0)))])
    assert resp.status_code == 200, resp.text
    assert resp.json()["captureCheck"]["pages"][0]["severe"] is True


def test_촬영_검사를_꺼도_쪽_번호를_못_읽은_장이_있으면_양호가_아니다(client, no_network, monkeypatch):
    """규칙 감사(2026-10-27): 촬영 검사가 꺼졌거나 실패해도(captureCheck 없음) 게이트는 쪽 번호로 막는다."""
    monkeypatch.setenv("CAPTURE_CHECK", "off")
    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    body = _post(client, [blank_image(PAGE_W, PAGE_H)]).json()
    assert body["grade"] != "양호"
    assert all(e["grade"] != "양호" for e in body["evidences"])
    assert body["pageNumbers"] == [None]
