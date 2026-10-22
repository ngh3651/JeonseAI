"""국내 LLM provider 구현체 — 대회 규정상 쓸 수 있는 모델만.

| provider | 모델 | 엔드포인트 | 키 환경변수 | 현재 상태 |
|---|---|---|---|---|
| `upstage` | solar-pro2 | api.upstage.ai/v1/solar | `UPSTAGE_API_KEY` | 키 있음 |
| `ax` | SKT A.X 4.0 | guest-api.sktax.chat/v1 | `AX_API_KEY` | **키 없음** |

**키가 없는 provider는 `available=False`로 조용히 빠진다.** 키가 도착하면
`backend/.env`에 값만 넣으면 비교 대상에 **자동으로 합류한다** — 코드를 고칠 필요가 없다.
이것이 이 파일의 설계 요구사항이다(2026-07-28 지시).
2026-10-22: 다른 회사 모델 하나는 쓰지 않기로 해 코드에서 뺐다(decisions.md 2026-10-22).

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

    def _payload(
        self, messages: list[dict], max_tokens: int, json_mode: bool, temperature: float
    ) -> dict:
        payload = super()._payload(messages, max_tokens, json_mode, temperature)
        # 문장 생성·표 옮겨적기는 복잡 추론이 필요 없다 — 빠르고 저비용
        payload["reasoning_effort"] = "low"
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
    AxProvider.name: AxProvider,
}
