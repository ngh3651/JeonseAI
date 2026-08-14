"""판례 카드 강조 구간(D23) — **본문을 바꾸지 않고 가리키기만 한다**는 성질의 봉인.

여기서 지키는 것은 하나다: LLM이 무엇을 돌려주든 **화면에 나가는 문장은 그대로**여야 하고,
지어낸 문자열은 굵게 처리될 수 없어야 한다. 그 보장이 `advice`(큐레이션 문구, LLM 불가침 —
decisions.md 2026-07-09)에도 강조를 붙일 수 있게 해 주는 근거다.
"""

from __future__ import annotations

from app.services.precedent import emphasis


BODY = "후순위 임차인은 낙찰자에게 임차권을 주장하지 못해 보증금 5억원을 돌려받지 못했어요"


# ── 검증: 하나라도 어기면 그 필드는 통째로 폐기(=None) ────────────────────────


def test_본문에_그대로_있는_구절만_통과한다():
    assert emphasis.validate(BODY, ["보증금 5억원"]) == ["보증금 5억원"]


def test_한_글자라도_다르면_폐기한다():
    """앱은 `indexOf`로 찾는다 — 못 찾으면 굵기가 안 붙는다. 그 전에 서버가 잘라낸다."""
    assert emphasis.validate(BODY, ["보증금 5억 원"]) is None


def test_지어낸_문자열은_폐기한다():
    """이것이 이 모듈의 존재 이유다 — LLM은 **가리킬 수만 있고 쓸 수는 없다**."""
    assert emphasis.validate(BODY, ["집주인이 도망갔어요"]) is None


def test_개수_상한을_넘으면_폐기한다():
    assert emphasis.validate(BODY, ["후순위", "임차인", "낙찰자"]) is None


def test_한_구절이_너무_길면_폐기한다():
    long_body = BODY * 3  # 비율 규칙에 먼저 걸리지 않게 본문을 늘린다
    too_long = "후순위 임차인은 낙찰자에게 임차권을 주장하지 못해 보증금 5억원을"
    assert len(too_long) > emphasis.MAX_ITEM_CHARS
    assert emphasis.validate(long_body, [too_long]) is None


def test_굵은_글자가_본문의_30퍼센트를_넘으면_폐기한다():
    half = BODY[: len(BODY) // 2]
    assert emphasis.validate(BODY, [half[:emphasis.MAX_ITEM_CHARS]]) is None


def test_겹치는_구절은_한_번만_센다():
    """`보증금`과 `보증금 5억원`이 둘 다 오면 겹친 만큼 두 번 세어 비율이 부푼다."""
    assert emphasis._ranges("보증금 5억원을", ["보증금", "보증금 5억원"]) == [(0, 7)]


# ── 폴백: 금액 · 비율 · 기간 ─────────────────────────────────────────────────


def test_폴백은_금액을_고른다():
    assert emphasis.fallback(BODY) == ["5억원"]


def test_폴백은_비율과_기간도_고른다():
    text = "보증금이 시세의 234%였고, 계약 2년 뒤 경매로 넘어가 한 푼도 돌려받지 못했어요"
    assert emphasis.fallback(text) == ["234%", "2년"]


def test_고를_것이_없으면_굵게_없음():
    """숫자가 없는 조언 문장 — 억지로 굵게 만들지 않는다."""
    text = "계약 전 등기부등본 을구의 근저당 규모를 확인하세요"
    assert emphasis.fallback(text) == []


def test_검증_실패하면_폴백으로_내려간다():
    assert emphasis.choose(BODY, ["보증금 5억 원"]) == ["5억원"]


def test_LLM이_아무것도_안_주면_폴백을_쓴다():
    assert emphasis.choose(BODY, None) == ["5억원"]


def test_빈_본문에는_아무것도_붙이지_않는다():
    assert emphasis.choose("", ["뭐든"]) == []
