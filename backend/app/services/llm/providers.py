"""LLM provider 구현체 — **Upstage Solar 하나**(2026-10-22 "AI는 Upstage만").

| provider | 모델 | 엔드포인트 | 키 환경변수 | 현재 상태 |
|---|---|---|---|---|
| `upstage` | solar-pro2 → (거절되면) solar-pro4 | api.upstage.ai/v1/solar | `UPSTAGE_API_KEY` | 키 있음 |

**키가 없는 provider는 `available=False`로 조용히 빠진다**(분석은 폴백 문구로 완성된다).
2026-10-22: 본선 때 비교 실험에 쓰던 다른 회사 모델 자리는 모두 뺐다 — AI는 Upstage만(decisions.md 2026-10-22).

모델명은 전부 환경변수로 덮을 수 있다(`*_MODEL`). serverless 엔드포인트는 제공 모델이
바뀌므로, 모델명이 틀렸을 때 코드 배포 없이 `.env`만 고쳐 복구할 수 있어야 한다.
"""

from __future__ import annotations

from . import solar_models
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

    def __init__(self) -> None:
        super().__init__()
        # 이 서버가 이미 다음 모델로 바꿨으면 처음부터 그 이름으로 (로그·표기가 실제와 같게)
        self.model = solar_models.current()

    def _payload(
        self, messages: list[dict], max_tokens: int, json_mode: bool, temperature: float
    ) -> dict:
        payload = super()._payload(messages, max_tokens, json_mode, temperature)
        # 문장 생성·표 옮겨적기는 복잡 추론이 필요 없다 — 빠르고 저비용 (모델마다 맞는 값, solar_models 참고)
        payload.update(solar_models.reasoning_fields(self.model))
        return payload

    def _send(
        self, messages: list[dict], max_tokens: int, json_mode: bool, temperature: float, timeout: float
    ):
        """모델이 끝났다며 거절되면 다음 모델로 바꿔 다시 부른다(2026-10-31, `solar_models`)."""
        payload = super()._payload(messages, max_tokens, json_mode, temperature)
        payload.pop("model", None)
        resp, used = solar_models.post_chat(payload, api_key=self._key, timeout=timeout)
        self.model = used  # 리포트의 '설명 · 모델' 표기·로그가 실제로 답한 모델을 말하게
        return resp


#: 이름 → 클래스. 새 provider는 여기 한 줄만 더한다.
PROVIDER_CLASSES = {
    UpstageSolarProvider.name: UpstageSolarProvider,
}
