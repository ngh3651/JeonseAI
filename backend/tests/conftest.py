"""pytest 공통 설정 — backend 루트를 import 경로에 추가해 `app.*`를 불러온다."""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# 테스트에서 실 API 호출(크레딧 소모) 원천 차단 — LLM 경로는 '키 없음 → 폴백'으로 흐른다.
# (explanation._load_api_key의 load_dotenv는 기존 환경변수를 덮지 않으므로 이 값이 유지됨.
#  LLM 호출 경로를 테스트할 때는 monkeypatch.setenv + _call_solar 목으로 대체한다.)
os.environ["UPSTAGE_API_KEY"] = ""
