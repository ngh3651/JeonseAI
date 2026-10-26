"""사진 방향 바로 세우기 + 사진 순서를 앱에 알리기 (2026-10-26 규혁 요청).

1. 가로·거꾸로 찍은 사진 → OCR 결과 모양을 보고 바로 선 방향을 찾아 그 방향으로 읽는다.
   바로 찍은 사진은 **추가 호출 0회**, 못 찾으면 받은 그대로(지금보다 나빠지지 않음).
2. 리포트가 `pageRotations`(장마다 시계 방향 각도)와 `pageOrder`(1쪽부터의 업로드 순서)를 실어 보낸다
   → 앱의 '내 등기부등본 보기'가 1쪽부터 정렬하고 글자가 바로 서게 돌려 그린다.
"""

from __future__ import annotations

import io

import pytest
from PIL import Image, ImageDraw

from app.services import extraction, ocr, orientation
from app.services.ocr_layout import OcrPage

from tests.test_analyze_smoke import blank_image, client, no_network, post_analyze, raw_ocr_json, registry_raw  # noqa: F401
from tests.test_highlight import PAGE_H, PAGE_W, gap_gu_page
from tests.test_page_order import paged

_IE_URL = extraction.UPSTAGE_URL


# ══════════════════════════════════════════════════════════════════════════════
# 재료
# ══════════════════════════════════════════════════════════════════════════════


def dotted(width: int, height: int) -> bytes:
    """글자 줄처럼 보이는 종이 + **왼쪽 위 빨간 점** — 점이 왼쪽 위에 있으면 바로 선 사진이다."""
    with Image.open(io.BytesIO(blank_image(width, height))) as base:
        im = base.convert("RGB")
    ImageDraw.Draw(im).rectangle([4, 4, 40, 40], fill=(230, 20, 20))
    out = io.BytesIO()
    im.save(out, format="JPEG", quality=95)
    return out.getvalue()


def dot_corner(data: bytes) -> str:
    """빨간 점이 어느 모서리에 있나 — 'tl' · 'tr' · 'bl' · 'br'."""
    with Image.open(io.BytesIO(data)) as im:
        rgb = im.convert("RGB")
        w, h = rgb.size
        corners = {"tl": (20, 20), "tr": (w - 21, 20), "bl": (20, h - 21), "br": (w - 21, h - 21)}
        for name, (x, y) in corners.items():
            r, g, b = rgb.getpixel((x, y))
            if r > 180 and g < 90 and b < 90:
                return name
    return "?"


def turned(data: bytes, degrees_cw: int) -> bytes:
    return orientation.rotate_jpeg(data, degrees_cw)


GOOD = raw_ocr_json(gap_gu_page(0))  # 바로 선 등기부 (표지 낱말 여럿, 가로로 긴 낱말, 왼→오)
EMPTY = {"apiVersion": "1.1", "pages": [{"id": 0, "words": []}]}


def sideways_of(raw: dict) -> dict:
    """같은 낱말을 **누운 상자**로 — 누운 사진을 OCR이 그래도 읽었을 때의 모양."""
    out = {"pages": [{"words": []}]}
    for w in raw["pages"][0]["words"]:
        v = w["boundingBox"]["vertices"]
        x0, y0, x1, y1 = v[0]["x"], v[0]["y"], v[2]["x"], v[2]["y"]
        # 90° 누우면 가로·세로가 바뀌고 읽는 방향이 아래로 향한다
        verts = [{"x": y0, "y": x0}, {"x": y0, "y": x1}, {"x": y1, "y": x1}, {"x": y1, "y": x0}]
        out["pages"][0]["words"].append({**w, "boundingBox": {"vertices": verts}})
    return out


def reversed_of(raw: dict) -> dict:
    """같은 낱말을 **오→왼 꼭짓점 순서**로 — 뒤집힌 사진을 OCR이 그래도 읽었을 때의 모양."""
    out = {"pages": [{"words": []}]}
    for w in raw["pages"][0]["words"]:
        v = w["boundingBox"]["vertices"]
        out["pages"][0]["words"].append({**w, "boundingBox": {"vertices": [v[2], v[3], v[0], v[1]]}})
    return out


# ══════════════════════════════════════════════════════════════════════════════
# 모양 읽기 · 돌리기
# ══════════════════════════════════════════════════════════════════════════════


def test_바로_선_등기부는_바로_섰다고_본다():
    shape = orientation.read_shape(GOOD)
    assert shape.markers >= 2
    assert shape.upright


@pytest.mark.parametrize(
    "raw, why",
    [
        (EMPTY, "글자가 없다"),
        (sideways_of(GOOD), "낱말 상자가 세로로 길다(누운 글자)"),
        (reversed_of(GOOD), "읽는 방향이 오→왼(뒤집힌 글자)"),
    ],
)
def test_바로_서지_않은_모양을_알아챈다(raw, why):
    assert not orientation.read_shape(raw).upright, why


def test_시계_방향으로_돌린다_크기와_점_위치():
    data = dotted(300, 400)
    assert dot_corner(data) == "tl"
    r90 = turned(data, 90)
    with Image.open(io.BytesIO(r90)) as im:
        assert im.size == (400, 300)
    assert dot_corner(r90) == "tr", "시계 방향 90°면 왼쪽 위 → 오른쪽 위"
    assert dot_corner(turned(data, 180)) == "br"
    assert dot_corner(turned(data, 270)) == "bl"
    assert turned(data, 0) is data


# ══════════════════════════════════════════════════════════════════════════════
# run_ocr — 방향 찾기
# ══════════════════════════════════════════════════════════════════════════════


@pytest.fixture
def fake_ocr(monkeypatch):
    """점이 왼쪽 위에 있는(=바로 선) 사진에만 등기부를 읽어 주는 가짜 OCR."""
    monkeypatch.setenv("AUTO_ROTATE", "on")
    monkeypatch.setenv("UPSTAGE_API_KEY", "test-key")
    calls: list[str] = []

    def fake(api_key, filename, data):
        corner = dot_corner(data)
        calls.append(corner)
        return GOOD if corner == "tl" else EMPTY

    monkeypatch.setattr(ocr, "call_document_ocr", fake)
    return calls


def test_바로_찍은_사진은_추가_호출_없이_그대로(fake_ocr):
    result = ocr.run_ocr([("page_1.jpg", dotted(PAGE_W, PAGE_H))])
    assert fake_ocr == ["tl"], "한 번만 부른다"
    assert result.pages[0].rotation == 0
    assert result.rotated is False


@pytest.mark.parametrize("how_taken, fix", [(270, 90), (90, 270), (180, 180)])
def test_가로_거꾸로_찍은_사진을_바로_세워_읽는다(fake_ocr, how_taken, fix):
    """`how_taken`만큼 돌아간 채 찍힌 사진 → `fix`만큼 돌려 바로 세운다."""
    photo = turned(dotted(PAGE_W, PAGE_H), how_taken)
    result = ocr.run_ocr([("page_1.jpg", photo)])
    page = result.pages[0]
    assert page.rotation == fix
    assert (page.width, page.height) == (PAGE_W, PAGE_H), "좌표는 바로 선 사진 기준"
    assert dot_corner(result.upright_images[0][1]) == "tl", "다른 경로(IE)가 쓸 사진도 바로 섰다"
    assert len(fake_ocr) <= 4, "장당 최대 3번 더"
    assert result.rotations(1) == [fix]


def test_어느_방향도_아니면_받은_그대로(monkeypatch, fake_ocr):
    monkeypatch.setattr(ocr, "call_document_ocr", lambda *a: fake_ocr.append("x") or EMPTY)
    data = dotted(PAGE_W, PAGE_H)
    result = ocr.run_ocr([("page_1.jpg", data)])
    assert result.pages[0].rotation == 0
    assert result.upright_images[0][1] is data
    assert len(fake_ocr) == 4


def test_추가_호출은_분석_한_번에_상한까지만(monkeypatch, fake_ocr):
    monkeypatch.setattr(ocr, "call_document_ocr", lambda *a: fake_ocr.append("x") or EMPTY)
    ocr.run_ocr([(f"page_{i}.jpg", dotted(PAGE_W, PAGE_H)) for i in range(5)])
    assert len(fake_ocr) == 5 + orientation.MAX_EXTRA_CALLS


def test_끄면_돌려_보지_않는다(monkeypatch, fake_ocr):
    monkeypatch.setenv("AUTO_ROTATE", "off")
    result = ocr.run_ocr([("page_1.jpg", turned(dotted(PAGE_W, PAGE_H), 180))])
    assert len(fake_ocr) == 1
    assert result.pages[0].rotation == 0


# ══════════════════════════════════════════════════════════════════════════════
# /api/analyze — 리포트에 순서·방향이 실린다
# ══════════════════════════════════════════════════════════════════════════════


def test_돌려_세운_장은_pageRotations에_실리고_IE도_바로_선_사진으로_다시_읽는다(client, no_network, monkeypatch):
    monkeypatch.setenv("AUTO_ROTATE", "on")
    monkeypatch.setattr(orientation, "candidate_turns", lambda data: [90, 270, 180])
    calls = no_network(registry_raw(), [EMPTY, GOOD])  # 받은 그대로 → 못 읽음, 90° → 읽음
    photo = turned(dotted(PAGE_W, PAGE_H), 270)
    resp = post_analyze(client, [photo])
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["pageRotations"] == [90]
    assert body["pageOrder"] == []
    assert calls.count(_IE_URL) == 2, "바로 세웠으니 IE도 한 번 더"
    assert body["highlights"], "돌려 세운 사진 기준 좌표로 형광펜이 붙는다"


def test_바로_찍은_사진은_IE를_한_번만(client, no_network, monkeypatch):
    monkeypatch.setenv("AUTO_ROTATE", "on")
    calls = no_network(registry_raw(), [GOOD])
    resp = post_analyze(client, [dotted(PAGE_W, PAGE_H)])
    assert resp.status_code == 200, resp.text
    assert resp.json()["pageRotations"] == [0]
    assert calls.count(_IE_URL) == 1


def test_순서가_뒤바뀐_사진이면_pageOrder로_1쪽부터의_순서를_알린다(client, no_network):
    pages = [paged(0, page_no=3, total=3), paged(1, page_no=1, total=3), paged(2, page_no=2, total=3)]
    no_network(registry_raw(), [raw_ocr_json(p) for p in pages])
    resp = post_analyze(client, [blank_image(PAGE_W, PAGE_H) for _ in pages])
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["pageOrder"] == [1, 2, 0], "2번째로 올린 사진이 1쪽"
    assert body["pageRotations"] == [0, 0, 0]


def test_5_4_3_2_1로_올려도_1쪽부터(client, no_network):
    pages = [paged(i, page_no=5 - i, total=5) for i in range(5)]
    no_network(registry_raw(), [raw_ocr_json(p) for p in pages])
    resp = post_analyze(client, [blank_image(PAGE_W, PAGE_H) for _ in pages])
    assert resp.status_code == 200, resp.text
    assert resp.json()["pageOrder"] == [4, 3, 2, 1, 0]


def test_순서가_맞으면_pageOrder는_비어_있다(client, no_network):
    pages = [paged(i, page_no=i + 1, total=3) for i in range(3)]
    no_network(registry_raw(), [raw_ocr_json(p) for p in pages])
    resp = post_analyze(client, [blank_image(PAGE_W, PAGE_H) for _ in pages])
    assert resp.status_code == 200, resp.text
    assert resp.json()["pageOrder"] == []


def test_OcrPage_기본_회전은_0():
    assert OcrPage(name="a", index=0, words=[], lines=[]).rotation == 0
