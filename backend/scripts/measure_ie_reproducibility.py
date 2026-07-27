r"""Information Extract **재현성 영점 측정** — 같은 입력을 N회 넣어 답이 흔들리는지 잰다.

왜 이걸 먼저 하나 (2026-07-28):
`out/ie_*.json` 5건 중 3건은 같은 문서인데 배열 길이 합계가 **18 / 16 / 16**으로 갈렸다.
이 차이가 **모델의 흔들림**인지 **입력이 달랐던 것**인지 모르면, 앞으로 붙일 다른 LLM과
비교했을 때 나온 차이가 모델 차이인지 노이즈인지 구분할 수 없다. 즉 **모든 AI 비교 실험의
영점(zero point)이 여기다.**

측정하는 것:
- 배열 필드별 길이 (mortgages / seizures / … 10종)
- 스칼라 필드(address·document_title·exclusive_area_sqm)의 **해시** — 값은 찍지 않는다
- 항목별 핵심 필드(rank_number·is_canceled·금액)의 **해시 집합** — 순서가 바뀌어도 같은지 본다
- 응답 시간

⚠ 실행마다 실제 크레딧을 쓴다 (IE 1회 ≈ 30초). 기본 3회.
⚠ 개인정보: 이름·주소·등록번호를 **출력하지 않는다.** 개수·해시·참/거짓만 남긴다.

실행:
  cd backend
  .\.venv\Scripts\python.exe scripts\measure_ie_reproducibility.py
  .\.venv\Scripts\python.exe scripts\measure_ie_reproducibility.py --repeat 3 --images test_samples\1.png ...
"""

from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import sys
import time
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))

from app.schemas.internal import RegistryExtract  # noqa: E402
from app.services.extraction import (  # noqa: E402
    ExtractionError,
    call_information_extract,
)

DOC_ROOT = _BACKEND_ROOT.parent / "docs"
LIST_KEYS = RegistryExtract.LIST_KEYS
SCALAR_KEYS = ("address", "document_title", "exclusive_area_sqm")


def h(value: object) -> str:
    """값 → 6자리 해시. **원문을 절대 출력하지 않기 위한** 동일성 비교 수단."""
    if value is None:
        return "-"
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:6]


def entry_fingerprints(raw: dict, key: str) -> list[str]:
    """배열 원소별 지문 — 항목 동일성을 값 노출 없이 비교한다.

    순서가 바뀌어도 같은 집합인지 보려고 **정렬한 해시 목록**으로 만든다.
    """
    items = raw.get(key)
    if not isinstance(items, list):
        return []
    return sorted(h(x) for x in items if isinstance(x, dict))


def run_once(images: list[tuple[str, bytes]], attempt: int) -> dict:
    print(f"  [{attempt}회차] IE 호출 중… (⚠ 크레딧 소모)", flush=True)
    t0 = time.perf_counter()
    try:
        raw = call_information_extract(images)
    except ExtractionError as e:
        elapsed = time.perf_counter() - t0
        print(f"    ✗ 실패 HTTP {e.status_code} — {e.detail} ({elapsed:.1f}초)")
        return {"ok": False, "elapsed": elapsed, "error": f"HTTP {e.status_code}"}
    elapsed = time.perf_counter() - t0

    lengths = {k: (len(raw[k]) if isinstance(raw.get(k), list) else None) for k in LIST_KEYS}
    scalars = {k: h(raw.get(k)) for k in SCALAR_KEYS}
    prints = {k: entry_fingerprints(raw, k) for k in LIST_KEYS}
    total = sum(v for v in lengths.values() if isinstance(v, int))
    print(f"    ✓ {elapsed:.1f}초 — 배열 합계 {total}건 " + " ".join(f"{k[:6]}={v}" for k, v in lengths.items() if v))
    return {
        "ok": True,
        "elapsed": elapsed,
        "lengths": lengths,
        "scalars": scalars,
        "fingerprints": prints,
        # 필드 단위 비교용 원본. **출력하지 않는다** — 해시로만 쓰인다(_field_level_wobble).
        "raw_items": {k: [x for x in (raw.get(k) or []) if isinstance(x, dict)] for k in LIST_KEYS},
        "total": total,
    }


def _stability(values: list) -> str:
    uniq = {json.dumps(v, ensure_ascii=False, sort_keys=True) for v in values}
    return "고정" if len(uniq) == 1 else f"흔들림({len(uniq)}종)"


def _field_level_wobble(
    ok_runs: list[dict], keys: list[str]
) -> dict[str, tuple[list[str], list[str]]]:
    """흔들린 배열에 대해 **어느 필드가** 회차마다 달랐는지 좁힌다.

    값은 절대 내보내지 않는다 — 필드별 값들을 해시해 정렬한 목록만 비교한다.
    반환: {배열키: (달라진 필드 목록, 같았던 필드 목록)}
    """
    out: dict[str, tuple[list[str], list[str]]] = {}
    for key in keys:
        per_run = [r["raw_items"].get(key, []) for r in ok_runs]
        names = sorted({f for items in per_run for it in items for f in it})
        differ, same = [], []
        for field_name in names:
            shapes = [sorted(h(it.get(field_name)) for it in items) for items in per_run]
            (same if _stability(shapes) == "고정" else differ).append(field_name)
        out[key] = (differ, same)
    return out


def write_report(runs: list[dict], images: list[str], out_path: Path, repeat: int) -> None:
    ok_runs = [r for r in runs if r["ok"]]
    lines: list[str] = [
        "# Information Extract 재현성 영점 측정 (2026-07-28)",
        "",
        "> `backend/scripts/measure_ie_reproducibility.py` 가 생성했다.",
        "> **개인정보 없음** — 값 대신 6자리 해시와 개수만 기록한다.",
        "",
        "## 왜 쟀나",
        "",
        "`out/ie_*.json` 3건(같은 문서)의 배열 길이 합계가 **18 / 16 / 16**으로 갈렸다.",
        "이것이 모델의 흔들림인지 입력 차이인지 모르면, 다른 LLM과 비교했을 때 나온 차이가",
        "**모델 차이인지 노이즈인지 구분할 수 없다.** 모든 AI 비교 실험의 영점이 여기다.",
        "",
        "## 측정 조건",
        "",
        f"- 입력: 같은 이미지 {len(images)}장 (`{', '.join(images)}`)",
        f"- 반복: {repeat}회 (성공 {len(ok_runs)}회)",
        "- 모델·엔드포인트·스키마: 운영 경로와 동일 (`app/services/extraction.py`)",
        "",
    ]

    if not ok_runs:
        lines += ["## 결과", "", "**전 회차 실패.** 아래 오류를 확인할 것.", ""]
        for i, r in enumerate(runs, 1):
            lines.append(f"- {i}회차: {r.get('error', '알 수 없음')}")
        out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return

    times = [r["elapsed"] for r in ok_runs]
    lines += [
        "## 1. 응답 시간",
        "",
        "| 회차 | 초 |",
        "|---|---|",
    ]
    for i, r in enumerate(ok_runs, 1):
        lines.append(f"| {i} | {r['elapsed']:.1f} |")
    lines += [
        f"| **중앙값** | **{statistics.median(times):.1f}** |",
        f"| **최소~최대** | {min(times):.1f} ~ {max(times):.1f} |",
        "",
        "## 2. 배열 길이 — 회차마다 같은가",
        "",
        "| 필드 | " + " | ".join(f"{i}회차" for i in range(1, len(ok_runs) + 1)) + " | 판정 |",
        "|---" * (len(ok_runs) + 2) + "|",
    ]
    unstable_fields: list[str] = []
    for k in LIST_KEYS:
        vals = [r["lengths"][k] for r in ok_runs]
        verdict = _stability(vals)
        if verdict != "고정":
            unstable_fields.append(k)
        lines.append(f"| `{k}` | " + " | ".join(str(v) for v in vals) + f" | {verdict} |")
    totals = [r["total"] for r in ok_runs]
    lines.append("| **합계** | " + " | ".join(str(t) for t in totals) + f" | {_stability(totals)} |")

    lines += [
        "",
        "## 3. 스칼라 필드 — 값이 같은가 (해시 비교, 원문 미출력)",
        "",
        "| 필드 | " + " | ".join(f"{i}회차" for i in range(1, len(ok_runs) + 1)) + " | 판정 |",
        "|---" * (len(ok_runs) + 2) + "|",
    ]
    for k in SCALAR_KEYS:
        vals = [r["scalars"][k] for r in ok_runs]
        lines.append(f"| `{k}` | " + " | ".join(f"`{v}`" for v in vals) + f" | {_stability(vals)} |")

    lines += [
        "",
        "## 4. 항목 지문 — 같은 항목이 **같은 내용으로** 오는가",
        "",
        "원소별 해시를 정렬해 비교한다(순서가 바뀌어도 집합이 같으면 '고정').",
        "**길이가 같아도 내용이 다를 수 있다** — 이 표가 그것을 잡는다.",
        "",
        "| 필드 | 판정 | 비고 |",
        "|---|---|---|",
    ]
    unstable_entries: list[str] = []
    for k in LIST_KEYS:
        sets = [r["fingerprints"][k] for r in ok_runs]
        verdict = _stability(sets)
        note = ""
        if verdict != "고정":
            unstable_entries.append(k)
            common = set(sets[0])
            for s in sets[1:]:
                common &= set(s)
            note = f"교집합 {len(common)}건 / 회차별 개수 {[len(s) for s in sets]}"
        lines.append(f"| `{k}` | {verdict} | {note} |")

    # 어떤 **필드**가 흔들렸는지까지 좁힌다 — 값은 찍지 않고 필드 이름만.
    field_wobble = _field_level_wobble(ok_runs, unstable_entries)
    if field_wobble:
        lines += [
            "",
            "### 4-1. 흔들린 배열의 **어느 필드**가 달랐나 (필드 이름만, 값 미출력)",
            "",
            "| 배열 | 회차마다 값이 달라진 필드 | 회차마다 같았던 필드 |",
            "|---|---|---|",
        ]
        for key, (differ, same) in field_wobble.items():
            lines.append(
                f"| `{key}` | {', '.join(f'`{f}`' for f in differ) or '—'} "
                f"| {', '.join(f'`{f}`' for f in same) or '—'} |"
            )

    lines += ["", "## 5. 결론", ""]
    if unstable_fields or unstable_entries:
        if unstable_fields:
            lines.append(
                f"**배열 길이가 흔들린다**: {', '.join(f'`{k}`' for k in unstable_fields)}"
            )
        if unstable_entries:
            lines.append(
                f"**항목 내용이 흔들린다**(길이는 같아도): "
                f"{', '.join(f'`{k}`' for k in unstable_entries)}"
            )
        lines += [
            "",
            "→ **이것이 이 실험의 영점(noise floor)이다.** 앞으로 다른 provider와 비교할 때,",
            "   여기서 흔들린 배열·필드에 나타난 차이는 **모델 차이로 볼 수 없다.**",
            "   비교표를 읽기 전에 반드시 이 절을 먼저 볼 것.",
            "",
        ]
    else:
        lines += [
            "**같은 입력에는 같은 답이 나왔다** (이 표본에서). 배열 길이·항목 지문 모두 회차 간 동일.",
            "",
            "→ 이 문서에서는 IE가 결정적으로 동작한다. 다른 문서에서 관측된 차이는",
            "   모델 흔들림이 아니라 **입력 차이**로 먼저 의심해야 한다.",
            "",
        ]
    lines += [
        "### 이 측정의 한계 — 축소해서 읽지 말 것",
        "",
        f"- 표본은 **문서 1건 × {len(ok_runs)}회**다. 다른 등기부에서 같다는 보장이 아니다.",
        "- 온도·seed 같은 호출 파라미터를 우리가 고정한 것이 아니다 — 서버 기본값에 의존한다.",
        "- '고정'은 **이 회차 수 안에서** 관측되지 않았다는 뜻이지, 흔들리지 않는다는 증명이 아니다.",
        "",
    ]
    failed = [r for r in runs if not r["ok"]]
    if failed:
        lines += [f"- 실패 {len(failed)}회: " + ", ".join(r.get("error", "?") for r in failed), ""]

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\n  저장: {out_path}")


def main() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
        except (AttributeError, OSError):
            pass

    parser = argparse.ArgumentParser(description="IE 재현성 측정 (⚠ 회차마다 크레딧 소모)")
    parser.add_argument("--repeat", type=int, default=3, help="반복 횟수 (기본 3)")
    parser.add_argument(
        "--images",
        nargs="+",
        default=[str(_BACKEND_ROOT / "test_samples" / f"{i}.png") for i in range(1, 6)],
        help="입력 이미지 경로들 (기본: test_samples/1~5.png)",
    )
    parser.add_argument(
        "--out",
        default=str(DOC_ROOT / "ie-reproducibility-2026-07-28.md"),
        help="보고서 저장 경로",
    )
    args = parser.parse_args()

    paths = [Path(p) for p in args.images]
    missing = [str(p) for p in paths if not p.is_file()]
    if missing:
        print("[오류] 파일을 찾을 수 없습니다:", *missing, sep="\n  - ")
        sys.exit(1)

    images = [(p.name, p.read_bytes()) for p in paths]
    print(f"입력 {len(images)}장 × {args.repeat}회 = IE 호출 {args.repeat}회 (⚠ 크레딧 소모)\n")

    runs = [run_once(images, i) for i in range(1, args.repeat + 1)]
    write_report(runs, [p.name for p in paths], Path(args.out), args.repeat)


if __name__ == "__main__":
    main()
