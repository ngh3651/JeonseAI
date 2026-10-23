# NOW — 지금 상태와 할 일

> **마지막 확인: 2026-10-22** · 서버 1단계 `feat/p0-backend-deploy`(PR #3) + 앱 1단계 `feat/p0-app-deploy`(PR #4 — PR #3 다음에 머지) + 촬영·개인정보 `feat/p1-capture-privacy`(PR #5) 반영
> · 계약 지킴이 알림·지금 할 일·요금제·테스트 결제 = `feat/p1-journey-business`(PR #5 다음에 머지)
> **이 파일이 현재 상태의 유일한 정본이다.** 작업이 끝날 때마다 고친다. 코드와 다르면 코드가 맞다.

## 1. 한 줄 상태

서버는 **클라우드에 올릴 준비가 됐다**(기기별 기록·영구 저장·앱 키·속도 제한·실명 마스킹·Dockerfile — 아래 "Railway 배포 방법").
앱도 **배포용 APK를 만들 준비가 됐다**(서버 주소·앱 키를 빌드 때 넣기 · 모든 요청에 기기 id · 쉬운 말 에러 · 릴리스 서명 자리 · 사진 속 이름 가리기 · CI가 APK 자동 빌드).
남은 것은 **사람이 할 일**: Railway에 올리기 → 저장소 변수 `API_BASE_URL` → 서명 비밀값 1개(`ANDROID_SIGNING_BUNDLE`) 넣기 → 고정 링크에서 APK 설치(아래 6-2). 가짜 로그인·종이 촬영본 미검증은 그대로.
**계약 지킴이**(P1-2)가 실물이 됐다: 잔금 하루 전·당일·입주 다음 날 **폰 알림** + 대조 결과 맨 위 **지금 할 일** 카드. **요금제 + 토스 테스트 결제**(P2-1)도
끝까지 돈다(가격은 예시, 실제 청구 없음, 패스는 표시만). 카카오 로그인은 다른 작업.

## 2. 코드 기준 사실표

| 영역 | 지금 코드 | 결선에서 문제 | 근거 |
|---|---|---|---|
| 분석 | 사진 → Upstage IE·OCR·Solar 병렬 → 규칙 엔진 판정 → Solar 설명. 실측 21~31초 | — | `backend/app/services/report_builder.py` |
| 같은 사진 재현성 | 같은 사진 5회 → IE 결과 거의 같음(가압류 `cause` 글자만 흔들림, 7/28 실측) | 결과가 매번 다른 원인은 **사진이 매번 달라서**다 | 보관 브랜치 `ie-reproducibility-2026-07-28*.md` |
| 촬영 | 시스템 카메라(`image_picker`), 미리보기·가이드 없음. ✅ **서버 촬영 검사**(P1-1, 2026-10-22): IE·OCR **전에** 장마다 흐림·어두움·빛 번짐·글자 없음·해상도(Pillow+numpy, AI 아님, 장당 0.15~0.4초) — 심하면 **분석 전 거절**(400, 크레딧 0원, "2쪽이 흐려요 — 다시 찍어 주세요 (이유)"), 가벼우면 분석하고 리포트에 `captureCheck`. OCR 뒤 쪽 번호(N/M) 안 보이면 '잘림 의심'. 비상 스위치 `CAPTURE_CHECK=warn/off`. ✅ 앱: 거절되면 촬영 화면으로 돌아가 **몇 쪽이 왜** + **그 장만 다시 찍어 바꾸기**(나머지 장 그대로) → 다시 보내기. 리포트에도 '확인 필요' 장 안내 + [다시 찍어 새로 분석]. ✅ **같은 사진 = 같은 결과**: 같은 기기·같은 사진 묶음(순서 포함)·같은 보증금·시세면 24시간 동안 같은 리포트를 크레딧 없이(`ANALYSIS_CACHE_HOURS`) — 새로 배포하면(커밋이 바뀌면) 저절로 빗나감 | 기준값은 **합성 사진으로만** 정했다 — **종이 촬영본은 아직 한 번도 검증 안 함**(아래 할 일의 측정 도구로 잰다). 기울기·원근 보정 없음 | `backend/app/services/capture_check.py`, `analysis_cache.py`, `frontend/lib/screens/search/capture_issue_panel.dart` |
| 서버 주소 | ✅ **빌드 때** 넣는다: `--dart-define=API_BASE_URL=https://…`(안 넣으면 `http://127.0.0.1:8000` + `adb reverse`). 앱 키도 `--dart-define=APP_KEY=…`(있을 때만 `X-App-Key`). CI 'APK 빌드'가 저장소 변수 `API_BASE_URL`·비밀값 `APP_KEY`로 release APK를 만든다 | 변수 `API_BASE_URL`이 아직 없다(Railway 주소가 나와야 넣는다) → 지금 CI APK는 USB용 기본 주소 | `frontend/lib/app/config.dart`, `.github/workflows/ci.yml` |
| 앱 서명·배포 | ✅ **고정 키**(2026-10-22): CI는 비밀값 **`ANDROID_SIGNING_BUNDLE` 하나**(키 파일 + key.properties 묶음)로 서명한다(예전 방식 비밀값 4개도 됨). 없으면 디버그 키로 되돌아감. versionCode = CI 실행 번호 → 새 APK는 늘 업데이트로 깔린다. **main에 합칠 때마다** 고정 링크(`…/releases/download/app-latest/jeonseai.apk`)에 최신 APK가 올라간다(고정 키일 때만). 평문(http) 통신은 개발 빌드·http 주소 APK에서만 | 비밀값을 넣기 전까지는 디버그 키 APK(Actions Artifacts에만). 고정 키 APK로 처음 바꿀 때 한 번은 예전 앱을 지우고 설치 | `frontend/android/app/build.gradle.kts`, `.github/workflows/ci.yml` |
| 분석 기록 | ✅ **기기별**(`X-Device-Id`) + **SQLite 영구 저장**(`${DATA_DIR}/app.db`, 리포트·대조 기준). 다른 기기 기록은 404. 판례 카드 캐시만 메모리(재시작 뒤 다시 만듦). 기록 DB를 못 열어도 목록은 예시 리포트를 돌려줌. ✅ 앱(PR #4)이 처음 실행 때 UUID를 한 번 만들어(`device_id_v1`) **모든 요청**에 싣는다 | 옛 APK(8/14 코드)는 여전히 공용 `legacy-device`를 쓴다 → 새 APK로 바꿔 설치. 앱을 지우면 새 id(예전 기록과 끊김) | `backend/app/services/store.py`, `dependencies.py`, `frontend/lib/services/device_id.dart` |
| 배포 설정 | ✅ 저장소 맨 위 `Dockerfile`·`railway.json`, `0.0.0.0:$PORT`, 시작 준비 `prepare_runtime.py`(시세 DB 내려받기·판례 인덱스). `DEV_MODE_AUTH` 없앰 → 원응답 저장은 `SAVE_RAW_RESPONSES`(기본 꺼짐) | Railway에 아직 안 올림(사람이 클릭 — 아래 배포 방법). 시세 DB 파일을 올릴 곳(`PRICE_DB_URLS`) 미정 | `Dockerfile`, `backend/scripts/prepare_runtime.py` |
| 보안 | ✅ `APP_KEY` 설정 시 `/api/*`는 `X-App-Key` 필요(401). 분석·대조는 최근 1시간 **세 겹** 상한(429) — 기기×IP 30회 · IP 60회 · 서버 전체 300회(`RATE_LIMIT_*_PER_HOUR`, PR #3 e8365a4) + **서버 전체 하루 500회**(`RATE_LIMIT_GLOBAL_PER_DAY`, 2026-10-22 — APK가 공개 링크로 나가 앱 키를 누구나 꺼낼 수 있어서). 1회 사진 20장 초과는 400. `DISABLE_DOCS=1`이면 API 문서 끔 · 접근 로그 끔(챗봇 질문이 로그에 안 남게). ✅ 앱은 빌드 때 넣은 `APP_KEY`를 `X-App-Key`로 보내고, 401·400(기기 정보)·429를 "최신 앱을 설치해 주세요 / 잠시 후 다시"로 보여 준다 | Railway `APP_KEY`와 GitHub 비밀값 `APP_KEY`가 **같은 값**이어야 한다 — 서버에 먼저 켜면 키 없는 APK가 401로 막힌다 | `backend/app/main.py`, `frontend/lib/services/api_client.dart` |
| 개인정보 | 서버 ✅: 원응답 저장 기본 꺼짐, 하이라이트 제목·명단 일치 문장은 `홍○○`, 개인 근저당권자도 가려서 Solar에 보냄, 챗봇 로그에 질문 원문 없음 — DB·로그·저장 JSON 실명 0건 자동 테스트(`test_pii_persistence.py`). 원본 사진은 서버에 저장 안 함. ✅ **사진 속 실명·주민번호 자리**(P0-2b, 2026-10-22): 서버가 OCR에서 이름 칸(소유자·공유자·이전 소유자·채무자·개인 근저당권자·전세권자·임차권자·개인 채권자)과 주민·법인번호의 **좌표만** `privacyMasks`로 보낸다(글자 없음, 은행·회사·관공서는 제외, 말소된 줄도 포함). 앱(마이 → '개인정보' → **'사진 속 이름 가리기'**, 기본 꺼짐): 켜면 뷰어·리포트 미리보기에서 그 자리 **전부** + 집주인 이름을 불투명 상자로 덮는다(빚·압류 형광펜은 그대로). 이름 자리를 모르는 쪽(옛 기록·OCR 실패)은 **쪽 전체**를 덮고 이유를 말한다. 사진 문구는 앱 전체가 한 문장: "사진은 분석에만 쓰고 서버에는 저장하지 않아요. 이 휴대폰에만 최근 분석 5건의 사진이 남아요." | 분석 **전** 화면(촬영 확인·사진 트레이·크게 보기)은 위치를 몰라 가리지 못한다(스위치 설명에도 적었다 — 부스에서는 찍는 장면만 미러링 화면에서 피한다). 기록 목록·공유 화면 이름 마스킹도 아직(공유 버튼은 준비 중 안내뿐). 스위치를 끄면(기본) 이름이 보인다 — 부스에서는 켠다. 실제 종이 촬영본으로 가림 상자를 눈으로 확인한 적 없음(합성 OCR로만 시험) | `privacy_masks.py`, `registry_viewer_screen.dart`, `privacy_settings.dart`, `registry_photo_store.dart` |
| 계약 여정 | 9단계, 날짜 4종(폰에만 저장), 다시 찍어 대조 → 바뀜/그대로/일부/기준 없음/다른 집. ✅ **폰 알림 3번**(2026-10-22): 잔금 하루 전 오전 9시 · 당일 오전 8시 · 입주 다음 날 오전 9시 — 날짜를 바꾸면 다시 걸고 지우면 취소, 권한은 날짜를 저장하는 순간 이유와 함께(거절하면 같은 세 날 배너), 알림을 누르면 그 집 여정. ✅ 대조 결과 맨 위 **지금 할 일**(위험 줄 → "잔금 보내기 전에 멈추세요" + 중개사 문자 복사 · 그대로 → 입금 전 체크리스트 · 일부 → 다시 찍기) | 알림은 몇 분 늦을 수 있다(정확한 알람 권한 안 씀). 실기기에서 폰을 꺼 둔 채 울리는지는 **사람이 확인**(아래 10절) | `journey_reminders.dart`, `journey_reminder_service.dart`, `compare_next_step.dart` |
| 로그인 | 가짜(아무 값이나 통과), 자동 로그인 "영호" | 비즈니스 껍데기 없음 | `config.dart` `devAutoLogin` |
| 결제 | ✅ (2026-10-22) 요금제 화면(마이·여정 맨 아래) — 무료 · 계약 지킴이 패스 · 기관용(문의), 가격은 `pricing.json`의 **예시**. 토스 공식 결제위젯 SDK로 **테스트 결제** → 서버가 요금제 가격으로 금액 검사 후 승인(테스트 키만, `live_` 거부) → 패스(기기별) → 영수증 "테스트 결제 — 실제 청구 없음". 패스가 있으면 알림 배너·다시 대조·폰 알림에 "지킴이 패스" **표시만** | 가격 미확정(6절 #5). 패스는 기기에 붙어 앱을 지우면 안 보인다 — 카카오 로그인 뒤 계정으로(주인 키는 서버 `get_pass_owner`·앱 `passOwnerKey` 한 곳) | `payments.py`, `pricing.json`, `checkout_screen.dart` |
| 웹 버전 | 없음 (`web/` 폴더 없음). 만들려면 사진 처리 8~10개 파일 수정, 1~3일 | 아이폰 심사위원은 체험 불가 | — |
| 시세 | 실거래가 → 공시가격×1.40 → 기준시가 3단 조회, DB 1,807만 행(로컬 전용) | 배포 서버로 DB 파일을 옮겨야 함 | `price_resolver.py`, `.gitignore` |
| 테스트 | 서버 **916 통과·7 건너뜀**(키 없이, 2026-10-22 — PR #5의 893 + 요금제·결제 23. 건너뜀 7 = 실명 원본 파일이 있어야 도는 것) / 앱 **309건**(2026-10-22 — PR #5의 246 + 알림·지금 할 일·요금제·결제 63) | — | `.github/workflows/ci.yml` (문서·서버·앱·**APK 빌드** 4개 작업) |

## 3. 결선 사실

상세는 [`competition-facts.md` §8](competition-facts.md). 핵심만:
**11/3~5 킨텍스 부스** · 세팅 **11/2 17~20시** · 심사위원 자유 방문(설명·시연·질의응답) ·
**전원·인터넷은 QR 사전조사로 미리 신청**(<https://m.site.naver.com/2gWR1>) · 보고서 10/23(이영호).

## 4. 전략 (팀 결정, 2026-10-21)

- 목표는 입상이 아니라 **킨텍스에서 부끄럽지 않게**. 발표는 기술보다 **방향성·페르소나·참여형**.
- 대신 **질의응답에서 무너지지 않을 실물**이 있어야 한다 → 개발(남규혁)의 몫.
- 포장(현수막·포스터·부스 참여 아이템·영상·PPT) = 이영호 팀대표 + 팀원.
- 안 한 것을 했다고 말하지 않는다. 현장에서 본선보다 **발전된 실물**을 보여준다.

## 5. 할 일 — 순서와 완료 조건

| 순서 | 일 | 완료 조건 (이게 돼야 끝) | 목표일 |
|---|---|---|---|
| **P0-1** | **배포 (Railway)** — 서버 ✅(2026-10-22, PR #3): `DEV_MODE_AUTH` 분리 · `0.0.0.0:$PORT` · Dockerfile · 볼륨(`/data`)에 기록 DB·판례 인덱스 · 시세 DB 내려받기(`PRICE_DB_URLS`) · 앱 키 + 속도 제한 · **기기별 기록 분리** · 기록 영구 저장. 앱 ✅(2026-10-22, PR #4): 서버 주소·앱 키 빌드 설정화 · `X-Device-Id`·`X-App-Key` 보내기 · 릴리스 서명 자리(키 없으면 디버그 키) · CI APK 자동 빌드(`jeonseai-apk`). 남은 것(사람): Railway에 올리기 · 시세 DB 파일 올리기(GitHub Release 등) · 저장소 변수 `API_BASE_URL` + 비밀값 `APP_KEY` · 서명 비밀값 `ANDROID_SIGNING_BUNDLE` 1개(키는 2026-10-22에 만듦 — 아래 6-2) · 고정 링크로 설치 | USB 없이 LTE 폰에서 설치 → 분석 → 리포트. 서버 재시작 뒤에도 기록 유지. 다른 폰에서 내 기록 안 보임 | 10/23 |
| **P0-2** | **개인정보** — 서버는 원본 사진·실명을 저장·기록하지 않음(로그 마스킹) ✅(2026-10-22, 자동 테스트 `test_pii_persistence.py`) · 사진의 이름 칸 **가리기 스위치** ✅(2026-10-22, PR #4 — 마이 → 개인정보, 부스 시연에선 켬 — 내 폰의 내 등기부에선 집주인 이름 대조 기능 유지) · "저장 안 함" 문구와 실제 동작 일치 ✅(PR #4) · 사진의 **다른 이름·주민번호 칸**(채무자·이전 소유자 등) ✅(2026-10-22, `feat/p1-capture-privacy` — 서버 `privacyMasks` + 앱이 전부 덮음, 모르는 쪽은 통째로) · 남은 것: 분석 전 화면(촬영 확인·트레이) 가리기 · 기록 목록·공유 화면 이름 마스킹(홍*동) | 서버 저장소·로그에 실명 0건(자동 테스트) · 가리기 켜면 화면에 실명 0건 | 10/23 |
| **P1-1** | **촬영 안정화** — 장별 흐림·어두움·잘림(꼬리말 페이지 표식) 검사 → 그 장만 다시 찍기 안내 ✅ · 같은 사진 = 같은 결과(해시 캐시) ✅ · 일관성 측정 도구 ✅(`measure_consistency.py`) (2026-10-22, `feat/p1-capture-privacy`) · 남은 것: **종이 촬영본으로 실제 측정**(아래 할 일) · 기울기·원근 보정(OpenCV, AI 아님) · IE와 OCR이 다른 칸은 "확인 필요" | 같은 종이 등기부를 10번 찍어 판정 일치 9회 이상, 나머지는 반드시 재촬영 안내 (전후 수치 기록) | 10/25 |
| **P1-2** | **차별화 = 계약 지킴이** — 진짜 알림 ✅(2026-10-22 — 잔금 하루 전·당일·입주 다음 날, 로컬 알림) · 대조 결과 → "지금 할 일" 카드 ✅ · 남은 것: 실기기에서 폰을 꺼 둔 채 울리는지 확인(사람) · (발표용) 등기가 실제로 바뀐 이력이 있는 등기부를 찾으면 그 기록으로 재현 | 폰을 꺼 둬도 알림이 울림 + 시연 대본 한 바퀴가 막힘 없이 돈다 | 10/28 |
| **P2-1** | **비즈니스 껍데기** — 카카오 로그인(실동작, 기록이 계정에 붙음 — 다른 작업) + 요금제 화면 ✅ + 토스페이먼츠 테스트 결제 ✅ → "계약 지킴이 패스" 열림 ✅(2026-10-22). 남은 것: 가격 확정(6절 #5) · 실기기에서 결제 한 바퀴(사람) · 로그인 뒤 패스를 계정으로 옮기기 | 결제 흐름이 끝까지 돈다 ("테스트 결제 — 실제 청구 없음" 표시) | 10/28 |
| **P2-2** | **숫자** — 일관성(같은 등기부 N번 → 같은 판정 %), 처리 시간, 시세 매칭률 83.3%·오탐 1.3%(측정 완료), 테스트 수, Solar 단독 vs 우리 방식(국내 모델끼리) | 포스터·PPT에 넣을 표 1장 | 10/28 |
| P3 | (여유 시) 웹 버전 | 아이폰 브라우저에서 분석 1회 | — |

> ⚠ 본선 이후 Upstage 키가 바뀜 — 배포 전 `python scripts/check_keys.py`로 확인. 키는 backend/.env와 Railway Variables에만 넣고 채팅·커밋에 쓰지 않는다.

- **10/26까지** 포스터용 앱 화면 캡처를 팀에 넘긴다 (인쇄 주문 10/28).
- **P1-1 숫자 재기(사람, 키 필요)**: 종이 등기부 하나를 10번 찍어 `촬영묶음/<등기부>/01~10/page_N.jpg`로 두고
  `cd backend && python scripts/measure_consistency.py ../촬영묶음 --deposit <보증금>` → `backend/out/consistency_*.md`(판정 일치율·재촬영 안내·처리 시간). 크레딧: 묶음당 IE 1 + OCR 장수 + 설명 1.
- **10/29 18시 기능 동결** → 이후는 버그만. 10/30~11/1 리허설·비상 영상·장비 점검.

## 6. 결정 (2026-10-21 규혁)

| # | 결정 | 내용 |
|---|---|---|
| 1 | 서버 위치 | **클라우드 = Railway.** 노트북 서버는 쓰지 않는다 (폰 LTE만으로 동작) |
| 2 | 로그인·결제 | **카카오 로그인(실동작) + 토스페이먼츠 테스트 결제** |
| 3 | 웹 버전 | **이번엔 안 함** (체험은 부스 폰 2대) |
| 4 | 변동 감지 시연 | **라이브로 보여주지 않는다** — 등기는 자주 바뀌지 않는다. 실제로 바뀐 이력이 있는 등기부를 찾으면 그 기록으로 재현해 **발표 자료**에 넣는다 |
| 5 | 요금제 가격·문구 | ⏳ 열림 — 팀이 10/25까지 확정 (그 전엔 화면에 "예시" 표기). 지금 자리 채움 값: 계약 지킴이 패스 **9,900원**(계약 1건) — `backend/data/pricing.json`의 `price`·`priceText`를 같이 고치면 앱·결제 금액 검사가 함께 바뀐다 |
| 6 | LG EXAONE 서비스 사용 여부 | ⏳ 열림 — 10/22까지 규혁·팀대표 결정. 1차 결선 보고서(10/23 제출)에 들어갈 내용이라 그 전에 정해야 한다. 지금 코드는 서비스 경로에서 EXAONE을 안 부름(기본 provider = upstage, SHADOW_LLM 기본 off) |
| 7 | 기록 보관 기간 | ⏳ 열림 — 기록 보관 기간(예: 30~90일 뒤 자동 삭제) 결정 필요. 기록에는 **주소**가 남고, 주소만 있으면 등기부를 떼어 소유자를 알 수 있다(이름 해시는 되찾는 속도를 늦출 뿐). 지금 코드는 자동 삭제가 없다 |

## 6-1. Railway 배포 방법 (서버)

> 앱 쪽은 **6-2**(APK 받는 법)를 본다. 순서: 서버를 올린다 → 주소를 저장소 변수에 넣는다 → APK를 받는다.

0. **키 확인**: `cd backend && python scripts/check_keys.py` → Upstage가 "정상"이어야 한다 (키 값은 화면에 안 나온다).
1. Railway → **New Project → Deploy from GitHub repo** → `ngh3651/JeonseAI` 선택 (저장소 맨 위 `Dockerfile`을 알아서 쓴다).
2. **Variables**에 아래 이름으로 넣는다 (값은 채팅·커밋에 쓰지 않는다):
   - `UPSTAGE_API_KEY` · `MOLIT_API_KEY` · `APP_KEY`(앱이 `X-App-Key`를 보내기 전까지는 **비워 둔다** — 넣으면 지금 앱이 401로 막힌다)
   - `TOSS_SECRET_KEY` — 토스페이먼츠 **테스트** 결제위젯 시크릿 키(`test_gsk_…`)만. 비워 두면 토스 문서 공개 테스트 키를 쓴다(그대로 둬도 된다).
     ⚠ `live_`로 시작하는 실제 키를 넣으면 서버가 결제 승인을 **거부**한다(503) — 결선은 테스트 결제만
   - `DATA_DIR=/data` · `PRICE_DB_DIR=/data/price` · `PRECEDENT_INDEX_DIR=/data/precedents-index`
   - `PRICE_DB_URLS` — 시세 DB 파일 주소(쉼표로 구분, `official_price.sqlite(.gz)`·`tax_base.sqlite(.gz)`)
   - `BUILD_PRECEDENT_INDEX=1` — 판례 인덱스가 없을 때 한 번 만든다(⚠ 임베딩 크레딧 1회)
   - `REQUIRE_DEVICE_ID=0` — 새 앱이 나올 때까지 0. ⚠ 그동안 헤더 없는 옛 앱은 **전부 `legacy-device` 칸 하나**를 함께 쓴다 →
     새 앱(`X-Device-Id`를 보내는 앱)이 나오면 **바로 1로**
   - `DISABLE_DOCS=1` — 공개 주소에서 API 문서(`/docs`·`/openapi.json`)를 끈다
   - 속도 제한(선택, 기본값이 있다): `RATE_LIMIT_ANALYZE_PER_HOUR=30`(기기×IP) · `RATE_LIMIT_IP_PER_HOUR=60` ·
     `RATE_LIMIT_GLOBAL_PER_HOUR=300` · `RATE_LIMIT_GLOBAL_PER_DAY=500`(서버 전체·하루). ⚠ **결선 날**에는 부스 폰들이 같은 와이파이(같은 IP)를 쓰므로 IP·전체 상한을 올려 둔다
   - `RAILWAY_RUN_UID=0` — 볼륨에 쓰기 위해 필요(Railway 볼륨은 root 소유로 붙는다)
   - `SAVE_RAW_RESPONSES`는 **넣지 않는다**(실명 원응답 저장 — 로컬 디버깅 전용)
   - (선택) `CAPTURE_CHECK` — 기본 `on`(심하게 흐리거나 어두운 사진은 분석 전 거절). 멀쩡한 사진이 거절되면 `warn` · `ANALYSIS_CACHE_HOURS` — 기본 24(같은 사진 재분석 시 크레딧 0원)
3. **Add Volume** → Mount path **`/data`**.
4. **Settings → Networking → Generate Domain** → 나온 주소로 `https://<주소>/` 를 열어 `"status":"ok"`와
   `historyDb`·`priceDb`·`precedentIndex`·`upstageKey`·`molitKey`가 `true`인지 본다.
   - 서버는 바로 뜨고, 시세 DB 내려받기·판례 인덱스 만들기는 **뒤에서** 돈다 → 처음 몇 분은 `priceDb`·`precedentIndex`가
     `false`일 수 있다(새로고침하면 바뀐다). `historyDb`가 `false`면 `RAILWAY_RUN_UID=0`을 확인한다.
- 헬스체크 경로는 `railway.json`이 `/`로 정한다. (Railway가 이 파일을 2026-12-01부터 안 읽는다고 공지 — 그때는 Settings에서 `/` 직접 입력)

## 6-2. APK 받는 법 (앱)

- **가장 쉬운 길 = 고정 링크** (2026-10-22): main에 합쳐질 때마다 CI가 최신 APK를 올린다 — 폰에서 열면 바로 받는다.
  <https://github.com/ngh3651/JeonseAI/releases/download/app-latest/jeonseai.apk>
  - **처음 한 번만**: 서명이 다른 예전 앱(USB로 깐 개발용·디버그 키 APK)을 지우고 설치한다(출처를 알 수 없는 앱 허용).
  - **그다음부터는 덮어 설치 = 업데이트**. 기기 id·폰에 저장된 날짜·사진이 그대로 남는다(같은 고정 키 + versionCode가 늘 커짐).
  - 고정 키 비밀값이 없으면 링크에 올리지 않는다(디버그 키 APK는 덮어 설치가 끊길 수 있어서) — CI 로그에 "건너뛴 이유"가 찍힌다.
  - ⚠ 링크는 **공개**다(저장소가 공개). APK를 풀면 앱 키가 보이므로 서버의 하루 상한(`RATE_LIMIT_GLOBAL_PER_DAY`)이 크레딧을 한 번 더 막는다.
- PR에서 만든 APK: GitHub → **Actions → 그 실행** → 맨 아래 **Artifacts의 `jeonseai-apk`** → 압축을 풀면 `app-release.apk`. 30일 보관.
- 저장소 **Settings → Secrets and variables → Actions** (한 번만):
  - **Variables**: `API_BASE_URL` = Railway 주소(`https://….up.railway.app`, 끝의 `/` 없어도 됨)
  - **Secrets**: `APP_KEY` = Railway Variables의 `APP_KEY`와 **같은 값**(값은 채팅·커밋에 쓰지 않는다)
  - **Secrets**: `ANDROID_SIGNING_BUNDLE` = 고정 서명 키 묶음(키 파일 + key.properties를 base64 한 줄로). 2026-10-22에 만들어
    규혁에게 파일로 전달 — **그 파일이 키의 유일한 사본**이니 드라이브 등에 따로 보관한다(잃어버리면 새 키 → 모든 폰에서 한 번 지우고 다시 설치).
    예전 방식 비밀값 4개(`ANDROID_KEYSTORE_BASE64`·`ANDROID_KEYSTORE_PASSWORD`·`ANDROID_KEY_ALIAS`·`ANDROID_KEY_PASSWORD`)도 된다.
  - 넣은 뒤 Actions에서 CI를 다시 돌리면(**Re-run** 또는 `workflow_dispatch`) 그 값으로 새 APK가 나온다.
- 변수가 없으면 APK는 `http://127.0.0.1:8000`(USB + `adb reverse`)을 본다 — CI 로그의 '빌드 설정 확인' 줄에 주소 유무·서명 종류·빌드 번호가 찍힌다(값은 안 찍힌다).
- 로컬에서 직접: `cd frontend && flutter build apk --release --dart-define=API_BASE_URL=https://<주소> --dart-define=APP_KEY=<키>`
  (고정 키로 서명하려면 묶음을 `frontend/android`에 풀어 둔다: `base64 -d 묶음파일 | tar -xz -C frontend/android` — 커밋 금지, `.gitignore`가 막는다)
- 카카오 로그인용 **키 해시**(고정 키 기준): `IGUD29cSPI5wE4xw+utVjaQXR+A=` · 패키지명 `com.jeonseai.jeonse_ai`
  (카카오 개발자 콘솔 → 내 애플리케이션 → 플랫폼 → Android에 넣는다. 키 해시는 APK에서 누구나 읽을 수 있는 공개 값이다)

## 7. 부스 준비물 (팀)

노트북 2대(PPT + 폰 화면 미러링 `scrcpy`) · 시연 폰 2대 · HDMI 어댑터 · 멀티탭 · 휴대폰 핫스팟 ·
**촬영 거치대 + 조명**(흔들림 제거) · 시연용 등기부 인쇄본(양호·위험) · 비상 영상(본선 3분 영상) ·
족자현수막 + S자 고리 · 테이프.

- [ ] **부스 시연 전 '사진 속 이름 가리기' 켜기** (시연 폰 2대 모두 — 마이 → 개인정보) — 켠 뒤 시연용 등기부 하나를 분석해 뷰어에서 이름·주민번호가 전부 덮였는지 눈으로 확인

## 8. 하지 않는 것 / 나중에 (발표에서는 로드맵으로)

CODEF 주소→등기부 자동 조회 · 실시간 등기 변동 알림(자동 조회가 전제) · 앱인토스 출시(부동산 한시 불가) ·
iOS · 월세·반전세 · 계약서 교차검증(보류 확정) · 소액임차인·선순위 임차인(등기부만으로 확인 불가 — 화면에 한계로 고지).

## 9. 옛 문서

8/14 이전 문서 40여 개는 보관 브랜치 **`archive-2026-10-21`**에 그대로 있다: `git show archive-2026-10-21:docs/<파일>`.
옛 문서는 **역사 기록**이지 지금의 정답이 아니다.

## 10. 알려진 한계 (화면이 실제보다 더 말하는 곳)

- **판례 검수**: `seed_cases.json` 11건 중 `verified:true` 10건이지만, 사람이 검수한 것은 **4건**(정민재 2026-08-12)뿐이고
  **7건은 "야간 자율 작업(웹 검증) — 정민재 검수 대기"**다. 앱은 이 7건도 검수된 판례처럼 보여준다 → **결선 전 정민재 검수 필요.**
- **손실 시뮬레이터**: 계산이 **예시(자리표시)**다(`loss_simulator_screen.dart`, 낙찰가율 0.7은 "UI 배치용"). 낙찰가율 출처를 확보하기 전까지 예시 계산이다.
- **로딩 화면**: 진행 단계 문장은 **시간에 맞춘 연출**(700ms 타이머)이고, 서버의 실제 진행과 연결돼 있지 않다.
- **악성임대인 카드**: `blacklist.json`에 샘플 1줄뿐이라 카드는 **늘 "명단 대조 아직 안 됨"**이다.
- **촬영 검사 기준값**(2026-10-22): 흐림·어두움 기준은 **합성 사진**(일부러 흐리게·어둡게 만든 사본)으로만 정했다 — 종이 촬영본으로 검증 전이다.
  멀쩡한 사진이 거절되면 Railway 변수 `CAPTURE_CHECK=warn`(거절 없이 알리기만)으로 바로 바꾼다. 한 방향으로 곧게 끌린 흔들림(글자 두 겹)은 덜 잡는다.
- **사진 속 이름 가리기**: 분석 **전** 화면(촬영 확인·사진 트레이·크게 보기)은 이름 위치를 몰라 가리지 못한다. 가림 상자는 합성 OCR로만 시험했다
  (실제 등기부의 낯선 칸 배치에서 놓치는 이름이 있을 수 있다 — 부스 전에 시연용 등기부로 한 번 눈으로 확인).
- **계약 지킴이 알림**(2026-10-22): 위젯·단위 테스트(가짜 플러그인)로만 확인했다 — **실기기에서 폰을 꺼 둔 채 울리는지는 아직 사람이 안 봤다**
  (확인법: 잔금일을 내일로 넣고 → 알림 허용 → 다음 날 오전 9시). 정확한 알람 권한을 안 써서 **몇 분 늦게** 울릴 수 있다.
  사용자가 앱을 **강제 종료**하면 안드로이드가 알림을 지운다 → 다음에 앱을 켤 때 다시 건다(그 사이 날짜가 지나면 그 알림은 없다). 아이폰 설정은 안 했다.
- **지금 할 일 — 상담처**: 이름만 있다(HUG 안심전세포털·대한법률구조공단). 공식 확인한 전화·주소 데이터가 없어 링크를 넣지 않았다.
- **테스트 결제**: 토스 결제위젯은 위젯·서버 테스트(가짜 토스)와 CI APK 빌드까지만 확인했다 — **실기기 결제 한 바퀴는 아직**(사람).
  결제 수단 화면은 토스가 웹뷰로 그리므로 인터넷이 필요하다. 패스는 **기기**에 붙어 앱을 지우면 안 보인다(카카오 로그인 뒤 계정으로 옮길 일).
  가격 9,900원은 자리 채움 값이다(6절 #5).

## 11. 정리 대상 (임시·더미 — 때가 되면 지운다)

옛 정리 트래커(`archive-2026-10-21:docs/cleanup-tracker.md`)에서 아직 열린 것만 옮겼다.

- `backend/app/dummy_data.py` — 예시 리포트·용어 칩을 아직 여기서 만든다(`store.py`가 예시 시드로 쓴다)
- `backend/app/main.py`의 `POST /api/upload` — 레거시 통신 검증용. 지금 앱은 부르지 않는다
- `backend/app/main.py`의 `app.router.routes.extend(...)` — fastapi/starlette 버그 우회. 버전 정리 때 `include_router`로
- `backend/data/cases.json` — 쓰지 않는 옛 판례 파일(판례 화면은 `precedents/`)
- `backend/data/`의 `is_sample: true` 항목 — `blacklist.json` 샘플 1건(가짜 이름)
- `frontend/lib/app/config.dart`의 `devAutoLogin`(가짜 자동 로그인) · `devKeepRegistryPhotos`(폰에 등기부 사진 보관 — 실명 남음. 끄면 화면 문구도 `retentionNotice`가 알아서 "이 휴대폰에도 남기지 않아요"로 바뀐다)
- `frontend/lib/repositories/`의 `Dummy*Repository` — 테스트 전용. test/로 옮기거나 지운다
- `frontend/lib/repositories/price_source.dart` — 배선 안 된 확장점(배선하거나 지운다)
- `frontend/lib/design_system/gallery/` (`/gallery`) — 개발용 카탈로그. 유지할지 결정
- 법제처 `OC=test` 폴백(`collect_precedents.py`) — 정식 `LAW_API_OC` 발급 시 경고만 사라짐
- 개발 도구 스크립트: `run_rules.py` · `test_extract.py` · `demo_precedent.py` · `test_ocr_coords.py` · `probe_document_parse.py` ·
  `backend/tools/chat_ab.py`(+`data/chat_eval.json`) — 유지할지 결정
- `compare_llm_backends.py` — `compare_llm.py`와 중복. 판례 역할을 옮긴 뒤 삭제
- `backend/app/services/document_parse.py` — `LAYOUT_SOURCE=document_parse`일 때만 동작. 안 쓰기로 정하면 삭제
- 원응답 저장 코드(`artifacts.py` · IE/OCR `_save_raw_*`) — 이제 `SAVE_RAW_RESPONSES=1`일 때만 저장. 진단이 끝나면 삭제
- `backend/out/` · 로컬 `design_handoff_*/` 폴더 — 실명 샘플 포함(커밋 안 됨). 로컬에서 지운다
