# LLM 백엔드 비교 실측 (2026-07)

> **⚠ 이 시트의 품질(①) 열은 아직 채점되지 않았습니다.** 팀원이 직접 채워 넣는 칸입니다
> — 비전문가 이해 용이성·해요체·용어 풀이를 1~5로 매기고, 단가 메모도 수기로 기입합니다.
> 나머지 열(스키마 통과·금지어·지연·토큰·오류)은 자동 측정값입니다.
>
> **재생성 불가**: LLM 응답은 비결정적이라 같은 스크립트를 다시 돌려도 같은 값이 나오지
> 않습니다(크레딧도 소모). 그래서 실행 산출물을 버리지 않고 이 문서로 보존합니다.
> 원본 수치는 같은 이름의 `.json`에 실행별로 그대로 담겨 있습니다.

## 실행 정보

| 실행 | 일시 | 대상 | 비고 |
|---|---|---|---|
| A | **2026-07-22 17:47:13** | solar + exaone | exaone이 `429 Too Many Requests`(friendli.ai 레이트리밋)로 3개 역할 전부 실패 |
| B | **2026-07-22 17:52:11** | exaone 단독 | 5분 뒤 재시도 — 전 역할 3/3 통과, 오류 0 |

- 생성 스크립트: `backend/scripts/compare_llm_backends.py`
- 두 실행은 **상호보완**입니다. Solar 실측치는 A에만, 정상 동작하는 exaone 실측치는 B에만
  있습니다. 어느 한쪽만으로는 비교가 성립하지 않습니다.
- **운영 리스크 메모**: exaone(friendli.ai 서버리스)은 연속 호출 시 429에 걸렸습니다.
  실사용 시 재시도·백오프가 필요하다는 신호입니다. Solar는 같은 조건에서 오류 0이었습니다.

---

# 실행 A — 2026-07-22 17:47:13

_solar + exaone 동시 측정 (exaone은 레이트리밋으로 대부분 실패)_

품질(①) 열은 **사람 채점**(1~5): 비전문가 이해 용이성·해요체·용어 풀이. 단가는 수기 기입.

| 역할 | 프로바이더 | 모델 | ②스키마 통과 | 금지어 | ③지연 중앙값(s) | ④토큰 | ④오류 | ①품질(수기) | 단가 메모 |
|---|---|---|---|---|---|---|---|---|---|
| explanation | solar | solar-pro2 | 3/3 | 0 | 2.0 | 3785 | 0 | ☐ | ☐ |
| explanation | exaone | LGAI-EXAONE/K-EXAONE-236B-A23B | 2/2 | 0 | 4.24 | 2696 | 1 | ☐ | ☐ |
| precedent | solar | solar-pro2 | 3/3 | 0 | 1.41 | 3066 | 0 | ☐ | ☐ |
| precedent | exaone | LGAI-EXAONE/K-EXAONE-236B-A23B | 0/0 | 0 | None | 0 | 3 | ☐ | ☐ |
| case_compare | solar | solar-pro2 | 3/3 | 0 | 1.26 | 1921 | 0 | ☐ | ☐ |
| case_compare | exaone | LGAI-EXAONE/K-EXAONE-236B-A23B | 0/0 | 0 | None | 0 | 3 | ☐ | ☐ |
| tagging | solar | solar-pro2 | 3/3 | 0 | 0.69 | 977 | 0 | ☐ | ☐ |
| tagging | exaone | LGAI-EXAONE/K-EXAONE-236B-A23B | 0/0 | 0 | None | 0 | 3 | ☐ | ☐ |

## 출력 샘플 (품질 채점용)

### explanation / solar
- 시도 1: `{"headline": "보증금과 선순위 채권 합계가 시세를 크게 넘어요", "evidences": [{"id": "jeonse_ratio", "easy_explanation": "전세가율 60%로 보증금이 시세의 60%예요. 입력하신 시세가 정확한지 다시 확인해 주세요"}, {"id": "senior_debt", "easy_explanation": "나보다 먼저 돈을 받아갈 빚(선순위 채권)이 시세의 90%로 1억 8,000만원이에요. 보증금과 합하면 시세의 150%라 HUG(주택도시보증공사) 등 보증기관에 꼭 물어봐 주세요"}, {"id": "ownership", "easy_explanation": "집주인의 빚 때문에 집을 뺏길 수 있는 신탁등기나 압류 같은 건 보이지 않았어요. 계약 직전 최신 등기부`
- 시도 2: `{"headline": "보증금과 선순위 채권 합계가 시세를 크게 넘어요", "evidences": [{"id": "jeonse_ratio", "easy_explanation": "보증금이 시세의 60%로 안전한 범위에 들어요. 계약 직전 최신 등기부등본으로 다시 확인하세요"}, {"id": "senior_debt", "easy_explanation": "나보다 먼저 돈을 받아갈 빚(선순위 채권)이 시세의 90%로 위험해요. 보증금과 합치면 시세의 150%를 넘어요. HUG(주택도시보증공사) 안심전세포털에서 보증 가입 가능 여부를 물어보세요"}, {"id": "ownership", "easy_explanation": "집주인의 빚이나 압류 같은 권리 분쟁은 보이지 않았어요. 등기부등본에서 직접 말소 여부를 `
- 시도 3: `{"headline": "보증금과 선순위 채권 합계가 시세를 크게 넘어 위험해요", "evidences": [{"id": "jeonse_ratio", "easy_explanation": "보증금이 시세의 60%로 80% 미만이에요. 계약 직전 최신 등기부등본으로 다시 확인하세요"}, {"id": "senior_debt", "easy_explanation": "나보다 먼저 돈을 받아갈 빚(선순위 채권)이 시세의 90%로 기준을 크게 넘어요. 보증기관에 보증 가능 여부를 직접 물어보세요"}, {"id": "ownership", "easy_explanation": "신탁등기나 압류 같은 권리 분쟁은 보이지 않았어요. 등기소에서 등기부등본을 꼭 확인하세요"}, {"id": "insurance", "easy_expl`

### explanation / exaone
- 시도 1: `{"headline": "입력하신 시세 2억원 기준으로 보증금과 빚의 비율이 위험 수준이에요", "evidences": [{"id": "jeonse_ratio", "easy_explanation": "입력하신 시세 2억원 대비 보증금 1억 2,000만원은 60%예요. 전세가율이 높을수록 위험하니 계약 전 최신 등기부등본으로 다시 확인하세요"}, {"id": "senior_debt", "easy_explanation": "선순위 채권(나보다 먼저 돈을 받아가는 빚) 합계가 1억 8,000만원이고, 이는 시세의 90%예요. 보증금과 선순위 채권을 더하면 시세의 150%에 달해요"}, {"id": "ownership", "easy_explanation": "신탁등기, 압류, 가압류, 가처분, 경매개시결정 같은 권`
- 시도 2: `{"headline": "보증금과 시세, 선순위 빚을 꼼꼼히 따져보세요", "evidences": [{"id": "jeonse_ratio", "easy_explanation": "입력하신 시세 2억원 대비 보증금 1억 2,000만원은 60%예요. 시세 대비 보증금이 80%를 넘으면 주의가 필요해요. 계약 전 최신 등기부등본으로 다시 확인하세요."}, {"id": "senior_debt", "easy_explanation": "선순위 채권 합계 1억 8,000만원은 시세의 90%예요. 보증금과 선순위 채권을 더하면 시세의 150%가 되어요. 이보다 먼저 돈을 받아갈 빚이 많으면 위험해요. 등기부등본에서 근저당 2건을 다시 확인하세요."}, {"id": "ownership", "easy_explanation":`
- 시도 3: `[호출 실패] HTTPError: 429 Client Error: Too Many Requests for url: https://api.friendli.ai/serverless/v1/chat/completions`

### precedent / solar
- 시도 1: `{"cases": [{"case_id": "prec-230033", "easy_summary": "경매로 넘어간 부동산에서 선순위 채권이 있으면 후순위 임차인은 낙찰자에게 임차권을 주장할 수 없어요. 법원은 주민등록만으로 임차권 효력이 인정되지 않는다고 봤어요.", "common_point": "선순위 채권이 있는 경우 후순위 권리자는 보호받기 어렵다는 점이 위험 태그와 일치해요"}, {"case_id": "prec-160247", "easy_summary": "중개사는 임차인에게 선순위 채권 등 권리관계를 정확히 설명해야 해요. 설명 누락 시 중개사에게 손해배상 책임이 있어요.", "common_point": "선순위 채권 존재 시 임차인이 피해를 입을 수 있다는 점이 위험 태그와 연결돼요"}]}`
- 시도 2: `{"cases": [{"case_id": "prec-230033", "easy_summary": "경매로 집을 산 사람은 선순위 채권보다 뒤에 있는 임차권을 주장할 수 없어요. 법원은 후순위 임차인이 낙찰자에게 임차권을 주장할 수 없다고 판단했어요.", "common_point": "경매 시 선순위 채권이 있으면 후순위 임차인은 권리를 주장하기 어려워요"}, {"case_id": "prec-160247", "easy_summary": "중개사는 임차인에게 다른 세입자의 임대차 정보(보증금, 기간 등)를 확인하고 설명해야 해요. 법원은 중개사가 이를 소홀히 하면 손해배상 책임이 있다고 판단했어요.", "common_point": "선순위 채권 확인을 소홀히 하면 임차인에게 피해가 발생할 수 있어요"}]}`
- 시도 3: `{"cases": [{"case_id": "prec-230033", "easy_summary": "경매로 부동산이 넘어갈 때 선순위 채권이 있으면 후순위 임차인은 권리를 주장할 수 없어요. 법원은 주민등록이 있어도 임차권 효력이 낙찰자에게 미치지 않는다고 판단했어요.", "common_point": "선순위 채권이 있는 경우 후순위 임차권이 소멸할 수 있다는 점이 위험 태그와 연결돼요"}, {"case_id": "prec-160247", "easy_summary": "중개사는 임차인에게 선순위 채권 정보를 설명해야 해요. 법원은 중개사가 다른 세입자의 보증금 정보를 알려주지 않아 손해가 발생하면 배상해야 한다고 판단했어요.", "common_point": "선순위 채권 정보가 제대로 공개되지 않으면 임차권이`

### precedent / exaone
- 시도 1: `[호출 실패] HTTPError: 429 Client Error: Too Many Requests for url: https://api.friendli.ai/serverless/v1/chat/completions`
- 시도 2: `[호출 실패] HTTPError: 429 Client Error: Too Many Requests for url: https://api.friendli.ai/serverless/v1/chat/completions`
- 시도 3: `[호출 실패] HTTPError: 429 Client Error: Too Many Requests for url: https://api.friendli.ai/serverless/v1/chat/completions`

### case_compare / solar
- 시도 1: `{"same_points": ["선순위 채권이 존재하는 경우 임차권의 효력이 제한될 수 있다는 점", "대항력 요건 충족 여부가 임차권 보호 가능성에 영향을 미친다는 점"], "different_points": ["판정은 선순위 채권 금액과 보증금 규모를 수치적으로 비교한 반면, 판례는 등기 순서와 대항력 공시 방법을 중점적으로 다룬 점", "판정은 위험 등급을 부여한 반면, 판례는 구체적 사건에서의 법적 효력 여부를 판단한 점"], "case_outcome": "후순위 임차인은 낙찰자에게 임차권을 주장하지 못했어요", "lesson": "선순위 채권이 있는 매물에서는 대항력 요건을 철저히 확인하고 등기 순서를 고려해야 해요"}`
- 시도 2: `{"same_points": ["선순위 채권이 존재하는 경우 후순위 임차권의 효력이 제한될 수 있어요", "임차권의 대항력이 인정되지 않으면 낙찰자에게 임차권을 주장하기 어려워요"], "different_points": ["판정은 선순위 채권 금액이 보증금보다 높은 상황을 지적하지만 판례는 임차권 공시 요건 충족 여부를 강조해요", "판정은 수치적 위험 요소를 제시하는 반면 판례는 법적 요건 해석을 중심으로 설명해요"], "case_outcome": "후순위 임차인은 낙찰자에게 임차권을 주장하지 못했어요", "lesson": "선순위 채권 확인과 함께 임차권 대항 요건 충족 여부를 반드시 점검해야 해요"}`
- 시도 3: `{"same_points": ["선순위 채권이 존재하는 경우 후순위 임차권의 효력이 제한될 수 있다는 점", "대항력 요건 충족 여부가 임차권의 효력에 영향을 미친다는 점"], "different_points": ["판정은 선순위 채권 금액과 보증금 규모를 수치적으로 비교한 반면, 판례는 등기 순서와 대항력 요건 충족 여부를 중점적으로 판단했다는 점", "판정은 특정 매물의 위험 등급을 평가한 것이고, 판례는 실제 소송에서의 법적 효력 문제를 다룬 것이라는 점"], "case_outcome": "후순위 임차인은 낙찰자에게 임차권을 주장하지 못했어요", "lesson": "선순위 채권이 있는 매물에서는 대항력 요건을 철저히 확인하고 등기 순서를 고려해야 해요"}`

### case_compare / exaone
- 시도 1: `[호출 실패] HTTPError: 429 Client Error: Too Many Requests for url: https://api.friendli.ai/serverless/v1/chat/completions`
- 시도 2: `[호출 실패] HTTPError: 429 Client Error: Too Many Requests for url: https://api.friendli.ai/serverless/v1/chat/completions`
- 시도 3: `[호출 실패] HTTPError: 429 Client Error: Too Many Requests for url: https://api.friendli.ai/serverless/v1/chat/completions`

### tagging / solar
- 시도 1: `{"tags": ["선순위 채권", "경매"], "reason": "판시사항에서 '다른 소액임차인 등보다 후순위'와 '경매절차'가 언급되어 해당 태그 부여"}`
- 시도 2: `{"tags": ["선순위 채권", "경매"], "reason": "판시사항에서 임대차보증금 반환 문제 시 다른 소액임차인보다 후순위에 있어 경매 절차에서 손해를 입은 점이 언급되었기 때문"}`
- 시도 3: `{"tags": ["선순위 채권", "경매"], "reason": "판시사항에서 임대차보증금 반환 문제가 경매 절차에서 선순위 채권자에 의해 후순위인 임차인이 피해를 입은 사례와 관련되어 있음"}`

### tagging / exaone
- 시도 1: `[호출 실패] HTTPError: 429 Client Error: Too Many Requests for url: https://api.friendli.ai/serverless/v1/chat/completions`
- 시도 2: `[호출 실패] HTTPError: 429 Client Error: Too Many Requests for url: https://api.friendli.ai/serverless/v1/chat/completions`
- 시도 3: `[호출 실패] HTTPError: 429 Client Error: Too Many Requests for url: https://api.friendli.ai/serverless/v1/chat/completions`

---

# 실행 B — 2026-07-22 17:52:11

_exaone 재측정 (레이트리밋 해소 후)_

품질(①) 열은 **사람 채점**(1~5): 비전문가 이해 용이성·해요체·용어 풀이. 단가는 수기 기입.

| 역할 | 프로바이더 | 모델 | ②스키마 통과 | 금지어 | ③지연 중앙값(s) | ④토큰 | ④오류 | ①품질(수기) | 단가 메모 |
|---|---|---|---|---|---|---|---|---|---|
| explanation | exaone | LGAI-EXAONE/K-EXAONE-236B-A23B | 3/3 | 0 | 4.47 | 4092 | 0 | ☐ | ☐ |
| precedent | exaone | LGAI-EXAONE/K-EXAONE-236B-A23B | 3/3 | 0 | 2.62 | 3146 | 0 | ☐ | ☐ |
| case_compare | exaone | LGAI-EXAONE/K-EXAONE-236B-A23B | 3/3 | 0 | 1.95 | 2057 | 0 | ☐ | ☐ |
| tagging | exaone | LGAI-EXAONE/K-EXAONE-236B-A23B | 3/3 | 0 | 0.92 | 1055 | 0 | ☐ | ☐ |

## 출력 샘플 (품질 채점용)

### explanation / exaone
- 시도 1: `{"headline": "입력하신 시세 대비 보증금 비율과 선순위 빚이 기준보다 높아 주의가 필요해요", "evidences": [{"id": "jeonse_ratio", "easy_explanation": "입력하신 시세 2억원에 보증금 1억 2,000만원은 60%예요. 이 비율은 주의 기준 80%를 넘진 않았지만, 위험 기준 90%에 가까워요. 계약 전 최신 등기부등본으로 다시 확인하세요"}, {"id": "senior_debt", "easy_explanation": "선순위 빚(근저당 2건 포함)이 1억 8,000만원으로, 입력하신 시세의 90%예요. 보증금과 선순위 빚을 더하면 시세의 150%가 되어 기준을 크게 초과해요. HUG(주택도시보증공사) 안심전세포털에서 보증 가능 여부를 직접 물어보세요"}`
- 시도 2: `{"headline": "입력하신 시세보다 보증금과 선순위 빚 합계가 더 높아요", "evidences": [{"id": "jeonse_ratio", "easy_explanation": "입력하신 시세 2억원 대비 보증금 1억 2,000만원은 60%예요. 전세가율이 80%를 넘으면 주의가 필요해요. 계약 전 최신 등기부등본으로 다시 확인하세요."}, {"id": "senior_debt", "easy_explanation": "선순위 빚(나보다 먼저 돈을 받아갈 빚) 합계가 1억 8,000만원이에요. 이 금액이 시세의 90%에 달하고, 보증금과 더하면 시세의 150%가 돼요. HUG(주택도시보증공사) 안심전세포털에서 보증 가능 여부를 직접 확인해 보세요."}, {"id": "ownership", "easy_e`
- 시도 3: `{"headline": "입력하신 시세 2억원 대비 보증금 1억 2,000만원, 선순위 빚 1억 8,000만원으로 위험해요", "evidences": [{"id": "jeonse_ratio", "easy_explanation": "입력하신 시세 2억원 대비 보증금 1억 2,000만원은 전세가율 60%예요. 계약 전 최신 등기부등본으로 다시 확인하세요"}, {"id": "senior_debt", "easy_explanation": "선순위 빚 1억 8,000만원은 시세의 90%에 달하고, 보증금과 더하면 시세의 150%예요. 근저당 2건이 있으니 HUG(주택도시보증공사) 안심전세포털에서 보증 가능 여부를 직접 물어보세요"}, {"id": "ownership", "easy_explanation": "신탁등기, `

### precedent / exaone
- 시도 1: `{"cases": [{"case_id": "prec-230033", "easy_summary": "경매로 집이 팔리면 먼저 등기된 저당권보다 나중에 생긴 임차권은 사라지고, 낙찰자는 그 임차권을 인정하지 않아요.", "common_point": "선순위 채권이 있으면 후순위 임차인은 낙찰자에게 임차권을 주장할 수 없어요."}, {"case_id": "prec-160247", "easy_summary": "중개사는 다른 세입자의 보증금과 계약 기간을 제대로 알려주지 않으면 책임을 져요.", "common_point": "선순위 채권이 있는지 확인하지 않으면 임차인이 보증금을 돌려받기 어려울 수 있어요."}]}`
- 시도 2: `{"cases": [{"case_id": "prec-230033", "easy_summary": "경매로 집이 팔렸을 때, 먼저 등기된 빚(선순위 저당권)보다 나중에 생긴 임차권은 함께 사라져요. 그래서 낙찰자는 그 임차권을 인정할 의무가 없어요.", "common_point": "선순위 채권이 있는 경우 후순위 임차인은 낙찰자에게 임차권을 주장할 수 없어요"}, {"case_id": "prec-160247", "easy_summary": "중개사는 임차인이 보증금을 돌려받을 수 있는지 확인하려면 다른 세입자의 계약 내용도 알려줘야 해요. 이를 안 하면 손해배상 책임이 생겨요.", "common_point": "선순위 채권이 있는 경우 후순위 임차인은 낙찰자에게 임차권을 주장할 수 없어요"}]}`
- 시도 3: `{"cases": [{"case_id": "prec-230033", "easy_summary": "경매로 집이 팔리면, 먼저 등기된 빚(선순위 채권)보다 나중에 생긴 임차권은 사라져요. 그래서 낙찰자는 그 임차권을 인정하지 않아도 되어요.", "common_point": "선순위 채권이 있으면 후순위 임차인은 낙찰자에게 임차권을 주장하기 어려워요"}, {"case_id": "prec-160247", "easy_summary": "중개사는 다른 세입자의 보증금과 계약 기간 같은 정보를 확인하고, 임차인에게 알려줘야 해요. 이를 안 하면 임차인이 중개사에게 손해배상을 청구할 수 있어요.", "common_point": "선순위 채권이 있는지 확인하지 않으면 임차인이 보증금을 못 받을 위험이 커져요"}]}`

### case_compare / exaone
- 시도 1: `{"same_points": ["선순위 채권이 존재하고, 임차인의 보증금이 그보다 작음", "임차인이 대항력을 갖추지 못해 권리 주장에 실패함"], "different_points": ["판정은 종합등급 '위험'으로 평가했지만, 판례는 구체적 사건의 결과에 초점", "판례는 주민등록의 공시효력 해석을 포함하나, 판정 요약은 이를 반영하지 않음"], "case_outcome": "판례에서 임차인은 낙찰자에게 임차권을 주장하지 못했어요", "lesson": "이 매물 사용자에게 주는 교훈은 대항력 요건을 충족하지 못하면 임차권을 보호받기 어려워요"}`
- 시도 2: `{"same_points": ["선순위 채권이 존재하고, 보증금보다 선순위 채권 합계가 크다는 점에서 위험하다고 평가해요", "임차인이 낙찰자에게 임차권을 주장하지 못한 점에서 보호받지 못한 상황이에요"], "different_points": ["판정은 위험 등급을 '위험'으로 평가했지만, 판례는 구체적인 등급이나 수치 기준을 제시하지 않아요", "판정은 선순위 채권 합계와 보증금을 비교해 위험도를 산정하지만, 판례는 대항력 요건 충족 여부에 초점을 맞춰요"], "case_outcome": "후순위 임차인은 낙찰자에게 임차권을 주장하지 못했어요", "lesson": "임차인이 대항력을 갖추지 못하면 낙찰자에게 임차권을 주장하기 어려워요"}`
- 시도 3: `{"same_points": ["선순위 채권이 존재하고, 임차인의 보증금이 선순위 채권보다 낮음", "임차인이 대항력을 갖추지 못해 권리를 주장하지 못함"], "different_points": ["판정은 종합등급 '위험'으로 평가했으나, 판례는 구체적인 등급 없이 법적 결과만 제시함", "판정은 수치 기반 위험 태그를 사용하지만, 판례는 주민등록의 실질적 공시 효과를 판단 기준으로 함"], "case_outcome": "판례에서 후순위 임차인은 낙찰자에게 임차권을 주장하지 못했어요", "lesson": "임차인이 대항력을 갖추지 못하면 보증금 회수에 어려움을 겪을 수 있어요"}`

### tagging / exaone
- 시도 1: `{"tags": ["경매", "선순위 채권"], "reason": "임차인이 경매 절차에서 후순위로 인해 보증금을 회수하지 못한 사례로, 경매와 선순위 채권 관련 위험이 존재함"}`
- 시도 2: `{"tags": ["선순위 채권"], "reason": "임차인이 경매에서 다른 임차인보다 후순위에 있어 보증금을 회수하지 못한 사안으로, 선순위 채권 존재 여부가 손해배상 책임 판단에 영향을 미침"}`
- 시도 3: `{"tags": ["선순위 채권"], "reason": "임차인이 다른 소액임차인보다 후순위에 있어 임대차보증금을 회수하지 못한 사안으로, 선순위 채권과의 우선순위 관계가 핵심 쟁점이었기 때문"}`

---
