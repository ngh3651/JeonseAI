"""등기부 대조(S-11) — **네 갈래가 각각 제 조건에서만 나오는지** 못 박는다.

왜 이 파일이 중요한가:
대조 결과는 사용자가 **잔금을 보낼지 말지**를 정하는 화면이다. 여기서 가장 나쁜 실패는
"달라진 게 없어요"가 틀리는 것 — 못 본 것을 안 변한 것으로 말하는 순간, 화면은 그
사람의 보증금을 지키는 대신 안심시킨다. 그래서 아래 세 경계를 테스트로 굳힌다:

1. 못 읽은 항목은 `same`이 아니라 `unknown`이다 (침묵 금지).
2. 다른 집이면 숫자를 **아예 내보내지 않는다** (`different_property`).
3. 스냅샷에 **소유자 실명이 남지 않는다**.

⚠ 판정(등급)은 검사하지 않는다 — 그건 `test_rule_engine.py`의 일이다. 여기서 보는 것은
  두 등급을 **나란히 놓는 방식**이다.
"""

from __future__ import annotations

import json

import pytest

from app.schemas.contract import Report
from app.schemas.internal import RegistryExtract
from app.services import compare, journey, store

from tests.test_analyze_smoke import (  # noqa: F401 — pytest 픽스처 재사용
    blank_image,
    client,
    no_network,
    raw_ocr_json,
    registry_raw,
)
from tests.test_highlight import PAGE_H, PAGE_W, gap_gu_page


# ══════════════════════════════════════════════════════════════════════════════
# 재료
# ══════════════════════════════════════════════════════════════════════════════


def _report(report_id: str, *, grade: str = "확인 필요", viewed_at: str | None = "2026.07.09") -> Report:
    return Report(
        id=report_id,
        alias="정자동 빌라",
        address="경기 성남시 분당구 정자동 456-7",
        analyzedAt="2026-07-27T10:00:00+09:00",
        grade=grade,
        gaugeProgress=0.5,
        headline="확인이 필요해요",
        nextAction="확인 후 결정하세요",
        topRiskSummary="예시",
        deposit=300_000_000,
        seniorDebtAmount=0,
        evidences=[],
        registryViewedAt=viewed_at,
    )


def _extract(**overrides) -> RegistryExtract:
    raw = {
        "unique_number": "1355-1996-123456",
        "address": "경기 성남시 분당구 정자동 456-7",
        "exclusive_area_sqm": 59.8,
        "current_owners": [{"name": "김철수", "share": "단독"}],
        "ownership_changes": [],
        "provisional_seizures": [],
        "provisional_dispositions": [],
        "seizures": [],
        "auction_commencements": [],
        "trust_registrations": [],
        "mortgages": [],
        "jeonse_rights": [],
        "lease_registrations": [],
    }
    raw.update(overrides)
    return RegistryExtract.from_raw(raw)


def _snapshot(
    extract: RegistryExtract,
    *,
    report_id: str = "base",
    grade: str = "확인 필요",
    viewed_at: str | None = "2026.07.09",
    page_count: int = 5,
) -> compare.RegistrySnapshot:
    return compare.build_snapshot(
        extract,
        report=_report(report_id, grade=grade, viewed_at=viewed_at),
        page_count=page_count,
        manual_market_price=None,
    )


def _row(result, kind: str):
    return next((r for r in result.rows if r.kind == kind), None)


# ══════════════════════════════════════════════════════════════════════════════
# ① 변동 발견
# ══════════════════════════════════════════════════════════════════════════════


def test_새로_생긴_근저당을_금액과_접수일까지_짚는다():
    base = _snapshot(_extract())
    current = _snapshot(
        _extract(
            mortgages=[
                {
                    "rank_number": "3",
                    "max_claim_amount": 120_000_000,
                    "receipt_date": "2026-08-01",
                    "is_canceled": False,
                }
            ]
        ),
        report_id="current",
        grade="위험",
        viewed_at="2026.08.05",
    )

    result = compare.compare(base, current)

    assert result.result == "changed"
    added = _row(result, "added")
    assert added is not None, "새 근저당이 잡히지 않았다"
    assert "1억 2,000만원" in added.detail
    assert added.receiptDate == "2026-08-01", "접수일이 없으면 앱이 '계약서 쓴 다음 날'을 말할 수 없다"
    assert result.daysBetween == 27, "두 서류 날짜 차이를 세지 못했다"


def test_등급이_내려가면_안전도_행이_danger로_나간다():
    base = _snapshot(_extract(), grade="확인 필요")
    current = _snapshot(_extract(), report_id="current", grade="위험", viewed_at="2026.08.05")

    grade_row = _row(compare.compare(base, current), "grade")

    assert grade_row is not None
    assert grade_row.tone == "danger"
    assert (grade_row.gradeBefore, grade_row.gradeAfter) == ("확인 필요", "위험")


def test_안_변한_것도_함께_보여준다():
    """변한 것만 나열하면 '나머지는 앱이 안 봤나?'로 읽힌다 (S-11 원칙)."""
    base = _snapshot(_extract())
    current = _snapshot(_extract(), report_id="current", viewed_at="2026.08.05")

    result = compare.compare(base, current)

    same_titles = [r.title for r in result.rows if r.kind == "same"]
    assert any("집주인" in t for t in same_titles)
    assert any("압류" in t for t in same_titles)
    assert result.headline == "달라진 점은 없었어요"
    assert "한 번 더 확인" in (result.subline or ""), "변동 없음을 '안전하다'로 말하면 안 된다"


def test_순위번호를_한쪽만_읽어도_같은_근저당으로_본다():
    """IE는 같은 서류에서도 `rank_number`를 읽을 때가 있고 못 읽을 때가 있다.

    그걸 지문에 넣으면 **같은 근저당이 '없어진 것 + 새로 생긴 것'으로 갈라져**
    있지도 않은 새 빚을 경고한다. 접수일·금액이 같으면 같은 항목이다.
    """
    mortgage = {
        "max_claim_amount": 50_000_000,
        "receipt_date": "2025-03-14",
        "is_canceled": False,
    }
    base = _snapshot(_extract(mortgages=[{**mortgage, "rank_number": "2"}]))
    current = _snapshot(_extract(mortgages=[mortgage]), report_id="current")

    result = compare.compare(base, current)

    assert _row(result, "added") is None, "순위번호 유무만으로 새 빚이 생겼다고 말했다"
    assert _row(result, "removed") is None


def test_말소된_근저당은_새로_생긴_것으로_세지_않는다():
    canceled = {
        "rank_number": "3",
        "max_claim_amount": 120_000_000,
        "receipt_date": "2026-08-01",
        "is_canceled": True,
    }
    base = _snapshot(_extract())
    current = _snapshot(_extract(mortgages=[canceled]), report_id="current")

    assert _row(compare.compare(base, current), "added") is None


def test_집주인이_바뀌면_실명_없이_알린다():
    base = _snapshot(_extract())
    current = _snapshot(
        _extract(current_owners=[{"name": "이영희", "share": "단독"}]), report_id="current"
    )

    result = compare.compare(base, current)
    changed = _row(result, "changed")

    assert changed is not None and "집주인" in changed.title
    assert "이영희" not in json.dumps(result.model_dump(), ensure_ascii=False)
    assert "이○○" in changed.detail


# ══════════════════════════════════════════════════════════════════════════════
# ② 일부 대조 불가 — **침묵 금지**
# ══════════════════════════════════════════════════════════════════════════════


def test_빚_항목을_못_읽으면_그대로가_아니라_대조_불가다():
    base = _snapshot(_extract())
    partial_raw = {
        "unique_number": "1355-1996-123456",
        "address": "경기 성남시 분당구 정자동 456-7",
        "current_owners": [{"name": "김철수", "share": "단독"}],
        # mortgages·jeonse_rights·lease_registrations 키 자체가 없다 = 그 쪽을 못 봤다
        "seizures": [],
        "provisional_seizures": [],
        "provisional_dispositions": [],
        "auction_commencements": [],
        "trust_registrations": [],
        "ownership_changes": [],
    }
    current = _snapshot(
        RegistryExtract.from_raw(partial_raw), report_id="current", page_count=3
    )

    result = compare.compare(base, current)

    assert result.result == "partial"
    unknown_titles = [r.title for r in result.rows if r.kind == "unknown"]
    assert any("빚" in t for t in unknown_titles)
    # 빚을 못 봤으면 등급도 견주지 않는다 — 등급은 빚 위에 서 있다
    assert any("안전도" in t for t in unknown_titles)
    assert not any("빚" in r.title and r.kind == "same" for r in result.rows)


def test_못_본_항목에는_행동_버튼이_붙는다():
    """경고 문구 뒤에는 반드시 행동 버튼 (S-11 원칙)."""
    base = _snapshot(_extract())
    current = _snapshot(
        RegistryExtract.from_raw(
            {"address": "경기 성남시 분당구 정자동 456-7", "current_owners": [{"name": "김철수"}]}
        ),
        report_id="current",
        page_count=3,
    )

    rows = [r for r in compare.compare(base, current).rows if r.kind == "unknown"]

    assert rows, "못 본 항목이 하나도 안 잡혔다"
    assert any(r.action == "recapture" and r.actionLabel for r in rows)


def test_같은_집인지_확인_못_하면_일부_대조_불가로_떨어진다():
    base = _snapshot(_extract(unique_number=None, address="경기 성남시 분당구 정자동 456-7"))
    current = _snapshot(
        _extract(unique_number=None, address=None), report_id="current"
    )

    result = compare.compare(base, current)

    assert result.result == "partial"
    assert result.identityBasis is None
    assert any("같은 집인지" in n for n in result.notices)


# ══════════════════════════════════════════════════════════════════════════════
# ③ 다른 집 차단
# ══════════════════════════════════════════════════════════════════════════════


def test_고유번호가_다르면_숫자를_아예_내보내지_않는다():
    base = _snapshot(_extract())
    current = _snapshot(
        _extract(
            unique_number="1355-1996-999999",
            address="서울 강남구 역삼동 123-45",
            mortgages=[{"max_claim_amount": 500_000_000, "is_canceled": False}],
        ),
        report_id="current",
        grade="위험",
    )

    result = compare.compare(base, current)

    assert result.result == "different_property"
    assert result.rows == [], "다른 집인데 대조 행을 그렸다"
    assert result.current.grade is None, "다른 집의 등급을 내보내면 그 집 판정으로 읽힌다"
    assert result.newReportId is None
    assert result.identityBasis == "고유번호"


def test_주소_표기가_달라도_번지가_같으면_같은_집이다():
    """'서울 강남구 역삼동 123-45' ↔ '서울특별시 강남구 역삼동 123-45' 는 같은 집이다."""
    assert compare.address_relation(
        "서울 강남구 역삼동 123-45", "서울특별시 강남구 역삼동 123-45"
    ) == "same"
    assert compare.address_relation("서울 강남구 역삼동 123-45", "서울 강남구 대치동 987-6") == "different"
    assert compare.address_relation("서울 강남구 역삼동 123-45", None) == "unclear"


def test_주소가_같아도_전용면적이_다르면_다른_집으로_본다():
    base = _snapshot(_extract(unique_number=None))
    current = _snapshot(
        _extract(unique_number=None, exclusive_area_sqm=84.9), report_id="current"
    )

    assert compare.compare(base, current).result == "different_property"


# ══════════════════════════════════════════════════════════════════════════════
# ④ 기준 없음 + 개인정보
# ══════════════════════════════════════════════════════════════════════════════


def test_기준이_없으면_초대_톤으로_말한다():
    result = compare.no_baseline_result(_report("old"))

    assert result.result == "no_baseline"
    assert result.rows == []
    # 비난이 아니라 초대 — 경고색 문구('위험'·'주의')를 쓰지 않는다
    assert "위험" not in result.headline and "주의" not in result.headline
    assert "기준을 만들어" in (result.subline or "")


def test_스냅샷에_소유자_실명이_남지_않는다():
    snapshot = _snapshot(_extract(current_owners=[{"name": "김철수"}, {"name": "박영수"}]))

    dumped = repr(snapshot)

    assert "김철수" not in dumped and "박영수" not in dumped
    assert snapshot.owner_display == "김○○ 외 1명"


# ══════════════════════════════════════════════════════════════════════════════
# ⑤ 엔드포인트 — 라우터부터 규칙까지 실물로 관통 (크레딧 0원)
# ══════════════════════════════════════════════════════════════════════════════


def _post_compare(client, images: list[bytes]):
    files = [
        ("files", (f"page_{i + 1}.jpg", data, "image/jpeg")) for i, data in enumerate(images)
    ]
    return files


def test_기준이_없는_리포트는_사진_없이도_기준없음을_돌려준다(client):
    """찍게 해 놓고 마지막에 '못 한다'고 말하지 않는다 — 사진 요청 전에 답한다."""
    report_id = next(iter(store.EXAMPLE_IDS))

    resp = client.post(f"/api/reports/{report_id}/compare")

    assert resp.status_code == 200, resp.text
    assert resp.json()["result"] == "no_baseline"


def test_없는_리포트를_대조하면_404다(client):
    assert client.post("/api/reports/없는id/compare").status_code == 404


def test_분석하고_다시_떼면_새_빚을_찾아낸다(client, no_network):
    """분석 → (근저당 1건 늘어난 서류로) 대조 → `changed`. 두 등급 모두 규칙 엔진 산출물이다."""
    page = gap_gu_page(0)
    no_network(registry_raw(), [raw_ocr_json(page)])
    first = client.post(
        "/api/analyze",
        files=_post_compare(client, [blank_image(PAGE_W, PAGE_H)]),
        data={"deposit": "120000000"},
    )
    assert first.status_code == 200, first.text
    base_report = first.json()
    assert base_report["comparable"] is True, "분석하면 다음 대조의 기준이 되어야 한다"

    # 같은 집(주소 동일) + 근저당 1건 추가된 서류
    raw = registry_raw()
    raw["mortgages"] = raw["mortgages"] + [
        {
            "rank_number": 2,
            "max_claim_amount": 120_000_000,
            "receipt_date": "2026-08-01",
            "mortgagee": "△△캐피탈",
            "is_canceled": False,
        }
    ]
    no_network(raw, [raw_ocr_json(page)])

    resp = client.post(
        f"/api/reports/{base_report['id']}/compare",
        files=_post_compare(client, [blank_image(PAGE_W, PAGE_H)]),
    )

    assert resp.status_code == 200, resp.text
    result = resp.json()
    assert result["result"] == "changed"
    assert any(r["kind"] == "added" for r in result["rows"])
    assert result["newReportId"], "이번에 뗀 서류의 리포트 id가 없으면 앱이 새 리포트로 갈 수 없다"


def test_다른_집_서류로_대조하면_이력에도_남지_않는다(client, no_network):
    page = gap_gu_page(0)
    no_network(registry_raw(), [raw_ocr_json(page)])
    base = client.post(
        "/api/analyze",
        files=_post_compare(client, [blank_image(PAGE_W, PAGE_H)]),
        data={"deposit": "120000000"},
    ).json()

    other = registry_raw()
    other["address"] = "부산 해운대구 우동 999-9"
    other["unique_number"] = "2741-2020-000111"
    no_network(other, [raw_ocr_json(page)])
    before = len(client.get("/api/reports").json())

    resp = client.post(
        f"/api/reports/{base['id']}/compare",
        files=_post_compare(client, [blank_image(PAGE_W, PAGE_H)]),
    )

    assert resp.json()["result"] == "different_property"
    after = client.get("/api/reports").json()
    assert len(after) == before, "다른 집 분석이 이력에 남았다 — 기준 매물 보증금으로 계산된 등급이다"


def test_기준이_있는데_사진이_없으면_400이다(client, no_network):
    page = gap_gu_page(0)
    no_network(registry_raw(), [raw_ocr_json(page)])
    base = client.post(
        "/api/analyze",
        files=_post_compare(client, [blank_image(PAGE_W, PAGE_H)]),
        data={"deposit": "120000000"},
    ).json()

    assert client.post(f"/api/reports/{base['id']}/compare").status_code == 400


# ══════════════════════════════════════════════════════════════════════════════
# ⑥ 여정 단계 — 큐레이션 파일이 화면 동작을 정한다
# ══════════════════════════════════════════════════════════════════════════════


def test_여정_단계는_데이터_파일에서_온다():
    stages = journey.load_stages()

    assert len(stages) == 9, "계약 여정은 9단계다 (data/journey_stages.json)"
    assert stages[0].kind == "analysis", "1단계는 분석 기록으로 자동 완료되는 단계다"
    balance = next(s for s in stages if s.dateKey == "balance")
    assert balance.compare, "잔금일에 [다시 떼서 대조하기]가 없으면 이 화면의 존재 이유가 사라진다"
    assert sum(1 for s in stages if s.compare) == 4, "등기부를 다시 떼는 단계는 2·3·4·6단계다"


def test_단계_파일이_깨져도_화면은_산다(monkeypatch, tmp_path):
    broken = tmp_path / "journey_stages.json"
    broken.write_text("{ 이건 JSON이 아니다 ", encoding="utf-8")
    monkeypatch.setattr(journey, "_STAGES_PATH", broken)

    stages = journey.load_stages()

    assert stages, "파일이 깨졌다고 여정 탭이 빈 화면이 되면 안 된다"
    assert any(s.dateKey == "balance" for s in stages)


@pytest.mark.parametrize("bad", ["없는kind", "", "ACTION"])
def test_kind_칸을_잘못_적으면_action으로_떨어진다(bad, monkeypatch, tmp_path):
    path = tmp_path / "journey_stages.json"
    path.write_text(
        json.dumps(
            {"stages": [{"title": "т", "subtitle": "s", "kind": bad, "items": []}]},
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(journey, "_STAGES_PATH", path)

    assert journey.load_stages()[0].kind == "action"
