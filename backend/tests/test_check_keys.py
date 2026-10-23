"""`scripts/check_keys.py` — 키 점검 분류 (목 응답만, 실제 호출 0회).

지키는 것: ⑴ 결과는 4가지(정상 / 키가 틀림 / 크레딧·한도 / 연결 실패)뿐 ⑵ 키 값·응답 본문을
출력하지 않는다 ⑶ 설정된 키가 모두 정상일 때만 종료 코드 0 ⑷ data.go.kr은 HTTP 200이어도
본문의 오류 코드를 본다.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest
import requests

_SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check_keys.py"


@pytest.fixture
def ck(monkeypatch):
    spec = importlib.util.spec_from_file_location("check_keys", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    # @dataclass가 자기 모듈을 sys.modules에서 찾는다 — 실행 전에 등록해 둔다
    monkeypatch.setitem(sys.modules, "check_keys", module)
    spec.loader.exec_module(module)
    return module


class _Resp:
    def __init__(self, status_code: int, text: str = ""):
        self.status_code = status_code
        self.text = text


def _http(responses: dict[str, _Resp], calls: list[str]):
    """주소 일부 → 응답. 없는 주소로 부르면 테스트 실패(진짜 네트워크로 새지 않게)."""

    def fake(url, **kwargs):
        calls.append(url)
        for part, resp in responses.items():
            if part in url:
                if isinstance(resp, Exception):
                    raise resp
                return resp
        raise AssertionError(f"목이 막지 않은 호출: {url}")

    return fake


MOLIT_OK = (
    "<response><header><resultCode>000</resultCode><resultMsg>OK</resultMsg></header>"
    "<body><items/></body></response>"
)
MOLIT_BAD_KEY = (
    "<OpenAPI_ServiceResponse><cmmMsgHeader><errMsg>SERVICE ERROR</errMsg>"
    "<returnAuthMsg>SERVICE_KEY_IS_NOT_REGISTERED_ERROR</returnAuthMsg>"
    "<returnReasonCode>30</returnReasonCode></cmmMsgHeader></OpenAPI_ServiceResponse>"
)
MOLIT_QUOTA = (
    "<OpenAPI_ServiceResponse><cmmMsgHeader>"
    "<returnAuthMsg>LIMITED_NUMBER_OF_SERVICE_REQUESTS_EXCEEDS_ERROR</returnAuthMsg>"
    "<returnReasonCode>22</returnReasonCode></cmmMsgHeader></OpenAPI_ServiceResponse>"
)


# ── 분류 (순수 함수) ─────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    "status,expected",
    [(200, "정상"), (401, "키가 틀림"), (403, "키가 틀림"), (402, "크레딧·한도 문제"),
     (429, "크레딧·한도 문제"), (500, "연결 실패"), (502, "연결 실패")],
)
def test_HTTP_상태별_분류(ck, status, expected):
    assert ck.classify_http(status) == expected


@pytest.mark.parametrize(
    "status,body,expected",
    [
        (200, MOLIT_OK, "정상"),
        (200, MOLIT_BAD_KEY, "키가 틀림"),  # HTTP 200인데 본문이 키 오류
        (200, MOLIT_QUOTA, "크레딧·한도 문제"),
        (401, "Unauthorized", "키가 틀림"),
        (200, '{"response":{"header":{"resultCode":"000"}}}', "정상"),
        (200, '{"response":{"header":{"resultCode":"30"}}}', "키가 틀림"),
        (500, "<html>error</html>", "연결 실패"),
        (200, "<html>점검 중</html>", "연결 실패"),
    ],
)
def test_실거래가_응답_분류(ck, status, body, expected):
    assert ck.classify_molit(status, body) == expected


# ── Upstage ──────────────────────────────────────────────────────────────────


def test_Upstage_모델_목록이_200이면_정상이고_채팅은_안_부른다(ck, monkeypatch):
    monkeypatch.setenv("UPSTAGE_API_KEY", "up_test_key_value")
    calls: list[str] = []
    result = ck.check_upstage(
        http_get=_http({"/v1/models": _Resp(200, '{"data": []}')}, calls),
        http_post=_http({}, calls),
    )
    assert result.status == "정상"
    assert calls == [ck.UPSTAGE_MODELS_URL]
    # 모델 목록은 무료라 키만 확인한다 — 잔액은 모른다는 것을 밝힌다(2026-10-22 리뷰)
    assert "크레딧 잔액은 확인하지 않음" in result.note


@pytest.mark.parametrize("status,expected", [(401, "키가 틀림"), (402, "크레딧·한도 문제")])
def test_Upstage_모델_목록_오류는_그대로_분류한다(ck, monkeypatch, status, expected):
    monkeypatch.setenv("UPSTAGE_API_KEY", "up_test_key_value")
    calls: list[str] = []
    result = ck.check_upstage(
        http_get=_http({"/v1/models": _Resp(status)}, calls), http_post=_http({}, calls)
    )
    assert result.status == expected


@pytest.mark.parametrize("missing", [404, 405])
def test_모델_목록_주소가_없으면_1토큰_채팅으로_확인한다(ck, monkeypatch, missing):
    monkeypatch.setenv("UPSTAGE_API_KEY", "up_test_key_value")
    calls: list[str] = []
    posted: list[dict] = []

    def post(url, **kwargs):
        calls.append(url)
        posted.append(kwargs["json"])
        return _Resp(200)

    result = ck.check_upstage(http_get=_http({"/v1/models": _Resp(missing)}, calls), http_post=post)
    assert result.status == "정상"
    assert "크레딧" in result.note  # 아주 적은 크레딧을 쓴다는 표시
    assert posted[0]["model"] == "solar-pro2" and posted[0]["max_tokens"] == 1


def test_Upstage_연결_실패(ck, monkeypatch):
    monkeypatch.setenv("UPSTAGE_API_KEY", "up_test_key_value")
    calls: list[str] = []
    result = ck.check_upstage(
        http_get=_http({"/v1/models": requests.ConnectionError("끊김")}, calls),
        http_post=_http({}, calls),
    )
    assert result.status == "연결 실패"


# ── MOLIT ────────────────────────────────────────────────────────────────────


def test_실거래가는_1행_조회만_한다(ck, monkeypatch):
    monkeypatch.setenv("MOLIT_API_KEY", "molit_test_key_value")
    seen: list[dict] = []

    def get(url, **kwargs):
        seen.append(kwargs["params"])
        return _Resp(200, MOLIT_OK)

    assert ck.check_molit(http_get=get).status == "정상"
    assert seen[0]["numOfRows"] == 1 and seen[0]["LAWD_CD"] == ck.MOLIT_PROBE_LAWD


def test_실거래가_키_오류는_HTTP_200이어도_키가_틀림이다(ck, monkeypatch):
    monkeypatch.setenv("MOLIT_API_KEY", "molit_test_key_value")
    result = ck.check_molit(http_get=lambda url, **k: _Resp(200, MOLIT_BAD_KEY))
    assert result.status == "키가 틀림"


# ── 전체 실행 · 종료 코드 · 출력 ────────────────────────────────────────────────


def _all_ok_http():
    calls: list[str] = []
    get = _http(
        {"/v1/models": _Resp(200), "apis.data.go.kr": _Resp(200, MOLIT_OK)},
        calls,
    )
    return get, _http({}, calls)


def test_설정된_키가_모두_정상이면_종료_코드_0(ck, monkeypatch):
    monkeypatch.setenv("UPSTAGE_API_KEY", "up_test_key_value")
    monkeypatch.setenv("MOLIT_API_KEY", "molit_test_key_value")
    get, post = _all_ok_http()
    _, code = ck.run(http_get=get, http_post=post)
    assert code == 0


def test_하나라도_틀리면_종료_코드_1(ck, monkeypatch):
    monkeypatch.setenv("UPSTAGE_API_KEY", "up_test_key_value")
    monkeypatch.setenv("MOLIT_API_KEY", "molit_test_key_value")
    get = _http({"/v1/models": _Resp(200), "apis.data.go.kr": _Resp(200, MOLIT_BAD_KEY)}, [])
    _, code = ck.run(http_get=get, http_post=_http({}, []))
    assert code == 1


def test_Upstage_키가_없으면_종료_코드_1(ck, monkeypatch):
    monkeypatch.setenv("UPSTAGE_API_KEY", "")
    monkeypatch.setenv("MOLIT_API_KEY", "")
    results, code = ck.run(http_get=_http({}, []), http_post=_http({}, []))
    assert code == 1
    assert results[0].status == "설정 안 됨"


def test_출력에_키_값과_응답_본문이_없다(ck, monkeypatch, capsys):
    keys = {
        "UPSTAGE_API_KEY": "up_SUPER_SECRET_upstage_123",
        "MOLIT_API_KEY": "molit%2BSUPER%2FSECRET%3D%3D",
    }
    for k, v in keys.items():
        monkeypatch.setenv(k, v)
    body_secret = "BODY_SHOULD_NOT_PRINT_789"

    def get(url, **kwargs):
        if "data.go.kr" in url:
            return _Resp(200, MOLIT_BAD_KEY + f"<!-- {body_secret} -->")
        return _Resp(401, f'{{"error": "{body_secret}"}}')

    assert ck.main(http_get=get, http_post=lambda *a, **k: _Resp(401, body_secret)) == 1
    out = capsys.readouterr().out
    for secret in (*keys.values(), body_secret):
        assert secret not in out
    assert "키가 틀림" in out
