"""pytest 공통 설정 — backend 루트를 import 경로에 추가해 `app.*`를 불러온다."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
