"""국내 AI API 호출 로그 뽑기 — 대회 「국내 AI API 호출 로그 제출 가이드」(v11.0) 형식 (2026-10-23).

무엇을 하나
    실제 키로 **AI를 쓰는 기능을 기능마다 한 번씩** 돌리면서, 그동안 나간 Upstage API 호출을
    "요청 + 응답 = 한 건"으로 기록해 **기능 이름과 같은 파일**(JSON)로 저장하고, 전부 압축 파일 하나로 묶는다.

    기능(기본 이름 — 보고서의 기능명과 다르면 --names로 바꾼다):
      1. 등기부등본 분석   POST /api/analyze            → Information Extract · Document OCR · Solar(글자 정리·쉬운 설명)
      2. 판례 근거 찾기    GET  /api/reports/{id}/cases  → Embeddings(질의) · Solar(판례 설명)
      3. 다시 떼서 대조    POST /api/reports/{id}/compare → Information Extract · Document OCR
      4. 용어 챗봇         GET  /api/glossary/lookup     → Solar(설명 생성)

원칙
    - 서비스 코드는 건드리지 않는다. 이 스크립트 안에서만 `requests.post`를 감싸 **api.upstage.ai로 가는 호출만** 기록한다
      (국토부 실거래가 같은 일반 API는 가이드상 제출 대상이 아니라 그냥 통과시킨다).
    - 가이드의 기록 항목: 요청 시각(KST) · 엔드포인트(도메인 포함) · 요청 모델 · 요청 내용(보낸 메시지 전체)
      · 응답 시각(KST) · 응답 본문(응답 ID·모델명·답변·토큰 사용량).
    - 민감정보(가이드 유의사항): API 키·Authorization 헤더는 **처음부터 기록하지 않는다**. 등기부 사진 데이터는
      개인정보가 그대로 찍혀 있어 **내용만 빼고 자리(형식·크기·SHA-256)를 남긴다**. 글자 속 사람 이름·주민등록번호·
      주소(시·도 이름으로 시작하는 곳부터 그 줄 끝까지, OCR 낱말 목록은 주소 꼬리 낱말)는 가린다 — 사람 주소만
      골라낼 수 없어 주소꼴은 모두 가린다(더 가리는 쪽).
      나머지 내용과 구조(키·순서)는 그대로 둔다.
    - 가이드는 10월 14일 이후 호출만 인정한다 → 지금 실제로 호출해서 만든다.
      크레딧: 분석 1회 + 대조 1회 + 판례 설명 1회 + 챗봇 1회(분석 캐시는 이 실행에서 끈다).
    - 실제 기록 DB(`app.db`)를 건드리지 않게 이 실행만 임시 폴더를 쓴다.

사용 (backend 폴더에서, .env에 UPSTAGE_API_KEY가 있어야 한다)
    python scripts/export_ai_call_logs.py --photos test_samples/<등기부 사진 폴더>
    python scripts/export_ai_call_logs.py --photos <폴더> --names "등기부 분석,판례 근거,변동 대조,용어 챗봇"
    → out/ai_call_logs/<기능명>.json  +  out/AI_API_호출로그_전세AI프.zip   (out/은 커밋 금지 폴더)
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import sys
import tempfile
import threading
import time
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

BACKEND = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND))

KST = timezone(timedelta(hours=9), "KST")  # 한국은 서머타임이 없어 +9 고정 — 윈도우에 시간대 DB(tzdata)가 없어도 된다
UPSTAGE_HOST = "api.upstage.ai"
DEVICE_ID = "ailog-export-0001"
DEFAULT_NAMES = ["등기부등본 분석", "판례 근거 찾기", "다시 떼서 대조", "용어 챗봇"]
#: 챗봇은 사전에 그대로 있는 낱말이면 AI 없이 답한다(L2) → AI가 붙는 자연어 질문을 차례로 시도한다.
CHAT_QUESTIONS = [
    "집주인이 빚이 많으면 세입자는 어떻게 되나요?",
    "전세 계약하기 전에 등기부에서 무엇을 먼저 봐야 하나요?",
    "잔금 날 집주인이 대출을 받으면 세입자에게 무슨 일이 생기나요?",
]
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".bmp", ".tif", ".tiff", ".pdf"}


# ══════════════════════════════════════════════════════════════════════════════
# ① 기록 — requests.post를 감싸 Upstage 호출만 남긴다
# ══════════════════════════════════════════════════════════════════════════════


def kst_now() -> str:
    return datetime.now(KST).isoformat(timespec="milliseconds")


def _sha16(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:16]


_DATA_URL = re.compile(r"^data:(?P<mime>[\w/+.-]+);base64,(?P<b64>.*)$", re.S)


def scrub_images(value):
    """요청 안의 사진(base64 data URL)을 '자리 표시'로 바꾼다 — 구조(키·순서)는 그대로."""
    if isinstance(value, dict):
        return {k: scrub_images(v) for k, v in value.items()}
    if isinstance(value, list):
        return [scrub_images(v) for v in value]
    if isinstance(value, str):
        m = _DATA_URL.match(value)
        if m:
            b64 = m.group("b64")
            return (
                f"<등기부 사진 데이터 생략 — 개인정보가 찍혀 있어 내용을 뺐어요: {m.group('mime')}, "
                f"base64 {len(b64):,}글자, sha256 {_sha16(b64.encode())}>"
            )
    return value


def describe_request(kwargs: dict) -> tuple[object, str | None]:
    """(요청 내용, 요청 모델). 헤더(Authorization·API 키)는 **보지도 않는다**."""
    if kwargs.get("json") is not None:
        payload = scrub_images(copy.deepcopy(kwargs["json"]))
        model = payload.get("model") if isinstance(payload, dict) else None
        return payload, model
    form = dict(kwargs.get("data") or {}) if isinstance(kwargs.get("data"), dict) else kwargs.get("data")
    files = []
    raw_files = kwargs.get("files") or {}
    items = raw_files.items() if isinstance(raw_files, dict) else raw_files
    for field, spec in items:
        if isinstance(spec, (tuple, list)):
            name = spec[0]
            blob = spec[1]
            mime = spec[2] if len(spec) > 2 else None
        else:
            name, blob, mime = None, spec, None
        if hasattr(blob, "read"):  # 파일 객체 — 읽은 뒤 **제자리로 되감는다**(안 그러면 실제 업로드가 빈 파일이 된다)
            start = blob.tell() if hasattr(blob, "tell") else None
            data = blob.read()
            if start is not None and hasattr(blob, "seek"):
                blob.seek(start)
            blob = data
        blob = blob if isinstance(blob, (bytes, bytearray)) else str(blob).encode()
        files.append(
            {
                "필드": field,
                "파일 이름": name,
                "형식": mime,
                "내용": f"<등기부 사진 파일 생략 — 개인정보가 찍혀 있어 내용을 뺐어요: {len(blob):,}바이트, sha256 {_sha16(bytes(blob))}>",
            }
        )
    content = {"form": form, "files": files}
    model = form.get("model") if isinstance(form, dict) else None
    return content, model


class CallRecorder:
    """기능 하나가 도는 동안 나간 Upstage 호출을 모은다(분석은 여러 호출을 병렬로 낸다 → 잠금)."""

    def __init__(self, original_post):
        self._original = original_post
        self._lock = threading.Lock()
        self.feature: str | None = None
        self.records: dict[str, list[dict]] = {}

    def start(self, feature: str) -> None:
        self.feature = feature
        self.records.setdefault(feature, [])

    def post(self, url, *args, **kwargs):
        if UPSTAGE_HOST not in str(url) or self.feature is None:
            return self._original(url, *args, **kwargs)
        content, model = describe_request(kwargs)
        request = {"요청 시각": kst_now(), "엔드포인트": str(url), "요청 모델": model, "요청 내용": content}
        started = time.monotonic()
        try:
            resp = self._original(url, *args, **kwargs)
        except Exception as e:  # 기록은 남기고 원래 예외를 그대로 올린다
            self._add(request, {"응답 시각": kst_now(), "응답 본문": {"오류": type(e).__name__, "내용": str(e)[:300]}}, started)
            raise
        try:
            body = resp.json()
        except ValueError:
            body = {"text": (resp.text or "")[:2000]}
        self._add(request, {"응답 시각": kst_now(), "HTTP 상태": resp.status_code, "응답 본문": body}, started)
        return resp

    def _add(self, request: dict, response: dict, started: float) -> None:
        response["걸린 시간(ms)"] = round((time.monotonic() - started) * 1000)
        with self._lock:
            bucket = self.records.setdefault(self.feature or "기타", [])
            bucket.append({"순번": len(bucket) + 1, "기능명": self.feature, "요청": request, "응답": response})


# ══════════════════════════════════════════════════════════════════════════════
# ② 가리기 — 사람 이름 · 주민등록번호 · 주소꼴 낱말
# ══════════════════════════════════════════════════════════════════════════════

_RRN = re.compile(r"(?<!\d)\d{6}\s*-\s*[0-9*Xx]{7}(?![0-9*])")
_NAME_BEFORE_RRN = re.compile(r"([가-힣]{2,4})\s*(?=\d{6}\s*-\s*[0-9*Xx]{7})")
#: 주소 — 시·도 이름으로 시작하는 곳부터 그 줄 끝까지(최대 60자) 가린다. 사람 주소를 골라낼 수 없어서
#: 주소처럼 시작하면 모두 가린다(은행 주소·집 소재지도 함께 가려진다 — 더 가리는 쪽).
_PROVINCE = (
    r"(?:서울|부산|대구|인천|광주|대전|울산|세종|경기|강원|충청북|충청남|충북|충남|전라북|전라남|전북|전남|"
    r"경상북|경상남|경북|경남|제주)[가-힣]*(?:특별시|광역시|특별자치시|특별자치도|도)?"
)
_ADDRESS_LINE = re.compile(_PROVINCE + r"(?:[ \t]+[^\n\"\\{}\[\]]{0,60})?")  # 따옴표·괄호에서 멈춘다(JSON 구조 보호)
#: OCR 낱말 목록(words[].text)은 한 낱말씩 끊겨 있어 줄 단위로 못 가린다 → 주소 꼬리로 끝나는 낱말을 가린다.
_ADDRESS_WORD = re.compile(
    r"^[(\[]?[가-힣0-9]*[가-힣](?:특별자치시|특별자치도|특별시|광역시|시|도|구|군|읍|면|동|리|가|로|길)(?:\d+(?:-\d+)?(?:번길|길)?)?[)\],.]*$"
)
#: 기관(은행·회사)은 개인정보가 아니라 이름을 가리지 않는다 — 서버의 기관 판별을 그대로 쓴다.
try:
    from app.services.formatting import looks_like_institution, mask_name  # noqa: E402
except Exception:  # 서버 패키지를 못 읽는 환경에서도 돌게

    def looks_like_institution(name: str) -> bool:
        return any(m in name for m in ("은행", "주식회사", "(주)", "㈜", "금고", "캐피탈", "보험", "공사", "공단", "조합"))

    def mask_name(name: str) -> str:
        return name[0] + "○" * (len(name) - 1) if len(name) > 1 else name


def collect_names_near_rrn(value, found: set[str]) -> None:
    """주민등록번호 바로 앞의 2~4글자 한글 = 사람 이름(이전 소유자처럼 personNames에 없는 사람까지)."""
    if isinstance(value, dict):
        for v in value.values():
            collect_names_near_rrn(v, found)
    elif isinstance(value, list):
        for v in value:
            collect_names_near_rrn(v, found)
    elif isinstance(value, str):
        for m in _NAME_BEFORE_RRN.finditer(value):
            found.add(m.group(1))


def _name_pattern(name: str) -> re.Pattern:
    # OCR이 '홍 길 동'처럼 띄어 읽은 것도 잡는다
    return re.compile(r"\s*".join(re.escape(ch) for ch in name))


def mask_text(text: str, name_patterns: list[tuple[re.Pattern, str]], *, word: bool = False) -> str:
    for pattern, masked in name_patterns:
        text = pattern.sub(masked, text)
    text = _RRN.sub("******-*******", text)
    if word and _ADDRESS_WORD.match(text.strip()):
        return "○" * min(len(text.strip()), 4)
    return _ADDRESS_LINE.sub(lambda m: "[주소 가림]", text)


def mask_value(value, name_patterns, *, in_words: bool = False):
    """문자열마다 가린다. OCR 낱말 목록(`words`) 안의 `text`는 낱말 규칙으로."""
    if isinstance(value, dict):
        return {
            k: mask_value(v, name_patterns, in_words=in_words or k == "words")
            if not (in_words and k == "text" and isinstance(v, str))
            else mask_text(v, name_patterns, word=True)
            for k, v in value.items()
        }
    if isinstance(value, list):
        return [mask_value(v, name_patterns, in_words=in_words) for v in value]
    if isinstance(value, str):
        inner = _maybe_json(value)
        if inner is not None:  # 응답 'content' 안에 JSON 문자열이 든 경우 — 풀어서 가리고 다시 묶는다(구조 그대로)
            return json.dumps(mask_value(inner, name_patterns, in_words=in_words), ensure_ascii=False)
        return mask_text(value, name_patterns)
    return value


def _maybe_json(text: str):
    stripped = text.strip()
    if len(stripped) < 2 or stripped[0] not in "{[" or stripped[-1] not in "}]":
        return None
    try:
        parsed = json.loads(stripped)
    except ValueError:
        return None
    return parsed if isinstance(parsed, (dict, list)) else None


def mask_record(record: dict, name_patterns) -> dict:
    """시각·엔드포인트·모델은 그대로 두고 **요청 내용·응답 본문만** 가린다(타임스탬프가 지번처럼 가려지지 않게)."""
    out = copy.deepcopy(record)
    out["요청"]["요청 내용"] = mask_value(out["요청"]["요청 내용"], name_patterns)
    out["응답"]["응답 본문"] = mask_value(out["응답"]["응답 본문"], name_patterns)
    return out


def build_name_patterns(names: set[str]) -> list[tuple[re.Pattern, str]]:
    people = sorted({n.strip() for n in names if n and len(n.strip()) >= 2 and not looks_like_institution(n)}, key=len, reverse=True)
    return [(_name_pattern(n), mask_name(n)) for n in people]


# ══════════════════════════════════════════════════════════════════════════════
# ③ 기능 실행 — FastAPI 앱을 이 프로세스 안에서 그대로 부른다(실제 키·실제 호출)
# ══════════════════════════════════════════════════════════════════════════════


def pick_photos(arg: str | None) -> list[Path]:
    if arg:
        base = Path(arg)
        if not base.is_absolute():
            base = (Path.cwd() / base).resolve()
        if base.is_file():
            return [base]
        photos = sorted(p for p in base.iterdir() if p.suffix.lower() in IMAGE_SUFFIXES)
        if photos:
            return photos
        raise SystemExit(f"[중단] {base} 에 등기부 사진이 없어요.")
    root = BACKEND / "test_samples"
    candidates = sorted(d for d in root.iterdir() if d.is_dir()) if root.exists() else []
    for d in candidates:
        photos = sorted(p for p in d.iterdir() if p.suffix.lower() in IMAGE_SUFFIXES)
        if photos:
            print(f"(--photos가 없어 첫 번째 사진 폴더를 씁니다: {d.relative_to(BACKEND)})")
            return photos
    raise SystemExit("[중단] --photos 로 등기부 사진 폴더를 알려 주세요 (예: --photos test_samples/서초동).")


def _mime(p: Path) -> str:
    return {".png": "image/png", ".webp": "image/webp", ".pdf": "application/pdf"}.get(p.suffix.lower(), "image/jpeg")


def _files(photos: list[Path]):
    return [("files", (p.name, p.read_bytes(), _mime(p))) for p in photos]


def _check(resp, what: str):
    if resp.status_code >= 400:
        raise RuntimeError(f"{what} 실패 — HTTP {resp.status_code}: {resp.text[:300]}")
    return resp.json()


def run_all(client, headers: dict, recorder: CallRecorder, names: list[str], photos: list[Path], deposit: int) -> dict:
    """기능 4개를 차례로 한 번씩. 돌려준 값: 이름 가리기에 쓸 사람 이름 목록 등."""
    analyze_name, cases_name, compare_name, chat_name = names
    people: set[str] = set()
    notes: dict[str, str] = {}

    recorder.start(analyze_name)
    report = _check(
        client.post("/api/analyze", files=_files(photos), data={"deposit": str(deposit), "alias": "로그 제출용"}, headers=headers),
        analyze_name,
    )
    people.update(report.get("personNames") or [])
    rid = report["id"]

    recorder.start(cases_name)
    try:
        cases = _check(client.get(f"/api/reports/{rid}/cases", headers=headers), cases_name)
        notes[cases_name] = f"판례 카드 {len(cases) if isinstance(cases, list) else '?'}개"
    except Exception as e:  # 판례 인덱스가 없을 수 있다 — 다른 기능은 계속
        notes[cases_name] = f"실패: {e}"

    recorder.start(compare_name)
    try:
        result = _check(client.post(f"/api/reports/{rid}/compare", files=_files(photos), headers=headers), compare_name)
        notes[compare_name] = f"대조 결과 {result.get('result')}"
    except Exception as e:
        notes[compare_name] = f"실패: {e}"

    recorder.start(chat_name)
    for q in CHAT_QUESTIONS:
        before = len(recorder.records.get(chat_name, []))
        try:
            _check(client.get("/api/glossary/lookup", params={"q": q}, headers=headers), chat_name)
        except Exception as e:
            notes[chat_name] = f"실패: {e}"
        if len(recorder.records.get(chat_name, [])) > before:
            notes[chat_name] = f"질문: {q}"
            break
    else:
        notes.setdefault(chat_name, "AI가 붙는 질문을 찾지 못함(CHATBOT_LLM=off인지 확인)")

    recorder.feature = None
    return {"people": people, "notes": notes}


def write_outputs(recorder: CallRecorder, names: list[str], people: set[str], out_dir: Path, zip_path: Path) -> list[tuple[str, int, set[str]]]:
    found = set(people)
    for feature in names:
        collect_names_near_rrn(recorder.records.get(feature, []), found)
    patterns = build_name_patterns(found)

    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.json"):
        old.unlink()
    summary = []
    for feature in names:
        records = [mask_record(r, patterns) for r in recorder.records.get(feature, [])]
        (out_dir / f"{feature}.json").write_text(json.dumps(records, ensure_ascii=False, indent=2), encoding="utf-8")
        models = {f"{r['요청']['엔드포인트']} · {r['요청']['요청 모델']}" for r in records}
        summary.append((feature, len(records), models))
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for feature in names:
            zf.write(out_dir / f"{feature}.json", arcname=f"{feature}.json")
    return summary


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="국내 AI API 호출 로그(기능별 1회) 뽑기")
    ap.add_argument("--photos", help="등기부 사진 폴더(또는 파일 하나). 없으면 test_samples의 첫 폴더")
    ap.add_argument("--deposit", type=int, default=200_000_000, help="분석에 넣을 보증금(원, 기본 2억)")
    ap.add_argument("--names", help="기능 이름 4개(쉼표) — 보고서의 기능명과 같게. 순서: 분석,판례,대조,챗봇")
    ap.add_argument("--out", default=str(BACKEND / "out"), help="결과 폴더(기본 backend/out)")
    args = ap.parse_args(argv)

    names = [n.strip() for n in args.names.split(",")] if args.names else list(DEFAULT_NAMES)
    if len(names) != 4 or any(not n for n in names):
        raise SystemExit("[중단] --names 는 쉼표로 4개 (분석,판례,대조,챗봇 순서)")
    bad = [n for n in names if re.search(r'[\\/:*?"<>|]', n)]
    if bad:
        raise SystemExit(f"[중단] 파일 이름에 못 쓰는 글자가 있어요: {bad}")
    photos = pick_photos(args.photos)

    # 이 실행만의 설정 — .env보다 먼저 넣어 두면 load_dotenv가 덮지 않는다
    tmp = tempfile.mkdtemp(prefix="ailog-")
    os.environ["DATA_DIR"] = tmp                  # 진짜 기록 DB를 건드리지 않게
    os.environ["ANALYSIS_CACHE_HOURS"] = "0"      # 같은 사진이어도 실제로 다시 호출
    os.environ["CAPTURE_CHECK"] = "warn"          # 사진 품질로 거절되지 않게(경고만)
    os.environ["SAVE_RAW_RESPONSES"] = ""         # 실명 원응답 파일을 남기지 않게
    os.environ["REQUIRE_DEVICE_ID"] = ""
    from dotenv import load_dotenv

    load_dotenv(BACKEND / ".env")
    if not os.environ.get("UPSTAGE_API_KEY", "").strip():
        raise SystemExit("[중단] backend/.env 에 UPSTAGE_API_KEY가 없어요.")

    import requests

    recorder = CallRecorder(requests.post)
    requests.post = recorder.post  # 서비스 코드는 `requests.post(...)`로 부르므로 여기서 감싼 것을 쓴다

    from fastapi.testclient import TestClient

    from app.main import app

    headers = {"X-Device-Id": DEVICE_ID}
    if os.environ.get("APP_KEY", "").strip():
        headers["X-App-Key"] = os.environ["APP_KEY"].strip()

    print(f"사진 {len(photos)}장으로 기능 4개를 한 번씩 돌립니다(실제 Upstage 호출 — 1~3분).")
    client = TestClient(app)
    try:
        result = run_all(client, headers, recorder, names, photos, args.deposit)
    finally:
        requests.post = recorder._original

    out_root = Path(args.out)
    summary = write_outputs(recorder, names, result["people"], out_root / "ai_call_logs", out_root / "AI_API_호출로그_전세AI프.zip")
    print("\n기능별 기록:")
    for feature, count, models in summary:
        print(f"  · {feature}.json — 호출 {count}건  ({result['notes'].get(feature, '')})")
        for m in sorted(models):
            print(f"      {m}")
    print(f"\n압축 파일: {out_root / 'AI_API_호출로그_전세AI프.zip'}")
    print("※ 사람 이름·주민등록번호·주소꼴 낱말은 가렸어요. 내기 전에 파일을 한 번 열어 실명이 없는지 눈으로 확인하세요.")
    empty = [f for f, c, _ in summary if c == 0]
    if empty:
        print(f"⚠ 호출 기록이 없는 기능: {empty} — 위 괄호의 이유를 확인하세요.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
