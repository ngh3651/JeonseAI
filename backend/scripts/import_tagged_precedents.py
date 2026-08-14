# -*- coding: utf-8 -*-
r"""검수 완료한 판례를 `backend/data/precedents/raw/`로 이식한다 (일회성 마이그레이션).

배경 (2026-08-07):
  판례 RAG를 두 사람이 각자 만들었다. 모듈 구조는 `services/precedent/`(규혁)를 쓰기로
  했고, **데이터와 관련성 판정은 별도 수집분**(정민재, 288건)을 가져오기로 정리했다.
  이 스크립트가 그 이관을 한다.

무엇을 옮기고 무엇을 안 옮기나
  - 옮긴다: `관련성 == "관련"` 인 판례만. 나머지(제외·검토필요)는 노이즈이거나
    사람 판단이 아직 안 끝난 것이라 검색 대상에 넣지 않는다.
  - 안 옮긴다: `가장임차인_의심` 태그가 붙은 판례. **임차인이 가해자**인 사건이라
    (경매를 예상하고 소액임차인 최우선변제를 노려 위장 전입한 사례 등)
    "당신과 닮은 사례"로 보여주면 메시지가 정반대가 된다.
  - 태그는 옮기지 않는다. 위험 태그 어휘는 `precedent/models.RISK_TAGS`가 정본이고,
    `ingest.auto_tags()`가 본문에서 다시 뽑는다. 두 어휘를 섞으면 정본이 흐려진다.

입력  : data/tagged/*.json   (tag_and_chunk.py 산출물 — 관련성·사유가 붙어 있다)
출력  : backend/data/precedents/raw/prec-<판례일련번호>.json

사용법
  backend/.venv/Scripts/python.exe backend/scripts/import_tagged_precedents.py
  backend/.venv/Scripts/python.exe backend/scripts/import_tagged_precedents.py --dry-run
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

# backend/scripts/ → 저장소 루트
_ROOT = Path(__file__).resolve().parents[2]
TAGGED_DIR = _ROOT / "data" / "tagged"
RAW_DIR = _ROOT / "backend" / "data" / "precedents" / "raw"

SOURCE_URL = "https://www.law.go.kr/LSW/precInfoP.do?precSeq={prec_id}"

# 임차인이 가해자인 사건 — 피해 예방 사례로 부적절 (위 docstring 참고)
EXCLUDED_TAGS = {"가장임차인_의심"}


def _fmt_decided(s: str) -> str:
    """'2023.08.31' 또는 '20230831' → '20230831' (규혁 raw 형식과 동일하게)."""
    digits = "".join(ch for ch in (s or "") if ch.isdigit())
    return digits[:8] if len(digits) >= 8 else ""


def convert(case: dict) -> dict:
    """tag_and_chunk 산출물 → collect_precedents.py가 쓰는 raw 형식."""
    prec_id = str(case["판례일련번호"])
    return {
        "_source": "law.go.kr Open API (lawService.do?target=prec)",
        "_collected_at": "2026-07-29",
        "_imported_from": "data/tagged (관련성 검수 완료분)",
        # 사람이 왜 이 판례를 남겼는지 — 나중에 되짚을 수 있게 사유를 함께 옮긴다
        "_relevance_reason": case.get("관련성_사유", ""),
        "_reviewed": case.get("검토상태") == "검수완료",
        "prec_id": prec_id,
        "case_no": case.get("사건번호", ""),
        "case_name": case.get("사건명", ""),
        "court": case.get("법원명", ""),
        "decided": _fmt_decided(case.get("선고일자", "")),
        "case_type": case.get("사건종류명", ""),
        "holding_points": case.get("판시사항", ""),
        "holding_summary": case.get("판결요지", ""),
        "ref_articles": case.get("참조조문", ""),
        "ref_precedents": case.get("참조판례", ""),
        "full_text": case.get("전문", ""),
        "source_url": SOURCE_URL.format(prec_id=prec_id),
        "raw": {
            "판시사항": case.get("판시사항", ""),
            "판결요지": case.get("판결요지", ""),
            "참조조문": case.get("참조조문", ""),
            "참조판례": case.get("참조판례", ""),
        },
    }


def main() -> None:
    ap = argparse.ArgumentParser(description="검수 완료 판례 → precedents/raw 이식")
    ap.add_argument("--dry-run", action="store_true", help="쓰지 않고 결과만 출력")
    args = ap.parse_args()

    if not TAGGED_DIR.exists():
        raise SystemExit(f"[오류] {TAGGED_DIR} 가 없습니다. tag_and_chunk.py 산출물이 필요합니다.")

    files = sorted(TAGGED_DIR.glob("*.json"))
    if not files:
        raise SystemExit(f"[오류] {TAGGED_DIR} 에 판례가 없습니다.")

    stats = {"관련": 0, "제외됨": 0, "가장임차인": 0, "덮어씀": 0, "신규": 0}
    written: list[dict] = []

    for fp in files:
        case = json.loads(fp.read_text(encoding="utf-8"))

        if case.get("관련성") != "관련":
            stats["제외됨"] += 1
            continue
        if set(case.get("topic_tags", [])) & EXCLUDED_TAGS:
            stats["가장임차인"] += 1
            continue

        stats["관련"] += 1
        doc = convert(case)
        out = RAW_DIR / f"prec-{doc['prec_id']}.json"
        stats["덮어씀" if out.exists() else "신규"] += 1
        written.append(doc)

        if not args.dry_run:
            RAW_DIR.mkdir(parents=True, exist_ok=True)
            out.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")

    print("=" * 60)
    print(f"전체 {len(files)}건 검토")
    print(f"  이식 대상(관련)     : {stats['관련']}건  (신규 {stats['신규']} / 덮어씀 {stats['덮어씀']})")
    print(f"  건너뜀(제외·검토필요): {stats['제외됨']}건")
    print(f"  건너뜀(가장임차인)   : {stats['가장임차인']}건 — 임차인이 가해자인 사건")
    if args.dry_run:
        print("\n[dry-run] 파일을 쓰지 않았습니다.")
    else:
        print(f"\n출력: {RAW_DIR}")
        print("다음: backend/.venv/Scripts/python.exe backend/scripts/ingest_precedents.py")
    print("=" * 60)


if __name__ == "__main__":
    main()
