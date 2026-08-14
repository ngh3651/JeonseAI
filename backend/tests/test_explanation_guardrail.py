"""E-2 가드레일 봉인 — LLM(통역사)이 판정을 바꿀 수 없음을 테스트로 강제한다.

핵심: 목(mock) LLM이 {"grade": "양호"} 같은 판정 조작을 끼워 보내도
최종 Report의 판정([판정] 필드)은 규칙 엔진 결과에서 한 글자도 변하지 않는다.
(실 API 호출 없음 — _call_solar를 목으로 대체)
"""

import json
import re
from pathlib import Path

import pytest
import requests

from app.schemas.internal import Grade, RegistryExtract
from app.services import explanation, fallback_texts, report_builder, rule_engine

FIXTURES = Path(__file__).parent / "fixtures" / "registry"


def load_fixture(name: str) -> dict:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


@pytest.fixture
def danger_case():
    """근저당 과다(위험) 케이스 — 판정 조작 시도가 가장 티 나는 대상."""
    data = load_fixture("mortgage_heavy")
    extract = RegistryExtract.from_raw(data["registry"])
    verdict = rule_engine.evaluate(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"]["market_price"],
        blacklist_entries=data["blacklist"],
    )
    return data, extract, verdict


@pytest.fixture
def solar_key(monkeypatch):
    """generate()가 호출 경로로 들어가게 가짜 키 설정 (_call_solar는 목으로 대체됨)."""
    monkeypatch.setenv("UPSTAGE_API_KEY", "test-key")


def valid_content(verdict, *, headline="빚이 커서 보증금 회수가 어려울 수 있어요"):
    return json.dumps(
        {
            "headline": headline,
            "evidences": [
                {"id": e.id, "easy_explanation": f"{e.id} 항목 설명이에요. 확인이 필요해요."}
                for e in verdict.evidences
            ],
        },
        ensure_ascii=False,
    )


# ── ① 판정 조작 차단 ─────────────────────────────────────────────────────────


def test_tampered_payload_with_grade_key_falls_back(monkeypatch, solar_key, danger_case):
    """LLM이 grade·gaugeProgress를 실어 보내면 extra='forbid'가 거부 → 폴백."""
    data, extract, verdict = danger_case
    tampered = json.dumps(
        {
            "grade": "양호",  # 판정 조작 시도
            "gaugeProgress": 0.95,
            "headline": "아주 안전한 집이에요",
            "top_risk_summary": "위험 없음",
            "evidences": [],
        },
        ensure_ascii=False,
    )
    calls: list[int] = []

    def mock_call(messages, api_key):
        calls.append(1)
        return tampered

    monkeypatch.setattr(explanation, "_call_solar", mock_call)

    result = explanation.generate(verdict)
    assert result.source == "폴백"  # 조작 페이로드는 통째로 거부된다
    assert len(calls) == 2  # 최초 1회 + 재시도 1회 후 폴백
    assert result.texts["headline"] == fallback_texts.HEADLINES[verdict.grade]

    # Report 조립까지 가도 판정은 규칙 엔진 값 그대로
    report = report_builder.build_report(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"]["market_price"],
        alias=None,
    )
    assert report.grade == "위험"
    assert report.gaugeProgress == verdict.gauge_progress
    assert report.seniorDebtAmount == verdict.senior_debt_amount


def test_valid_payload_merges_but_verdict_fields_untouched(monkeypatch, solar_key, danger_case):
    """정상 응답이어도 LLM이 채우는 건 설명 슬롯뿐 — 판정 필드는 verdict에서만 복사."""
    data, extract, verdict = danger_case
    monkeypatch.setattr(explanation, "_call_solar", lambda m, k: valid_content(verdict))

    result = explanation.generate(verdict)
    assert result.source == "AI 생성"
    assert result.texts["headline"] == "빚이 커서 보증금 회수가 어려울 수 있어요"
    # nextAction·topRiskSummary는 결정적 템플릿 유지 (decisions.md 2026-07-07 + 하네스 조치)
    assert result.texts["next_action"] == fallback_texts.NEXT_ACTIONS[verdict.grade]
    assert result.texts["top_risk_summary"] == fallback_texts.top_risk_summary(verdict)

    report = report_builder.build_report(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"]["market_price"],
        alias=None,
    )
    # build_report는 실제 명단 파일 경로로 평가하므로, 같은 조건의 verdict로 대조한다
    verdict_for_report = rule_engine.evaluate(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"]["market_price"],
    )
    verdict_by_id = {e.id: e for e in verdict_for_report.evidences}
    assert report.grade == verdict_for_report.grade.value
    for ev in report.evidences:
        assert ev.grade == verdict_by_id[ev.id].grade.value  # [판정] 불변
        assert ev.detailText == verdict_by_id[ev.id].detail_text
        assert "설명이에요" in ev.easyExplanation  # [설명]만 LLM 문구


# ── ② 금지어·부분 폴백 ───────────────────────────────────────────────────────


def test_banned_phrase_replaced_field_level(monkeypatch, solar_key, danger_case):
    """'안전합니다' 단정이 섞인 필드만 폴백으로 치환 — 나머지 LLM 문구는 유지."""
    _, _, verdict = danger_case
    payload = json.loads(valid_content(verdict))
    payload["evidences"][0]["easy_explanation"] = "이 집은 안전합니다. 걱정 마세요."
    bad_id = payload["evidences"][0]["id"]
    monkeypatch.setattr(
        explanation, "_call_solar", lambda m, k: json.dumps(payload, ensure_ascii=False)
    )

    result = explanation.generate(verdict)
    assert result.source == "AI 생성(일부 폴백)"
    base = fallback_texts.build(verdict)
    assert result.texts["evidences"][bad_id]["easy_explanation"] == base["evidences"][bad_id]["easy_explanation"]
    good_ids = [e.id for e in verdict.evidences if e.id != bad_id]
    assert "설명이에요" in result.texts["evidences"][good_ids[0]]["easy_explanation"]


def test_banned_phrase_in_headline_falls_back(monkeypatch, solar_key, danger_case):
    """headline에 단정 표현("안전 범위" 등) → headline만 폴백 (rule-auditor 지적 봉인)."""
    _, _, verdict = danger_case
    monkeypatch.setattr(
        explanation,
        "_call_solar",
        lambda m, k: valid_content(verdict, headline="이 집은 안전 범위예요"),
    )
    result = explanation.generate(verdict)
    assert result.source == "AI 생성(일부 폴백)"
    assert result.texts["headline"] == fallback_texts.HEADLINES[verdict.grade]


def test_overlong_field_falls_back(monkeypatch, solar_key, danger_case):
    """길이 상한(_MAX_LEN) 초과 필드는 폴백으로 치환 (rule-auditor 지적 봉인)."""
    _, _, verdict = danger_case
    payload = json.loads(valid_content(verdict))
    long_id = payload["evidences"][0]["id"]
    # 2026-08-05: 상한이 240 → 600으로 올라가(문단 4단 구성) 초과량도 함께 늘렸다.
    payload["evidences"][0]["easy_explanation"] = "확인이 필요해요. " * 80  # 640자 > 600자
    monkeypatch.setattr(
        explanation, "_call_solar", lambda m, k: json.dumps(payload, ensure_ascii=False)
    )
    result = explanation.generate(verdict)
    assert result.source == "AI 생성(일부 폴백)"
    base = fallback_texts.build(verdict)
    assert result.texts["evidences"][long_id]["easy_explanation"] == base["evidences"][long_id]["easy_explanation"]


def test_deterministic_summary_excludes_service_side_cautions():
    """topRiskSummary(결정적): 전부 양호면 매물 고유 수치로 — 서비스측 '확인 필요'가
    비교 줄을 독점하지 않는다 (서연 리뷰 반영 봉인)."""
    data = load_fixture("clean_house")
    extract = RegistryExtract.from_raw(data["registry"])
    verdict = rule_engine.evaluate(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"]["market_price"],
        blacklist_entries=[],  # 명단 미구축(서비스측 사정)
    )
    summary = fallback_texts.top_risk_summary(verdict)
    assert summary == "전세가율 50% · 먼저 갚을 빚 0건"


# ── ③ 실패 시 리포트 항상 완성 ───────────────────────────────────────────────


def test_timeout_falls_back_and_report_completes(monkeypatch, solar_key, danger_case):
    data, extract, verdict = danger_case

    def boom(messages, api_key):
        raise requests.exceptions.Timeout("모의 타임아웃")

    monkeypatch.setattr(explanation, "_call_solar", boom)

    result = explanation.generate(verdict)
    assert result.source == "폴백"

    # 분석 실패로 격상되지 않고 리포트가 완성된다
    report = report_builder.build_report(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"]["market_price"],
        alias=None,
    )
    assert report.grade == "위험"
    assert report.headline  # 폴백 문구로 채워짐


def test_no_api_key_skips_call_entirely(monkeypatch, danger_case):
    """키가 없으면 호출 자체를 안 한다 (크레딧 0, 폴백)."""
    _, _, verdict = danger_case
    monkeypatch.setenv("UPSTAGE_API_KEY", "")
    called: list[int] = []
    monkeypatch.setattr(explanation, "_call_solar", lambda m, k: called.append(1))

    result = explanation.generate(verdict)
    assert result.source == "폴백"
    assert called == []


def test_llm_input_is_verdict_only(monkeypatch, solar_key, danger_case):
    """LLM에 넘어가는 내용에 원본 이미지·추출 전체가 아닌 판정 파생 값만 담긴다."""
    _, _, verdict = danger_case
    captured: dict = {}

    def capture(messages, api_key):
        captured["messages"] = messages
        return valid_content(verdict)

    monkeypatch.setattr(explanation, "_call_solar", capture)
    explanation.generate(verdict)

    user_content = captured["messages"][1]["content"]
    assert "판정 JSON" in user_content
    assert "종합등급" in user_content
    assert "base64" not in user_content  # 이미지 전달 금지

    # ── 2026-08-05: 봉인 방식을 **블랙리스트 → 화이트리스트**로 바꿨다 ──────────
    #
    # 예전에는 `assert "mortgagee" not in user_content` 한 줄이었다. 취지는
    # decisions.md [2026-07-07] ⑴ "원본 이미지·추출 JSON 전달 금지"였는데, 문자열
    # 하나를 막는 방식이라 **다른 원본 필드가 새로 실려도 잡지 못했다.**
    #
    # 이번에 설명 재료를 넓히면서(근저당 순위·설정일·근저당권자) 그 한 줄이 걸렸다.
    # 실린 것은 추출 JSON 통째가 아니라 **규칙 엔진이 골라 담은 facts**이지만,
    # "무엇이 실려도 되는가"를 사람이 매번 판단하게 두면 다음에 또 흐려진다.
    # 그래서 **최상위 키를 화이트리스트로 못 박는다** — 새 키를 추가하려면 이 목록을
    # 함께 고쳐야 하고, 그 순간 사람이 한 번 더 생각하게 된다.
    material = json.loads(user_content.split("판정 JSON:\n", 1)[1])
    allowed_top = {
        "종합등급", "보증금_원", "시세_원", "선순위채권합계_원", "문서_플래그",
        "근거", "시세출처", "소유권이전이력",
        # 2026-08-05 2차 — 등기부 자체의 사실. 이 세 줄을 **의식적으로** 추가했다는 것이
        # 화이트리스트 방식의 요점이다(블랙리스트였다면 아무도 몰랐다).
        "등기부_열람일시",  # 스냅샷 시점. None이면 '읽지 못함'을 명시해 분석일 대체를 막는다
        "찾아본_것",  # checked_notes — 무엇을 보고 무엇을 왜 뺐는지
        "배정된_중개사_질문",  # questions.json에서 이 근거에 실제로 배정된 질문 문구
    }
    assert set(material) <= allowed_top, f"허용되지 않은 최상위 키: {set(material) - allowed_top}"

    # 근거 원소도 마찬가지 — 추출 원본이 통째로 들어오는 경로를 막는다.
    for e in material["근거"]:
        assert set(e) <= {"id", "등급", "상태", "판정상세", "수치사실"}

    # **사람 이름은 여전히 금지다.** 소유자 명단은 어떤 경로로도 실리지 않는다.
    owner_names = [o.get("name") for o in danger_case[0]["registry"].get("current_owners", [])]
    for name in owner_names:
        assert name and name not in user_content, f"소유자 실명이 프롬프트에 실렸다: {name}"
    # 주민등록번호 형태도 금지 (추출 원본이 새는 가장 나쁜 형태)
    assert not re.search(r"\d{6}\s*-\s*[0-9*]{6,7}", user_content)


# ── ⑦ 설명 출처 라벨 — 카드마다 갈린다 (2026-08-14 D26) ──────────────────────
#
# 2026-07-09에 'AI 생성' → '자동 생성'으로 바꾼 이유는 그대로 유효하다: 폴백 문장에
# 모델명을 붙이면 거짓말이다. 그 결정을 되돌리지 않고 **조건부로 정밀화**한 것이 D26이라,
# "폴백 카드에 모델명이 붙지 않는다"가 이 기능의 봉인점이다.


def test_설명_출처는_카드마다_갈린다(danger_case, solar_key, monkeypatch):
    """한 응답 안에서 어떤 카드는 모델 문장, 어떤 카드는 준비된 문구가 될 수 있다.

    설명 폴백은 **필드 단위**다. 전체 라벨 하나만 두면 준비된 문구를 쓴 카드에까지
    모델명이 붙어 과대 표기가 된다 — 이 앱에서 가장 하면 안 되는 종류의 거짓말이다.
    """
    _, _, verdict = danger_case
    bad_id = verdict.evidences[0].id

    def mock_call(messages, api_key):
        return json.dumps(
            {
                "headline": "빚이 커서 보증금 회수가 어려울 수 있어요",
                "evidences": [
                    {
                        "id": e.id,
                        # 첫 카드만 검증에 걸리게 한다 — 재료에 없는 수치(금지 사유).
                        "easy_explanation": (
                            "전세가율이 1234%예요"
                            if e.id == bad_id
                            else f"{e.id} 항목 설명이에요. 확인이 필요해요."
                        ),
                    }
                    for e in verdict.evidences
                ],
            },
            ensure_ascii=False,
        )

    monkeypatch.setattr(explanation, "_call_solar", mock_call)
    result = explanation.generate(verdict)

    assert result.evidence_sources[bad_id] == explanation.FALLBACK_SOURCE_LABEL
    others = [v for k, v in result.evidence_sources.items() if k != bad_id]
    assert others, "비교할 다른 카드가 없다"
    assert all(v == result.model for v in others)
    assert explanation.FALLBACK_SOURCE_LABEL not in result.model


def test_LLM을_아예_못_부르면_모든_카드가_준비된_문구다(danger_case, monkeypatch):
    """키가 없으면 호출 자체가 없다 — 그때 모델명이 새어 나가면 안 된다."""
    _, _, verdict = danger_case
    monkeypatch.setenv("UPSTAGE_API_KEY", "")
    result = explanation.generate(verdict)
    assert result.source == "폴백"
    assert set(result.evidence_sources) == {e.id for e in verdict.evidences}
    assert all(
        v == explanation.FALLBACK_SOURCE_LABEL for v in result.evidence_sources.values()
    )


def test_출처_라벨이_리포트_카드까지_실려_나간다(danger_case, solar_key, monkeypatch):
    """계약(§2.2 explanationSource)까지 이어지지 않으면 화면은 아무것도 못 그린다."""
    data, extract, verdict = danger_case
    monkeypatch.setattr(explanation, "_call_solar", lambda m, k: valid_content(verdict))
    report = report_builder.build_report(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"]["market_price"],
        alias="테스트",
    )
    assert all(ev.explanationSource for ev in report.evidences)
