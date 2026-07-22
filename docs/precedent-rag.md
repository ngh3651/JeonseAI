# 판례 RAG 모듈 인수 문서 (precedent-rag.md)

> **이 문서의 독자는 이영호** — 이 모듈을 이어받아 고도화할 개발자입니다.
> 2026-07-22 야간 자율 작업으로 구축된 판례 RAG 환경의 경계·실행법·확장 지점을 담습니다.
> 구축 경위·결정 근거는 `docs/night-report-2026-07-22.md`와 `docs/decisions.md`(2026-07-22 항목) 참고.

## 0. 30초 요약

- **무엇**: 위험 판정 리포트에 "유사 실제 판례"를 붙이기 위한 검색·설명 파이프라인.
  `수집(법제처 API) → 청킹 → 임베딩 → 벡터DB → 하이브리드 검색 → Solar 설명`이 전부 돌아간다.
- **지금 상태**: 시드 판례 7건(웹 검증, 6건은 법제처 공식 원문)으로 E2E 검증 완료.
  평가셋 10 시나리오에서 Hit@K 100% · P@1 100% · MRR 1.00 (Upstage 실임베딩).
- **안 한 것**: 라우터(`/api/reports/{id}/cases`) 연결 — **E-3 게이트의 몫**으로 남겼다.
  현재 그 엔드포인트는 여전히 dummy_data를 쓴다. 프론트도 무변경.
- **대원칙**: 판례는 **설명 전용**. 판정(rule_engine)은 이 모듈을 모른다(테스트로 봉인).
  LLM은 검색으로 실제 가져온 판례만 설명한다(환각 case_id 폐기, 테스트로 봉인).

## 1. 모듈 경계 (무엇이 어디 있나)

```
backend/app/services/precedent/     ← 모듈 본체 (판정 코드와 격리)
  models.py      데이터 모델. PrecedentDoc(큐레이션·사실), PrecedentExplanation(LLM 출력,
                 extra="forbid" — 판정·사건번호·advice 필드 자체가 없음)
  embedding.py   임베딩 백엔드 3종 + 팩토리. upstage(API) / local(GPU, KURE-v1) / hash(오프라인)
  store.py       벡터 저장소 2종 + 팩토리. Chroma(주력) / JSON(무의존 폴백). 서명 불일치 가드
  chunking.py    판결요지 중심 청킹 (쟁점 [1][2] 분리 → 요약 → 전문 문단)
  retrieval.py   BM25(자체) + 벡터 RRF 융합 + 태그 필터 + 보수적 노출 게이트
  ingest.py      raw(법제처)+시드 큐레이션 조인 → 자동 태깅 → 청킹 → 임베딩 → 적재
  explainer.py   Solar Pro 판례 설명 (E-2 explanation.py와 금지어·모델 상수 공유)
  service.py     오케스트레이션. 판정→태그 파생, 태그별 분기 검색, 섹션 조립

backend/scripts/
  collect_precedents.py   법제처 Open API 수집기 (OC 주입 시 대량 수집)
  ingest_precedents.py    적재 CLI (--backend upstage|local|hash)
  eval_retrieval.py       검색 정확도 평가 (개선 루프의 기준)
  demo_precedent.py       E2E 데모 (픽스처→판정→검색→설명) — 계약 무변경 검증 도구

backend/data/precedents/
  raw/                    법제처 공식 원문 (수집기 산출물, git 추적)
  seed_cases.json         팀 큐레이션 (정민재 편집 대상 — README 참고)
  eval_set.json           검색 평가 기대 쌍 (판례 추가 시 함께 갱신)
  index/                  벡터 인덱스 (재생성 산출물 — .gitignore, 아래 §2로 재구축)
```

**격리 보장**: `rule_engine.py`·`report_builder.py`·`thresholds.py`에는 `precedent`라는
문자열 자체가 없고, `tests/test_precedent.py::test_rule_engine_does_not_import_precedent`가
이를 봉인한다. 데이터 흐름은 `RuleVerdict → (읽기) → 판례 검색` 한 방향뿐이다.

## 2. 실행 방법 (처음부터 끝까지)

```bash
cd backend

# 0) 의존성 (chromadb 추가됨)
.venv/Scripts/python.exe -m pip install -r requirements.txt

# 1) (선택) 판례 수집 — 시드 7건은 이미 raw/에 있음
#    정식 OC 발급: open.law.go.kr 회원가입 → OPEN API 활용신청(승인 1~2일)
#    → backend/.env에 LAW_API_OC=<발급값> 추가. 없으면 OC=test로 동작(개발용).
.venv/Scripts/python.exe scripts/collect_precedents.py --query "임대차 보증금" --org 400201 --max 100

# 2) 적재 (청킹→임베딩→벡터DB). UPSTAGE_API_KEY가 .env에 있으면 자동으로 upstage 백엔드
.venv/Scripts/python.exe scripts/ingest_precedents.py

# 3) 검색 품질 측정 (개선 루프의 기준점 — 바꾸기 전/후 반드시 비교)
.venv/Scripts/python.exe scripts/eval_retrieval.py --show-scores

# 4) E2E 데모 (Solar 설명 포함은 --explain, 크레딧 소모)
.venv/Scripts/python.exe scripts/demo_precedent.py --fixture mortgage_heavy --explain

# 5) 테스트 (전부 오프라인 — 크레딧 0)
.venv/Scripts/python.exe -m pytest tests/ -q
```

**지속 업데이트(프레시니스) — 설계 확정, 구현 대기** (decisions.md 2026-07-22 프레시니스 항목):
- 의미론: **사건번호 기준 idempotent** — 추가/교체는 `collect --nb <사건번호> --force`(재수집
  덮어쓰기), 삭제는 `removals.json` 기재(원본 보존 + 사유 추적, 물리 삭제는 --purge만).
- 증분 수집: 수집 프로필별 `lawSearch(sort=ddes)` + 선고일 커서 — 기존 일련번호를 만나면
  조기 종료. 신규 유입은 자동으로 `verified=False`(게이트가 노출 차단) → 검수 큐 →
  seed_cases.json 승격(자동 태그 재검토 포함).
- 재임베딩 트리거: 모델 교체(서명 변화 — 자동 감지)·청킹 규칙 변경·컨텍스추얼 도입 = 전체
  재구축. 소량 갱신은 청크 해시 증분(서명 동일 시만).
- 원커맨드(설계): `scripts/update_precedents.py` — 수집→중복 제거→적재→평가→검수 큐 요약.
  상세 설계는 docs/rag-expansion-review-2026-07-22.md §4.

환경변수(전부 선택 — 기본값으로 그냥 돌아감):
| 변수 | 값 | 기본 |
|---|---|---|
| `PRECEDENT_EMBEDDING_BACKEND` | upstage / local / hash | 키 있으면 upstage, 없으면 hash |
| `PRECEDENT_VECTOR_STORE` | chroma / json | chroma (import 실패 시 json) |
| `LAW_API_OC` | 법제처 API 인증값 | test (개발용) |
| `PRECEDENT_LOCAL_MODEL` | HF 모델명 | kakaocorp/kanana-nano-2.1b-embedding |

## 3. GPU 실행 지점 (대량 임베딩 배치)

**RAG는 학습이 아니다.** GPU가 필요한 구간은 "판례 수만 건 → 벡터" 1회성 배치뿐이고,
그 지점은 코드에서 `embedding.LocalEmbeddingBackend` 하나다.

대회 GPU에서의 실행 절차:
```bash
# 권장: 임베딩 배치용 별도 venv (Python 3.12~3.13 — sentence-transformers가 3.14 미지원)
python3.12 -m venv .venv-embed && source .venv-embed/bin/activate
pip install -r requirements.txt sentence-transformers

PRECEDENT_EMBEDDING_BACKEND=local python scripts/ingest_precedents.py
# 끝. index/ 폴더를 서비스 서버로 복사하면 이전 완료 (Chroma는 폴더가 곧 DB)
```

- **모델**: `kakaocorp/kanana-nano-2.1b-embedding` (카카오 공식 배포, from-scratch 계보,
  한국어 검색 nDCG@10 65.0, CC-BY-NC — 비상업 대회 무방). **모델 사용 기준(decisions.md
  2026-07-22)에 따라 초기 후보 KURE-v1(개인·학계 외산 베이스 파인튜닝)은 배제·교체됨.**
  ⚠ 채택 확정 전 두 가지 확인: ⑴ 512토큰 권장이라 청킹 길이(현행 900자 상한) 점검
  ⑵ Upstage API 임베딩과 평가셋 A/B — 결과에 따라 "임베딩은 Upstage API 배치(Embed 2,
  10만 건 ≈ $3), GPU는 다른 구간" 재편도 열려 있다(rag-expansion-review §6.1).
- **규모 감각**: 판례 10만 건(청크 ~30만, 평균 500토큰)이면 A100에서 **약 40분~1시간**,
  RTX 4090급에서 2~6시간. 우리 현실 규모(수천~수만 건)는 어느 GPU든 수십 분 내.
  (2.1B 모델은 0.6B 기준 추정치보다 다소 느릴 수 있음 — 배치 시 실측.)
- **주의**: 백엔드를 바꾸면 벡터 공간이 달라진다 — 반드시 **전체 재적재**(스크립트 1회).
  질의 시 서명 불일치는 store가 명시적 에러로 막아 준다.
- 검색기는 질의 1건만 임베딩하므로 서비스 런타임에는 GPU가 필요 없다
  (local 백엔드로 서비스하려면 서버에도 모델이 필요하니, 운영은 upstage 백엔드 유지 권장).

## 4. 확장 지점 (고도화 후보와 그 자리)

1. **라우터 연결 (E-3)**: `service.PrecedentService.match_for_report(report)`가 진입점.
   `routers/reports.py::report_cases`에서 dummy_data 호출을 교체하면 된다. 단:
   - 저장된 Report에는 판정 facts가 없어 `tags_from_report`가 detailText 문구로 태그를
     파생한다(거칢). **권장: analyze 시점에 위험 태그를 리포트에 저장**(계약 additive 확장
     또는 서버 내부 저장) — `docs/api-contract-cases-v2-proposal.md` 참고.
   - 응답 스키마 확장(advice·sourceUrl·matchedTags)은 같은 제안서에 정리해 뒀다.
2. **판례 카드 advice**: `PrecedentDoc.advice`는 큐레이션 전용(LLM 불가침, 테스트 봉인).
   정민재의 실데이터가 오면 `seed_cases.json`에 채우기만 하면 된다.
3. **검색 품질 튜닝**: `retrieval.py` 상단 상수(RRF 가중, 후보 폭, 유사도 하한)가 튜닝 지점.
   **반드시 `eval_retrieval.py` 전/후 비교로만 바꿀 것.** 판례가 늘면 eval_set.json에
   기대 쌍을 같이 늘려야 지표가 의미를 유지한다.
4. **재정렬(리랭킹)**: 외산 베이스 크로스인코더(dragonkue 등)는 모델 사용 기준(decisions.md
   2026-07-22)에 따라 배제됐다. 대체 경로 2단 — ⑴ 하이브리드 가중 튜닝(RRF 가중·후보 폭,
   비용 0, 평가셋 루프의 일부) ⑵ **국내 LLM listwise 재정렬**(Solar 1순위·EXAONE 대안):
   RRF 융합 뒤 게이트 통과 후보 10~20건의 **노출 순서에만** 관여(판정·게이트 무접촉),
   temperature 0 + 리포트 단위 캐시로 결정성 확보. 대량 수집 후 평가셋 A/B로 채택 확정
   (RankGPT/RankZephyr 근거 — rag-expansion-review §6.2).
5. **형태소 분석기**: `_tokenize`는 의존성 없는 어절+바이그램이다. kiwipiepy 등으로
   교체하면 BM25가 좋아질 수 있다 — 역시 평가셋으로 증명 후.
6. **대량 수집 큐레이션 워크플로**: 자동 태깅(`ingest.auto_tags`)은 키워드 규칙이라
   거칠다. 수집 규모가 커지면 "자동 태깅 → 정민재 검수 → verified 승격" 흐름을
   seed_cases.json 양식 위에 얹을 것 (미검수분은 verified=False라 노출 차단됨 — 안전).

## 5. 가드레일 요약 (지키던 것을 계속 지키기)

| 원칙 | 강제 지점 | 봉인 테스트 |
|---|---|---|
| 판례는 판정에 불개입 | rule_engine에 import 없음, 단방향 데이터 흐름 | test_rule_engine_does_not_import_precedent |
| 실검색 판례만 인용 | explainer가 case_id 대조, 불일치 폐기 | test_explainer_discards_fabricated_case_ids |
| 유사도 미달 비노출 | retrieval 게이트 (verified·태그·하한 3중) | test_gate_* 3종 |
| 사건번호·출처 필수 | 서버가 doc에서 복사(LLM 통로 없음) | test_service_builds_cases_with_citation_fields |
| advice 불가침 | PrecedentExplanation에 필드 없음(extra=forbid) | test_advice_passes_through_untouched |
| 단정 금지 문구 | E-2 금지어 목록 공유 | test_explainer_banned_phrase_falls_back |
| "판례 없음 ≠ 안전" | FALLBACK_* 문구에 확인 유도 포함 | test_service_returns_honest_fallback_when_no_risk |
| 신규 유입 기본 미검수 | ingest가 대량 수집분 verified=False 부여 → 게이트 차단 | test_build_documents_auto_tags_raw_without_seed |
