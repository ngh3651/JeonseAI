"""판례 RAG E2E 데모 — 등기부 픽스처 → 규칙 엔진 판정 → 분기 검색 → Solar 설명.

API 계약을 건드리지 않는 CLI 검증 도구다 (라우터 통합은 E-3 게이트의 몫).
Solar 호출은 --explain을 줄 때만 일어난다 (크레딧 소모 주의).

사용:
  python scripts/demo_precedent.py                          # 폴백 문구로 E2E (크레딧 0)
  python scripts/demo_precedent.py --explain                # Solar 설명 포함 E2E
  python scripts/demo_precedent.py --fixture mortgage_heavy # 다른 픽스처
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

from app.schemas.internal import RegistryExtract  # noqa: E402
from app.services import rule_engine  # noqa: E402
from app.services.precedent.service import PrecedentService, tags_from_verdict  # noqa: E402

FIXTURE_DIR = _BACKEND_ROOT / "tests" / "fixtures" / "registry"


def main() -> None:
    ap = argparse.ArgumentParser(description="판례 RAG E2E 데모")
    ap.add_argument("--fixture", default="trust_seizure", help="tests/fixtures/registry/ 파일명")
    ap.add_argument("--deposit", type=int, help="예정 보증금(기본: 픽스처 inputs)")
    ap.add_argument("--market-price", type=int, help="매매 시세(기본: 픽스처 inputs)")
    ap.add_argument("--explain", action="store_true", help="Solar 설명 생성 포함 (크레딧 소모)")
    args = ap.parse_args()

    data = json.loads((FIXTURE_DIR / f"{args.fixture}.json").read_text(encoding="utf-8"))
    extract = RegistryExtract.from_raw(data["registry"])
    inputs = data.get("inputs", {})
    deposit = args.deposit or inputs.get("deposit", 120_000_000)
    market_price = args.market_price or inputs.get("market_price")

    print(f"=== 1) 규칙 엔진 판정 (픽스처: {args.fixture}) ===")
    verdict = rule_engine.evaluate(
        extract,
        deposit=deposit,
        market_price=market_price,
        blacklist_entries=data.get("blacklist", []),
    )
    print(f"종합 등급: {verdict.grade.value}")
    for ev in verdict.evidences:
        print(f"  · {ev.id}: {ev.grade.value} — {(ev.detail_text or '')[:70]}")

    tags = tags_from_verdict(verdict)
    print(f"\n=== 2) 판정 → 위험 태그 파생 ===\n{tags}")

    print(f"\n=== 3) 분기 검색 + 게이트 {'+ Solar 설명' if args.explain else '(설명은 폴백)'} ===")
    svc = PrecedentService()
    section = svc.match_for_verdict(verdict, explain=args.explain)
    if not section.cases:
        print(f"판례 없음 → 폴백: {section.fallback_text}")
        return
    for i, c in enumerate(section.cases, 1):
        print(f"\n[{i}] {c['caseNo']} ({c['decided']}) — 매칭 태그 {c['matchedTags']}")
        print(f"    요약: {c['summary']}")
        print(f"    공통점: {c['commonPoint']}")
        print(f"    결과: {c['result']}")
        if c.get("advice"):
            print(f"    조언(큐레이션): {c['advice']}")
        print(f"    출처: {c['sourceUrl']}")


if __name__ == "__main__":
    main()
