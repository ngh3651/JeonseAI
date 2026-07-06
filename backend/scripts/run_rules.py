r"""픽스처 판정표 러너 — 규칙 엔진을 육안으로 확인하는 임시 개발 도구.

(cleanup-tracker.md 등록: E-6에서 유지 여부 결정)

실행:
  cd backend
  .\.venv\Scripts\python.exe scripts\run_rules.py
"""

import json
import sys
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))

from app.schemas.internal import RegistryExtract  # noqa: E402
from app.services import rule_engine  # noqa: E402
from app.services.formatting import format_won  # noqa: E402

FIXTURES = _BACKEND_ROOT / "tests" / "fixtures" / "registry"
ORDER = [
    "clean_house",
    "mortgage_heavy",
    "trust_seizure",
    "canceled_only",
    "messy_amounts",
    "missing_sections",
    "real_snapshot",
]


def main() -> None:
    print("=" * 100)
    print("규칙 엔진 판정표 (픽스처 6종 + 실추출 스냅샷 1종)")
    print("근거 카드 순서: 전세가율 / 선순위채권 / 소유권 / 보증보험 / 악성임대인")
    print("=" * 100)

    for name in ORDER:
        path = FIXTURES / f"{name}.json"
        if not path.is_file():
            print(f"\n[{name}] 픽스처 없음 — 건너뜀")
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        extract = RegistryExtract.from_raw(data["registry"])
        v = rule_engine.evaluate(
            extract,
            deposit=data["inputs"]["deposit"],
            market_price=data["inputs"].get("market_price"),
            blacklist_entries=data.get("blacklist"),
        )

        grades = " / ".join(
            f"{e.grade.value}" + (f"[{e.status_label}]" if e.status_label else "")
            for e in v.evidences
        )
        market = format_won(v.market_price) if v.market_price else "미입력"
        print(f"\n■ {name} — {data.get('description', '')}")
        print(f"  입력: 보증금 {format_won(v.deposit)} · 시세 {market}")
        print(f"  종합: {v.grade.value}  (게이지 {v.gauge_progress})  선순위합계 {format_won(v.senior_debt_amount)}")
        print(f"  카드: {grades}")
        if v.doc_flags:
            print(f"  문서 플래그: {', '.join(v.doc_flags)}")
        notable = [e for e in v.evidences if e.detail_text and e.grade.value != "양호"]
        for e in notable[:3]:
            print(f"    - {e.id}: {e.detail_text}")

    print("\n" + "=" * 100)


if __name__ == "__main__":
    main()
