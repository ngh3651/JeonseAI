r"""Upstage Information Extract 실호출 CLI (thin — E-1c에서 서비스로 승격됨).

호출·병합·파싱 로직은 전부 `app/services/extraction.py`에 있다. 이 스크립트는
그 서비스를 그대로 통과시키는 수동 검증·스냅샷 확보용 껍데기다.
⚠ 실행할 때마다 실제 크레딧이 소모된다 — 개발·테스트는 tests/fixtures/를 사용할 것.

실행 예:
  cd backend
  .\.venv\Scripts\python.exe scripts\test_extract.py test_samples\1.png test_samples\2.png
"""

import argparse
import json
import sys
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))

from app.schemas.internal import RegistryExtract  # noqa: E402
from app.services.extraction import ExtractionError, call_information_extract  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(description="등기부 추출 실호출 검증 (크레딧 소모 주의)")
    parser.add_argument("image_paths", nargs="+", help="등기부 페이지 이미지 경로(순서대로)")
    args = parser.parse_args()

    paths = [Path(p) for p in args.image_paths]
    missing = [str(p) for p in paths if not p.is_file()]
    if missing:
        print("[오류] 파일을 찾을 수 없습니다:", *missing, sep="\n  - ")
        sys.exit(1)

    images = [(p.name, p.read_bytes()) for p in paths]
    print(f"[요청] {len(images)}장 → Information Extract 호출 중... (수십 초 걸릴 수 있음)")
    try:
        raw = call_information_extract(images)
    except ExtractionError as e:
        print(f"[오류] HTTP {e.status_code} — {e.detail}")
        sys.exit(1)

    print("\n[추출 결과 JSON]")
    print(json.dumps(raw, ensure_ascii=False, indent=2))

    extract = RegistryExtract.from_raw(raw)
    print("\n[정형화 요약]")
    print(f"  주소: {extract.address}")
    print(f"  현재 소유자: {[o.name for o in extract.current_owners]}")
    print(f"  유효 근저당: {sum(1 for m in extract.mortgages if m.is_active)}건 / 전체 {len(extract.mortgages)}건")
    print(f"  누락 필드: {extract.missing_fields or '없음'}")


if __name__ == "__main__":
    main()
