"""국내 LLM provider 구현체 3종 — 대회 규정상 쓸 수 있는 모델만.

| provider | 모델 | 엔드포인트 | 키 환경변수 | 현재 상태 |
|---|---|---|---|---|
| `upstage` | solar-pro2 | api.upstage.ai/v1/solar | `UPSTAGE_API_KEY` | 키 있음 |
| `exaone` | LG EXAONE (FriendliAI 경유) | api.friendli.ai/serverless/v1 | `EXAONE_API_KEY` | 키 있음 |
| `ax` | SKT A.X 4.0 | guest-api.sktax.chat/v1 | `AX_API_KEY` | **키 없음** |

**키가 없는 provider는 `available=False`로 조용히 빠진다.** 키가 도착하면
`backend/.env`에 값만 넣으면 비교 대상에 **자동으로 합류한다** — 코드를 고칠 필요가 없다.
이것이 이 파일의 설계 요구사항이다(2026-07-28 지시).

모델명은 전부 환경변수로 덮을 수 있다(`*_MODEL`). serverless 엔드포인트는 제공 모델이
바뀌므로, 모델명이 틀렸을 때 코드 배포 없이 `.env`만 고쳐 복구할 수 있어야 한다.
"""

from __future__ import annotations

from .base import OpenAiCompatibleProvider


class UpstageSolarProvider(OpenAiCompatibleProvider):
    """Upstage Solar Pro — 지금까지 설명 문장을 만들어 온 모델.

    [decisions.md 2026-07-07 Solar Pro 연동 스펙 — 공식 쿡북(UpstageAI/cookbook) 원문 근거]
    """

    name = "upstage"
    default_model = "solar-pro2"
    key_env = "UPSTAGE_API_KEY"
    model_env = "UPSTAGE_MODEL"
    base_url = "https://api.upstage.ai/v1/solar"

    def _payload(self, messages: list[dict], max_tokens: int, json_mode: bool) -> dict:
        payload = super()._payload(messages, max_tokens, json_mode)
        # 문장 생성·표 옮겨적기는 복잡 추론이 필요 없다 — 빠르고 저비용
        payload["reasoning_effort"] = "low"
        return payload


class ExaoneProvider(OpenAiCompatibleProvider):
    """LG EXAONE — FriendliAI serverless 경유 (OpenAI 호환).

    Upstage와 **다른 회사의 모델**이라는 점이 중요하다. 같은 회사 모델 둘을 비교하면
    같은 방향으로 틀릴 수 있어 교차검증의 의미가 줄어든다.
    """

    name = "exaone"
    # 2026-07-28 실측: FriendliAI serverless가 제공하는 EXAONE 계열은 이 하나뿐이다
    # (`GET /serverless/v1/models` 확인 — 나머지 6종은 국외 모델이라 대회 규정상 쓸 수 없다).
    # 예전 이름(`EXAONE-3.5-32B-Instruct`)은 404다. serverless 목록은 바뀌므로
    # 모델명이 틀리면 `.env`의 `EXAONE_MODEL`만 고쳐 복구한다.
    default_model = "LGAI-EXAONE/K-EXAONE-236B-A23B"
    key_env = "EXAONE_API_KEY"
    model_env = "EXAONE_MODEL"
    base_url = "https://api.friendli.ai/serverless/v1"
    # 사고를 꺼도 여유는 조금 둔다 (JSON이 길어질 수 있다).
    extra_max_tokens = 1000

    def _payload(self, messages: list[dict], max_tokens: int, json_mode: bool) -> dict:
        payload = super()._payload(messages, max_tokens, json_mode)
        # ⚠ **추론(thinking)을 끈다.** 2026-07-28 실측:
        #   - 켠 상태로 등기부 구조화를 시키면 사고에 6,143~8,717자를 쓰고 생성 토큰
        #     상한에 먼저 닿아 `content`가 **빈 문자열**로 돌아온다(3/3 전부 실패).
        #   - 끄면 같은 질문에 사고 0자·6토큰으로 즉시 답한다.
        # 비교의 공정성 측면에서도 이쪽이 맞다 — Solar도 `reasoning_effort="low"`로 돌린다.
        payload["chat_template_kwargs"] = {"enable_thinking": False}
        return payload


class AxProvider(OpenAiCompatibleProvider):
    """SKT A.X 4.0 — **키 미발급 상태**(2026-07-28).

    구현은 전부 해 두었다. `backend/.env`에 `AX_API_KEY=...`를 넣는 순간
    `available`이 True가 되어 비교 하네스와 provider 선택에 자동으로 합류한다.
    """

    name = "ax"
    default_model = "ax4"
    key_env = "AX_API_KEY"
    model_env = "AX_MODEL"
    base_url = "https://guest-api.sktax.chat/v1"


#: 이름 → 클래스. 새 provider는 여기 한 줄만 더한다.
PROVIDER_CLASSES = {
    UpstageSolarProvider.name: UpstageSolarProvider,
    ExaoneProvider.name: ExaoneProvider,
    AxProvider.name: AxProvider,
}
