r"""Upstage Information Extract 실제 호출 검증 스크립트 (STEP 2-B-1, 멀티 이미지).

목적: 앱/엔드포인트 연결 없이, 한 등기부의 **여러 페이지 이미지**를 Upstage
      Information Extract에 STEP 2-A 스키마와 함께 보내 "여러 장이 하나로 통합되어
      스키마대로 추출되는가"를 독립적으로 검증한다. (위험판단 로직은 아직 없음)

실행 예:
  cd backend
  # 여러 페이지를 순서대로 넘긴다
  .\.venv\Scripts\python.exe scripts\test_extract.py test_samples\sample1_p1.jpg test_samples\sample1_p2.jpg
  # 한 장만 넘겨도 된다
  .\.venv\Scripts\python.exe scripts\test_extract.py test_samples\sample_registry.jpg

확인 완료된 API 사양(STEP 2-B-1, Upstage 공식 문서):
  - Endpoint: POST https://api.upstage.ai/v1/information-extraction
  - Model:    "information-extract"
  - 스키마:    response_format(type=json_schema)  ← registry_schema.build_response_format()
  - 이미지:    base64 data URL을 messages content에 type="image_url"로 전달
  - 멀티 이미지: 동기 엔드포인트는 요청당 image_url 1개만 허용(파일당 최대 100페이지).
    → 여러 장은 **하나의 멀티페이지 PDF로 병합**해 1개 image_url로 보낸다.
      [실호출로 검증 필요] PDF(application/pdf) data URL 전송이 동작하는지 확인 대상.
"""

import argparse
import base64
import json
import mimetypes
import sys
from pathlib import Path

import img2pdf
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


def _build_document(image_paths: list[Path]) -> tuple[bytes, str]:
    """입력 이미지들을 하나의 전송용 문서로 만든다.

    - 이미지 1장: 그 이미지를 그대로 전송(형식은 확장자로 추정).
    - 이미지 여러 장: 순서대로 멀티페이지 PDF로 병합해 전송(각 이미지 = 한 페이지).

    반환: (문서 바이트, MIME 타입)
    """
    if len(image_paths) == 1:
        p = image_paths[0]
        mime = mimetypes.guess_type(str(p))[0] or "application/octet-stream"
        return p.read_bytes(), mime

    # 여러 장 → 멀티페이지 PDF로 병합 (img2pdf: JPEG 무손실 임베딩)
    print(f"[병합] {len(image_paths)}장을 멀티페이지 PDF로 병합하는 중...")
    try:
        pdf_bytes = img2pdf.convert([str(p) for p in image_paths])
    except Exception as e:  # noqa: BLE001 - 병합 실패 원인을 사용자에게 그대로 안내
        print(f"[오류] 이미지들을 PDF로 병합하지 못했습니다: {e}")
        print("       입력 파일이 모두 정상 이미지(JPEG/PNG)인지 확인하세요.")
        sys.exit(1)
    return pdf_bytes, "application/pdf"


def _to_data_url(doc_bytes: bytes, mime: str) -> str:
    """문서 바이트를 base64 data URL로 변환한다."""
    b64 = base64.b64encode(doc_bytes).decode("ascii")
    return f"data:{mime};base64,{b64}"


def _explain_http_error(status: int, body: str) -> None:
    """HTTP 상태 코드별 원인을 한국어로 안내한다."""
    guide = {
        400: "요청 형식 오류. 스키마 형식(최상위 scalar/array 제약)이나 문서(이미지/PDF) 형식을 확인하세요.",
        401: "인증 실패. UPSTAGE_API_KEY 값이 틀렸거나 만료되었을 수 있습니다.",
        402: "크레딧 부족(결제 필요). Upstage Console > Dashboard에서 잔여 크레딧을 확인하세요.",
        403: "권한 없음. 해당 키로 Information Extract 사용 권한이 있는지 확인하세요.",
        413: "문서 용량이 너무 큽니다. 페이지 수를 줄이거나 더 작은 파일로 시도하세요.",
        415: "지원하지 않는 미디어 타입. JPEG/PNG 이미지 또는 PDF인지 확인하세요.",
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


# 요약에서 다룰 "여러 개일 수 있는" 배열 항목들 (키 → 한글 이름)
_LIST_FIELDS = {
    "current_owners": "현재 소유자",
    "ownership_changes": "소유권 변동 이력",
    "provisional_seizures": "가압류",
    "provisional_dispositions": "가처분",
    "seizures": "압류",
    "auction_commencements": "경매개시결정",
    "trust_registrations": "신탁등기",
    "mortgages": "근저당",
    "jeonse_rights": "전세권",
    "lease_registrations": "임차권",
}


def _print_summary(data: dict, page_count: int) -> None:
    """육안 검증용 요약을 출력한다."""
    print("\n" + "=" * 60)
    print(f"검증 요약 (육안 확인용) — 입력 {page_count}페이지 통합 결과")
    print("=" * 60)

    # 0) 전체 항목 카운트 (여러 페이지 정보가 하나로 통합됐는지 한눈에)
    print("■ 전체 항목 카운트(유효=말소 아님):")
    for key, kor in _LIST_FIELDS.items():
        items = _as_list(data, key)
        if key == "current_owners":
            # 소유자는 말소 개념 대신 인원수만
            print(f"  - {kor}({key}): {len(items)}건")
        else:
            active = [x for x in items if isinstance(x, dict) and x.get("is_canceled") is not True]
            print(f"  - {kor}({key}): 총 {len(items)}건 (유효 {len(active)})")

    # 1) 근저당 개수 및 말소 건수 (핵심)
    mortgages = _as_list(data, "mortgages")
    canceled = [m for m in mortgages if isinstance(m, dict) and m.get("is_canceled") is True]
    print(f"\n■ 근저당(mortgages): 총 {len(mortgages)}건, 그중 말소 {len(canceled)}건")

    # 2) 채권최고액이 숫자로 왔는지
    if mortgages:
        print("  - 채권최고액(max_claim_amount) 타입 점검:")
        for i, m in enumerate(mortgages, 1):
            if not isinstance(m, dict):
                print(f"    {i}) (항목이 dict가 아님: {type(m).__name__})")
                continue
            amt = m.get("max_claim_amount")
            t = type(amt).__name__
            ok = (
                "숫자 OK"
                if isinstance(amt, (int, float)) and not isinstance(amt, bool)
                else "숫자 아님 → 후처리 필요"
            )
            canceled_mark = " [말소]" if m.get("is_canceled") is True else ""
            print(f"    {i}) {amt!r} (타입 {t}) → {ok}{canceled_mark}")

    # 3) 현재 소유자 이름 목록
    owners = _as_list(data, "current_owners")
    names = [o.get("name") for o in owners if isinstance(o, dict)]
    print(f"\n■ 현재 소유자(current_owners): {len(owners)}명 → {names if names else '없음'}")

    # 4) 갑구 처분제한/신탁 각 건수 (요약)
    def count_active(key: str) -> str:
        items = _as_list(data, key)
        active = [x for x in items if isinstance(x, dict) and x.get("is_canceled") is not True]
        return f"{len(items)}건(유효 {len(active)})"

    print("\n■ 처분제한/신탁 항목별 건수:")
    print(f"  - 가압류(provisional_seizures):        {count_active('provisional_seizures')}")
    print(f"  - 가처분(provisional_dispositions):    {count_active('provisional_dispositions')}")
    print(f"  - 압류(seizures):                      {count_active('seizures')}")
    print(f"  - 경매개시결정(auction_commencements): {count_active('auction_commencements')}")
    print(f"  - 신탁등기(trust_registrations):       {count_active('trust_registrations')}")
    print("=" * 60)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Upstage Information Extract 등기부등본 추출 검증 스크립트 (멀티 이미지 지원)"
    )
    parser.add_argument(
        "image_paths",
        nargs="+",
        help="등기부등본 이미지 경로(들). 한 등기부의 여러 페이지를 순서대로 나열",
    )
    args = parser.parse_args()

    image_paths = [Path(p) for p in args.image_paths]
    missing = [str(p) for p in image_paths if not p.is_file()]
    if missing:
        print("[오류] 다음 이미지 파일을 찾을 수 없습니다:")
        for m in missing:
            print(f"       - {m}")
        print("       backend/test_samples/ 폴더에 이미지를 넣고 경로를 확인하세요.")
        sys.exit(1)

    api_key = _load_api_key()

    total_kb = sum(p.stat().st_size for p in image_paths) / 1024
    print(f"[준비] 입력 {len(image_paths)}장, 합계 {total_kb:.1f} KB")
    for i, p in enumerate(image_paths, 1):
        print(f"       {i}) {p.name}")

    doc_bytes, mime = _build_document(image_paths)
    data_url = _to_data_url(doc_bytes, mime)
    print(f"[전송문서] MIME={mime}, 크기 {len(doc_bytes) / 1024:.1f} KB")

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

    print("[요청] Upstage Information Extract로 요청 전송 중... (수십 초 걸릴 수 있음)")
    try:
        resp = requests.post(UPSTAGE_URL, headers=headers, json=payload, timeout=300)
    except requests.exceptions.Timeout:
        print("[오류] 요청 시간 초과(timeout). 네트워크 상태를 확인하고 다시 시도하세요.")
        sys.exit(1)
    except requests.exceptions.RequestException as e:
        print(f"[오류] 요청 실패: {e}")
        sys.exit(1)

    print(f"[응답] 수신 (HTTP {resp.status_code})")

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

    _print_summary(data, page_count=len(image_paths))


if __name__ == "__main__":
    main()
