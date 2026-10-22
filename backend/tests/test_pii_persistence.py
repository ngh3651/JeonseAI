"""개인정보 — **화면엔 실명, 서버엔 가린 사본** (2026-10-21 → 2026-10-22 규혁 결정으로 바뀜).

NOW.md P0-2 완료 조건: "서버 저장소·로그에 실명 0건(자동 테스트)". 이 파일이 그 자동 테스트다.

분석 흐름을 끝에서 끝까지 실물로 태운다(목은 HTTP 경계에만 — `test_analyze_smoke.py`와 같은 규칙).
합성 등기부의 소유자는 `홍길동`·`김영희`, 근저당권자 중 한 명은 **개인**(`박사채`)이다. 확인하는 것:

(a) **분석 응답**의 집주인 카드에는 실명 — 사용자가 실제 만난 계약자와 맞춰 본다(2026-10-22부터)
(b) 기록 DB(`${DATA_DIR}/app.db` 와 WAL 조각, 바이트 그대로) · 서버 로그 · 서버가 남긴 JSON 파일에 실명 0
(c) 서버 기록에서 꺼낸 응답(기록 목록·상세·같은 사진 캐시 적중·대조)에는 가린 이름(`홍○○`)
(d) 은행·회사 이름은 그대로 (저장 사본에서도)
(e) 설명을 쓰는 Solar로 가는 입력에 실명 0

⚠ 두 번째 경로(OCR 글자 → Solar 구조화)는 **글자를 읽는** 단계라 OCR 글자를 그대로 보낸다(IE와 같은 성격) —
  (e)는 설명 입력만 본다.
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
def test_분석_응답은_실명이고_서버에_남는_것에는_실명이_없다(
    client, no_network, server_logs, tmp_path, monkeypatch, second_path
):
    """`second_path="upstage"`면 OCR → LLM 구조화 → 교차검증 경로의 로그까지 함께 본다."""
    from app.services import artifacts, explanation, store

    data_dir = tmp_path / "data"
    monkeypatch.setenv("DATA_DIR", str(data_dir))
    monkeypatch.delenv("SAVE_RAW_RESPONSES", raising=False)  # 클라우드 기본값 = 꺼짐
    monkeypatch.setenv("LLM_STRUCTURE_PROVIDER", second_path)
    store.reset()

    # (e) 설명을 쓰는 Solar로 가는 입력을 그대로 모은다
    explain_inputs: list[str] = []
    real_call = explanation._call_solar

    def spy(messages, api_key):
        explain_inputs.append(json.dumps(messages, ensure_ascii=False))
        return real_call(messages, api_key)

    monkeypatch.setattr(explanation, "_call_solar", spy)

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

    # ── (a) 분석 응답 = 실명 ────────────────────────────────────────────────
    # 집주인 하이라이트가 실제로 만들어졌는지부터 — 0건이면 이 테스트는 아무것도 확인하지 못한다
    owner_titles = [h["title"] for h in report["highlights"] if h["kind"] == "owner"]
    assert owner_titles, "집주인 하이라이트가 없다 — 합성 등기부와 IE 목이 어긋났다"
    assert all(t.split(" · ")[1] in ("홍길동", "김영희") for t in owner_titles), owner_titles
    assert set(FULL_NAMES) <= set(report["personNames"]), report["personNames"]
    assert "○○은행" not in report["personNames"]  # 기관은 사람 이름 목록에 넣지 않는다

    # 판례·질문·목록까지 한 바퀴 (판례는 키가 없어 빈 목록/폴백 경로)
    rid = report["id"]
    for path in ("/api/reports", f"/api/reports/{rid}", f"/api/reports/{rid}/questions"):
        assert client.get(path, headers=DEVICE).status_code == 200, path

    # 같은 사진 다시 → 캐시 적중(크레딧 0원) = 서버 기록의 사본
    cached = client.post("/api/analyze", files=files, data={"deposit": "120000000"}, headers=DEVICE)
    assert cached.status_code == 200 and cached.json()["id"] == rid

    # 다시 떼어 대조 → 스냅샷 두 벌이 DB에 남는다
    no_network(_registry_with_private_lender(), [raw_ocr_json(page)])
    resp2 = client.post(f"/api/reports/{rid}/compare", files=files, headers=DEVICE)
    assert resp2.status_code == 200, resp2.text

    # ── (c) 서버 기록에서 꺼낸 응답 = 가린 이름 ────────────────────────────────
    saved = client.get(f"/api/reports/{rid}", headers=DEVICE)
    listing = client.get("/api/reports", headers=DEVICE)
    for label, body in (("기록 상세", saved.text), ("기록 목록", listing.text),
                        ("캐시 적중", cached.text), ("대조", resp2.text)):
        for name in FULL_NAMES:
            assert name not in body, f"{label} 응답에 실명 '{name}'"
    saved_titles = [h["title"] for h in saved.json()["highlights"] if h["kind"] == "owner"]
    assert saved_titles and all(t.split(" · ")[1] in ("홍○○", "김○○") for t in saved_titles), saved_titles
    # (d) 기관 이름이 그대로인지는 아래 저장 사본 단위 테스트가 본다(이 합성 리포트 글자에는 은행 이름이 없다)

    # ── (b) 기록 DB (바이트 그대로 — 압축·인코딩을 거치지 않은 원문에서 찾는다) ──
    db_files = _files_under(data_dir)
    assert any(p.name == "app.db" for p in db_files), db_files
    for path in db_files:
        blob = path.read_bytes()
        for name in FULL_NAMES:
            assert name.encode("utf-8") not in blob, f"{path.name}에 실명 '{name}'"

    # ── (b) 로그 ─────────────────────────────────────────────────────────────
    assert server_logs, "로그를 하나도 못 잡았다 — 로거 연결이 틀렸다"
    joined = "\n".join(server_logs)
    for name in FULL_NAMES:
        assert name not in joined, f"로그에 실명 '{name}'"

    # ── (b) 저장 JSON (진단 저장 꺼짐 → out/runs에 아무것도 없어야 한다) ──────────
    assert not _files_under(artifacts.RUNS_DIR), "진단 저장이 꺼져 있는데 원응답이 남았다"
    for path in [p for p in _files_under(tmp_path) if p.suffix in {".json", ".jsonl"}]:
        text = path.read_text(encoding="utf-8")
        for name in FULL_NAMES:
            assert name not in text, f"{path.name}에 실명 '{name}'"

    # ── (e) 설명(Solar) 입력 = 가린 이름 ──────────────────────────────────────
    assert explain_inputs, "설명 호출이 없었다 — 이 테스트는 Solar 입력을 확인하지 못한다"
    for sent in explain_inputs:
        for name in FULL_NAMES:
            assert name not in sent, f"설명 입력에 실명 '{name}'"


def test_저장_사본은_사람_이름만_가리고_기관_주소는_그대로다():
    """`mask_report_for_storage` — 모든 글자 칸의 사람 이름을 `홍○○`로, 은행·주소는 그대로, 원본은 그대로."""
    from app.schemas.contract import Highlight, HighlightBox, Report
    from app.schemas.internal import RegistryExtract
    from app.services import name_privacy

    raw = _registry_with_private_lender()
    raw["mortgages"][0]["mortgagee"] = "주식회사하나은행"
    extract = RegistryExtract.from_raw(raw)
    names = name_privacy.person_names(extract)
    assert {"홍길동", "김영희", "박사채"} <= set(names)
    assert not any("은행" in n for n in names)

    report = Report.model_validate(
        {
            **_example_report_fields(),
            "address": "서울특별시 ○○구 가나동 1",
            "alias": "홍길동 아저씨 집",
            "highlights": [
                Highlight(id="owner-0", page=0, kind="owner", badge=1,
                          box=HighlightBox(x=0, y=0, w=0.1, h=0.1),
                          title="집주인 이름 · 홍길동", body="").model_dump(),
            ],
            "checkedNotes": ["근저당권자 주식회사하나은행 · 채무자 홍길동 · 개인 근저당권자 박사채"],
            "personNames": names,
        }
    )
    stored = name_privacy.mask_report_for_storage(report)
    text = stored.model_dump_json()
    for name in FULL_NAMES:
        assert name not in text, f"저장 사본에 실명 '{name}'"
    assert stored.highlights[0].title == "집주인 이름 · 홍○○"
    assert stored.alias == "홍○○ 아저씨 집"
    assert "주식회사하나은행" in stored.checkedNotes[0]  # (d) 기관은 그대로
    assert stored.address == report.address
    assert set(stored.personNames) >= {"홍○○", "김○○", "박○○"}
    # 원본(응답)은 그대로 실명, 다시 넣어도 그대로(이미 가린 사본)
    assert report.highlights[0].title == "집주인 이름 · 홍길동"
    assert name_privacy.mask_report_for_storage(stored) == stored


def test_양호라는_이름이_있어도_등급_값은_깨지지_않는다():
    """`grade`는 정해진 말(`위험`·`확인 필요`·`양호`) — 이름 가리기가 건드리면 앱이 등급을 못 읽는다."""
    from app.schemas.contract import Report
    from app.services import name_privacy

    report = Report.model_validate({**_example_report_fields(), "grade": "양호", "headline": "양호 씨 집이에요",
                                    "personNames": ["양호"]})
    stored = name_privacy.mask_report_for_storage(report)
    assert stored.grade == "양호"
    assert stored.headline == "양○ 씨 집이에요"


def test_띄어_쓴_이름_칸도_글자_그대로_가린다():
    """하이라이트 제목은 이름 칸 글자를 그대로 쓴다 — `홍 길동`이면 `홍 길동` 전체를 찾아 가려야 한다."""
    from app.schemas.internal import RegistryExtract
    from app.services import name_privacy

    raw = registry_raw()
    raw["current_owners"] = [{"name": "홍 길동", "share": "1분의 1"}]
    names = name_privacy.person_names(RegistryExtract.from_raw(raw))
    assert "홍 길동" in names
    assert name_privacy.mask_text("집주인 이름 · 홍 길동", names) == "집주인 이름 · 홍○○○"


def _example_report_fields() -> dict:
    """`Report`의 필수 칸만 — 값은 아무거나(판정과 무관한 저장 사본 시험용)."""
    return {
        "id": "analysis-pii-unit",
        "alias": "",
        "address": "",
        "analyzedAt": "2026.10.22",
        "grade": "확인 필요",
        "gaugeProgress": 0.5,
        "deposit": 120_000_000,
        "headline": "확인이 필요해요",
        "nextAction": "",
        "topRiskSummary": "",
        "seniorDebtAmount": 0,
        "evidences": [],
    }


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
