"""API 키 점검 — 설정된 키마다 "정상 / 키가 틀림 / 크레딧·한도 문제 / 연결 실패"만 말한다 (2026-10-21).

왜: 본선 뒤 Upstage 키가 바뀌었다. `backend/.env`(또는 Railway Variables)의 키가 아직 맞는지
배포 **전에** 확인해야 한다. 헬스체크(`GET /`)는 키가 **있는지만** 본다(외부 호출 0회).

⚠ 키 값과 응답 본문은 **절대 출력하지 않는다.** 화면에 나오는 것은 결과 분류와 HTTP 상태 코드뿐이다.

무엇을 부르나 (가장 싼 호출):
- Upstage   : `GET /v1/models` (무료). 그 주소가 없으면(404·405) Solar 채팅 1토큰
               — **아주 적은 크레딧**을 쓴다(출력에 표시).
- 국토부(MOLIT, data.go.kr): 실거래가 1건 조회(서울 종로구 1개월, 1행). 공공 API라 무료.
               HTTP 200이어도 본문의 오류 코드(SERVICE_KEY_IS_NOT_REGISTERED_ERROR 등)를 본다.
- LG EXAONE (FriendliAI serverless, 설정됐을 때만): `GET /models`, 없으면 1토큰 채팅.

실행: `cd backend && python scripts/check_keys.py`
종료 코드: 설정된 키가 **모두 정상**이면 0, 하나라도 아니면 1. (설정 안 된 키는 판단에서 뺀다 —
         단, UPSTAGE_API_KEY는 분석에 반드시 필요하므로 없으면 1.)
"""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

import requests  # noqa: E402

from app import settings  # noqa: E402 — .env를 앱과 같은 방식으로 읽는다(플랫폼 값이 이긴다)

OK = "정상"
BAD_KEY = "키가 틀림"
QUOTA = "크레딧·한도 문제"
NETWORK = "연결 실패"
NOT_SET = "설정 안 됨"

TIMEOUT_SECONDS = 20

UPSTAGE_MODELS_URL = "https://api.upstage.ai/v1/models"
UPSTAGE_CHAT_URL = "https://api.upstage.ai/v1/solar/chat/completions"
UPSTAGE_FALLBACK_MODEL = "solar-pro2"

EXAONE_BASE_URL = "https://api.friendli.ai/serverless/v1"

#: 실거래가 점검용 고정 조회값 — 서울 종로구(11110), 2026년 1월, 1행. 결과 내용은 보지 않는다.
MOLIT_PROBE_LAWD = "11110"
MOLIT_PROBE_YMD = "202601"

#: data.go.kr 공통 오류 코드 (공공데이터포털 OpenAPI 에러 코드표)
#: 키 문제: 20 SERVICE_ACCESS_DENIED / 30 SERVICE_KEY_IS_NOT_REGISTERED / 31 DEADLINE_HAS_EXPIRED
#: 한도 문제: 22 LIMITED_NUMBER_OF_SERVICE_REQUESTS_EXCEEDS / 23 …PER_SECOND_EXCEEDS
_MOLIT_KEY_MARKERS = (
    "SERVICE_KEY_IS_NOT_REGISTERED",
    "SERVICE_ACCESS_DENIED",
    "DEADLINE_HAS_EXPIRED",
    "SERVICE_KEY_IS_NULL",
    "UNREGISTERED_IP",
    "PERMISSION_DENIED",
)
_MOLIT_QUOTA_MARKERS = ("LIMITED_NUMBER_OF_SERVICE_REQUESTS",)
_MOLIT_KEY_CODES = {"20", "30", "31", "32"}
_MOLIT_QUOTA_CODES = {"22", "23"}


@dataclass
class Result:
    name: str
    status: str
    note: str = ""


# ══════════════════════════════════════════════════════════════════════════════
# 분류 — 순수 함수 (테스트는 여기를 본다)
# ══════════════════════════════════════════════════════════════════════════════


def classify_http(status_code: int) -> str:
    """HTTP 상태 코드 → 결과 분류."""
    if 200 <= status_code < 300:
        return OK
    if status_code in (401, 403):
        return BAD_KEY
    if status_code in (402, 429):
        return QUOTA
    return NETWORK


def classify_molit(status_code: int, body: str) -> str:
    """data.go.kr 응답 → 결과 분류. **HTTP 200이어도 본문의 오류 코드를 본다.**"""
    text = body or ""
    upper = text.upper()
    if any(m in upper for m in _MOLIT_QUOTA_MARKERS):
        return QUOTA
    if any(m in upper for m in _MOLIT_KEY_MARKERS):
        return BAD_KEY
    code = _molit_result_code(text)
    if code in _MOLIT_QUOTA_CODES:
        return QUOTA
    if code in _MOLIT_KEY_CODES:
        return BAD_KEY
    if status_code != 200:
        return classify_http(status_code)
    if code in ("000", "00"):
        return OK
    if code:  # 그 밖의 오류 코드(파라미터·서비스 오류) — 키 문제라고 단정하지 않는다
        return NETWORK
    return OK if "<response" in text or '"response"' in text else NETWORK


def _molit_result_code(text: str) -> str:
    """XML `<resultCode>`/`<returnReasonCode>` 또는 JSON `"resultCode"`를 찾는다."""
    try:
        root = ET.fromstring(text)
        for tag in ("resultCode", "returnReasonCode"):
            found = root.find(f".//{tag}")
            if found is not None and (found.text or "").strip():
                return found.text.strip()
    except ET.ParseError:
        pass
    m = re.search(r'"(?:resultCode|returnReasonCode)"\s*:\s*"?(\w+)"?', text)
    return m.group(1) if m else ""


# ══════════════════════════════════════════════════════════════════════════════
# 호출 (키는 헤더·파라미터로만 쓰고 어디에도 찍지 않는다)
# ══════════════════════════════════════════════════════════════════════════════

HttpGet = Callable[..., requests.Response]
HttpPost = Callable[..., requests.Response]


def _openai_style_check(
    name: str,
    *,
    key: str,
    models_url: str,
    chat_url: str,
    model: str,
    http_get: HttpGet,
    http_post: HttpPost,
) -> Result:
    """`GET /models` → (404·405면) 1토큰 채팅. Upstage·EXAONE 공통."""
    headers = {"Authorization": f"Bearer {key}"}
    try:
        resp = http_get(models_url, headers=headers, timeout=TIMEOUT_SECONDS)
    except requests.RequestException:
        return Result(name, NETWORK, "모델 목록 주소에 연결하지 못함")
    if resp.status_code not in (404, 405):
        # ⚠ 모델 목록은 무료라 "키가 맞는지"만 알려 준다 — 남은 크레딧은 콘솔에서 봐야 한다(2026-10-22 리뷰)
        return Result(
            name,
            classify_http(resp.status_code),
            f"GET /models → HTTP {resp.status_code} · 크레딧 잔액은 확인하지 않음",
        )

    try:
        resp = http_post(
            chat_url,
            headers=headers,
            json={
                "model": model,
                "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": 1,
            },
            timeout=TIMEOUT_SECONDS,
        )
    except requests.RequestException:
        return Result(name, NETWORK, "채팅 주소에 연결하지 못함")
    return Result(
        name,
        classify_http(resp.status_code),
        f"모델 목록 주소가 없어 1토큰 채팅으로 확인(⚠ 아주 적은 크레딧 사용) → HTTP {resp.status_code}",
    )


def check_upstage(*, http_get: HttpGet = requests.get, http_post: HttpPost = requests.post) -> Result:
    key = settings.env_str("UPSTAGE_API_KEY")
    if not key:
        return Result("Upstage (UPSTAGE_API_KEY)", NOT_SET, "⚠ 분석에 반드시 필요한 키입니다")
    return _openai_style_check(
        "Upstage (UPSTAGE_API_KEY)",
        key=key,
        models_url=UPSTAGE_MODELS_URL,
        chat_url=UPSTAGE_CHAT_URL,
        model=UPSTAGE_FALLBACK_MODEL,
        http_get=http_get,
        http_post=http_post,
    )


def check_exaone(*, http_get: HttpGet = requests.get, http_post: HttpPost = requests.post) -> Result:
    key = settings.env_str("EXAONE_API_KEY")
    if not key:
        return Result("LG EXAONE (EXAONE_API_KEY)", NOT_SET, "서비스에서 안 씀")
    from app.services.llm.providers import ExaoneProvider

    base = settings.env_str("EXAONE_BASE_URL") or EXAONE_BASE_URL
    model = settings.env_str("EXAONE_MODEL") or ExaoneProvider.default_model
    return _openai_style_check(
        "LG EXAONE (EXAONE_API_KEY)",
        key=key,
        models_url=f"{base.rstrip('/')}/models",
        chat_url=f"{base.rstrip('/')}/chat/completions",
        model=model,
        http_get=http_get,
        http_post=http_post,
    )


def check_molit(*, http_get: HttpGet = requests.get) -> Result:
    key = settings.env_str("MOLIT_API_KEY")
    if not key:
        return Result("국토부 실거래가 (MOLIT_API_KEY)", NOT_SET, "없으면 시세 자동 조회를 건너뜁니다")
    from app.services import market_price

    try:
        resp = http_get(
            market_price.ENDPOINTS["apt"],
            params={
                "serviceKey": key,
                "LAWD_CD": MOLIT_PROBE_LAWD,
                "DEAL_YMD": MOLIT_PROBE_YMD,
                "numOfRows": 1,
                "pageNo": 1,
            },
            timeout=TIMEOUT_SECONDS,
        )
    except requests.RequestException:
        return Result("국토부 실거래가 (MOLIT_API_KEY)", NETWORK, "data.go.kr에 연결하지 못함")
    return Result(
        "국토부 실거래가 (MOLIT_API_KEY)",
        classify_molit(resp.status_code, resp.text),
        f"실거래가 1건 조회 → HTTP {resp.status_code}",
    )


def run(
    *, http_get: HttpGet = requests.get, http_post: HttpPost = requests.post
) -> tuple[list[Result], int]:
    results = [
        check_upstage(http_get=http_get, http_post=http_post),
        check_molit(http_get=http_get),
        check_exaone(http_get=http_get, http_post=http_post),
    ]
    upstage, *optional = results
    # 설정 안 된 선택 키(MOLIT·EXAONE)는 판단에서 뺀다. Upstage는 없어도 실패다(분석 불가).
    failed = upstage.status != OK or any(r.status not in (OK, NOT_SET) for r in optional)
    return results, (1 if failed else 0)


def main(*, http_get: HttpGet = requests.get, http_post: HttpPost = requests.post) -> int:
    print("API 키 점검 — 키 값과 응답 본문은 출력하지 않습니다\n")
    results, code = run(http_get=http_get, http_post=http_post)
    for r in results:
        # 예: "설정 안 됨 (서비스에서 안 씀)" — 결과 분류 뒤에 괄호로 이유를 붙인다
        line = f"  {r.name:<32} {r.status}"
        print(line + (f" ({r.note})" if r.note else ""))
    print()
    print("모든 키 정상" if code == 0 else "⚠ 확인이 필요한 키가 있습니다 (위 표 참고)")
    return code


if __name__ == "__main__":
    sys.exit(main())
