r"""Upstage Document OCR 좌표 검증 CLI — "OCR 하이라이트" 기능 **사전 검증** 도구.

배경: Information Extract는 등기부 필드를 구조화 추출하지만 **좌표를 주지 않는다**.
그래서 "채권최고액 1억 8천"이 사진의 어디에 있는지 알 수 없어 표시할 수 없다.
Document OCR은 단어 단위 좌표를 주므로, **그 좌표가 실제로 쓸 만한지**를 여기서 잰다.

⚠ 이 스크립트는 검증에 실패하면 기능과 함께 폐기된다(앱을 먼저 만들지 않는 이유).
⚠ 실행마다 실제 크레딧이 소모된다. 응답 원본은 `out/ocr_<이름>.json`에 저장되므로,
  로직만 고쳐 다시 볼 때는 `--from-json out` 으로 **API 호출 0회** 재실행할 것.

호출·키 로딩·에러 처리는 `app/services/extraction.py`의 패턴을 그대로 쓴다
(새 패턴을 만들지 않는다). 다만 전송 방식은 다르다 — IE는 JSON+base64 data URL,
OCR은 **multipart/form-data**다.

실행 예:
  cd backend
  .\.venv\Scripts\python.exe scripts\test_ocr_coords.py test_samples\1.png test_samples\3.png
  .\.venv\Scripts\python.exe scripts\test_ocr_coords.py test_samples\3.png --from-json out
  .\.venv\Scripts\python.exe scripts\test_ocr_coords.py test_samples\4.png --from-json out ^
      --target 채권최고액 75,600,000
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import re
import statistics
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import requests
from PIL import Image, ImageDraw, ImageFont

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))

# extraction.py의 키 로딩·에러 클래스·상태코드 안내를 그대로 재사용한다.
# (_ 접두 이름이지만 의도적 재사용 — 같은 저장소 안에서 패턴을 중복 정의하지 않기 위함)
from app.services.extraction import (  # noqa: E402
    _USER_FACING_STATUS,
    ExtractionError,
    _load_api_key,
)

# 레이아웃 해석(줄 묶기·컬럼 밴드·항목 그룹화·이름 추출)은 백엔드와 **같은 모듈**을 쓴다.
# 검증 스크립트에서 만든 로직이 곧 서비스 로직이 되도록 하기 위함 — 두 벌로 나뉘면
# "스크립트에선 되는데 서버에선 안 되는" 상황이 생긴다.
from app.services.ocr_layout import (  # noqa: E402
    Line,
    OcrPage,
    RegistryItem,
    Word,
    build_items,
    extract_names,
    group_lines,
    median_height,
    parse_words,
)

# ── 확인된 API 사양 (추측 금지 — 그대로 사용) ────────────────────────────────
OCR_URL = "https://api.upstage.ai/v1/document-digitization"
OCR_MODEL = "ocr"
REQUEST_TIMEOUT_SECONDS = 300  # extraction.py와 동일 상한
OUT_DIR = _BACKEND_ROOT / "out"

# ── 검증용 정규식 ────────────────────────────────────────────────────────────
# 금액: 3자리 콤마 패턴 ([2]의 주 관심사)
_MONEY_COMMA = re.compile(r"\d{1,3}(?:,\d{3})+")
# 콤마가 유실된 채 붙어버린 긴 숫자 — 쪼개짐/병합의 반대 증상 탐지용
_LONG_DIGITS = re.compile(r"(?<!\d)\d{5,}(?!\d)")
# 말소 관련 표기 ([4])
_CANCEL_WORD = re.compile(r"말소")
# ⚠ 이름 추출·순위번호 판정은 여기 있던 정규식을 버리고 `ocr_layout` 의 word 단위 로직으로
#   옮겼다 (2026-07-27). 문자 단위 정규식은 '매매'+'소유자D'을 한 덩어리로 삼켜 bbox가
#   옆 칸까지 번졌고, '줄 맨 앞 숫자 = 순위번호' 규칙은 등기목적 칸에 접힌 분수의 분모를
#   순위번호로 오인했다. 자세한 근거는 docs/ocr-highlight-findings.md.
# 페이지 대조 키 ([6]) — 우선순위는 아래 PAGE_KEYS 참조
_ISSUE_CONFIRM_NO = re.compile(r"[A-Z]{3,5}\s*[-－]\s*[A-Z]{3,5}\s*[-－]\s*\d{3,5}")
_ADDR_HEADER = re.compile(r"\[집합건물\][^\n]*|\[건물\][^\n]*|\[토지\][^\n]*")
_UNIQUE_NO = re.compile(r"\d{4}\s*[-－]\s*\d{4}\s*[-－]\s*\d{6}")

# 하이라이트 후보 키워드 ([2]와 함께 파란 박스로 표시)
_KEYWORDS = ("채권최고액", "근저당권설정", "소유자", "공유자", "말소", "전세권", "임차권", "가압류", "압류", "신탁")

# [6] 페이지 대조 키 — STEP 1 조사 결과 반영:
#     고유번호는 **1페이지에만** 있으므로 1순위로 쓸 수 없다.
#     발급확인번호가 전 페이지 푸터에 동일하게 찍히므로 1순위, 상단 주소 줄이 2순위.
PAGE_KEYS = [
    ("발급확인번호", _ISSUE_CONFIRM_NO, "1순위 — 같은 발급본이면 전 페이지 동일"),
    ("상단 주소 줄", _ADDR_HEADER, "2순위 — 전 페이지 반복되나 표기 흔들림 가능"),
    ("고유번호", _UNIQUE_NO, "참고 — 1페이지에만 있음(STEP 1 확인)"),
]


class OcrError(ExtractionError):
    """OCR 호출 실패 — extraction.py의 에러 계약을 그대로 따른다."""


# ══════════════════════════════════════════════════════════════════════════════
# 콘솔 / 인코딩
# ══════════════════════════════════════════════════════════════════════════════


def setup_console() -> str:
    """stdout을 UTF-8로 고정하고 **원래** 인코딩을 돌려준다 ([1] 판별 근거)."""
    original = getattr(sys.stdout, "encoding", None) or "unknown"
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
        except (AttributeError, OSError):
            pass
    return original


def h1(title: str) -> None:
    print(f"\n{'═' * 78}\n{title}\n{'═' * 78}")


def h2(title: str) -> None:
    print(f"\n── {title} " + "─" * max(0, 74 - len(title)))


# ══════════════════════════════════════════════════════════════════════════════
# 자료구조
# ══════════════════════════════════════════════════════════════════════════════


@dataclass
class Page:
    """이미지 1장의 OCR 결과 (검증 스크립트용 — 원본 파일 경로·raw를 함께 들고 다닌다).

    ⚠ Word/Line/줄 묶기/항목 그룹화는 `app.services.ocr_layout`에 있다. 여기에 복제하지
      않는다 — 백엔드와 로직이 갈라지면 이 검증이 무의미해진다.
    """

    name: str  # 이미지 파일 stem
    index: int  # 업로드 순서 (0부터)
    path: Path
    raw: dict
    words: list[Word]
    lines: list[Line]

    def as_ocr_page(self) -> OcrPage:
        return OcrPage(name=self.name, index=self.index, words=self.words, lines=self.lines)


# ══════════════════════════════════════════════════════════════════════════════
# API 호출 (multipart) — extraction.py 에러/로깅 패턴 준용
# ══════════════════════════════════════════════════════════════════════════════


def _post_ocr(api_key: str, path: Path, field: str) -> requests.Response:
    """multipart 1회 전송. field 는 'document' 또는 'image'."""
    mime = mimetypes.guess_type(path.name)[0] or "image/png"
    with path.open("rb") as fh:
        return requests.post(
            OCR_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            data={"model": OCR_MODEL},
            files={field: (path.name, fh, mime)},
            timeout=REQUEST_TIMEOUT_SECONDS,
        )


def call_document_ocr(api_key: str, path: Path) -> tuple[dict, str]:
    """이미지 1장 → OCR 원본 JSON. (응답, 통한 필드명) 반환.

    ⚠ 장별로 **원본 그대로** 개별 호출한다 — PDF 병합 시 좌표계가 원본 사진과
    어긋나 하이라이트를 그릴 수 없기 때문이다(이 검증의 전제).
    """
    last_status = None
    for field in ("document", "image"):
        print(f"[요청] {path.name} → Document OCR 호출 (multipart {field}=@) ⚠ 크레딧 소모")
        t0 = time.perf_counter()
        try:
            resp = _post_ocr(api_key, path, field)
        except requests.exceptions.Timeout as e:
            raise OcrError(504, "분석 서버 응답이 너무 늦어요. 잠시 후 다시 시도해 주세요") from e
        except requests.exceptions.RequestException as e:
            raise OcrError(502, "분석 서버에 연결하지 못했어요. 잠시 후 다시 시도해 주세요") from e
        print(f"[응답] HTTP {resp.status_code} ({time.perf_counter() - t0:.1f}초)")

        if resp.status_code == 200:
            if field != "document":
                print(f"  ※ 'document=@' 는 실패(HTTP {last_status})했고 '{field}=@' 로 통했습니다")
            return resp.json(), field

        last_status = resp.status_code
        # 필드명 문제로 보이는 응답이면 대체 필드명으로 1회 재시도
        if field == "document" and resp.status_code in (400, 415, 422):
            print(f"  'document=@' 실패(HTTP {resp.status_code}) → 'image=@' 로 재시도합니다")
            print(f"  서버 응답: {resp.text[:300]}")
            continue

        detail = _USER_FACING_STATUS.get(
            resp.status_code, "분석 서버에 문제가 생겼어요. 잠시 후 다시 시도해 주세요"
        )
        raise OcrError(resp.status_code, f"{detail}\n  서버 응답: {resp.text[:300]}")

    raise OcrError(last_status or 502, f"document/image 두 필드명 모두 실패했습니다 (마지막 HTTP {last_status})")


# ══════════════════════════════════════════════════════════════════════════════
# 파싱 + 줄 묶기 ([3])
# ══════════════════════════════════════════════════════════════════════════════


# parse_words / group_lines 는 app.services.ocr_layout 에서 가져온다 (위 import 참조).


# ══════════════════════════════════════════════════════════════════════════════
# [1] 한글 인코딩
# ══════════════════════════════════════════════════════════════════════════════

# latin-1로 잘못 해석된 UTF-8의 흔적 (mojibake) — 데이터 자체가 깨졌을 때 나타난다
_MOJIBAKE_HINT = re.compile(r"[ÃÂì무í ë][\x80-\xbf]|ï¿½")


def check_encoding(pages: list[Page], original_console: str, json_paths: list[Path]) -> None:
    h1("[1] 한글 인코딩")
    print(f"  콘솔 원래 인코딩: {original_console}  →  이 스크립트가 stdout을 UTF-8로 재설정함")
    if original_console.lower().replace("-", "") not in ("utf8", "utf_8"):
        print(f"  ※ 원래 콘솔이 {original_console}(비 UTF-8)였습니다. 재설정했으므로 아래가")
        print("     깨져 보인다면 콘솔 코드페이지가 아니라 **데이터 또는 터미널 글꼴** 문제입니다.")

    total_bad = 0
    for p in pages:
        text = "".join(w.text for w in p.words)
        hangul = sum(1 for ch in text if "\uac00" <= ch <= "\ud7a3")
        replacement = text.count("\ufffd")
        mojibake = len(_MOJIBAKE_HINT.findall(text))
        total_bad += replacement + mojibake
        print(f"\n  [{p.name}] 단어 {len(p.words)}개 / 총 {len(text)}자")
        print(f"    한글 음절: {hangul}자 ({hangul / max(1, len(text)):.0%})")
        print(f"    U+FFFD(치환문자): {replacement}개   mojibake 의심: {mojibake}건")
        sample = [w.text for w in p.words if any("\uac00" <= c <= "\ud7a3" for c in w.text)][:8]
        print(f"    한글 단어 표본: {sample}")

    print("\n  판정:")
    if total_bad == 0:
        print("    ✅ 데이터에 깨짐 신호(U+FFFD·mojibake) 없음 — API 응답의 한글은 정상입니다.")
        print("       콘솔에서만 깨져 보인다면 그것은 코드페이지/글꼴 문제입니다.")
    else:
        print(f"    ⚠ 깨짐 신호 {total_bad}건 — 데이터 문제일 수 있습니다.")
    print("    대조용 UTF-8 원본이 아래에 저장돼 있습니다 (메모장/VSCode로 열어 확인):")
    for jp in json_paths:
        print(f"      {jp}")


# ══════════════════════════════════════════════════════════════════════════════
# [2] 금액 쪼개짐 — 가장 중요
# ══════════════════════════════════════════════════════════════════════════════


def _split_kind(matched: str, parts: list[str]) -> str:
    if len(parts) == 1:
        return "단독 word" if parts[0] == matched else "한 덩어리(접두/접미 포함)"
    return f"쪼개짐 {len(parts)}개"


def check_money(pages: list[Page]) -> dict[str, list[str]]:
    """콤마 금액이 **원본 word로 어떻게 쪼개져 있는지** 그대로 보여준다.

    반환: 금액문자열 → 등장한 "페이지:줄" 목록 ([4]에서 중복 금액 판정에 사용)
    """
    h1("[2] 금액 쪼개짐 (매칭 로직 설계를 좌우하는 항목)")
    occurrences: dict[str, list[str]] = {}
    kinds: dict[str, int] = {}

    for p in pages:
        h2(f"{p.name}")
        found = 0
        for line in p.lines:
            joined, owner = line.concat()
            for m in _MONEY_COMMA.finditer(joined):
                found += 1
                idxs = sorted(set(owner[m.start() : m.end()]))
                parts = [line.words[i].text for i in idxs]
                kind = _split_kind(m.group(0), parts)
                kinds[kind] = kinds.get(kind, 0) + 1
                occurrences.setdefault(m.group(0), []).append(f"{p.name}:L{line.index}")
                print(f"  L{line.index:<3} {m.group(0):>15}  ← 원본 word {parts}")
                print(f"        └ {kind} | 줄 전체: {line.display[:70]}")
        if not found:
            print("  (콤마 금액 패턴 없음)")

        # 콤마가 유실된 긴 숫자 — 반대 증상 점검
        stray = []
        for line in p.lines:
            joined, owner = line.concat()
            for m in _LONG_DIGITS.finditer(joined):
                idxs = sorted(set(owner[m.start() : m.end()]))
                stray.append((line.index, m.group(0), [line.words[i].text for i in idxs]))
        if stray:
            print(f"\n  ※ 콤마 없는 5자리 이상 숫자 {len(stray)}건 (콤마 유실 의심 — 발급번호 등 정상 포함):")
            for idx, val, parts in stray[:10]:
                print(f"      L{idx:<3} {val}  ← {parts}")

    h2("쪼개짐 유형 집계")
    if kinds:
        for k, v in sorted(kinds.items(), key=lambda kv: -kv[1]):
            print(f"  {k}: {v}건")
        print("\n  해석:")
        print("    '단독 word'/'한 덩어리' 위주  → 금액 1개 = word 1개. 매칭이 단순해집니다.")
        print("    '쪼개짐 N개' 위주            → 줄 단위로 이어붙여 매칭한 뒤, 기여 word들의")
        print("                                   bbox를 합쳐 하이라이트해야 합니다.")
    else:
        print("  (집계할 금액 없음)")
    return occurrences


# ══════════════════════════════════════════════════════════════════════════════
# [3] 줄 묶기
# ══════════════════════════════════════════════════════════════════════════════


def check_lines(pages: list[Page], tol_ratio: float) -> None:
    h1(f"[3] 줄 묶기 (tol_ratio={tol_ratio} — y중심 차이 ≤ 비율 × 글자높이)")
    for p in pages:
        h2(f"{p.name} — 단어 {len(p.words)}개 → 줄 {len(p.lines)}개")
        for line in p.lines:
            _, y0, _, y1 = line.box
            print(f"  L{line.index:<3} y{y0:>5.0f}~{y1:<5.0f} w{len(line.words):<3} {line.display}")
    print("\n  ※ 표 형식 문서라 **같은 y의 다른 칸**도 한 줄로 묶입니다(의도된 동작 —")
    print("     '채권최고액'과 '금75,600,000원'이 같은 줄이어야 --target 매칭이 됩니다).")
    print("     셀 안에서 여러 줄로 접힌 텍스트는 각각 다른 줄이 됩니다.")
    print("     눈으로 볼 검증물: out/marked_*.png 의 옅은 회색 가로 밴드")


# ══════════════════════════════════════════════════════════════════════════════
# [4] 말소 구분
# ══════════════════════════════════════════════════════════════════════════════


def check_cancellation(
    pages: list[Page], items: list[RegistryItem], money_occurrences: dict[str, list[str]]
) -> None:
    h1("[4] 말소 구분")

    print("  ▶ 취소선(실선) 인식 여부 — 응답 구조로 먼저 확인")
    raw = pages[0].raw
    page0 = (raw.get("pages") or [{}])[0]
    word0 = (page0.get("words") or [{}])[0] if page0.get("words") else {}
    print(f"    최상위 키   : {sorted(raw.keys())}")
    print(f"    pages[0] 키 : {sorted(page0.keys())}")
    print(f"    words[0] 키 : {sorted(word0.keys())}")
    line_keys = {"strikethrough", "strike", "style", "lines", "decoration", "shapes", "graphics"}
    hit = line_keys & (set(raw.keys()) | set(page0.keys()) | set(word0.keys()))
    if hit:
        print(f"    ⚠ 선/스타일 관련 키가 있습니다: {sorted(hit)} — 확인 필요")
    else:
        print("    ❌ 취소선·선·스타일 정보 없음. OCR은 **텍스트와 좌표만** 줍니다.")
        print("       → 취소선으로는 말소를 판정할 수 없습니다. 아래 텍스트 단서를 써야 합니다.")

    print("\n  ▶ '말소' 표기가 텍스트로 잡히는가")
    cancel_lines: list[tuple[str, Line]] = []
    for p in pages:
        for line in p.lines:
            joined, _ = line.concat()
            if _CANCEL_WORD.search(joined):
                cancel_lines.append((p.name, line))
    if cancel_lines:
        print(f"    ✅ '말소' 포함 줄 {len(cancel_lines)}개:")
        for name, line in cancel_lines:
            print(f"      [{name}] L{line.index:<3} {line.display[:70]}")
        print("\n    → 등기부는 말소를 '<N>번근저당권설정등기말소' 같은 **별도 행**으로 남깁니다.")
        print("       이 행의 'N번'을 파싱해 해당 순위번호 항목을 말소 처리하는 것이 유일한 경로입니다.")
    else:
        print("    ❌ '말소' 문자열이 잡히지 않았습니다.")

    print("\n  ▶ 말소 행이 여러 줄로 갈라져도 이어붙였는가 (등기목적 컬럼 단위 결합)")
    records = [it for it in items if it.is_cancel_record]
    if records:
        for it in records:
            span = len(it.lines)
            print(f"    [{it.section} 순위 {it.rank}] {it.location} (줄 {span}개) → 등기목적 '{it.purpose}'")
        print("    ※ 줄 단위로 이어붙이면 사이에 접수·등기원인 칸 날짜가 끼어들어 끊깁니다.")
        print("       등기목적 컬럼 x밴드 안의 word만 이어붙여야 '…등' + '기말소'가 붙습니다.")
    else:
        print("    (말소 근거 행 없음)")

    print("\n  ▶ 어느 항목이 말소로 판정됐는가 (근거 필수)")
    canceled = [it for it in items if it.canceled]
    if canceled:
        for it in canceled:
            print(f"    ✅ {it.section} 순위 {it.rank} → 말소  (근거: {it.cancel_evidence})")
    else:
        print("    (말소로 판정된 항목 없음)")

    print("\n  ▶ 같은 금액이 여러 줄에 나타나는가 (말소분/유효분 혼동 위험)")
    dupes = {k: v for k, v in money_occurrences.items() if len(v) > 1}
    if dupes:
        for amount, spots in sorted(dupes.items(), key=lambda kv: -len(kv[1])):
            print(f"    ⚠ {amount} → {len(spots)}곳: {spots}")
        print("    → 금액만으로 하이라이트하면 말소분까지 칠합니다. 순위번호·문맥 병행이 필수입니다.")
    else:
        print("    중복 등장 금액 없음 — 이 샘플에서는 금액이 항목을 유일하게 지목합니다.")

    print("\n  ▶ 말소 줄과 일반 줄의 confidence 비교 (취소선이 인식률에 남기는 간접 흔적)")
    cancel_idx = {(name, line.index) for name, line in cancel_lines}
    a = [w.confidence for p in pages for line in p.lines if (p.name, line.index) in cancel_idx for w in line.words]
    b = [w.confidence for p in pages for line in p.lines if (p.name, line.index) not in cancel_idx for w in line.words]
    if a and b:
        print(f"    '말소' 포함 줄 평균 {statistics.mean(a):.3f} (n={len(a)})")
        print(f"    그 외 줄     평균 {statistics.mean(b):.3f} (n={len(b)})")
        print("    ※ 이건 '말소 행' 기준이지 '취소선 그어진 행' 기준이 아닙니다. 참고치입니다.")
    else:
        print("    비교할 표본이 부족합니다.")


# ══════════════════════════════════════════════════════════════════════════════
# [5] 소유자 / 공유자 이름
# ══════════════════════════════════════════════════════════════════════════════


def collect_names(pages: list[Page]) -> list[tuple[Page, Line, list]]:
    """페이지별 이름 검출 결과 — 그리기와 리포트가 같은 결과를 쓰도록 한 곳에서 만든다."""
    out = []
    for p in pages:
        med_h = median_height(p.words)
        for line in p.lines:
            hits = extract_names(line, p.index, med_h)
            if hits:
                out.append((p, line, hits))
    return out


def check_owner(pages: list[Page]) -> None:
    h1("[5] 소유자·공유자 이름 (형광펜 1순위 대상)")
    print("  ※ 이 샘플의 현재 권리자 표기는 '소유자'가 아니라 '공유자'(4명)입니다.")
    print("     추출 방식: 등록번호 word(`○○○○○○-○******`)를 먼저 찾고 **바로 앞 word**를 이름으로 삼는다.")
    print("     (문자 단위 정규식은 '매매'+'소유자D'을 한 덩어리로 삼켜 bbox가 옆 칸까지 번졌다)")
    print("     개인/법인 판별: 등록번호 뒤 7자리가 마스킹이면 개인, 숫자면 법인.\n")

    total = {"개인": 0, "법인": 0}
    for p in pages:
        h2(f"{p.name}")
        found = False
        med_h = median_height(p.words)
        for line in p.lines:
            hits = extract_names(line, p.index, med_h)
            if not hits:
                continue
            found = True
            print(f"  L{line.index:<3} {line.display[:72]}")
            for hit in hits:
                total[hit.kind] += 1
                x0, y0, x1, y1 = hit.box
                strip = f" (접두어 {hit.stripped} 제거)" if hit.stripped else ""
                print(f"        [{hit.kind}] '{hit.name}' ← word '{hit.raw_candidate}'{strip}")
                print(
                    f"        bbox ({x0:.0f},{y0:.0f})-({x1:.0f},{y1:.0f})  폭 {x1 - x0:.0f}px"
                    f"  등록번호 {hit.id_prefix}-*******"
                )
        if not found:
            print("  (등록번호 + 이름 패턴 없음)")

    print(f"\n  합계 — 개인 {total['개인']}건 / 법인 {total['법인']}건")
    print("  기대치: 갑구에 개인 5명(소유자A·소유자B·소유자C·소유자D·소유자E),")
    print("          을구에 법인 2곳(하나은행·우리은행).")
    print("  개인 이름 폭이 40~50px 근처면 이름 word에만 정확히 맞은 것입니다(과거 181px = 실패).")


# ══════════════════════════════════════════════════════════════════════════════
# [6] 페이지 대조 (다른 등기부 사진이 섞였는지 판별)
# ══════════════════════════════════════════════════════════════════════════════


def _norm(s: str) -> str:
    return re.sub(r"\s+", "", s)


def check_page_identity(pages: list[Page]) -> None:
    h1("[6] 페이지 대조 — 같은 등기부인가")
    print("  대조 키 우선순위 (STEP 1 조사 반영: 고유번호는 1페이지에만 있어 1순위로 못 씀)")
    for name, _, note in PAGE_KEYS:
        print(f"    · {name}: {note}")

    per_key: dict[str, dict[str, list[str]]] = {name: {} for name, _, _ in PAGE_KEYS}
    for p in pages:
        full = "".join(line.concat()[0] for line in p.lines)
        spaced = "\n".join(line.display for line in p.lines)
        for name, pattern, _ in PAGE_KEYS:
            hay = spaced if name == "상단 주소 줄" else full
            found = [_norm(m.group(0)) for m in pattern.finditer(hay)]
            per_key[name][p.name] = sorted(set(found))

    verdict_key = None
    for name, _, _ in PAGE_KEYS:
        h2(f"{name}")
        values = per_key[name]
        for pname, vals in values.items():
            print(f"    [{pname}] {vals if vals else '❌ 미검출'}")
        present = {pname: v for pname, v in values.items() if v}
        if len(present) < len(pages):
            missing = [pname for pname, v in values.items() if not v]
            print(f"    → 이 키로는 전 페이지 대조 불가 (미검출: {missing})")
            continue
        union = {v for vals in present.values() for v in vals}
        common = set.intersection(*(set(v) for v in present.values()))
        if common:
            print(f"    ✅ 전 페이지 공통값 있음: {sorted(common)}")
            if verdict_key is None:
                verdict_key = (name, sorted(common))
        else:
            print(f"    ⚠ 페이지마다 값이 다릅니다: {sorted(union)} — 다른 등기부가 섞였을 수 있습니다")

    h2("종합 판정")
    if len(pages) < 2:
        print("  이미지가 1장이라 대조할 수 없습니다. 2장 이상 넘겨 주세요.")
    elif verdict_key:
        name, common = verdict_key
        print(f"  ✅ '{name}' 기준으로 {len(pages)}장이 같은 등기부입니다 (공통값 {common})")
        print("     → 이 키를 앱의 '다른 등기부 섞임' 판별에 쓸 수 있습니다.")
    else:
        print("  ❌ 전 페이지를 관통하는 공통 키를 찾지 못했습니다.")
        print("     → 페이지별 크롭 범위(푸터 잘림 등)에 따라 키가 사라집니다. 이 방식은")
        print("        '섞임 판별'로 쓰기 부적합하다는 결론이 됩니다(보수적으로: 판별 불가 처리).")


# ══════════════════════════════════════════════════════════════════════════════
# [7] confidence 분포
# ══════════════════════════════════════════════════════════════════════════════


def check_confidence(pages: list[Page]) -> None:
    h1("[7] confidence 분포 (사진 품질 지표로 쓸 수 있는가)")
    print(f"  {'페이지':<12}{'단어수':>7}{'평균':>9}{'중앙':>9}{'최저':>9}{'<0.5 개수':>11}")
    for p in pages:
        cs = [w.confidence for w in p.words]
        if not cs:
            print(f"  {p.name:<12}{0:>7}")
            continue
        low = sum(1 for c in cs if c < 0.5)
        print(
            f"  {p.name:<12}{len(cs):>7}{statistics.mean(cs):>9.3f}"
            f"{statistics.median(cs):>9.3f}{min(cs):>9.3f}{low:>11}"
        )
    print("\n  최저 confidence 단어 (페이지별 5개):")
    for p in pages:
        worst = sorted(p.words, key=lambda w: w.confidence)[:5]
        items = ", ".join(f"'{w.text}'({w.confidence:.2f})" for w in worst)
        print(f"    [{p.name}] {items}")
    print("\n  ※ 이 샘플은 촬영본이 아니라 깨끗한 캡처라 값이 높게 나오는 것이 정상입니다.")
    print("     품질 게이트 임계값을 정하려면 **실제 촬영본**으로 다시 재야 합니다.")


# ══════════════════════════════════════════════════════════════════════════════
# [8] 항목 단위 그룹화 — 줄이 아니라 '등기 항목'이 하이라이트의 단위다
# ══════════════════════════════════════════════════════════════════════════════


def _item_rows(items: list[RegistryItem]) -> list[dict[str, str]]:
    rows = []
    for it in items:
        money = " / ".join(m.text for m in it.moneys) or "-"
        holders = " / ".join(f"{n.name}({n.kind})" for n in it.names) or "-"
        if it.canceled:
            status = "말소"
        elif it.is_cancel_record:
            status = "말소근거행"
        else:
            status = "유효"
        rows.append(
            {
                "구역": it.section,
                "순위번호": it.rank or "-",
                "등기목적": it.purpose or "-",
                "금액": money,
                "권리자": holders,
                "말소여부": status,
                "말소근거": it.cancel_evidence or "-",
                "위치": it.location,
            }
        )
    return rows


def check_items(items: list[RegistryItem]) -> None:
    h1("[8] 등기 항목 그룹화 (하이라이트의 실제 단위)")
    print("  줄(line)이 아니라 **항목(item)** 이 단위다. 순위번호 줄부터 다음 순위번호 전까지가")
    print("  한 항목이며, **페이지를 넘어 이어진다**(을구 1번: 금액은 3.png, 은행명은 4.png).")
    print("  말소여부는 반드시 근거와 함께 남긴다 — 근거 없이 말소로 단정하지 않는다.\n")
    if not items:
        print("  ❌ 항목이 하나도 만들어지지 않았습니다 (컬럼 헤더 인식 실패 가능성).")
        return
    for row in _item_rows(items):
        flag = {"말소": "✗", "말소근거행": "·", "유효": "✅"}[row["말소여부"]]
        print(f"  {flag} [{row['구역']} 순위 {row['순위번호']}] {row['등기목적'][:34]}")
        print(f"      금액 {row['금액']}  |  권리자 {row['권리자']}")
        print(f"      말소 {row['말소여부']}  근거 {row['말소근거']}  |  위치 {row['위치']}")
    active = [it for it in items if not it.canceled and not it.is_cancel_record]
    print(f"\n  합계 {len(items)}항목 — 유효 {len(active)} / 말소 {sum(1 for i in items if i.canceled)}"
          f" / 말소근거행 {sum(1 for i in items if i.is_cancel_record)}")


def write_items_summary(items: list[RegistryItem], out_path: Path, sources: list[str]) -> None:
    """항목 표를 마크다운으로 저장 — 비개발 팀원도 읽을 수 있게."""
    lines = [
        "# OCR 항목 추출 결과 (검증용)",
        "",
        "> `backend/scripts/test_ocr_coords.py` 가 자동 생성한 파일이다. **채택 미확정** 기능의",
        "> 중간 산출물이며, 등기부 실명이 들어 있으므로 **커밋하지 않는다**(`out/`은 .gitignore).",
        "",
        f"- 입력: {', '.join(sources)}",
        f"- 항목 {len(items)}건",
        "",
        "| 구역 | 순위번호 | 등기목적 | 금액 | 권리자 | 말소여부 | 말소근거 | 위치 |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for row in _item_rows(items):
        cells = [row[k] for k in ("구역", "순위번호", "등기목적", "금액", "권리자", "말소여부", "말소근거", "위치")]
        lines.append("| " + " | ".join(c.replace("|", "\\|") for c in cells) + " |")
    lines += [
        "",
        "## 읽는 법",
        "",
        "- **말소여부 = 말소**: 이미 없어진 권리다. 하이라이트를 **칠하지 않는다**.",
        "- **말소여부 = 말소근거행**: 그 말소를 기록한 행 자체다(이 행에는 취소선이 없다).",
        "- **말소근거**: 어느 페이지 몇 번째 줄의 어떤 문구 때문에 말소로 봤는지. 근거가 `-` 인데",
        "  말소로 표시된 항목이 있으면 그것은 버그다.",
        "",
    ]
    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"  저장: {out_path}")


# ══════════════════════════════════════════════════════════════════════════════
# --target 매칭
# ══════════════════════════════════════════════════════════════════════════════


def find_target_lines(page: Page, targets: list[str]) -> tuple[list[Line], dict[str, list[int]]]:
    """모든 target이 **같은 줄**에 있는 줄들을 찾는다.

    반환: (완전 매칭 줄 목록, target별 개별 발견 줄 인덱스)
    부분 매칭으로 대충 그리지 않기 위해, 완전 매칭이 없으면 빈 목록을 돌려준다.
    """
    per_target: dict[str, list[int]] = {t: [] for t in targets}
    full: list[Line] = []
    for line in page.lines:
        joined, _ = line.concat()
        squeezed = _norm(joined)
        hits = 0
        for t in targets:
            if _norm(t) in squeezed:
                per_target[t].append(line.index)
                hits += 1
        if hits == len(targets):
            full.append(line)
    return full, per_target


def report_targets(page: Page, targets: list[str], full: list[Line], per_target: dict[str, list[int]]) -> None:
    h2(f"{page.name} — --target {targets}")
    if full:
        print(f"  ✅ 모든 문자열이 같은 줄에서 잡힘 — {len(full)}개 줄:")
        for line in full:
            x0, y0, x1, y1 = line.box
            print(f"    L{line.index} bbox ({x0:.0f},{y0:.0f})-({x1:.0f},{y1:.0f})  {line.display[:66]}")
        return
    print("  ❌ 같은 줄에서 전부 잡히지 않았습니다 — 이 페이지에는 아무것도 그리지 않습니다.")
    for t in targets:
        where = per_target[t]
        if not where:
            print(f"    · '{t}' : 어느 줄에서도 못 찾음")
        else:
            print(f"    · '{t}' : L{where} 에서 찾았으나 다른 문자열과 같은 줄이 아님")


# ══════════════════════════════════════════════════════════════════════════════
# 시각 출력
# ══════════════════════════════════════════════════════════════════════════════

BAND_FILL = (120, 120, 120, 24)  # 옅은 회색 가로 밴드 (줄 묶기 검증)
MONEY_COLOR = (0, 90, 220)  # 파랑 — 금액
KEYWORD_COLOR = (0, 170, 255)  # 하늘 — 키워드
NAME_COLOR = (0, 155, 60)  # 초록 — 이름(권리자)
CANCEL_COLOR = (255, 140, 0)  # 주황 — 말소 행
TARGET_COLOR = (220, 20, 20)  # 빨강 — --target 매칭
LEGEND = [
    ("금액", MONEY_COLOR),
    ("키워드", KEYWORD_COLOR),
    ("이름", NAME_COLOR),
    ("말소 행", CANCEL_COLOR),
    ("target", TARGET_COLOR),
]


def _font(size: int) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
    for path in (r"C:\Windows\Fonts\malgun.ttf", r"C:\Windows\Fonts\gulim.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def _draw_legend(d: ImageDraw.ImageDraw, width: int, caption: str) -> None:
    """이미지 상단에 색 범례를 그린다 — 색만 보고 무엇인지 알 수 있게."""
    font = _font(14)
    bar_h = 26
    d.rectangle([0, 0, width, bar_h], fill=(255, 255, 255))
    d.line([0, bar_h, width, bar_h], fill=(200, 200, 200), width=1)
    x = 6
    for label, color in LEGEND:
        d.rectangle([x, 6, x + 14, 20], outline=color, width=3)
        x += 19
        d.text((x, 6), label, fill=(40, 40, 40), font=font)
        x += int(d.textlength(label, font=font)) + 14
    d.text((x + 4, 6), caption, fill=(120, 120, 120), font=font)


def draw_marked(
    page: Page,
    items: list[RegistryItem],
    target_lines: list[Line] | None,
    out_path: Path,
) -> None:
    """회색 밴드(줄) + 파랑(금액) + 하늘(키워드) + 초록(이름) + 주황(말소 행) + 빨강(target)."""
    base = Image.open(page.path).convert("RGBA")
    overlay = Image.new("RGBA", base.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)

    # 1) 줄 밴드 — 가장 아래 레이어 (좌우는 이미지 전폭으로 늘려 줄 경계를 보이게)
    for line in page.lines:
        _, y0, _, y1 = line.box
        od.rectangle([0, y0, base.width, y1], fill=BAND_FILL)

    # 2) 말소 행 배경 — 이 항목은 "칠하면 안 되는 것"이므로 눈에 띄게 깔아 둔다
    for it in items:
        if not (it.canceled or it.is_cancel_record):
            continue
        box = it.box_on_page(page.index)
        if box:
            od.rectangle([0, box[1] - 2, base.width, box[3] + 2], fill=(255, 140, 0, 30))

    base = Image.alpha_composite(base, overlay)
    d = ImageDraw.Draw(base)
    font = _font(13)

    # 3) 말소 항목 테두리 (주황)
    for it in items:
        if not (it.canceled or it.is_cancel_record):
            continue
        box = it.box_on_page(page.index)
        if box:
            d.rectangle([box[0] - 4, box[1] - 3, box[2] + 4, box[3] + 3], outline=CANCEL_COLOR, width=2)
            tag = "말소됨" if it.canceled else "말소근거"
            d.text((box[2] + 8, box[1]), tag, fill=CANCEL_COLOR, font=font)

    # 4) 금액(파랑) · 키워드(하늘)
    for line in page.lines:
        joined, owner = line.concat()
        money_idx: set[int] = set()
        kw_idx: set[int] = set()
        for m in _MONEY_COMMA.finditer(joined):
            money_idx |= set(owner[m.start() : m.end()])
        for kw in _KEYWORDS:
            for m in re.finditer(re.escape(kw), joined):
                kw_idx |= set(owner[m.start() : m.end()])
        for i in sorted(kw_idx - money_idx):
            w = line.words[i]
            d.rectangle([w.x0 - 1, w.y0 - 1, w.x1 + 1, w.y1 + 1], outline=KEYWORD_COLOR, width=2)
        for i in sorted(money_idx):
            w = line.words[i]
            d.rectangle([w.x0 - 1, w.y0 - 1, w.x1 + 1, w.y1 + 1], outline=MONEY_COLOR, width=2)

    # 5) 이름(초록) — 이름 word 하나에만 딱 맞춘 박스 + 개인/법인 표시
    name_count = 0
    for _, _, hits in collect_names([page]):
        for hit in hits:
            x0, y0, x1, y1 = hit.box
            name_count += 1
            d.rectangle([x0 - 2, y0 - 2, x1 + 2, y1 + 2], outline=NAME_COLOR, width=3)
            d.text((x1 + 5, y0 - 1), f"{hit.kind}", fill=NAME_COLOR, font=font)

    # 6) target 빨간 타원 — 완전 매칭일 때만
    if target_lines:
        for line in target_lines:
            x0, y0, x1, y1 = line.box
            pad_x, pad_y = 10, 6
            d.ellipse([x0 - pad_x, y0 - pad_y, x1 + pad_x, y1 + pad_y], outline=TARGET_COLOR, width=3)

    _draw_legend(d, base.width, f"{page.path.name} | 줄 {len(page.lines)} | 이름 {name_count}")
    base.convert("RGB").save(out_path)
    print(f"  저장: {out_path}")


# ══════════════════════════════════════════════════════════════════════════════
# main
# ══════════════════════════════════════════════════════════════════════════════


def main() -> None:
    original_console = setup_console()

    parser = argparse.ArgumentParser(
        description="Upstage Document OCR 좌표 검증 (⚠ --from-json 없이 실행하면 크레딧 소모)"
    )
    parser.add_argument("image_paths", nargs="+", help="등기부 페이지 이미지 경로(장별 원본, 병합하지 않음)")
    parser.add_argument("--from-json", metavar="디렉터리", help="저장된 OCR JSON 재사용 (API 호출 0회)")
    parser.add_argument("--target", nargs="+", metavar="문자열", help="같은 줄에서 함께 찾아야 하는 문자열들")
    parser.add_argument("--line-tol", type=float, default=0.6,
                        help="줄 묶기 허용 비율 (y중심 차이 ÷ 글자높이, 기본 0.6). 레이아웃 파라미터")
    args = parser.parse_args()

    paths = [Path(p) for p in args.image_paths]
    missing = [str(p) for p in paths if not p.is_file()]
    if missing:
        print("[오류] 파일을 찾을 수 없습니다:", *missing, sep="\n  - ")
        sys.exit(1)

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # ── OCR 확보 (신규 호출 또는 저장본 재사용) ──────────────────────────────
    pages: list[Page] = []
    json_paths: list[Path] = []
    api_key = None
    if not args.from_json:
        try:
            api_key = _load_api_key()
        except ExtractionError as e:
            print(f"[오류] {e.detail}")
            sys.exit(1)
        print(f"⚠ 이미지 {len(paths)}장을 개별 호출합니다 (병합 없음 — 좌표계를 원본과 1:1로 맞추기 위함)")

    for path in paths:
        stem = path.stem
        json_path = OUT_DIR / f"ocr_{stem}.json"
        if args.from_json:
            src = Path(args.from_json) / f"ocr_{stem}.json"
            if not src.is_file():
                print(f"[오류] 저장된 OCR JSON이 없습니다: {src}")
                print("       먼저 --from-json 없이 1회 실행해 응답을 저장하세요.")
                sys.exit(1)
            raw = json.loads(src.read_text(encoding="utf-8"))
            json_path = src
            print(f"[재사용] {src} (API 호출 없음)")
        else:
            try:
                raw, field = call_document_ocr(api_key, path)  # type: ignore[arg-type]
            except ExtractionError as e:
                print(f"[오류] HTTP {e.status_code} — {e.detail}")
                sys.exit(1)
            json_path.write_text(json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8")
            print(f"  저장: {json_path}  (통한 필드명: {field}=@)")

        json_paths.append(json_path)
        words = parse_words(raw)
        pages.append(Page(name=stem, index=len(pages), path=path, raw=raw, words=words,
                          lines=group_lines(words, args.line_tol)))

    if not any(p.words for p in pages):
        print("\n[오류] 단어가 하나도 파싱되지 않았습니다. 응답 구조를 확인하세요:")
        print(json.dumps(pages[0].raw, ensure_ascii=False)[:800])
        sys.exit(1)

    # 항목 그룹화는 **인자로 준 페이지 순서**를 그대로 따른다 (실제 업로드 순서와 동일해야 함)
    items = build_items([p.as_ocr_page() for p in pages], args.line_tol)

    # ── 검증 8종 ────────────────────────────────────────────────────────────
    check_encoding(pages, original_console, json_paths)
    money_occurrences = check_money(pages)
    check_lines(pages, args.line_tol)
    check_cancellation(pages, items, money_occurrences)
    check_owner(pages)
    check_page_identity(pages)
    check_confidence(pages)
    check_items(items)

    # ── 시각 출력 ───────────────────────────────────────────────────────────
    h1("시각 출력")
    write_items_summary(items, OUT_DIR / "items_summary.md", [p.path.name for p in pages])
    if args.target:
        print("  --target 모드: 지정 문자열이 **모두 같은 줄**에서 잡힌 페이지만 그립니다.")
        print("  (부분 매칭으로 대충 그리지 않습니다 — 틀린 표시보다 표시 없음이 낫습니다)\n")
        for p in pages:
            full, per_target = find_target_lines(p, args.target)
            report_targets(p, args.target, full, per_target)
            if full:
                draw_marked(p, items, full, OUT_DIR / f"marked_{p.name}.png")
    else:
        for p in pages:
            draw_marked(p, items, None, OUT_DIR / f"marked_{p.name}.png")

    h1("완료")
    print(f"  결과물: {OUT_DIR}")
    print("  ⚠ out/ 은 .gitignore 대상입니다 — 등기부에는 소유자 실명이 있으므로 커밋 금지.")
    print("  로직만 고쳐 다시 볼 때는 --from-json out 을 쓰면 크레딧이 들지 않습니다.")


if __name__ == "__main__":
    main()
