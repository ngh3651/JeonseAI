# 팀원 실행 가이드 — pull 받아서 앱으로 실제 분석 테스트하기

> 이 문서대로 따라 하면, 최신 `dev`를 받아 **등기부 사진을 올려 실제 위험 분석**까지
> 돌려볼 수 있습니다. (Phase E-1c 기준 — 사진 → Upstage 추출 → 규칙 판정 → 리포트)
>
> 처음이라면 위에서부터 순서대로, 이미 해봤다면 **매번 하는 것**(⚡ 표시)만 반복하면 됩니다.

## 0. 미리 깔려 있어야 하는 것

- **Git**, **Python 3.11+**, **Flutter SDK**(+ Android Studio)
- **안드로이드 에뮬레이터** 또는 USB로 연결한 실기기 중 하나
- 확인: 터미널에서 `flutter doctor` 실행 → Android toolchain·연결된 기기에 ✓ 가 뜨면 OK

---

## 1. 코드 받기 ⚡

```bash
git checkout dev
git pull origin dev
```

(처음이면 `git clone https://github.com/ngh3651/JeonseAI.git` 후 `cd JeonseAI && git checkout dev`)

---

## 2. Upstage API 키 넣기 — **팀 공유 채널의 대회 공식 지원 키 사용**

분석(등기부 정보추출)은 Upstage API를 부릅니다. 이제 **대회 공식 지원 키**가 있으므로,
따로 발급받지 말고 **팀 공유 채널에 배포된 공식 지원 키를 받아** 넣으면 됩니다.
(키는 git에 올라가지 않으므로 — 개인정보·보안 — 각자 본인 PC의 `backend/.env`에만 채웁니다.
채널 위치·키 값은 **남규혁에게 문의**하세요.)

1. 팀 공유 채널에서 **공식 지원 키**(`up_...` 로 시작)를 복사합니다.
2. `backend/.env.example` 을 복사해 `backend/.env` 를 만들고 키를 채웁니다:

   ```bash
   # 프로젝트 루트에서
   cp backend/.env.example backend/.env
   ```

   그런 다음 `backend/.env` 를 열어 실제 키로 바꿉니다:

   ```
   UPSTAGE_API_KEY=up_공유받은_공식_지원_키
   ```

- ⚠ **`.env` 는 절대 git에 커밋하지 마세요.** (`.gitignore`로 막혀 있지만, `git add`/커밋 전
  항상 확인하는 습관을 들이세요 — **공식 지원 키가 공개 저장소에 노출되면 안 됩니다.**)
- **사용량·잔여 크레딧**은 공유 키를 관리하는 **남규혁**이 <https://console.upstage.ai> 의
  **Dashboard**에서 확인합니다(공유 키라 각자 콘솔에 계정이 없습니다).
  크레딧이 소진되면 앱에 "분석 크레딧이 소진됐어요"가 뜹니다(과금 아님 — 호출만 중단).
- 개발·테스트를 크레딧 없이 하고 싶으면: 백엔드 규칙 엔진은 `backend/tests/`의 픽스처로
  Upstage 호출 없이 검증됩니다 (`pytest`). 실제 사진 분석에만 크레딧이 듭니다.

---

## 2-1. (선택) 다른 국내 AI 모델 키 — 없어도 앱은 그대로 돌아갑니다

2026-07-28부터 **국내 LLM 3사를 같은 인터페이스 뒤에** 둘 수 있게 했습니다.
**키가 없는 모델은 조용히 빠지고, 기본값(Upstage Solar)으로만 동작합니다.**
그러니 아래는 **안 해도 됩니다** — 비교 실험을 돌릴 때만 필요합니다.

| 모델 | `.env` 키 이름 | 발급처 | 현재 상태 |
|---|---|---|---|
| Upstage Solar Pro | `UPSTAGE_API_KEY` | 위 2절과 같은 키 | ✅ 있음 |
| LG EXAONE | `EXAONE_API_KEY` | FriendliAI (대회 주최 안내 경로, `flp_`로 시작) | ✅ 있음 |
| SKT A.X | `AX_API_KEY` | SKT | ❌ 아직 없음 |

```
# backend/.env — 있는 것만 채우면 됩니다
EXAONE_API_KEY=flp_...
AX_API_KEY=...            # 도착하면 이 줄만 추가하면 자동으로 비교 대상에 합류합니다
```

**모델 이름을 바꿔야 할 때** (제공 목록이 바뀌어 호출이 404가 날 때) — 코드를 고치지 않고
`.env`에서만 바꿉니다:

```
UPSTAGE_MODEL=solar-pro2
EXAONE_MODEL=LGAI-EXAONE/K-EXAONE-236B-A23B
AX_MODEL=ax4
```

**어떤 일을 어느 모델에게 시킬지**도 `.env`로 정합니다(둘 다 기본값 `upstage`):

```
LLM_EXPLAIN_PROVIDER=upstage       # 리포트 설명 문장 만들기
LLM_STRUCTURE_PROVIDER=upstage     # 사진 글자 → 등기 항목 2차 확인 (교차검증용)
LLM_STRUCTURE_PROVIDER=off         # 2차 확인을 아예 끄기 (크레딧·시간 절약)
LAYOUT_SOURCE=ocr_layout           # 2차 확인에 넘길 글자의 출처 (또는 document_parse)
```

> ⚠ 이 설정들은 **설명·교차검증 계층에만** 영향을 줍니다.
> **위험 등급·점수는 어떤 값을 넣어도 달라지지 않습니다** — 판정은 규칙 엔진이 하고,
> LLM은 판정 결과를 바꿀 통로가 없습니다(`backend/tests/test_verdict_regression.py`가
> 이걸 테스트로 못 박아 두었습니다).

**설정이 잘 됐는지 확인** (API 호출 0회, 크레딧 안 듭니다):

```powershell
cd backend
.\.venv\Scripts\python.exe scripts\compare_llm.py --list
```

---

## 3. 백엔드 서버 실행

### 3-1. 처음 한 번 — 가상환경 만들기

`.venv`(파이썬 가상환경)는 **git에 올라가지 않습니다.** 각자 본인 PC에서 한 번 만들어야 하고,
**프로젝트 폴더를 옮겼거나 OS가 다르면 지우고 새로 만들어야 합니다**(옛 절대경로가 깨짐).

```bash
cd backend
python -m venv .venv
# Windows PowerShell:
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
# macOS/Linux:
# .venv/bin/python -m pip install -r requirements.txt
cd ..
```

### 3-2. 서버 켜기 ⚡ (이 창은 로그 창으로 계속 켜 둠)

```powershell
# Windows (프로젝트 루트에서)
.\scripts\run-backend.ps1
```

```bash
# macOS/Linux (프로젝트 루트에서)
cd backend && .venv/bin/python -m uvicorn app.main:app --reload
```

- `http://127.0.0.1:8000` 에서 `{"status":"ok"}` 가 보이면 성공.
- **8000 포트를 이미 쓰고 있다는 에러(WinError 10013)**가 나도 `run-backend.ps1`이
  이전 서버를 자동으로 정리하고 다시 뜹니다. (다른 프로그램이 점유 중이면 안내만 하고 멈춤)
- 서버 콘솔에 요청 로그가 한국어로 찍힙니다 — 분석 시 `[Upstage] 호출 (크레딧 소모)`,
  `[분석 완료] 주소·선순위채권·판정·소요시간` 등으로 잘 되는지 눈으로 확인할 수 있습니다.

---

## 4. 앱 실행 ⚡

**에뮬레이터든 실기기든 동일합니다.** 백엔드가 켜진 상태에서:

```bash
cd frontend
flutter pub get            # 처음 한 번(또는 의존성 바뀌었을 때)

# 앱에서 서버(127.0.0.1:8000)로 연결되게 포트를 터널링 — 에뮬레이터·실기기 공통
adb reverse tcp:8000 tcp:8000

flutter run
```

### 왜 `adb reverse` 가 필요한가

앱의 서버 주소는 `http://127.0.0.1:8000` 으로 고정돼 있습니다
([frontend/lib/app/config.dart](../frontend/lib/app/config.dart)). `adb reverse` 를 하면
**에뮬레이터/폰 안의 `127.0.0.1:8000` 요청이 여러분 PC의 8000번(백엔드)으로 연결**됩니다.
이 방식이라 config를 각자 고칠 필요가 없습니다.

- 기기가 여러 개면 `adb devices` 로 확인 후 `adb -s <기기ID> reverse tcp:8000 tcp:8000`.
- ⚠ `adb reverse` 는 **에뮬레이터/USB 재연결·PC 재부팅 시마다 다시** 실행해야 합니다.
  ("서버에 연결하지 못했어요" 에러가 뜨면 대개 이걸 안 한 것 — 다시 실행하세요.)

### 로그인 없이 바로 분석

지금은 **개발용 자동 로그인**이 켜져 있어(`config.dart`의 `devAutoLogin = true`),
로그인 화면 없이 바로 홈에서 ＋분석 → 사진 선택 → 분석까지 됩니다.
(비회원 흐름을 테스트하려면 앱 안에서 로그아웃하거나 이 값을 `false`로.)

---

## 5. 테스트 흐름

1. 홈에서 **＋ 분석** → 갤러리에서 등기부등본 사진 선택(여러 장 가능) → 예정 보증금 입력(시세는 선택)
2. 분석 시작 → 로딩(수십 초, Upstage 추출) → **안전도 리포트**
3. 리포트에서 주소·선순위채권 합계·위험 등급과 근거 카드 5종 확인
4. 홈으로 돌아오면 방금 분석이 이력에 쌓임

**위험 신호가 있는 등기부**로 테스트하고 싶으면(근저당·압류·신탁 등):
[docs/registry-sample-guide.md](registry-sample-guide.md) 참고 — 법원경매정보에서 물건 주소를
찾아 인터넷등기소에서 열람(700원)하는 절차입니다.

---

## 자주 나는 문제

| 증상 | 해결 |
|---|---|
| `Fatal error ... Unable to create process`(uvicorn 등) | `.venv`가 옛 경로로 깨진 것 → `backend/.venv` 지우고 3-1 다시 |
| 앱에 "서버에 연결하지 못했어요" | ⑴ 백엔드 켜졌나 ⑵ `adb reverse` 다시 실행 ⑶ `adb devices`에 기기 보이나 |
| 앱에 "분석 크레딧이 소진됐어요" | Upstage 크레딧 소진 → Console > Dashboard 확인, 필요 시 키 재발급 |
| 서버 기동 시 포트 에러(10013) | `run-backend.ps1`이 자동 정리 — 그래도 안 되면 메시지의 `taskkill` 안내대로 |
| `pytest`만 돌려보고 싶다 | `cd backend && .\.venv\Scripts\python.exe -m pytest tests/ -q` (크레딧 안 씀) |
