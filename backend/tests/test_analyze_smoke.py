"""`/api/analyze` 스모크 — 엔드포인트를 **끝에서 끝까지 진짜 코드로** 관통시킨다.

왜 이 파일이 생겼나 (2026-07-28):
백엔드 테스트 298건이 전부 통과한 상태로 실기기 첫 실행이 500으로 죽었다. 테스트는
계층별로 촘촘했지만 **엔드포인트를 통째로 태우는 테스트가 하나도 없었다.** 계층별
테스트는 각자 자기 이웃을 목으로 대신하므로, 이웃끼리 어긋난 것은 아무도 못 본다.

이 파일의 규칙은 `test_provider_contract.py`와 같다: **목은 HTTP 경계에만.**
`requests.post`만 가로채고 그 위(라우터 → 병렬 실행 → IE 파싱 → OCR 파싱 → 레이아웃
조립 → 사진 묶음 점검 → 순서 정렬 → 교차검증 → 하이라이트 매칭 → 규칙 판정 →
설명 생성 → 리포트 조립)는 전부 실물이다. 크레딧은 1원도 쓰지 않는다.

두 갈래로 둔다 — `tests/test_highlight.py`와 같은 방식이다:
  1. **합성 등기부** (항상 실행): 손으로 만든 좌표. 실명이 없어 저장소에 둘 수 있다.
  2. **저장된 실제 원응답** (`out/runs/<회차>/` 가 있을 때만): 실기기에서 실제로
     500을 낸 바로 그 입력. `out/`은 소유자 실명이 있어 커밋하지 않으므로 없으면 skip.

⚠ 이 파일은 판정값(등급·점수)을 검사하지 않는다 — 그건 `test_rule_engine.py`와
  `test_verdict_regression.py`의 일이다. 여기서 보는 것은 **관통하는가**다.
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import pytest
import requests
from PIL import Image

from app.schemas.internal import Grade
from app.services import artifacts, extraction, ocr as ocr_service
from app.services.llm.prompts import EXPLAIN_SYSTEM_PROMPT
from app.services.ocr_layout import OcrPage

from tests.test_highlight import PAGE_H, PAGE_W, eul_gu_page, gap_gu_page

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
_RUNS_DIR = _BACKEND_ROOT / "out" / "runs"

_IE_URL = extraction.UPSTAGE_URL
_OCR_URL = ocr_service.OCR_URL

#: 등급 문자열을 테스트에 손으로 적지 않는다 — enum이 바뀌면 이 파일도 같이 따라간다.
GRADES = {g.value for g in Grade}


# ══════════════════════════════════════════════════════════════════════════════
# 입력 만들기
# ══════════════════════════════════════════════════════════════════════════════


def blank_image(width: int, height: int) -> bytes:
    """정확한 크기의 실제 JPEG 바이트.

    내용은 비어 있어도 된다 — OCR 응답은 목으로 넣기 때문이다. 하지만 **크기는
    진짜여야 한다**: `ocr._image_size`가 Pillow로 직접 재고, 그 값이 하이라이트
    정규화의 분모다. 1px만 어긋나도 앱에서 좌표가 통째로 밀린다.
    또 `extraction._build_document`가 img2pdf로 진짜 병합을 하므로 유효한 이미지여야 한다.
    """
    buf = io.BytesIO()
    Image.new("RGB", (width, height), "white").save(buf, format="JPEG")
    return buf.getvalue()


def raw_ocr_json(page: OcrPage) -> dict:
    """합성 `OcrPage` → Document OCR 원응답 형태.

    `ocr_layout.parse_words`가 실제로 읽는 모양 그대로 만든다 — 여기서 형태를 대충
    맞추면 `parse_words`를 우회하는 셈이라 스모크의 의미가 없다.
    """
    return {
        "apiVersion": "1.1",
        "modelVersion": "ocr-test",
        "pages": [
            {
                "id": 0,
                "width": page.width,
                "height": page.height,
                "text": " ".join(w.text for w in page.words),
                "words": [
                    {
                        "id": i,
                        "text": w.text,
                        "confidence": w.confidence,
                        "boundingBox": {
                            "vertices": [
                                {"x": w.x0, "y": w.y0},
                                {"x": w.x1, "y": w.y0},
                                {"x": w.x1, "y": w.y1},
                                {"x": w.x0, "y": w.y1},
                            ]
                        },
                    }
                    for i, w in enumerate(page.words)
                ],
            }
        ],
    }


def registry_raw() -> dict:
    """IE 원응답 — 합성 페이지에 실제로 그려져 있는 내용과 맞춘다.

    맞추지 않으면 하이라이트가 0건이 되고, 그러면 "관통했다"는 것만 확인할 뿐
    **좌표가 실제로 붙는지**는 확인하지 못한다.
    """
    return {
        "address": "서울특별시 ○○구 ○○동 123-4",
        "exclusive_area_sqm": 44.2,
        "current_owners": [
            {"name": "홍길동", "share": "2분의 1"},
            {"name": "김영희", "share": "2분의 1"},
        ],
        "ownership_changes": [],
        "provisional_seizures": [],
        "provisional_dispositions": [],
        "seizures": [],
        "auction_commencements": [],
        "trust_registrations": [],
        "mortgages": [
            {"rank_number": 1, "max_claim_amount": 36000000, "mortgagee": "○○은행",
             "is_canceled": False}
        ],
        "jeonse_rights": [],
        "lease_registrations": [],
    }


class _FakeResponse:
    def __init__(self, payload: dict):
        self.status_code = 200
        self._payload = payload
        self.text = ""

    def json(self) -> dict:
        return self._payload


@pytest.fixture
def no_network(monkeypatch, tmp_path):
    """HTTP 경계만 막는다 + 진단 산출물이 `out/`을 건드리지 못하게 한다.

    ⚠ `artifacts`의 경로를 tmp로 돌리는 것이 중요하다. 그러지 않으면 테스트가
      **사용자의 실제 분석 원응답을 지운다**(`prune_runs`는 최근 N회분만 남긴다).
    """
    monkeypatch.setenv("UPSTAGE_API_KEY", "test-key")
    monkeypatch.setenv("LLM_STRUCTURE_PROVIDER", "off")  # 두 번째 경로는 별도 테스트에서
    monkeypatch.setattr(artifacts, "OUT_DIR", tmp_path / "out")
    monkeypatch.setattr(artifacts, "RUNS_DIR", tmp_path / "out" / "runs")

    def _install(
        ie_raw: dict,
        ocr_raws: list[dict],
        explain: dict | None = None,
        structure: dict | None = None,
    ):
        ocr_queue = list(ocr_raws)
        calls: list[str] = []

        def _llm_body(payload: dict) -> dict:
            """설명 생성이냐 구조화냐를 **시스템 프롬프트로** 가른다.

            두 작업이 같은 엔드포인트(`/chat/completions`)를 쓰므로 URL로는 못 가른다.
            서로 다른 스키마를 요구하고(`extra="forbid"`) 한쪽 응답을 다른 쪽에 주면
            검증에서 떨어지므로, 목도 실제와 같은 기준으로 갈라야 한다.
            """
            system = next(
                (m["content"] for m in payload.get("messages", []) if m.get("role") == "system"),
                "",
            )
            if system == EXPLAIN_SYSTEM_PROMPT:
                return explain or {"headline": "확인이 필요해요", "evidences": []}
            return structure if structure is not None else ie_raw

        def fake_post(url, *args, **kwargs):
            calls.append(url)
            if url == _IE_URL:
                return _FakeResponse(
                    {"choices": [{"message": {"content": json.dumps(ie_raw, ensure_ascii=False)}}]}
                )
            if url == _OCR_URL:
                assert ocr_queue, "OCR 목 응답이 모자란다 — 사진 장수와 맞춰라"
                return _FakeResponse(ocr_queue.pop(0))
            if url.endswith("/chat/completions"):
                body = _llm_body(kwargs.get("json") or {})
                return _FakeResponse(
                    {
                        "choices": [
                            {"message": {"content": json.dumps(body, ensure_ascii=False)}}
                        ],
                        "usage": {},
                    }
                )
            raise AssertionError(f"목이 막지 않은 외부 호출: {url}")

        monkeypatch.setattr(requests, "post", fake_post)
        return calls

    return _install


@pytest.fixture
def client():
    from fastapi.testclient import TestClient

    from app.main import app

    return TestClient(app)


def post_analyze(client, images: list[bytes], *, deposit: int = 120_000_000) -> object:
    files = [
        ("files", (f"page_{i + 1}.jpg", data, "image/jpeg")) for i, data in enumerate(images)
    ]
    return client.post("/api/analyze", files=files, data={"deposit": str(deposit)})


# ══════════════════════════════════════════════════════════════════════════════
# ① 합성 등기부 — 항상 실행
# ══════════════════════════════════════════════════════════════════════════════


def test_analyze가_200과_하이라이트를_돌려준다(client, no_network):
    """**이 테스트가 있었으면 오늘 아침 500이 안 났다.**

    라우터부터 리포트 조립까지 한 번에 태운다. 어제 밤 어긋난
    `build_highlights(check=...)`는 이 경로 위에 있었고, `_payload`의 TypeError는
    이 경로 끝의 설명 생성에서 터졌다.
    """
    pages = [gap_gu_page(0), eul_gu_page()]
    pages[1] = OcrPage(  # eul_gu_page는 index 0으로 고정돼 있어 두 번째 장으로 옮긴다
        name="page_2.jpg", index=1, words=pages[1].words, lines=pages[1].lines,
        width=PAGE_W, height=PAGE_H,
    )
    no_network(registry_raw(), [raw_ocr_json(p) for p in pages])

    resp = post_analyze(client, [blank_image(PAGE_W, PAGE_H) for _ in pages])

    assert resp.status_code == 200, resp.text
    report = resp.json()
    assert report["grade"] in GRADES
    assert report["evidences"], "근거 카드가 비었다"
    assert report["highlights"], "하이라이트가 한 건도 붙지 않았다 — 좌표 경로가 죽어 있다"

    # 좌표는 0~1 정규화 값이어야 한다 (앱이 그대로 곱해 그린다)
    for h in report["highlights"]:
        box = h["box"]
        assert 0.0 <= box["x"] <= 1.0 and 0.0 <= box["y"] <= 1.0, f"정규화 밖: {box}"
        assert 0 <= h["page"] < len(pages), f"없는 쪽을 가리킨다: {h['page']}"


def test_설명_생성이_코드_버그로_터져도_200이_나온다(client, no_network, monkeypatch):
    """오늘 500의 **정확한 재현**이다.

    어제는 `_payload()` 시그니처 불일치가 TypeError를 냈고, 폴백이 API 오류만 잡아서
    **리포트가 이미 완성된 채로** 요청 전체가 죽었다. 이제는 어떤 예외든 폴백으로 간다.
    사용자에게는 네트워크 실패든 우리 오타든 똑같이 "안 나온 화면"이기 때문이다.
    """
    from app.services import explanation

    def exploding_call(messages, api_key):
        raise TypeError("_payload() takes 4 positional arguments but 5 were given")

    monkeypatch.setattr(explanation, "_call_solar", exploding_call)

    page = gap_gu_page(0)
    no_network(registry_raw(), [raw_ocr_json(page)])
    resp = post_analyze(client, [blank_image(PAGE_W, PAGE_H)])

    assert resp.status_code == 200, resp.text
    report = resp.json()
    assert report["headline"], "폴백 문구조차 없다"
    assert report["evidences"], "설명이 실패해도 근거 카드는 나와야 한다"


def test_하이라이트_매칭이_터져도_리포트는_완성된다(client, no_network, monkeypatch):
    """표시 계층은 분석을 죽이지 못한다 — 좌표만 빠지고 리포트는 나온다."""
    from app.services import highlight

    def exploding(*args, **kwargs):
        raise RuntimeError("좌표 매칭 중 예기치 못한 실패")

    monkeypatch.setattr(highlight, "build_highlights", exploding)

    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    resp = post_analyze(client, [blank_image(PAGE_W, PAGE_H)])

    assert resp.status_code == 200, resp.text
    assert resp.json()["highlights"] == []


def test_이력_저장이_터져도_리포트는_응답으로_나간다(client, no_network, monkeypatch):
    """리포트가 완성된 **뒤**의 실패로 리포트를 잃지 않는다."""
    from app.services import store

    monkeypatch.setattr(store, "add", lambda report: (_ for _ in ()).throw(OSError("디스크")))

    no_network(registry_raw(), [raw_ocr_json(gap_gu_page(0))])
    resp = post_analyze(client, [blank_image(PAGE_W, PAGE_H)])

    assert resp.status_code == 200, resp.text
    assert resp.json()["grade"] in GRADES


def test_두_번째_경로가_켜져도_관통한다(client, no_network, monkeypatch):
    """구조화(경로 ③) + 교차검증 고지까지 포함해 태운다.

    `LLM_STRUCTURE_PROVIDER=off`로 돌리는 위 테스트들은 이 경로를 건너뛴다 —
    실기기 로그의 `[LLM:upstage] 구조화 실패`가 바로 여기였으므로 따로 태운다.
    """
    monkeypatch.setenv("LLM_STRUCTURE_PROVIDER", "upstage")
    page = gap_gu_page(0)
    no_network(registry_raw(), [raw_ocr_json(page)], explain=None)

    resp = post_analyze(client, [blank_image(PAGE_W, PAGE_H)])
    assert resp.status_code == 200, resp.text
    # 두 번째 경로 결과가 무엇이든 **판정 필드는 존재하고 정상 범위**여야 한다
    assert resp.json()["grade"] in GRADES


# ══════════════════════════════════════════════════════════════════════════════
# ② 저장된 실제 원응답 — 실기기에서 500을 낸 그 입력
# ══════════════════════════════════════════════════════════════════════════════


def _saved_runs() -> list[Path]:
    if not _RUNS_DIR.is_dir():
        return []
    return sorted(
        p for p in _RUNS_DIR.iterdir()
        if p.is_dir() and (p / "ie.json").exists() and list(p.glob("ocr_*.json"))
    )


@pytest.mark.skipif(not _saved_runs(), reason="out/runs/ 원응답 없음 (실명 포함이라 커밋 안 함)")
def test_저장된_실제_원응답으로_analyze가_200을_준다(client, no_network):
    """크레딧 0원 재현 — 저장된 IE·OCR 원응답을 그대로 다시 흘려보낸다.

    다시 만들려면 실호출 1회 후 `backend/out/runs/<회차>/`를 쓴다(개발 모드에서 자동 저장).
    """
    run = _saved_runs()[-1]
    ie_raw = json.loads((run / "ie.json").read_text(encoding="utf-8"))
    ocr_files = sorted(run.glob("ocr_*.json"), key=lambda p: p.name)
    ocr_raws = [json.loads(p.read_text(encoding="utf-8")) for p in ocr_files]

    # 사진은 **저장된 응답이 말하는 크기 그대로** 만든다 — 정규화 분모가 실제와 같아진다
    sizes = [
        (raw["pages"][0]["width"], raw["pages"][0]["height"])
        for raw in ocr_raws
    ]
    no_network(ie_raw, ocr_raws)

    resp = post_analyze(client, [blank_image(w, h) for w, h in sizes])

    assert resp.status_code == 200, resp.text
    report = resp.json()
    assert report["grade"] in GRADES
    assert report["evidences"], "근거 카드가 비었다"
    # 실제 등기부라 하이라이트가 0건일 수는 있다(전부 말소된 경우) — 그때는 **반드시**
    # 이유를 말해야 한다. 침묵이 신뢰를 깎는다는 것이 페르소나 2인의 공통 지적이었다.
    assert report["highlights"] or report["checkedNotes"], "표시도 설명도 없이 침묵한다"


# ══════════════════════════════════════════════════════════════════════════════
# ③ 판례 엔드포인트 — 밖이 끊겨도 화면을 깨뜨리지 않는다 (2026-08-14 D7)
# ══════════════════════════════════════════════════════════════════════════════


def test_판례_매칭이_터져도_500이_아니라_빈_목록이_나온다(client, monkeypatch):
    """촬영 중 크레딧이 끊겨도 심사위원에게 보일 것은 에러 화면이 아니어야 한다.

    판례 경로는 임베딩 호출 → 벡터 검색 → Solar 설명으로 이어져 밖에서 끊길 자리가
    많다. 끊기면 지금까지는 500이 나가 리포트에서 넘어온 화면이 통째로 에러로 덮였다.
    빈 목록이면 앱은 "이 매물의 위험과 딱 맞는 판례가 아직 없어요. 위험이 없다는
    뜻은 아니니…"를 띄운다(case_match_screen.dart) — 그쪽이 훨씬 정직한 화면이다.
    """
    from app.routers import reports as reports_router
    from app.services import store

    report_id = next(iter(store.EXAMPLE_IDS))
    # 앞선 테스트가 남긴 캐시를 비운다 — 캐시가 있으면 아래 예외 경로에 닿지도 못한다.
    store._cases_cache.pop(report_id, None)

    def boom():
        raise RuntimeError("임베딩 크레딧 소진 (테스트에서 일부러 냄)")

    monkeypatch.setattr(reports_router.precedent_service, "get_service", boom)

    resp = client.get(f"/api/reports/{report_id}/cases")

    assert resp.status_code == 200, resp.text
    assert resp.json() == []


def test_실패한_판례_결과는_캐시되지_않는다(client, monkeypatch):
    """캐시하면 원인이 사라진 뒤에도 이 리포트만 영원히 '판례 없음'으로 굳는다."""
    from app.routers import reports as reports_router
    from app.services import store

    report_id = next(iter(store.EXAMPLE_IDS))
    store._cases_cache.pop(report_id, None)

    def boom():
        raise RuntimeError("일시적 실패")

    monkeypatch.setattr(reports_router.precedent_service, "get_service", boom)
    assert client.get(f"/api/reports/{report_id}/cases").json() == []

    assert store.get_cases(report_id) is None, "실패 결과가 캐시에 남았다 — 복구가 막힌다"
