"""판례 RAG 모듈 — 위험 판정 리포트에 붙는 "유사 실제 판례" 검색·설명 환경.

가드레일 (이 모듈의 불변 원칙 — CLAUDE.md 3절의 연장):
1. **판례는 설명 전용이다.** 이 모듈의 어떤 출력도 위험 판정(등급·점수·수치)에
   영향을 주지 않는다 — 규칙 엔진(rule_engine.py)은 이 모듈을 import하지 않으며,
   데이터 흐름은 언제나 `판정 → 판례 검색` 한 방향이다.
2. **실제 검색된 판례만 인용한다.** 검색 결과가 없거나 유사도 하한선 미달이면
   판례 섹션은 정직한 폴백으로 처리한다(지어내기 금지).
3. **국내 스택**: 설명 LLM = Solar Pro, 임베딩 = Upstage API 또는 로컬 오픈모델.

모듈 구성 (파이프라인 순서):
- collector(스크립트)  : 법제처 Open API 판례 수집 → data/precedents/raw/
- chunking.py          : 판결요지 중심 청킹
- embedding.py         : 임베딩 백엔드 추상화 (Upstage API ↔ 로컬 GPU 모델 ↔ 오프라인 해시)
- store.py             : 벡터 저장소 (파일 영속화 + 코사인 검색, 인터페이스 뒤 교체 가능)
- retrieval.py         : 하이브리드 검색 (BM25 키워드 + 벡터) + 위험 유형 필터 + 유사도 게이트
- explainer.py         : Solar Pro가 검색된 판례를 쉬운 말로 설명 (extra="forbid" 가드레일)
- service.py           : 판정(RuleVerdict/Report) → 검색 → 설명 오케스트레이션

인수·확장 지점은 docs/precedent-rag.md 참고.
"""

from .service import PrecedentService  # noqa: F401
