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
