r"""Upstage Information Extract 실제 호출 검증 스크립트 (STEP 2-B-1).

목적: 앱/엔드포인트 연결 없이, 등기부등본 이미지 1건을 Upstage Information Extract에
      STEP 2-A 스키마와 함께 보내 "스키마대로 추출되는가"를 독립적으로 검증한다.
      (위험판단 로직은 아직 없음)

실행 예:
  cd backend
  .\.venv\Scripts\python.exe scripts\test_extract.py test_samples\sample_registry.jpg

확인 완료된 API 사양(STEP 2-B-1, Upstage 공식 문서):
  - Endpoint: POST https://api.upstage.ai/v1/information-extraction
  - Model:    "information-extract"
  - 이미지:    base64 data URL을 messages content에 type="image_url"로 전달
  - 스키마:    response_format(type=json_schema)  ← registry_schema.build_response_format()
"""

import argparse
import base64
import json
import mimetypes
import sys
from pathlib import Path

import requests
from dotenv import load_dotenv

# ── backend 루트를 import 경로에 추가해 app.schemas를 불러온다 ──
_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))

from app.schemas.registry_schema import build_response_format  # noqa: E402

UPSTAGE_URL = "https://api.upstage.ai/v1/information-extraction"
MODEL = "information-extract"


def _load_api_key() -> str:
    """backend/.env에서 UPSTAGE_API_KEY를 읽는다. (하드코딩 금지)"""
    import os

    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
    key = os.environ.get("UPSTAGE_API_KEY", "").strip()
    if not key:
        print("[오류] UPSTAGE_API_KEY를 찾을 수 없습니다.")
        print("       backend/.env 파일에 UPSTAGE_API_KEY=... 가 있는지 확인하세요.")
        sys.exit(1)
    return key


def _to_data_url(image_path: Path) -> str:
    """이미지 파일을 base64 data URL로 변환한다."""
    mime = mimetypes.guess_type(str(image_path))[0] or "application/octet-stream"
    b64 = base64.b64encode(image_path.read_bytes()).decode("ascii")
    return f"data:{mime};base64,{b64}"


def _explain_http_error(status: int, body: str) -> None:
    """HTTP 상태 코드별 원인을 한국어로 안내한다."""
    guide = {
        400: "요청 형식 오류. 스키마 형식(최상위 scalar/array 제약)이나 이미지 형식을 확인하세요.",
        401: "인증 실패. UPSTAGE_API_KEY 값이 틀렸거나 만료되었을 수 있습니다.",
        402: "크레딧 부족(결제 필요). Upstage Console > Dashboard에서 잔여 크레딧을 확인하세요.",
        403: "권한 없음. 해당 키로 Information Extract 사용 권한이 있는지 확인하세요.",
        413: "이미지 용량이 너무 큽니다. 더 작은 파일로 시도하세요.",
        415: "지원하지 않는 미디어 타입. JPEG/PNG 등 표준 이미지인지 확인하세요.",
        429: "요청 한도 초과(rate limit). 잠시 후 다시 시도하세요.",
    }
    print(f"\n[오류] Upstage 응답 HTTP {status}")
    if status in guide:
        print(f"       → {guide[status]}")
    elif 500 <= status < 600:
        print("       → Upstage 서버 오류. 잠시 후 다시 시도하세요.")
    else:
        print("       → 예상치 못한 상태 코드입니다.")
    print(f"\n[응답 본문]\n{body[:2000]}")


def _extract_content(resp_json: dict) -> dict:
    """응답 JSON에서 추출 결과(dict)를 꺼낸다.

    Upstage는 choices[0].message.content에 JSON '문자열'을 담아준다.
    """
    try:
        content = resp_json["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        print("[오류] 응답 구조가 예상과 다릅니다. 전체 응답을 출력합니다:")
        print(json.dumps(resp_json, ensure_ascii=False, indent=2))
        sys.exit(1)

    if isinstance(content, dict):
        return content
    try:
        return json.loads(content)
    except (json.JSONDecodeError, TypeError):
        print("[오류] content가 JSON으로 파싱되지 않습니다. 원본을 출력합니다:")
        print(content)
        sys.exit(1)


def _as_list(data: dict, key: str) -> list:
    """data[key]가 리스트면 그대로, 아니면 빈 리스트로 반환한다."""
    v = data.get(key)
    return v if isinstance(v, list) else []


def _print_summary(data: dict) -> None:
    """육안 검증용 요약을 출력한다."""
    print("\n" + "=" * 60)
    print("검증 요약 (육안 확인용)")
    print("=" * 60)

    # 1) 근저당 개수 및 말소 건수
    mortgages = _as_list(data, "mortgages")
    canceled = [m for m in mortgages if isinstance(m, dict) and m.get("is_canceled") is True]
    print(f"■ 근저당(mortgages): 총 {len(mortgages)}건, 그중 말소 {len(canceled)}건")

    # 2) 채권최고액이 숫자로 왔는지
    if mortgages:
        print("  - 채권최고액(max_claim_amount) 타입 점검:")
        for i, m in enumerate(mortgages, 1):
            if not isinstance(m, dict):
                print(f"    {i}) (항목이 dict가 아님: {type(m).__name__})")
                continue
            amt = m.get("max_claim_amount")
            t = type(amt).__name__
            ok = "숫자 OK" if isinstance(amt, (int, float)) and not isinstance(amt, bool) else "숫자 아님 → 후처리 필요"
            canceled_mark = " [말소]" if m.get("is_canceled") is True else ""
            print(f"    {i}) {amt!r} (타입 {t}) → {ok}{canceled_mark}")

    # 3) 현재 소유자 이름 목록
    owners = _as_list(data, "current_owners")
    names = [o.get("name") for o in owners if isinstance(o, dict)]
    print(f"■ 현재 소유자(current_owners): {len(owners)}명 → {names if names else '없음'}")

    # 4) 갑구 처분제한/신탁 각 건수 (+ 을구 전세권/임차권도 참고로)
    def count_active(key: str) -> str:
        items = _as_list(data, key)
        active = [x for x in items if isinstance(x, dict) and x.get("is_canceled") is not True]
        return f"{len(items)}건(유효 {len(active)})"

    print("■ 처분제한/기타 항목별 건수(유효=말소 아님):")
    print(f"  - 가압류(provisional_seizures):        {count_active('provisional_seizures')}")
    print(f"  - 가처분(provisional_dispositions):    {count_active('provisional_dispositions')}")
    print(f"  - 압류(seizures):                      {count_active('seizures')}")
    print(f"  - 경매개시결정(auction_commencements): {count_active('auction_commencements')}")
    print(f"  - 신탁등기(trust_registrations):       {count_active('trust_registrations')}")
    print(f"  - (참고) 전세권(jeonse_rights):        {count_active('jeonse_rights')}")
    print(f"  - (참고) 임차권(lease_registrations):  {count_active('lease_registrations')}")
    print("=" * 60)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Upstage Information Extract 등기부등본 추출 검증 스크립트"
    )
    parser.add_argument("image_path", help="등기부등본 이미지 경로 (예: test_samples/sample_registry.jpg)")
    args = parser.parse_args()

    image_path = Path(args.image_path)
    if not image_path.is_file():
        print(f"[오류] 이미지 파일을 찾을 수 없습니다: {image_path}")
        print("       backend/test_samples/ 폴더에 이미지를 넣고 경로를 확인하세요.")
        sys.exit(1)

    api_key = _load_api_key()

    print(f"[준비] 이미지: {image_path}  ({image_path.stat().st_size / 1024:.1f} KB)")
    data_url = _to_data_url(image_path)

    payload = {
        "model": MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": data_url}},
                ],
            }
        ],
        "response_format": build_response_format(),
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    print("[요청] Upstage Information Extract로 요청 보내는 중... (수십 초 걸릴 수 있음)")
    try:
        resp = requests.post(UPSTAGE_URL, headers=headers, json=payload, timeout=180)
    except requests.exceptions.Timeout:
        print("[오류] 요청 시간 초과(timeout). 네트워크 상태를 확인하고 다시 시도하세요.")
        sys.exit(1)
    except requests.exceptions.RequestException as e:
        print(f"[오류] 요청 실패: {e}")
        sys.exit(1)

    print(f"[응답] 받음 (HTTP {resp.status_code})")

    if resp.status_code != 200:
        _explain_http_error(resp.status_code, resp.text)
        sys.exit(1)

    try:
        resp_json = resp.json()
    except ValueError:
        print("[오류] 응답이 JSON이 아닙니다. 원본:")
        print(resp.text[:2000])
        sys.exit(1)

    data = _extract_content(resp_json)

    print("\n[추출 결과 JSON]")
    print(json.dumps(data, ensure_ascii=False, indent=2))

    _print_summary(data)


if __name__ == "__main__":
    main()
