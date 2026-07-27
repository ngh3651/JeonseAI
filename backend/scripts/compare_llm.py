r"""국내 LLM 비교 하네스 — **같은 입력을 여러 provider에 넣고 나란히 잰다.**

무엇을 재나 (2026-07-28 지시):
- 역할 ① `structure` : 저장된 OCR 레이아웃 텍스트 → 등기 필드 구조화
- 역할 ② `explain`   : 저장된 규칙 엔진 판정 → 쉬운 설명 문장

각 provider × 각 역할 × N회(기본 3) 반복해 아래를 기록한다:
- 응답 시간 / 토큰 수(제공하는 경우)
- 스키마 위반 (제품과 **같은** pydantic 검증: `extra="forbid"`)
- 금지어 위반 (제품과 **같은** `_BANNED_PHRASES`)
- IE 결과와의 필드별 일치율 (항목 수 · 순위번호 집합 · 금액 집합)
- **회차 간 흔들림** — 같은 입력에 다른 답을 주는가

⚠ **승자를 단정하지 않는다.** 숫자와 관찰을 적어 판단 재료를 만드는 것이 목적이다.
   비교표를 읽기 전에 `docs/ie-reproducibility-2026-07-28*.md`(영점)를 먼저 볼 것 —
   거기서 흔들린 폭보다 작은 차이는 모델 차이로 볼 수 없다.

⚠ 개인정보: **보고서에 실명·주소·금액 원문을 넣지 않는다.** 개수·일치율·해시만 쓴다.
   원본 응답은 `backend/out/llm_compare/`(.gitignore)에 남긴다.

⚠ 키가 없는 provider는 자동으로 건너뛴다. 키가 도착하면 `.env`에 값만 넣으면
   **코드 수정 없이** 비교 대상에 합류한다.

실행:
  cd backend
  .\.venv\Scripts\python.exe scripts\compare_llm.py --list          # 호출 0회, 설정만 확인
  .\.venv\Scripts\python.exe scripts\compare_llm.py --repeat 3      # ⚠ 크레딧 소모
  .\.venv\Scripts\python.exe scripts\compare_llm.py --roles structure
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
from app.services import llm, rule_engine  # noqa: E402
from app.services.explanation import _BANNED_PHRASES, _verdict_for_prompt  # noqa: E402
from app.services.llm.base import LlmError  # noqa: E402
from app.services.ocr_layout import OcrPage, group_lines, parse_words  # noqa: E402

OUT_DIR = _BACKEND_ROOT / "out"
RAW_DIR = OUT_DIR / "llm_compare"
DOC_PATH = _BACKEND_ROOT.parent / "docs" / "llm-comparison-2026-07-28.md"
FIXTURES = _BACKEND_ROOT / "tests" / "fixtures" / "registry"

COMPARED_FIELDS = (
    "current_owners",
    "mortgages",
    "jeonse_rights",
    "lease_registrations",
    "provisional_seizures",
    "seizures",
    "auction_commencements",
    "trust_registrations",
)


def h(value: object) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:8]


# ══════════════════════════════════════════════════════════════════════════════
# 입력 준비 — 저장된 OCR / 저장된 판정 (실호출 0회)
# ══════════════════════════════════════════════════════════════════════════════


def load_layout_text() -> tuple[str, list[str]]:
    """저장된 `out/ocr_page_*.json` → 레이아웃 텍스트. 없으면 `out/ocr_<n>.json`."""
    for pattern in ("ocr_page_*.json", "ocr_[0-9].json"):
        files = sorted(OUT_DIR.glob(pattern), key=lambda p: p.stem)
        if not files:
            continue
        pages = []
        for i, f in enumerate(files):
            raw = json.loads(f.read_text(encoding="utf-8"))
            words = parse_words(raw)
            pages.append(
                OcrPage(name=f.stem, index=i, words=words, lines=group_lines(words))
            )
        return llm.render_layout_text(pages), [f.name for f in files]
    raise SystemExit(
        "[오류] backend/out/ 에 저장된 OCR 응답이 없습니다.\n"
        "       먼저 앱에서 1회 분석하거나 scripts/test_ocr_coords.py 를 실행하세요."
    )


def load_ie_extract() -> tuple[RegistryExtract | None, str | None]:
    """저장된 IE 원응답 중 **가장 최근에 항목이 들어 있는** 것 (structure 정답지 대용)."""
    best, best_name = None, None
    for f in sorted(OUT_DIR.glob("ie_*.json"), reverse=True):
        raw = json.loads(f.read_text(encoding="utf-8"))
        if any(isinstance(raw.get(k), list) and raw[k] for k in COMPARED_FIELDS):
            best, best_name = RegistryExtract.from_raw(raw), f.name
            break
    return best, best_name


def load_verdict(fixture: str = "mortgage_heavy"):
    """설명 역할의 입력 — **픽스처에서 만든 판정**이라 실명이 들어 있지 않다."""
    data = json.loads((FIXTURES / f"{fixture}.json").read_text(encoding="utf-8"))
    extract = RegistryExtract.from_raw(data["registry"])
    return rule_engine.evaluate(
        extract,
        deposit=data["inputs"]["deposit"],
        market_price=data["inputs"].get("market_price"),
    )


# ══════════════════════════════════════════════════════════════════════════════
# 채점
# ══════════════════════════════════════════════════════════════════════════════


def _values(extract: RegistryExtract, field: str, attr: str) -> set:
    out = set()
    for item in getattr(extract, field, []) or []:
        if not getattr(item, "is_active", True):
            continue
        v = getattr(item, attr, None)
        if v not in (None, ""):
            out.add(str(v))
    return out


def score_structure(ie: RegistryExtract | None, got: RegistryExtract) -> dict:
    """IE 결과와의 필드별 일치 — 항목 수 · 순위번호 집합 · 금액 집합."""
    if ie is None:
        return {"compared": False}
    rows = {}
    for field in COMPARED_FIELDS:
        ie_n = len([x for x in getattr(ie, field, []) if getattr(x, "is_active", True)])
        got_n = len([x for x in getattr(got, field, []) if getattr(x, "is_active", True)])
        ie_ranks = _values(ie, field, "rank_number")
        got_ranks = _values(got, field, "rank_number")
        amount_attr = {
            "mortgages": "max_claim_amount",
            "jeonse_rights": "deposit_amount",
            "lease_registrations": "deposit_amount",
        }.get(field, "claim_amount")
        ie_amounts = _values(ie, field, amount_attr) | _values(ie, field, "amount")
        got_amounts = _values(got, field, amount_attr) | _values(got, field, "amount")
        rows[field] = {
            "ie_count": ie_n,
            "got_count": got_n,
            "rank_jaccard": _jaccard(ie_ranks, got_ranks),
            "amount_jaccard": _jaccard(ie_amounts, got_amounts),
        }
    counts_match = sum(1 for r in rows.values() if r["ie_count"] == r["got_count"])
    return {
        "compared": True,
        "fields": rows,
        "count_agreement": counts_match / len(COMPARED_FIELDS),
        "rank_agreement": statistics.mean(r["rank_jaccard"] for r in rows.values()),
    }


def _jaccard(a: set, b: set) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def banned_hits(text: str) -> list[str]:
    return [p for p in _BANNED_PHRASES if p in text]


# ══════════════════════════════════════════════════════════════════════════════
# 실행
# ══════════════════════════════════════════════════════════════════════════════


def run_structure(provider, layout_text: str, ie: RegistryExtract | None, attempt: int) -> dict:
    t0 = time.perf_counter()
    try:
        got = provider.structure(layout_text)
    except LlmError as e:
        return {"ok": False, "elapsed": time.perf_counter() - t0, "error": str(e)[:200]}
    elapsed = time.perf_counter() - t0
    dump = got.model_dump()
    return {
        "ok": True,
        "elapsed": elapsed,
        "counts": {f: len(getattr(got, f, [])) for f in COMPARED_FIELDS},
        "score": score_structure(ie, got),
        "fingerprint": h({f: sorted(str(x) for x in getattr(got, f, [])) for f in COMPARED_FIELDS}),
        "raw": dump,
        "attempt": attempt,
    }


def run_explain(provider, verdict, attempt: int) -> dict:
    from app.services.explanation import ExplanationPayload

    t0 = time.perf_counter()
    try:
        payload = provider.explain(_verdict_for_prompt(verdict), {})
    except LlmError as e:
        return {"ok": False, "elapsed": time.perf_counter() - t0, "error": str(e)[:200]}
    elapsed = time.perf_counter() - t0

    schema_ok, schema_error = True, None
    try:
        validated = ExplanationPayload.model_validate(payload)
        texts = [validated.headline] + [e.easy_explanation for e in validated.evidences]
    except Exception as e:  # noqa: BLE001 — 검증 실패 자체가 기록 대상이다
        schema_ok, schema_error = False, f"{type(e).__name__}"
        texts = [str(v) for v in payload.values() if isinstance(v, str)]

    joined = " ".join(texts)
    return {
        "ok": True,
        "elapsed": elapsed,
        "schema_ok": schema_ok,
        "schema_error": schema_error,
        "banned": banned_hits(joined),
        # 해요체 준수 — 제품 프롬프트의 2번 규칙
        "polite_violations": sum(1 for t in texts if t.strip().endswith(("합니다.", "입니다."))),
        "headline_len": len(payload.get("headline", "") or ""),
        "evidence_count": len(payload.get("evidences", []) or []),
        "fingerprint": h(payload),
        "raw": payload,
        "attempt": attempt,
    }


def main() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
        except (AttributeError, OSError):
            pass

    parser = argparse.ArgumentParser(description="국내 LLM 비교 (⚠ --list 외에는 크레딧 소모)")
    parser.add_argument("--repeat", type=int, default=3, help="역할별 반복 횟수 (기본 3)")
    parser.add_argument("--roles", nargs="+", default=["structure", "explain"],
                        choices=["structure", "explain"])
    parser.add_argument("--list", action="store_true", help="설정만 확인하고 끝낸다 (호출 0회)")
    parser.add_argument("--out", default=str(DOC_PATH))
    args = parser.parse_args()

    providers = llm.all_providers()
    print("provider 상태:")
    for p in providers:
        state = f"사용 가능 (model={p.model})" if p.available else f"키 없음 → 건너뜀 ({p.key_env})"
        print(f"  - {p.name:<10} {state}")
    usable = [p for p in providers if p.available]
    if args.list:
        print(f"\n--list 모드: 호출하지 않고 종료합니다. 사용 가능 {len(usable)}개")
        return
    if not usable:
        raise SystemExit("[오류] 사용 가능한 provider가 없습니다 (.env에 키를 넣으세요)")

    layout_text, ocr_files = load_layout_text()
    ie, ie_file = load_ie_extract()
    verdict = load_verdict()
    print(
        f"\n입력: OCR {len(ocr_files)}쪽({len(layout_text):,}자)"
        f" / IE 정답지 {'있음' if ie else '없음'} / 판정 근거 {len(verdict.evidences)}건"
    )
    print(f"계획: {len(usable)} provider × {len(args.roles)} 역할 × {args.repeat}회 (⚠ 크레딧 소모)\n")

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    results: dict[str, dict[str, list[dict]]] = {}
    for p in usable:
        results[p.name] = {}
        for role in args.roles:
            runs = []
            for i in range(1, args.repeat + 1):
                print(f"  [{p.name}/{role}] {i}/{args.repeat} 호출 중…", flush=True)
                r = run_structure(p, layout_text, ie, i) if role == "structure" else run_explain(p, verdict, i)
                if r["ok"]:
                    print(f"     ✓ {r['elapsed']:.1f}초")
                else:
                    print(f"     ✗ {r['error'][:120]}")
                runs.append(r)
            results[p.name][role] = runs
            # 원본은 out/ 에만 (실명 포함 가능 → .gitignore)
            (RAW_DIR / f"{p.name}_{role}.json").write_text(
                json.dumps([r.get("raw") for r in runs], ensure_ascii=False, indent=2),
                encoding="utf-8",
            )

    write_report(Path(args.out), results, providers, args, ocr_files, ie_file, layout_text)


def write_report(path: Path, results, providers, args, ocr_files, ie_file, layout_text) -> None:
    lines: list[str] = [
        "# 국내 LLM 비교 — 구조화 · 설명 (2026-07-28)",
        "",
        "> `backend/scripts/compare_llm.py` 가 생성했다.",
        "> **개인정보 없음** — 개수·일치율·해시만 기록한다. 원본 응답은 `backend/out/llm_compare/`(커밋 금지).",
        "",
        "## 읽기 전에 — 영점(noise floor)을 먼저 볼 것",
        "",
        "`docs/ie-reproducibility-2026-07-28-complex.md`에서 **같은 입력을 5회 반복**했을 때",
        "IE는 배열 길이가 전부 고정이었고, 자유서술 필드(`cause`) 하나만 흔들렸다.",
        "**여기서 그 폭보다 작은 차이는 모델 차이로 볼 수 없다.**",
        "",
        "## 측정 조건",
        "",
        f"- 입력 OCR: {', '.join(ocr_files)} ({len(layout_text):,}자 레이아웃 텍스트)",
        f"- 구조화 정답지(대조용): `{ie_file or '없음'}` — Upstage Information Extract 결과",
        "- 설명 입력: `tests/fixtures/registry/mortgage_heavy.json` 판정 (실명 없음)",
        f"- 반복: 역할별 {args.repeat}회",
        "",
        "## provider",
        "",
        "| provider | 모델 | 상태 |",
        "|---|---|---|",
    ]
    for p in providers:
        state = "사용" if p.available else f"**키 없음 → 건너뜀** (`{p.key_env}`)"
        lines.append(f"| `{p.name}` | `{p.model}` | {state} |")
    lines += [
        "",
        "> 키가 도착하면 `backend/.env`에 값만 넣으면 **코드 수정 없이** 이 표에 합류한다.",
        "",
    ]

    if "structure" in args.roles:
        lines += _structure_section(results, args)
    if "explain" in args.roles:
        lines += _explain_section(results, args)

    lines += [
        "## 관찰 (숫자가 말하지 않는 것)",
        "",
        "- (아침에 사람이 채울 칸) 어떤 모델의 출력이 실제로 읽을 만했는지, 어디서 이상했는지.",
        "- 승자를 단정하지 않는다. 이 표는 **판단 재료**이지 결론이 아니다.",
        "",
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\n저장: {path}")


def _stat(runs, key):
    vals = [r[key] for r in runs if r["ok"] and key in r]
    return statistics.median(vals) if vals else None


def _structure_section(results, args) -> list[str]:
    lines = [
        "## 역할 ① 구조화 (OCR 텍스트 → 등기 필드)",
        "",
        "| provider | 성공 | 중앙 응답(초) | 항목수 일치율 | 순위번호 일치율 | 회차 간 흔들림 |",
        "|---|---|---|---|---|---|",
    ]
    for name, roles in results.items():
        runs = roles.get("structure") or []
        ok = [r for r in runs if r["ok"]]
        if not ok:
            errs = {r.get("error", "?")[:60] for r in runs}
            lines.append(f"| `{name}` | 0/{len(runs)} | — | — | — | — |")
            lines.append(f"| ↳ 오류 | colspan | {'; '.join(errs)} | | | |")
            continue
        med = statistics.median([r["elapsed"] for r in ok])
        scored = [r["score"] for r in ok if r["score"].get("compared")]
        cnt = f"{statistics.mean([s['count_agreement'] for s in scored]):.0%}" if scored else "—"
        rnk = f"{statistics.mean([s['rank_agreement'] for s in scored]):.0%}" if scored else "—"
        prints = {r["fingerprint"] for r in ok}
        wob = "고정" if len(prints) == 1 else f"흔들림({len(prints)}종)"
        lines.append(f"| `{name}` | {len(ok)}/{len(runs)} | {med:.1f} | {cnt} | {rnk} | {wob} |")

    lines += ["", "### 필드별 항목 수 (IE vs 각 provider, 1회차 기준)", ""]
    header = "| 필드 | IE |" + "".join(f" {n} |" for n in results)
    lines += [header, "|---" * (len(results) + 2) + "|"]
    for field in COMPARED_FIELDS:
        row = [f"| `{field}` |"]
        ie_n = None
        for name, roles in results.items():
            ok = [r for r in (roles.get("structure") or []) if r["ok"]]
            if ok and ok[0]["score"].get("compared"):
                ie_n = ok[0]["score"]["fields"][field]["ie_count"]
                break
        row.append(f" {ie_n if ie_n is not None else '—'} |")
        for name, roles in results.items():
            ok = [r for r in (roles.get("structure") or []) if r["ok"]]
            row.append(f" {ok[0]['counts'][field] if ok else '—'} |")
        lines.append("".join(row))
    lines.append("")
    return lines


def _explain_section(results, args) -> list[str]:
    lines = [
        "## 역할 ② 설명 문장 (판정 JSON → 쉬운 한국어)",
        "",
        "제품과 **같은** 검증을 그대로 쓴다 — `ExplanationPayload`(extra=forbid) + `_BANNED_PHRASES`.",
        "",
        "| provider | 성공 | 중앙 응답(초) | 스키마 통과 | 금지어 위반 | 해요체 위반 | 회차 간 흔들림 |",
        "|---|---|---|---|---|---|---|",
    ]
    for name, roles in results.items():
        runs = roles.get("explain") or []
        ok = [r for r in runs if r["ok"]]
        if not ok:
            lines.append(f"| `{name}` | 0/{len(runs)} | — | — | — | — | — |")
            continue
        med = statistics.median([r["elapsed"] for r in ok])
        schema = sum(1 for r in ok if r["schema_ok"])
        banned = sum(len(r["banned"]) for r in ok)
        polite = sum(r["polite_violations"] for r in ok)
        prints = {r["fingerprint"] for r in ok}
        wob = "고정" if len(prints) == 1 else f"흔들림({len(prints)}종)"
        lines.append(
            f"| `{name}` | {len(ok)}/{len(runs)} | {med:.1f} | {schema}/{len(ok)}"
            f" | {banned}건 | {polite}건 | {wob} |"
        )
    lines += [
        "",
        "> 금지어·해요체 위반이 있어도 **제품에서는 그 필드만 폴백으로 치환**되므로 화면에 나가지 않는다",
        "> (`explanation.py`의 `_field_ok`). 이 표는 '얼마나 자주 폴백을 쓰게 되는가'를 재는 것이다.",
        "",
    ]
    return lines


if __name__ == "__main__":
    main()
