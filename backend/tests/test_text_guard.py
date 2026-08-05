"""설명 문장 검증(`text_guard`) 봉인 — **감사에서 실제로 샌 문자열**을 못 새게 한다.

근거: `docs/claude-chat/2026-08-05-llm-explanation-audit.md`
  §B-5-1 headline에 "양호"가 들어간 채 통과
  §B-5-3 `"안전한 범위에 속해요"`가 `"안전 범위"` 목록을 통과

이 파일의 값어치는 "패턴이 잘 짜였다"가 아니라 **"이미 한 번 뚫린 구멍이 다시 뚫리지
않는다"**이다. 그래서 실제로 관측된 문자열을 그대로 적어 둔다.
"""

from __future__ import annotations

import pytest

from app.services import text_guard as G


# ── ① 감사에서 실제로 샌 문자열 ──────────────────────────────────────────────


@pytest.mark.parametrize(
    "text",
    [
        "보증금이 시세의 50%로 안전한 범위에 속해요",  # §B-5-3 실측 — 옛 목록을 통과했다
        "이 집은 안전합니다",
        "안전 범위예요",
        "안전해요",
        "안심하셔도 돼요",
        "문제가 없습니다",
        "문제없어요",
        "위험 요소가 없어요",
        "이상이 없어요",
        "걱정 마세요",
        "걱정하지 않으셔도 돼요",
        "100% 안전한 매물이에요",
        "보증금 반환을 보장합니다",
    ],
)
def test_단정_표현은_막힌다(text):
    assert G.banned_hit(text) is not None, f"단정이 통과했다: {text}"


@pytest.mark.parametrize(
    "text",
    [
        # 부정문 — **보수적인** 문장이므로 통과해야 한다 (2026-08-05 실측 오탐)
        "명단에 없어도 완전히 안전하다고 볼 수 없어요",
        "안전하다고 보기 어려워요",
        "안전하다고 보기 힘들어요",
        # 우리 폴백 문구 — 이것들이 걸리면 폴백조차 못 쓴다
        "큰 위험 신호는 보이지 않았어요 — 그래도 직접 확인은 필요해요",
        "확인할 게 몇 가지 있어요 — 지금 결정은 잠시 미루세요",
        "보증금을 지키기 어려운 신호가 보여요",
    ],
)
def test_보수적_문장은_통과한다(text):
    assert G.banned_hit(text) is None, f"정상 문장이 막혔다: {text}"


# ── ② 등급 단어 ─────────────────────────────────────────────────────────────


def test_headline에_양호가_들어가면_막힌다():
    """§B-5-1 실측 — 이 문자열이 그대로 화면에 나갔다."""
    assert G.grade_word_hit("전세가율 50%로 양호하지만 보증 가입 여부는 직접 확인이 필요해요")


@pytest.mark.parametrize(
    "text,blocked",
    [
        ("확인 필요한 항목이에요", True),
        ("종합등급이 위험이에요", True),
        ("위험 등급으로 판단했어요", True),
        # '위험'은 일상어로도 쓰인다 — 일괄 금지하면 우리 폴백부터 막힌다
        ("큰 위험 신호는 보이지 않았어요", False),
        ("보증금을 잃을 위험이 있어요", False),
        ("확인이 필요해요", False),
    ],
)
def test_등급_단어는_라벨로_쓰일_때만_막는다(text, blocked):
    assert (G.grade_word_hit(text) is not None) is blocked, text


# ── ③ 숫자 화이트리스트 ──────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "text,value",
    [
        ("1억 8,000만원", 180_000_000),
        ("1억 2천만원", 120_000_000),  # 2026-08-05 오탐 — '천'을 못 읽어 100000002가 됐다
        ("2억원", 200_000_000),
        ("1.8억", 180_000_000),
        ("8,000만원", 80_000_000),
        ("3천만원", 30_000_000),
        ("180,000,000원", 180_000_000),
    ],
)
def test_금액_표기를_하나의_수로_읽는다(text, value):
    got = G.extract_numbers(text)
    assert got and got[0][1] == value, f"{text} → {got}"


def test_한글_수사도_읽는다():
    values = [v for _, v in G.extract_numbers("근저당이 두 건 있어요")]
    assert 2 in values


def test_재료에_없는_수치는_막힌다():
    material = {"수치사실": {"mortgage_count": 2, "senior_ratio_pct": 90}}
    allowed = G.collect_allowed(material)
    assert G.unsupported_numbers("근저당 2건, 시세의 90%예요", allowed) == []
    # 지어낸 수 — 재료에 없다
    assert G.unsupported_numbers("근저당 7건이에요", allowed)


def test_우리_문장에_적힌_수는_허용된다():
    """`detail_text`는 우리가 만든 문장이다. 거기 적힌 수를 LLM이 옮겨 써도 폴백되면 안 된다."""
    material = {
        "근거": [
            {
                "판정상세": "전세가율 60% — 보증금 1억 2,000만원 / 시세 2억원"
                " (주의 80% 초과 · 위험 90% 초과)",
                "수치사실": {},
            }
        ]
    }
    allowed = G.collect_allowed(material)
    text = "보증금 1억 2,000만원이 시세 2억원의 60%예요. 80%를 넘으면 주의로 봐요"
    assert G.unsupported_numbers(text, allowed) == []


def test_반올림_표기는_허용한다():
    allowed = G.collect_allowed({"x": 180_000_000})
    assert G.unsupported_numbers("1.8억", allowed) == []


def test_0은_언제나_허용한다():
    """'0원'·'0건'은 없음을 말하는 표현이라 재료에 0이 없어도 통과한다."""
    assert G.unsupported_numbers("근저당 0건이에요", G.collect_allowed({})) == []


# ── ④ 종합 check() ──────────────────────────────────────────────────────────


def test_check가_사유를_돌려준다():
    allowed = G.collect_allowed({"n": 2})
    assert G.check("", max_len=100, allowed=allowed) == "빈 문자열"
    assert "길이 초과" in G.check("가" * 101, max_len=100, allowed=allowed)
    assert "금지 표현" in G.check("이 집은 안전합니다", max_len=100, allowed=allowed)
    assert "등급 단어" in G.check("양호한 편이에요", max_len=100, allowed=allowed)
    assert "재료에 없는 수치" in G.check("근저당 9건이에요", max_len=100, allowed=allowed)
    assert G.check("근저당 2건이에요", max_len=100, allowed=allowed) is None
