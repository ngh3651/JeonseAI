"""그림자 로깅 — 같은 입력으로 **다른 모델**도 돌려 로그만 남긴다 (2026-08-05 신설).

왜 필요한가:
설명 프롬프트와 재료가 2026-08-05에 크게 바뀌었다. 그런데 기존 LLM 비교 하네스
(`scripts/compare_llm.py`)의 데이터는 **옛 프롬프트 기준**이라 무효다. 새 기준의 비교
데이터를 모으려면 실제 트래픽에서 같은 입력을 두 모델에 태워 보는 것이 가장 정확하다.

════════════════════════════════════════════════════════════════════════════
⚠ **그림자 출력은 사용자에게 절대 닿지 않는다.**
  이 모듈은 아무것도 돌려주지 않는다(`None`). `ExplanationResult`·`Report`·계약 어디에도
  실리지 않으며, 호출부는 결과를 받지 않는다. 구조적으로 섞일 수 없다.
⚠ **지연 0.** 사용자 응답을 만든 **뒤** 데몬 스레드에서 돈다. 실패·타임아웃은 로그
  한 줄로 끝난다(EXAONE은 FriendliAI 429 레이트리밋이 잦다 — decisions.md 2026-07-28).
⚠ **기본 OFF.** `.env`의 `SHADOW_LLM`이 켜져 있을 때만 호출한다. 켜져 있으면 분석 1건마다
  크레딧이 추가로 든다.
════════════════════════════════════════════════════════════════════════════

켜는 법:
    backend/.env 에  SHADOW_LLM=exaone   (끄려면 줄을 지우거나 SHADOW_LLM=off)
읽는 법:
    .venv/Scripts/python.exe scripts/shadow_report.py
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from dotenv import load_dotenv

from . import llm, text_guard
from .llm.prompts import EXPLAIN_SYSTEM_PROMPT

_log = logging.getLogger("jeonseai")
_BACKEND_ROOT = Path(__file__).resolve().parents[2]
LOG_DIR = _BACKEND_ROOT / "logs" / "llm_shadow"

KST = timezone(timedelta(hours=9))

#: 끄는 값들 — `llm/__init__.py`의 관례와 같다.
_OFF_VALUES = {"", "off", "none", "disabled", "no", "false", "0"}

#: 그림자 호출 시간 상한. 사용자 응답은 이미 나갔으므로 넉넉히 두되, 스레드가 영원히
#: 살아 있지 않게 막는다.
TIMEOUT_SECONDS = 90.0


def shadow_provider_name() -> str | None:
    """켜져 있으면 provider 이름, 꺼져 있으면 None."""
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
    raw = (os.environ.get("SHADOW_LLM", "") or "").strip().lower()
    return None if raw in _OFF_VALUES else raw


# ── 개인정보 마스킹 ──────────────────────────────────────────────────────────
#
# 로그는 파일로 남고 오래 산다. 등기부 실명·주민번호가 여기 남으면 out/ 원응답과 같은
# 문제가 된다(2026-08-02 마스킹 작업). 재료에는 이미 소유자 명단이 없지만
# (가드레일 테스트가 봉인), **방어적으로 한 겹 더** 지운다.
_ID_RE = re.compile(r"\d{6}\s*-\s*[0-9*]{6,7}")
_NAME_KEYS = ("name", "owner", "debtor", "holder", "claimant", "trustee")


def _scrub(node):
    """로그에 넣기 전 마스킹 — 주민번호 형태 제거 + 이름스러운 키의 값 가림."""
    if isinstance(node, str):
        return _ID_RE.sub("○○○○○○-○******", node)
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if any(t in str(k).lower() for t in _NAME_KEYS) and isinstance(v, str) and v:
                out[k] = v[0] + "○" * (len(v) - 1)
            else:
                out[k] = _scrub(v)
        return out
    if isinstance(node, list):
        return [_scrub(v) for v in node]
    return node


def _verify(raw_text: str, allowed: set[float], max_len: dict[str, int]) -> dict:
    """**제품과 같은 검증**을 돌리되 치환은 하지 않는다 — 통과/사유만 기록한다.

    폴백으로 갈아끼우지 않는 이유: 비교 대상은 **모델이 실제로 쓴 문장**이다.
    치환하면 무엇을 비교하는지 알 수 없게 된다.
    """
    out: dict = {"parsed": False, "fields": {}}
    try:
        payload = json.loads(raw_text)
    except ValueError as e:
        out["parse_error"] = f"{type(e).__name__}: {str(e)[:80]}"
        return out
    if not isinstance(payload, dict):
        out["parse_error"] = "최상위가 object가 아님"
        return out
    out["parsed"] = True
    out["extra_keys"] = sorted(set(payload) - {"headline", "evidences"})
    head = payload.get("headline")
    if isinstance(head, str):
        out["fields"]["headline"] = text_guard.check(
            head, max_len=max_len["headline"], allowed=allowed
        ) or "통과"
    for e in payload.get("evidences") or []:
        if not isinstance(e, dict):
            continue
        eid = str(e.get("id") or "?")
        text = e.get("easy_explanation")
        out["fields"][eid] = (
            text_guard.check(text, max_len=max_len["easy_explanation"], allowed=allowed) or "통과"
            if isinstance(text, str)
            else "easy_explanation 없음"
        )
    return out


def _write(record: dict) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    path = LOG_DIR / f"{datetime.now(KST):%Y-%m-%d}.jsonl"
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def _run(
    *,
    provider_name: str,
    material: dict,
    report_id: str,
    grade: str,
    primary_name: str,
    primary_raw: str | None,
    primary_elapsed: float,
    primary_source: str,
    max_len: dict[str, int],
) -> None:
    """스레드 본체 — **어떤 예외도 밖으로 내보내지 않는다.**"""
    try:
        provider = llm.get_provider(provider_name)
        if not provider.available:
            _log.info(f"[그림자] {provider_name} 건너뜀 — API 키 없음")
            return
        # ⚠ Solar에 넘긴 것과 **똑같은** 시스템 프롬프트·재료를 쓴다. 입력이 다르면
        #   비교가 무의미하다.
        user = "판정 JSON:\n" + json.dumps(material, ensure_ascii=False)
        t0 = time.perf_counter()
        raw = ""
        error = None
        try:
            raw = provider.chat(
                EXPLAIN_SYSTEM_PROMPT,
                user,
                max_tokens=3000,
                temperature=llm.EXPLAIN_TEMPERATURE,
                timeout=TIMEOUT_SECONDS,
            ).text
        except Exception as e:  # noqa: BLE001 — 429·타임아웃 포함. 조용히 기록만.
            error = f"{type(e).__name__}: {str(e)[:120]}"
        elapsed = time.perf_counter() - t0

        allowed = text_guard.collect_allowed(material)
        record = {
            "ts": datetime.now(KST).isoformat(),
            "report_id": report_id,
            "grade": grade,
            "models": {
                primary_name: {
                    "role": "primary",
                    "elapsed_sec": round(primary_elapsed, 2),
                    "source": primary_source,
                    "raw": _scrub(primary_raw) if primary_raw else None,
                    "verify": (
                        _verify(primary_raw, allowed, max_len) if primary_raw else None
                    ),
                },
                provider.name: {
                    "role": "shadow",
                    "elapsed_sec": round(elapsed, 2),
                    "error": error,
                    "raw": _scrub(raw) if raw else None,
                    "verify": _verify(raw, allowed, max_len) if raw else None,
                },
            },
        }
        _write(record)
        if error:
            _log.info(f"[그림자] {provider.name} 실패 — 기록만 남김 ({error})")
        else:
            _log.info(f"[그림자] {provider.name} 기록 완료 ({elapsed:.1f}초)")
    except Exception as e:  # noqa: BLE001 — 그림자가 서버 로그를 더럽히지 않게
        _log.info(f"[그림자] 기록 실패 — 무시하고 진행 ({type(e).__name__}: {str(e)[:80]})")


def maybe_run(
    *,
    material: dict,
    report_id: str,
    grade: str,
    primary_name: str,
    primary_raw: str | None,
    primary_elapsed: float,
    primary_source: str,
    max_len: dict[str, int],
) -> None:
    """켜져 있으면 **백그라운드로** 그림자 호출을 던진다. 돌려주는 값은 없다.

    ⚠ 반환값이 없는 것이 설계다 — 호출부가 결과를 쓸 수 없으므로 사용자 응답 경로에
      섞일 방법이 구조적으로 없다.
    """
    name = shadow_provider_name()
    if not name:
        return
    threading.Thread(
        target=_run,
        kwargs=dict(
            provider_name=name,
            material=material,
            report_id=report_id,
            grade=grade,
            primary_name=primary_name,
            primary_raw=primary_raw,
            primary_elapsed=primary_elapsed,
            primary_source=primary_source,
            max_len=max_len,
        ),
        name="shadow-llm",
        daemon=True,  # 서버 종료를 막지 않는다
    ).start()
