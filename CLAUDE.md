# 전세AI프 (JeonseAI)

> Claude가 매 세션 가장 먼저 읽는 안내서. **짧게 유지한다.**
> **지금 상태·할 일 = [`docs/NOW.md`](docs/NOW.md) 하나만 본다.**
> (2026-10-21 문서 교통정리 — 옛 문서는 보관 브랜치 `archive-2026-10-21`에 그대로 있다: `git show archive-2026-10-21:docs/<파일>`)

## 0. 무엇을 믿나 (헷갈리면 이 순서)

1. **코드와 테스트** — 유일한 정답. 문서와 코드가 다르면 코드를 믿고 문서를 고친다.
2. **`docs/NOW.md`** — 코드에서 확인한 현재 상태 + 결선 계획. **작업이 끝날 때마다 갱신**한다.
3. **`docs/decisions.md`** — 왜 그렇게 정했나 (append-only, 판정 수치의 출처).
4. **`docs/competition-facts.md`** — 코드 밖 사실(대회·팀·일정). 여기 없는 팀·대회 사실은 지어내지 않는다.

그 밖의 레퍼런스: `docs/api-contract.md`(앱↔서버 JSON 계약), `docs/personas.md`(페르소나 2인 — 리뷰 에이전트가 읽음).
**이 목록 밖의 `.md`를 새로 만들지 않는다** (CI가 검사한다). 측정 결과·세션 기록은 PR 설명에 쓴다.

## 1. 서비스 한 줄

전세 계약 **전부터 입주 다음 날까지**, 등기부등본으로 **깡통전세·전세사기 위험**을 찾고
부동산 비전문가에게 **근거와 함께 쉬운 말로** 알려주는 안드로이드 앱 (Flutter + FastAPI).

- 대회: AI ROOKIE **1차 결선 = 2026-11-03~05 킨텍스 현장 부스 시연** (심사위원 자유 방문·질의응답).
  시연은 **실제 등기부로 실제로 동작**해야 한다. 무대 세트 금지.
- 타깃: 부동산 지식이 거의 없는 사람(사회초년생·첫 전세·신혼부부). 결론 먼저 크게, 근거는 펼쳐 보기.

## 2. 불변 원칙 (반드시)

1. **위험 판정 = 규칙 엔진만** (ML 분류 금지). **LLM은 설명·문장만** — 판정을 바꾸거나 새로 만들 수 없다.
2. 가중치·임계값은 `권위 출처 확보 → docs/decisions.md 기록 → 코드` 순서로만. **출처 없는 수치 금지.**
   인정 출처: HUG 공식 기준, 정부·금융기관 기준, 판례, 법령. (상세: `.claude/rules/risk-scoring.md`)
   인터뷰 같은 비공식 자료는 **판정하지 않는 곳**(문구·질문·조언)에만 쓴다.
3. **보수적 편향**: 애매하면 경고 쪽. 정보가 없으면 절대 "양호" 없이 "확인 필요".
4. **국내 AI 모델만** (대회 규정, 확약서) — Upstage(Information Extract·Document OCR·Solar Pro 2·Embedding),
   LG K-EXAONE(비교 검증용). 해외 AI(구글 ML Kit 등 온디바이스 포함) 금지. 일반 영상처리(OpenCV 등)는 AI가 아니라 허용.
5. **개인정보**: 실명·주민번호는 화면·로그·저장소에 남기지 않는다. `backend/test_samples/`·`backend/out/` 커밋 금지.
6. 문서·주석·커밋 메시지·응답은 **한국어**.

## 3. 팀

남규혁(메인 개발) · 이영호(팀대표, LLM·RAG) · 정민재(법률 큐레이션·검수) · 최가은(현장 인터뷰) · 김시원(경쟁 분석·페르소나).
"팀장"이 아니라 **"팀대표"**(서류 용어). "서연·지수"는 팀원이 아니라 **페르소나 이름**이다.

## 4. 작업 방식

- 브랜치: `feat/<주제>` → **PR → `main`**. `main`은 언제나 시연 가능한 상태로 둔다.
- 루프: 테스트 → 작은 단위 커밋 → 주제별 PR → CI 통과 → 머지 → **`docs/NOW.md` 갱신**. 멈추지 않고 반복한다.
- 아키텍처·되돌리기 어려운 결정만 사람에게 묻는다. 확정된 결정은 `/add-decision`으로
  decisions.md에 **[처음 의도 → 바꾼 이유(근거) → 최종 결정]** 스토리로 남긴다 (발표 원재료).
- 보고는 **쉽게, 사람이 직접 할 일만 짧게**.
- 리뷰 에이전트(`.claude/agents/`): 판정 로직 바꿀 때 `rule-auditor`, 화면 바꿀 때 `design-reviewer`·페르소나 2인,
  시연 리허설 전 `judge-reviewer`.
- 백엔드는 `.claude/rules/api-design.md`를 따른다.

## 5. 실행

```bash
# 서버 — backend/.env 에 UPSTAGE_API_KEY (견본: backend/.env.example)
cd backend && python -m venv .venv && source .venv/Scripts/activate   # macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt && uvicorn app.main:app --reload      # API 문서: http://127.0.0.1:8000/docs
python -m pytest -q        # 키 없이 돈다 (2026-10-21: 681 통과 · 6 건너뜀)

# 앱 — 지금은 USB 실기기 + adb reverse 필요 (배포 작업으로 바뀔 예정: docs/NOW.md P0)
cd frontend && flutter pub get && adb reverse tcp:8000 tcp:8000 && flutter run
flutter test
```

- 시세 DB(`backend/data/price/*.sqlite`)와 판례 인덱스(`backend/data/precedents/index/`)는 git에 없다(용량·재생성 가능).
  시세: `python scripts/build_price_db.py --source official_price <원본>` / 판례: `python scripts/ingest_precedents.py`.
- 검사: `python3 scripts/check_docs.py`(문서 양산 금지). CI = `.github/workflows/ci.yml` (PR마다 서버·앱 테스트).
- 코드 주석에 나오는 옛 문서 경로(`docs/ocr-highlight-findings.md` 등)는 보관 브랜치에서 연다:
  `git show archive-2026-10-21:docs/<파일>`.
