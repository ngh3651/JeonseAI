"""검색 정확도 평가 하네스 — eval_set.json의 기대 쌍으로 측정하는 개선 루프의 심장.

측정 지표 (시나리오 = 판정 상황):
- **Hit@K**  : 기대 판례 중 1건 이상이 상위 K(=MAX_CASES)에 들었는가
- **P@1**    : must_rank_1 판례가 1위인가 (지정된 시나리오만)
- **Recall** : 기대 판례 집합 중 상위 K에 든 비율 (복합 시나리오용)
- **MRR**    : 첫 정답의 역순위 평균

두 모드로 잰다:
- filtered   : 실서비스 경로(service.search_by_tags — 태그 필터 + 분기 검색)
- unfiltered : 태그 필터 없이 순수 하이브리드 랭킹 (임베딩·BM25 품질의 민낯 —
               필터라는 목발 없이 순위가 서는지 추적)

사용:
  python scripts/eval_retrieval.py                 # 인덱스 서명에 맞는 백엔드로 평가
  python scripts/eval_retrieval.py --show-scores   # 시나리오별 상세 점수 출력
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

from app.services.precedent.retrieval import HybridRetriever  # noqa: E402
from app.services.precedent.service import (  # noqa: E402
    MAX_CASES,
    PrecedentService,
    QUERY_TEMPLATES,
)

EVAL_PATH = _BACKEND_ROOT / "data" / "precedents" / "eval_set.json"


def _norm(case_no: str) -> str:
    return "".join(case_no.split())


def _hit(expected: list[str], got: list[str]) -> bool:
    got_norm = [_norm(g) for g in got]
    return any(any(_norm(e) in g for g in got_norm) for e in expected)


def _first_rank(expected: list[str], got: list[str]) -> int | None:
    for i, g in enumerate(got):
        if any(_norm(e) in _norm(g) for e in expected):
            return i + 1
    return None


def run_eval(show_scores: bool = False) -> dict:
    scenarios = json.loads(EVAL_PATH.read_text(encoding="utf-8"))["scenarios"]
    retriever = HybridRetriever()
    service = PrecedentService(retriever=retriever)
    sig = retriever._backend.signature  # 리포트 표기용

    stats = {"filtered": {"hit": 0, "p1_ok": 0, "p1_total": 0, "recall_sum": 0.0, "rr_sum": 0.0},
             "unfiltered": {"hit": 0, "p1_ok": 0, "p1_total": 0, "recall_sum": 0.0, "rr_sum": 0.0}}
    rows = []

    for sc in scenarios:
        tags, expected = sc["tags"], sc["expected_case_nos"]
        must1 = sc.get("must_rank_1")

        # filtered — 실서비스 경로 (분기 검색 + 태그 필터 + 게이트)
        f_matches = service.search_by_tags(tags)
        f_got = [m.doc.case_no for m in f_matches]

        # unfiltered — 태그 질의 통짜 + 필터 없음 (게이트도 끔: 순수 랭킹 측정)
        query = " ".join(QUERY_TEMPLATES.get(t, t) for t in tags)
        u_matches = retriever.search(query, risk_tags=None, top_k=MAX_CASES, apply_gate=False)
        u_got = [m.doc.case_no for m in u_matches]

        for mode, got in (("filtered", f_got), ("unfiltered", u_got)):
            s = stats[mode]
            s["hit"] += 1 if _hit(expected, got) else 0
            hit_count = sum(1 for e in expected if any(_norm(e) in _norm(g) for g in got))
            s["recall_sum"] += hit_count / len(expected)
            rank = _first_rank(expected, got)
            s["rr_sum"] += (1.0 / rank) if rank else 0.0
            if must1:
                s["p1_total"] += 1
                if got and _norm(must1) in _norm(got[0]):
                    s["p1_ok"] += 1

        rows.append((sc["name"], f_got, u_got))
        if show_scores:
            print(f"\n[{sc['name']}] tags={tags}")
            print(f"  filtered  : {f_got}")
            print(f"  unfiltered: {u_got}")
            for m in f_matches:
                print(f"    · {m.doc.case_no}: vec={m.vector_score} kw={m.keyword_score} tags={m.matched_tags}")

    n = len(scenarios)
    result = {"signature": sig, "scenarios": n}
    print(f"\n=== 검색 평가 ({n}개 시나리오 · 백엔드 {sig} · top-{MAX_CASES}) ===")
    for mode in ("filtered", "unfiltered"):
        s = stats[mode]
        result[mode] = {
            "hit_at_k": round(s["hit"] / n, 3),
            "p_at_1": round(s["p1_ok"] / s["p1_total"], 3) if s["p1_total"] else None,
            "recall": round(s["recall_sum"] / n, 3),
            "mrr": round(s["rr_sum"] / n, 3),
        }
        r = result[mode]
        print(f"{mode:>10}: Hit@K {r['hit_at_k']:.0%} · P@1 {r['p_at_1']:.0%} · Recall {r['recall']:.0%} · MRR {r['mrr']:.2f}")
    return result


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--show-scores", action="store_true")
    args = ap.parse_args()
    run_eval(show_scores=args.show_scores)
