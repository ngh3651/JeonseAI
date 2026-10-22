"""개인정보 — 서버가 **남기는 것**(기록 DB·로그·저장 JSON)에 집주인 실명이 0건인지 (2026-10-21).

NOW.md P0-2 완료 조건: "서버 저장소·로그에 실명 0건(자동 테스트)". 이 파일이 그 자동 테스트다.

분석 흐름을 끝에서 끝까지 실물로 태운다(목은 HTTP 경계에만 — `test_analyze_smoke.py`와 같은 규칙).
합성 등기부의 소유자는 `홍길동`·`김영희`, 근저당권자 중 한 명은 **개인**(`박사채`)이다.
그다음 세 곳을 뒤진다:

1. 기록 DB(`${DATA_DIR}/app.db` 와 WAL 조각) — 바이트 그대로
2. 분석 중 찍힌 서버 로그(`jeonseai` 로거)
3. 서버가 남긴 JSON 파일(`DATA_DIR` 아래 전부 + 진단 저장이 꺼진 상태의 `out/`)

⚠ 응답 본문에도 실명이 없어야 한다(하이라이트 제목 마스킹). 사용자는 **자기 사진**에서
  칠해진 그 자리의 이름을 그대로 볼 수 있다 — 서버가 다시 적어 줄 이유가 없다.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

import pytest

from app.services.formatting import looks_like_institution, mask_person_name
from tests.test_analyze_smoke import (  # noqa: F401 — pytest 픽스처 재사용
    blank_image,
    client,
    no_network,
    raw_ocr_json,
    registry_raw,
)
from tests.test_highlight import PAGE_H, PAGE_W, gap_gu_page

FULL_NAMES = ("홍길동", "김영희", "박사채")
DEVICE = {"X-Device-Id": "pii-test-device-01"}


class _Collect(logging.Handler):
    def __init__(self) -> None:
        super().__init__(level=logging.DEBUG)
        self.lines: list[str] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.lines.append(self.format(record))


@pytest.fixture
def server_logs():
    """`jeonseai` 로거는 propagate=False라 caplog가 못 본다 → 직접 붙인다."""
    logger = logging.getLogger("jeonseai")
    handler = _Collect()
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(handler)
    old_level = logger.level
    logger.setLevel(logging.DEBUG)
    yield handler.lines
    logger.removeHandler(handler)
    logger.setLevel(old_level)


def _registry_with_private_lender() -> dict:
    raw = registry_raw()
    raw["mortgages"] = raw["mortgages"] + [
        {
            "rank_number": 2,
            "max_claim_amount": 20_000_000,
            "receipt_date": "2025-03-02",
            "mortgagee": "박사채",  # 개인 사채 — 이름이 그대로 나가면 안 된다
            "debtor": "홍길동",
            "is_canceled": False,
        }
    ]
    return raw


def _files_under(root: Path) -> list[Path]:
    return [p for p in root.rglob("*") if p.is_file()] if root.exists() else []


@pytest.mark.parametrize("second_path", ["off", "upstage"])
def test_분석해도_기록_DB_로그_저장_JSON에_실명이_없다(
    client, no_network, server_logs, tmp_path, monkeypatch, second_path
):
    """`second_path="upstage"`면 OCR → LLM 구조화 → 교차검증 경로의 로그까지 함께 본다."""
    from app.services import artifacts, store

    data_dir = tmp_path / "data"
    monkeypatch.setenv("DATA_DIR", str(data_dir))
    monkeypatch.delenv("SAVE_RAW_RESPONSES", raising=False)  # 클라우드 기본값 = 꺼짐
    monkeypatch.setenv("LLM_STRUCTURE_PROVIDER", second_path)
    store.reset()

    page = gap_gu_page(0)
    # 두 번째 경로(LLM 구조화)의 목 응답 — 구조화 스키마는 순위번호가 **문자열**이다
    structure = _registry_with_private_lender()
    for m in structure["mortgages"]:
        m["rank_number"] = str(m["rank_number"])
    no_network(_registry_with_private_lender(), [raw_ocr_json(page)], structure=structure)
    files = [("files", ("page_1.jpg", blank_image(PAGE_W, PAGE_H), "image/jpeg"))]
    resp = client.post(
        "/api/analyze", files=files, data={"deposit": "120000000"}, headers=DEVICE
    )
    assert resp.status_code == 200, resp.text
    report = resp.json()
    if second_path != "off":
        assert any("[교차검증:" in line for line in server_logs), "교차검증 경로가 돌지 않았다"
    # 집주인 하이라이트가 실제로 만들어졌는지부터 — 0건이면 이 테스트는 아무것도 확인하지 못한다
    owner_titles = [h["title"] for h in report["highlights"] if h["kind"] == "owner"]
    assert owner_titles, "집주인 하이라이트가 없다 — 합성 등기부와 IE 목이 어긋났다"
    assert all("○" in t for t in owner_titles), owner_titles

    # 판례·질문·목록까지 한 바퀴 (판례는 키가 없어 빈 목록/폴백 경로)
    rid = report["id"]
    for path in ("/api/reports", f"/api/reports/{rid}", f"/api/reports/{rid}/questions"):
        assert client.get(path, headers=DEVICE).status_code == 200, path

    # 다시 떼어 대조 → 스냅샷 두 벌이 DB에 남는다
    no_network(_registry_with_private_lender(), [raw_ocr_json(page)])
    resp2 = client.post(f"/api/reports/{rid}/compare", files=files, headers=DEVICE)
    assert resp2.status_code == 200, resp2.text

    # ── 1. 응답 본문 ─────────────────────────────────────────────────────────
    for body in (resp.text, resp2.text, client.get("/api/reports", headers=DEVICE).text):
        for name in FULL_NAMES:
            assert name not in body, f"응답에 실명 '{name}'"

    # ── 2. 기록 DB (바이트 그대로 — 압축·인코딩을 거치지 않은 원문에서 찾는다) ──
    db_files = _files_under(data_dir)
    assert any(p.name == "app.db" for p in db_files), db_files
    for path in db_files:
        blob = path.read_bytes()
        for name in FULL_NAMES:
            assert name.encode("utf-8") not in blob, f"{path.name}에 실명 '{name}'"

    # ── 3. 로그 ──────────────────────────────────────────────────────────────
    assert server_logs, "로그를 하나도 못 잡았다 — 로거 연결이 틀렸다"
    joined = "\n".join(server_logs)
    for name in FULL_NAMES:
        assert name not in joined, f"로그에 실명 '{name}'"

    # ── 4. 저장 JSON (진단 저장 꺼짐 → out/runs에 아무것도 없어야 한다) ──────────
    assert not _files_under(artifacts.RUNS_DIR), "진단 저장이 꺼져 있는데 원응답이 남았다"
    for path in [p for p in _files_under(tmp_path) if p.suffix in {".json", ".jsonl"}]:
        text = path.read_text(encoding="utf-8")
        for name in FULL_NAMES:
            assert name not in text, f"{path.name}에 실명 '{name}'"


def test_설명_재료의_근저당권자는_개인이면_가린다(no_network, monkeypatch):
    """LLM에 가는 재료(`facts.mortgages`)에서 개인 근저당권자를 가리고, 은행은 그대로 둔다."""
    from app.schemas.internal import RegistryExtract
    from app.services import rule_engine

    extract = RegistryExtract.from_raw(_registry_with_private_lender())
    verdict = rule_engine.evaluate(extract, deposit=120_000_000, market_price=None)
    senior = next(e for e in verdict.evidences if e.id == "senior_debt")
    lenders = [m.get("mortgagee") for m in senior.facts["mortgages"]]
    assert "○○은행" in lenders  # 기관명은 그대로 (설명이 구체적이어야 한다)
    assert "박사채" not in lenders and "박○○" in lenders
    debtors = [m.get("debtor") for m in senior.facts["mortgages"] if m.get("debtor")]
    assert debtors == ["홍○○"]


@pytest.mark.parametrize(
    "name",
    ["주식회사하나은행", "○○저축은행", "△△캐피탈", "(주)가나다대부", "㈜라마바", "□□새마을금고",
     "△△신용협동조합", "한국주택금융공사", "○○농협", "○○보험", "○○신탁", "△△투자증권"],
)
def test_기관명은_그대로_둔다(name):
    assert looks_like_institution(name)
    assert mask_person_name(name) == name


@pytest.mark.parametrize("name,masked", [("박사채", "박○○"), ("홍길동", "홍○○"), ("남궁민수", "남○○○")])
def test_사람_이름은_가린다(name, masked):
    assert not looks_like_institution(name)
    assert mask_person_name(name) == masked


def test_챗봇_로그에_질문_원문이_없다(server_logs):
    """질문에 이름·주소를 적는 사람이 있다 — 로그에는 길이·분류만 남긴다."""
    from app.services import chat

    secret = "홍길동 집주인 서울 어딘가 123 이 집 안전한가요"
    chat.answer(secret)  # 판정 요구 → L1 차단 (LLM 호출 없음)
    chat.answer("오늘 점심 메뉴 추천해줘 김영희")  # 범위 밖 → L3 (LLM 호출 없음)
    joined = "\n".join(server_logs)
    assert "[챗봇]" in joined
    for word in ("홍길동", "김영희", "점심", "어딘가"):
        assert word not in joined, f"챗봇 로그에 질문 원문 '{word}'"


def test_스냅샷_JSON에는_이름_해시만_있다():
    from app.schemas.internal import RegistryExtract
    from app.services import compare, store
    from tests.test_compare import _report

    snap = compare.build_snapshot(
        RegistryExtract.from_raw(_registry_with_private_lender()),
        report=_report("r1"),
        page_count=1,
        manual_market_price=None,
        name_salt=b"x" * 16,
    )
    text = store.snapshot_to_json(snap)
    for name in ("홍길동", "김영희"):
        assert name not in text
    assert json.loads(text)["owner_display"] == "홍○○ 외 1명"
