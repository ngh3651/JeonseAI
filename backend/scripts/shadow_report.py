"""그림자 로그 집계 — 쌓인 JSONL을 사람이 읽는 표로 (2026-08-05 신설).

    .venv/Scripts/python.exe scripts/shadow_report.py            # 전체
    .venv/Scripts/python.exe scripts/shadow_report.py --date 2026-08-05
    .venv/Scripts/python.exe scripts/shadow_report.py --samples 3  # 문장 예시도 보기

⚠ 이 표는 **품질을 채점하지 않는다.** 기계가 잴 수 있는 것(지연·폴백률·사유 분포)만
  낸다. "어느 문장이 더 좋은가"는 사람이 원문을 읽고 판단해야 한다 — `--samples`로
  두 모델의 문장을 나란히 뽑아 볼 수 있다.
⚠ 로그에 개인정보가 없어야 정상이다(`shadow_llm._scrub`). 이상한 값이 보이면 마스킹
  규칙부터 확인할 것.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path
from statistics import mean, median

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.services.shadow_llm import LOG_DIR  # noqa: E402


def load(date: str | None) -> list[dict]:
    if not LOG_DIR.is_dir():
        return []
    files = sorted(LOG_DIR.glob(f"{date}.jsonl" if date else "*.jsonl"))
    out: list[dict] = []
    for f in files:
        for line in f.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                continue
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="LLM 그림자 로그 집계")
    ap.add_argument("--date", help="YYYY-MM-DD (없으면 전체)")
    ap.add_argument("--samples", type=int, default=0, help="문장 예시를 N건 보여준다")
    args = ap.parse_args()

    records = load(args.date)
    if not records:
        print(f"기록이 없습니다: {LOG_DIR}")
        print("켜는 법: backend/.env 에  SHADOW_LLM=exaone  을 넣고 분석을 한 번 돌리세요.")
        return 1

    print("=" * 78)
    print(f" LLM 그림자 로그 — 케이스 {len(records)}건" + (f" ({args.date})" if args.date else ""))
    print("=" * 78)

    elapsed: dict[str, list[float]] = defaultdict(list)
    field_total: Counter = Counter()
    field_fail: Counter = Counter()
    reasons: dict[str, Counter] = defaultdict(Counter)
    errors: Counter = Counter()
    parse_fail: Counter = Counter()
    grades: Counter = Counter()

    for rec in records:
        grades[rec.get("grade", "?")] += 1
        for model, info in (rec.get("models") or {}).items():
            if info.get("elapsed_sec") is not None:
                elapsed[model].append(float(info["elapsed_sec"]))
            if info.get("error"):
                errors[model] += 1
            v = info.get("verify") or {}
            if v and not v.get("parsed"):
                parse_fail[model] += 1
            for field, reason in (v.get("fields") or {}).items():
                field_total[model] += 1
                if reason != "통과":
                    field_fail[model] += 1
                    # 사유의 앞부분만(괄호 안 상세는 묶는다)
                    reasons[model][reason.split("(")[0].strip()] += 1

    print(f"\n판정 등급 분포: {dict(grades)}")

    print("\n" + "-" * 78)
    print(f" {'모델':<12}{'케이스':>7}{'평균지연':>10}{'중앙':>8}{'호출실패':>9}{'파싱실패':>9}")
    print("-" * 78)
    for model in sorted(elapsed):
        e = elapsed[model]
        print(
            f" {model:<12}{len(e):>7}{mean(e):>9.1f}s{median(e):>7.1f}s"
            f"{errors[model]:>9}{parse_fail[model]:>9}"
        )

    print("\n" + "-" * 78)
    print(f" {'모델':<12}{'검증 필드':>10}{'폴백':>8}{'폴백률':>9}   사유 분포")
    print("-" * 78)
    for model in sorted(field_total):
        tot, bad = field_total[model], field_fail[model]
        dist = " · ".join(f"{k} {v}" for k, v in reasons[model].most_common()) or "-"
        print(f" {model:<12}{tot:>10}{bad:>8}{bad / tot * 100:>8.1f}%   {dist}")

    if args.samples:
        print("\n" + "=" * 78)
        print(f" 문장 예시 {args.samples}건 — **품질은 사람이 판단한다**")
        print("=" * 78)
        for rec in records[: args.samples]:
            print(f"\n── {rec.get('report_id')} · 판정 {rec.get('grade')} ──")
            for model, info in (rec.get("models") or {}).items():
                raw = info.get("raw")
                head = "-"
                if raw:
                    try:
                        head = json.loads(raw).get("headline", "-")
                    except ValueError:
                        head = "(JSON 파싱 실패)"
                print(f"  [{model:<8}] {info.get('elapsed_sec')}s  headline: {head}")

    print("\n" + "=" * 78)
    print(" 이 표로 알 수 있는 것 / 없는 것")
    print("=" * 78)
    print("  알 수 있다 : 어느 모델이 더 빠른가 · 형식을 더 잘 지키는가(파싱·폴백률) ·")
    print("               어떤 검증에 자주 걸리는가")
    print("  알 수 없다 : **어느 문장이 더 좋은가.** 그건 --samples 로 원문을 읽고")
    print("               사람이 채점해야 한다(설명이 이 집에만 해당하는가·읽기 쉬운가).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
