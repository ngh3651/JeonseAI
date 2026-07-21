"""판례 적재 CLI — 청킹→임베딩→벡터DB 재구축.

사용:
  python scripts/ingest_precedents.py                  # 기본 백엔드(키 있으면 upstage)
  python scripts/ingest_precedents.py --backend hash   # 오프라인 검증(크레딧 0)
  python scripts/ingest_precedents.py --backend local  # ★ GPU 실행 지점 — 대량 배치
  python scripts/ingest_precedents.py --no-full-text   # 요지·요약만 인덱싱

임베딩 백엔드를 바꾸면 벡터 공간이 달라지므로 전체 재적재(이 스크립트 1회 실행)가 필요하다.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

from app.services.precedent.embedding import get_backend  # noqa: E402
from app.services.precedent.ingest import ingest  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser(description="판례 청킹→임베딩→벡터DB 적재")
    ap.add_argument("--backend", choices=["upstage", "local", "hash"], help="임베딩 백엔드")
    ap.add_argument("--no-full-text", action="store_true", help="판례 전문 청크 제외")
    args = ap.parse_args()

    backend = get_backend(args.backend) if args.backend else get_backend()
    ingest(backend=backend, include_full_text=not args.no_full_text)


if __name__ == "__main__":
    main()
