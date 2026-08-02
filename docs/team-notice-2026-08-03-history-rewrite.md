# [팀 공지] 2026-08-03 — git 히스토리를 다시 썼습니다. **다시 clone 해주세요**

> 개발자 2명은 반드시, 비개발 팀원도 저장소를 받아 놓았다면 해당됩니다.

## 한 줄 요약

저장소에 남아 있던 **실제 등기부등본의 개인정보**(이름·주민등록번호 앞자리·상세주소)를
과거 커밋에서까지 지웠습니다. 그 과정에서 **모든 커밋의 주소값(해시)이 바뀌었습니다.**
기존에 받아 둔 폴더는 그대로 쓸 수 없습니다.

## 왜 했나

2026-08-02에 "현재 파일"의 개인정보는 지웠지만, git은 과거 기록을 통째로 보관하므로
**옛 커밋을 열면 원본이 그대로 보이는 상태**였습니다. 저장소를 다시 공개하려면
과거 기록까지 지워야 해서, 2026-08-03에 전체 히스토리를 다시 썼습니다.

## 해야 할 일

### ⚠ 먼저 — 아직 올리지 않은 작업이 있다면

```bash
cd <기존 JeonseAI 폴더>
git status          # 수정된 파일이 있는지 확인
git stash list      # stash 해 둔 게 있는지 확인
```

수정한 파일이 있으면 **그 파일들을 폴더 밖으로 복사해 두세요.** (커밋하지 말고 파일만)
없으면 바로 다음으로 갑니다.

### 1. 기존 폴더 이름 바꾸기 (지우지 말고)

```bash
cd ..
mv JeonseAI JeonseAI-old        # Windows 탐색기에서 이름만 바꿔도 됩니다
```

며칠 뒤 아무 문제 없으면 `JeonseAI-old`를 지우세요.

### 2. 새로 clone

```bash
git clone https://github.com/ngh3651/JeonseAI.git
cd JeonseAI
git checkout dev
```

### 3. 환경 다시 만들기 (개발자만)

`.venv`는 폴더 경로가 안에 박히므로 **새로 만들어야 합니다.**

```bash
cd backend
python -m venv .venv
.venv/Scripts/activate          # Windows PowerShell: .venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

`backend/.env`는 git에 올라가지 않으므로 **옛 폴더에서 복사**해 오세요.

```bash
cp ../../JeonseAI-old/backend/.env backend/.env
```

### 4. 정상인지 확인

```bash
cd backend && .venv/Scripts/python.exe -m pytest -q     # 전부 통과해야 정상
cd ../frontend && flutter analyze && flutter test        # 전부 통과해야 정상
```

### 5. 1단계에서 복사해 둔 작업 파일을 새 폴더로 옮기고 커밋

## 하면 안 되는 것

| 하지 마세요 | 왜 |
|---|---|
| 옛 폴더에서 `git pull` | 옛 히스토리와 새 히스토리가 뒤섞여 개인정보가 되살아납니다 |
| 옛 폴더에서 `git push` | 지운 옛 커밋을 GitHub에 다시 올리게 됩니다 |
| 옛 폴더를 다른 곳에 복사·공유 | 그 안에는 원본 개인정보가 그대로 있습니다 |

## 자주 묻는 것

**Q. 내가 쓴 커밋이 사라졌나요?**
아니요. 커밋 72개는 개수·순서·메시지·날짜까지 그대로입니다. 주소값(해시)만 바뀌었습니다.

**Q. 문서에 적힌 커밋 해시는요?**
`docs/` 안의 참조 47건은 새 해시로 고쳐 두었습니다. 카톡·메모에 적어 둔 옛 해시는
더 이상 아무 커밋도 가리키지 않습니다.

**Q. 앞으로 등기부를 다룰 때는?**
`docs/cleanup-tracker.md`의 "개인정보 포함 산출물 — 작성 규칙"을 따르세요.
문서·테스트 픽스처에는 **처음부터 가상값**을 씁니다. 실제 등기부 파일은
`backend/test_samples/`·`backend/out/`에만 두고(둘 다 `.gitignore` 처리됨) 커밋하지 않습니다.
