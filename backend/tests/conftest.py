"""pytest 공통 설정 — backend 루트를 import 경로에 추가해 `app.*`를 불러온다."""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# 테스트에서 실 API 호출(크레딧 소모) 원천 차단 — LLM 경로는 '키 없음 → 폴백'으로 흐른다.
# (explanation._load_api_key의 load_dotenv는 기존 환경변수를 덮지 않으므로 이 값이 유지됨.
#  LLM 호출 경로를 테스트할 때는 monkeypatch.setenv + _call_solar 목으로 대체한다.)
os.environ["UPSTAGE_API_KEY"] = ""

# 실거래가(공공 API)도 테스트에서 **절대 호출하지 않는다**. 크레딧은 안 들지만
# ⑴ 네트워크가 없으면 테스트가 느려지거나 깨지고, ⑵ 조회 결과가 그날 시장 상황에 따라
# 달라져 테스트가 비결정적이 되며, ⑶ 백그라운드 스레드가 테스트보다 오래 살아남아
# 로그가 닫힌 파일에 쓰이는 경고가 난다.
# 키를 비우면 `market_price._load_api_key`가 즉시 MarketPriceError를 내고,
# `price_lookup`이 그것을 '조회 불가' 안내로 바꾼다 — 리포트는 그대로 완성된다.
os.environ["MOLIT_API_KEY"] = ""
