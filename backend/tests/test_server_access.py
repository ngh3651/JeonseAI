"""서버 문 — 기기 id · 기기별 기록 · 앱 키 · 속도 제한 (2026-10-21 배포 준비).

예전에는 `DEV_MODE_AUTH = True` 하나가 인증 우회와 실명 원응답 저장을 같이 켰고,
`GET /api/reports`는 **모든 사람의 기록**을 돌려줬다. 이 파일이 지키는 것:

1. 호출자 = `X-Device-Id` 헤더(형식 검사). 없으면 공용 `legacy-device`(옛 앱 호환),
   `REQUIRE_DEVICE_ID=1`이면 400.
2. 기록은 기기별 — 다른 기기의 리포트는 404. 예시 리포트는 누구나 보되 못 지운다(403).
3. `APP_KEY`가 있으면 `/api/*`는 `X-App-Key`가 맞아야 한다(401). 헬스·문서는 열려 있다.
4. 분석·대조는 기기×IP별 1시간 상한(429).
"""

from __future__ import annotations

import pytest
from fastapi import HTTPException

from app import dependencies, settings


# ══════════════════════════════════════════════════════════════════════════════
# ① 기기 id
# ══════════════════════════════════════════════════════════════════════════════


def test_헤더가_없으면_공용_기기_id다(monkeypatch):
    monkeypatch.delenv("REQUIRE_DEVICE_ID", raising=False)
    assert dependencies.get_current_user(None) == settings.LEGACY_DEVICE_ID == "legacy-device"


def test_헤더_필수로_켜면_헤더_없이는_400이다(monkeypatch):
    monkeypatch.setenv("REQUIRE_DEVICE_ID", "1")
    with pytest.raises(HTTPException) as e:
        dependencies.get_current_user(None)
    assert e.value.status_code == 400
    assert "기기" in e.value.detail  # 한국어 안내


@pytest.mark.parametrize(
    "device_id",
    ["3f2b8c1e-9a4d-4e7b-b1c2-0d9e8f7a6b5c", "abcdEFGH", "a" * 64, "device-0001"],
)
def test_올바른_기기_id는_그대로_쓴다(device_id):
    assert dependencies.get_current_user(device_id) == device_id


@pytest.mark.parametrize(
    "device_id",
    ["short", "a" * 65, "has space here", "slash/not/ok", "한글기기아이디입니다", "semi;colon00"],
)
def test_형식이_틀린_기기_id는_400이다(device_id):
    with pytest.raises(HTTPException) as e:
        dependencies.get_current_user(device_id)
    assert e.value.status_code == 400


def test_공용_통로_이름을_직접_보내면_400이다():
    """헤더로 `legacy-device`를 보내 공용 기록에 들어가는 길을 막는다."""
    with pytest.raises(HTTPException) as e:
        dependencies.get_current_user("legacy-device")
    assert e.value.status_code == 400
