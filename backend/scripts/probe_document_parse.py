r"""Upstage **Document Parse** 조사 CLI — `ocr_layout.py`를 대체할 수 있는가.

배경 (2026-07-28):
지난 밤 하이라이트 버그 5건이 **전부 표 재조립 단계**에서 났다.
(분수 분모를 순위번호로 오인 / 등기목적 칸 두 줄 접힘 / `매매`+이름 삼킴 /
 각주가 항목에 삼켜짐 / 표지 문구 말소 오탐)
그 재조립을 지금은 `ocr_layout.py`가 손으로 한다. Document Parse가 문서 구조와
표 HTML을 대신 준다면 그 코드가 통째로 접힌다.

세 제품의 위치:
- Document OCR      = 낱말 + 좌표. 표 조립은 우리 몫.
- **Document Parse** = 문서 구조 + 표 HTML + 요소 좌표. 조립을 대신해 준다(주장).
- Information Extract = 완성된 필드. 좌표 없음.

즉 DP는 IE의 대체재가 아니라 **`ocr_layout.py`의 대체 후보**다.

이 스크립트가 답하는 것:
1. `coordinates`가 **요소 단위인가 낱말 단위인가** (가장 중요 — 이름 하이라이트가 걸린다)
2. 등기부 표가 `table` 요소로 잡히는가 / 두 줄 접힘·페이지 걸침이 살아 있는가
3. 꼬리말이 `footer`/`footnote`로 분류되는가 (정규식 방어를 걷어낼 수 있는가)
4. 말소 근거 행이 온전한 한 덩어리로 오는가
5. 응답 시간 (Document OCR 장당 1.6~3.1초 대비)

⚠ 실행 시 **크레딧 소모**. 원응답은 `out/dp_<stem>.json`에 저장(실명 포함 → 커밋 금지).
⚠ 출력에 실명·주소·등록번호를 찍지 않는다. 구조·개수·참·거짓만.

실행:
  cd backend
  .\.venv\Scripts\python.exe scripts\probe_document_parse.py                # 실호출
  .\.venv\Scripts\python.exe scripts\probe_document_parse.py --from-json    # 저장본 재분석(0원)
"""

from __future__ import annotations

import argparse
import io
import json
import mimetypes
import re
import sys
import time
from collections import Counter
from pathlib import Path

import requests

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))

from app.services.extraction import (  # noqa: E402
    _USER_FACING_STATUS,
    ExtractionError,
    _load_api_key,
)

DP_URL = "https://api.upstage.ai/v1/document-digitization"
DP_MODEL = "document-parse"
OUT_DIR = _BACKEND_ROOT / "out"
TIMEOUT = 300


def h1(t: str) -> None:
    print(f"\n{'=' * 78}\n{t}\n{'=' * 78}")


def h2(t: str) -> None:
    print(f"\n── {t} " + "─" * max(0, 72 - len(t)))


def call_dp(api_key: str, path: Path) -> tuple[dict, float]:
    """이미지 1장 → Document Parse 원응답. 좌표·HTML을 함께 요청한다."""
    mime = mimetypes.guess_type(path.name)[0] or "image/png"
    data = path.read_bytes()
    t0 = time.perf_counter()
    resp = requests.post(
        DP_URL,
        headers={"Authorization": f"Bearer {api_key}"},
        data={
            "model": DP_MODEL,
            "ocr": "force",  # 사진이므로 OCR을 강제한다(내장 텍스트가 없다)
            "coordinates": "true",
            "output_formats": '["html", "markdown", "text"]',
            "base64_encoding": "[]",  # 잘라낸 이미지는 필요 없다(응답만 커진다)
        },
        files={"document": (path.name, io.BytesIO(data), mime)},
        timeout=TIMEOUT,
    )
    elapsed = time.perf_counter() - t0
    if resp.status_code != 200:
        detail = _USER_FACING_STATUS.get(resp.status_code, "Document Parse 호출 실패")
        raise ExtractionError(resp.status_code, f"{detail}\n  서버 응답: {resp.text[:400]}")
    return resp.json(), elapsed


# ══════════════════════════════════════════════════════════════════════════════
# 분석 — 값은 찍지 않고 구조만 본다
# ══════════════════════════════════════════════════════════════════════════════

_MASK = re.compile(r"\d{6}\s*[-－]\s*[0-9*]{6,8}")


def safe(text: str, limit: int = 60) -> str:
    """등록번호를 지우고 길이를 자른 미리보기. 이름은 짧아 남을 수 있으므로 **호출 최소화**."""
    return _MASK.sub("******-*******", (text or "").replace("\n", " "))[:limit]


def elements_of(raw: dict) -> list[dict]:
    return raw.get("elements") or []


def report_shape(name: str, raw: dict, elapsed: float) -> dict:
    h2(f"{name} — 응답 {elapsed:.1f}초")
    print(f"  최상위 키: {sorted(raw.keys())}")
    els = elements_of(raw)
    print(f"  elements: {len(els)}개")
    if not els:
        return {}
    e0 = els[0]
    print(f"  element 키: {sorted(e0.keys())}")
    if "content" in e0 and isinstance(e0["content"], dict):
        print(f"  content 키: {sorted(e0['content'].keys())}")
    cats = Counter(e.get("category") for e in els)
    print(f"  category 분포: {dict(cats)}")

    # [1] 좌표 단위 — 요소 단위인가 낱말 단위인가
    coord_els = [e for e in els if e.get("coordinates")]
    print(f"  coordinates 있는 요소: {len(coord_els)}/{len(els)}")
    if coord_els:
        c = coord_els[0]["coordinates"]
        print(f"    좌표 형태: {type(c).__name__}, 길이 {len(c) if hasattr(c, '__len__') else '?'}")
        print(f"    첫 좌표 원소: {c[0] if isinstance(c, list) and c else c}")
    word_level = any("words" in e for e in els)
    print(f"  낱말 단위(words) 필드 존재: {word_level}")
    return {"cats": cats, "n": len(els), "coord": len(coord_els), "words": word_level}


def check_tables(name: str, raw: dict) -> None:
    tables = [e for e in elements_of(raw) if e.get("category") == "table"]
    print(f"  [{name}] table 요소 {len(tables)}개")
    for i, t in enumerate(tables):
        html = (t.get("content") or {}).get("html") or ""
        rows = html.count("<tr")
        cols = html.split("</tr>")[0].count("<td") + html.split("</tr>")[0].count("<th") if rows else 0
        spans = html.count("rowspan") + html.count("colspan")
        print(f"    표{i}: <tr> {rows}행 / 첫 행 칸 {cols}개 / span 속성 {spans}개 / html {len(html)}자")


def check_targets(all_raw: dict[str, dict]) -> None:
    """밤 버그의 원인이었던 **네 지점**이 DP에서 어떻게 오는지 본다."""
    targets = {
        "말소 근거 행(…등기말소)": re.compile(r"\d+번[가-힣]{0,12}등기말소"),
        "말소 근거 행(끊긴 형태)": re.compile(r"\d+번[가-힣]{0,12}등$"),
        "각주(실선으로 그어진…)": re.compile(r"실선으로\s*그어진"),
        "표지 제목(등기사항전부증명서)": re.compile(r"등기사항전부증명서"),
        "페이지 표식 N/M": re.compile(r"\b\d{1,3}\s*/\s*\d{1,3}\b"),
        "발급확인번호": re.compile(r"[A-Z]{3,5}-[A-Z]{3,5}-\d{3,5}"),
        "열람일시": re.compile(r"열람일시"),
        "채권최고액": re.compile(r"채권최고액"),
        "근저당권설정": re.compile(r"근저당권설정"),
        "전용면적(㎡)": re.compile(r"㎡"),
    }
    for label, rx in targets.items():
        hits: list[str] = []
        for name, raw in all_raw.items():
            for e in elements_of(raw):
                text = (e.get("content") or {}).get("text") or ""
                html = (e.get("content") or {}).get("html") or ""
                if rx.search(text) or rx.search(html):
                    hits.append(f"{name}:{e.get('category')}")
        uniq = Counter(hits)
        mark = "O" if hits else "X"
        print(f"  [{mark}] {label:<28} {len(hits)}건  {dict(uniq)}")


def check_cancel_row(all_raw: dict[str, dict]) -> None:
    """말소 근거 행이 **온전한 한 덩어리**로 오는가 (밤 버그 ②의 핵심)."""
    rx_full = re.compile(r"(\d+)번([가-힣]{1,20}?)말소")
    rx_broken = re.compile(r"(\d+)번[가-힣]{0,20}등\s*$")
    for name, raw in all_raw.items():
        for e in elements_of(raw):
            content = e.get("content") or {}
            for fmt in ("text", "html"):
                s = content.get(fmt) or ""
                for m in rx_full.finditer(s):
                    print(f"    ✅ [{name}/{e.get('category')}/{fmt}] 온전한 말소 문구 검출: '{m.group(0)}'")
                for m in rx_broken.finditer(s):
                    print(f"    ⚠ [{name}/{e.get('category')}/{fmt}] 끊긴 형태 의심: '{m.group(0)[-14:]}'")


def main() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
        except (AttributeError, OSError):
            pass

    parser = argparse.ArgumentParser(description="Document Parse 조사 (⚠ 크레딧 소모)")
    parser.add_argument("images", nargs="*",
                        default=[str(_BACKEND_ROOT / "test_samples" / f"{i}.png") for i in range(1, 6)])
    parser.add_argument("--from-json", action="store_true", help="저장된 out/dp_*.json 재사용 (호출 0회)")
    args = parser.parse_args()

    paths = [Path(p) for p in args.images]
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    all_raw: dict[str, dict] = {}
    times: dict[str, float] = {}

    api_key = None
    if not args.from_json:
        api_key = _load_api_key()
        print(f"⚠ 이미지 {len(paths)}장을 Document Parse로 개별 호출합니다 (크레딧 소모)")

    h1("[0] 호출 / 로드")
    for path in paths:
        out_path = OUT_DIR / f"dp_{path.stem}.json"
        if args.from_json:
            if not out_path.is_file():
                print(f"  [건너뜀] {out_path.name} 없음")
                continue
            raw, elapsed = json.loads(out_path.read_text(encoding="utf-8")), 0.0
            print(f"  [재사용] {out_path.name}")
        else:
            try:
                raw, elapsed = call_dp(api_key, path)  # type: ignore[arg-type]
            except ExtractionError as e:
                print(f"  [실패] {path.name} — HTTP {e.status_code}: {e.detail}")
                continue
            out_path.write_text(json.dumps(raw, ensure_ascii=False, indent=2), encoding="utf-8")
            print(f"  [저장] {out_path.name} ({elapsed:.1f}초, {len(json.dumps(raw))/1024:.0f}KB)")
        all_raw[path.stem] = raw
        times[path.stem] = elapsed

    if not all_raw:
        print("\n분석할 응답이 없습니다.")
        return

    h1("[1] 응답 구조 · 좌표 단위 (가장 중요)")
    for name, raw in all_raw.items():
        report_shape(name, raw, times.get(name, 0.0))

    h1("[2] 표(table) 요소")
    for name, raw in all_raw.items():
        check_tables(name, raw)

    h1("[3] 밤 버그 4지점이 어떻게 오는가")
    check_targets(all_raw)

    h1("[4] 말소 근거 행 — 온전한가 끊기는가")
    check_cancel_row(all_raw)

    h1("[5] 응답 시간")
    if times and any(times.values()):
        vals = [v for v in times.values() if v]
        print(f"  장당: {', '.join(f'{k} {v:.1f}초' for k, v in times.items() if v)}")
        print(f"  합계 {sum(vals):.1f}초 / 평균 {sum(vals)/len(vals):.1f}초")
        print("  비교: Document OCR 실측 장당 1.6~3.1초 (docs/ocr-highlight-findings.md §2.1)")
    else:
        print("  (--from-json 모드라 측정값 없음)")

    h1("완료")
    print(f"  원응답: {OUT_DIR}/dp_*.json  ⚠ 실명 포함 — 커밋 금지")


if __name__ == "__main__":
    main()
