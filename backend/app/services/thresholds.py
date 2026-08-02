"""위험 판정 임계값 — docs/decisions.md와 1:1 대응하는 유일한 수치 저장소.

규칙(.claude/rules/risk-scoring.md):
- 판정 수치는 이 파일의 상수만 사용한다. 다른 코드에 수치를 직접 쓰지 않는다.
- 각 상수의 주석은 decisions.md 항목(날짜·출처)과 일치해야 하며, rule-auditor가 대조한다.
- "임시값(수정 가능)" 표시가 붙은 상수는 사람 검증 대기 중 — 검증 결과가 다르면
  decisions.md에 새 항목을 추가한 뒤 이 값을 갱신한다.
"""

from ..schemas.internal import Grade

# [decisions.md 2026-07-06 기준 ③ — 조건부 채택 · 임시값(수정 가능)]
# 출처: HUG 전세보증금반환보증 담보인정비율 90% (서울주거포털·HUG 상품개요).
# 자동 조회에서 상충 문구(70~80% 차등)가 관측되어 HUG 화면 사람 확인 대기.
JEONSE_RATIO_DANGER_PCT: int = 90

# [decisions.md 2026-07-06 기준 ③ — 조건부 채택 · 임시값(수정 가능)]
# 출처: 한국부동산원 '임대차 시장 사이렌' 80% 초과 공표 관행 + 업계 통설(준공식).
# 더 공식적인 출처(국토부 보도자료 등) 확인을 팀 과제로 병행.
JEONSE_RATIO_CAUTION_PCT: int = 80

# [decisions.md 2026-07-06 기준 ① — 즉시 채택]
# 출처: HUG 가입요건 "선순위채권이 주택가액의 60% 이내일 것".
SENIOR_DEBT_RATIO_DANGER_PCT: int = 60

# [decisions.md 2026-07-06 기준 ① — 즉시 채택]
# 출처: HUG 가입요건 "전세보증금+선순위채권 ≤ 주택가격 × 담보인정비율(90%)".
COMBINED_RATIO_DANGER_PCT: int = 90

# ── 공적 가격 → 주택가격 환산 (2026-08-03 추가) ─────────────────────────────
#
# [decisions.md 2026-08-03 — 공시가격 기반 시세 산출]
# 출처: HUG 전세보증금반환보증 — 주택가격 산정 시 공동주택은 KB/부동산테크 시세가
#       없으면 **공시가격 × 140%**를 주택가격으로 보고, 그 주택가격에 **담보인정비율
#       90%**를 곱한 금액까지를 담보로 인정한다.
#
# ⚠ 140% × 90% = 126% 를 **상수 하나로 박지 않는다.** 제도가 한쪽만 바뀔 수 있고,
#   그때 126%라는 숫자는 어느 쪽이 바뀐 것인지 알려주지 않는다.
# ⚠ `marketPrice`(집값)에는 **140%만** 곱한다. 90%는 아래 COMBINED_RATIO_DANGER_PCT가
#   판정 단계에서 이미 적용하므로, 여기서 또 곱하면 같은 비율을 두 번 쓰게 된다.
# ⚠ 기준시가(국세청 오피스텔)에는 **어떤 배수도 곱하지 않는다** — 그런 공식이 없다.
#   (2026-08-03 사용자 결정. official_price._multiplier_for 참조)
# ⚠ 사람 확인 대기: HUG 업무처리기준 원문에서 140%·90%를 눈으로 확인하고, 다르면
#   decisions.md에 새 항목을 추가한 뒤 이 값을 고친다.
PUBLIC_PRICE_TO_HOUSE_PRICE_RATIO: float = 1.40

# [decisions.md 2026-08-03] HUG 담보인정비율. COMBINED_RATIO_DANGER_PCT(90)와 같은
# 제도값을 비율 형태로 둔 것이다 — 진단·설명용 계산(official_price.hug_recognized_limit)에서만
# 쓰고, 판정은 COMBINED_RATIO_DANGER_PCT 쪽 한 곳에서만 한다.
HUG_COLLATERAL_RECOGNITION_RATIO: float = 0.90

# [decisions.md 2026-07-06 gaugeProgress 공식 — 내부 결정]
# 근거 카드 점수: 양호 1.0 / 확인 필요 0.5 / 위험 0.0
EVIDENCE_SCORE: dict[Grade, float] = {
    Grade.GOOD: 1.0,
    Grade.CAUTION: 0.5,
    Grade.DANGER: 0.0,
}

# [decisions.md 2026-07-06 gaugeProgress 공식 — 내부 결정]
# 종합 등급별 게이지 구간(클램프): 점수 평균이 구간을 벗어나면 구간 경계로 자른다.
GAUGE_BANDS: dict[Grade, tuple[float, float]] = {
    Grade.DANGER: (0.10, 0.35),
    Grade.CAUTION: (0.40, 0.70),
    Grade.GOOD: (0.75, 0.95),
}
