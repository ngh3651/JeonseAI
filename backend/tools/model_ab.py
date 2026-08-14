"""국내 모델 2종 실측 비교 — 제안서 3.3에 그대로 붙일 표를 만든다 (부록 A, 2026-08-14).

⚠ **서비스 코드가 아니라 도구다.** 앱·서버는 이 파일을 import하지 않는다.
   실패해도 앱 동작에 영향이 0이다 — 이 파일은 아무것도 고치지 않고, 읽고 재기만 한다.

`tools/chat_ab.py`와 무엇이 다른가:
  chat_ab는 "우리 챗봇이 어느 모델로 도는가"를 고르기 위한 내부 실험이었다. 이 파일은
  **확약서·제안서에 그대로 들어갈 수치**를 만든다. 그래서 네 가지가 더 있다.
    ⑴ 호출 **원본 응답**을 붙잡아, 검증에 걸려 버려진 답변의 **원문**까지 잰다.
       (통과한 답만 재면 "200자 준수율 100%"가 나온다 — 200자 초과는 검증이 이미
        버리기 때문이다. 그건 모델의 성적이 아니라 우리 그물의 성적이다.)
    ⑵ 추론(thinking)이 실제로 꺼졌는지 `reasoning_content` 길이로 **확인**한다.
    ⑶ 실패한 호출을 실패로 남긴다. 성공분만 골라 평균 내지 않는다.
    ⑷ 모델명을 A/B로 가린 병렬 표 + 맨 아래 정답 공개 (팀 블라인드 투표용).

호출 예산:
  총 60회 상한. 질문 10개 중 **자연어 4개만** LLM을 탄다(나머지는 규칙·사전에서 끝난다).
  4문항 × 3회 × 2모델 = **24회**가 정상값이고, 429 재시도가 붙으면 그만큼 늘어난다.
  60회에 닿으면 그 뒤 호출은 '예산 소진'으로 기록되고 실제로 나가지 않는다.

쓰는 법:
    backend/.venv/Scripts/python.exe tools/model_ab.py
    # 모델을 바꾸려면 (기본: A=upstage · B=exaone)
    MODEL_A=upstage MODEL_B=exaone backend/.venv/Scripts/python.exe tools/model_ab.py
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))

from app.services import chat, llm, text_guard  # noqa: E402
from app.services.llm import base as llm_base  # noqa: E402
from app.services.llm.prompts import CHAT_SYSTEM_PROMPT  # noqa: E402

KST = timezone(timedelta(hours=9))
EVAL_PATH = _BACKEND_ROOT / "data" / "chat_eval.json"
OUT_DIR = _BACKEND_ROOT / "out"

#: 질문당 반복 — 1회로는 흔들림(같은 질문에 다른 답)을 볼 수 없다.
REPEATS = 3

#: 총 HTTP 호출 상한. 넘기면 실제로 나가지 않고 '예산 소진'으로 기록된다.
CALL_BUDGET = 60

#: 문장 수 — 마침표·물음표·느낌표로 끊는다.
_SENTENCE_RE = re.compile(r"[.!?。]+")


def sentence_count(text: str) -> int:
    return len([s for s in _SENTENCE_RE.split(text or "") if s.strip()])


# ══════════════════════════════════════════════════════════════════════════════
# 호출 계량기 — requests.post를 감싸 **원본 응답**과 횟수를 붙잡는다
# ══════════════════════════════════════════════════════════════════════════════
#
# 왜 여기서 붙잡나: 파이프라인(`chat.answer`)은 검증에 걸린 답변을 버리고 '준비된 문구'만
# 돌려준다. 버려진 원문을 재려면 HTTP 계층에서 가로채는 수밖에 없다. 서비스 코드를 고치지
# 않고 재는 유일한 자리다. **이 프로세스 안에서만** 유효한 패치다(도구 전용 CLI).


class CallLog:
    """1회 HTTP 호출의 원본 기록."""

    def __init__(self) -> None:
        self.status: int | None = None
        self.error: str = ""
        self.elapsed: float = 0.0
        self.raw_content: str = ""      # 모델이 돌려준 message.content 원문
        self.reasoning_len: int = 0     # 사고 과정 길이 — 0이면 thinking이 꺼진 것
        self.completion_tokens: Any = None
        self.budget_blocked: bool = False


_calls: list[CallLog] = []
_real_post = llm_base.requests.post


def _counting_post(url, *args, **kwargs):  # noqa: ANN001, ANN201
    entry = CallLog()
    _calls.append(entry)

    if len([c for c in _calls if not c.budget_blocked]) > CALL_BUDGET:
        entry.budget_blocked = True
        entry.error = "호출 예산 소진"
        # RequestException 계열로 올려야 provider가 LlmError로 받아 폴백한다.
        raise llm_base.requests.exceptions.ConnectionError("호출 예산 소진 — 실제로 보내지 않음")

    t0 = time.perf_counter()
    resp = _real_post(url, *args, **kwargs)
    entry.elapsed = time.perf_counter() - t0
    entry.status = resp.status_code
    try:
        body = resp.json()
        message = body["choices"][0]["message"]
        entry.raw_content = (message.get("content") or "").strip()
        entry.reasoning_len = len(
            message.get("reasoning_content") or message.get("reasoning") or ""
        )
        entry.completion_tokens = (body.get("usage") or {}).get("completion_tokens")
    except Exception:  # noqa: BLE001 — 계량기가 실험을 깨뜨리지 않는다
        entry.error = f"본문 해석 실패 (HTTP {resp.status_code})"
    return resp


llm_base.requests.post = _counting_post


# ══════════════════════════════════════════════════════════════════════════════
# 1회 실행
# ══════════════════════════════════════════════════════════════════════════════


class Run:
    """질문 1개 × 1회 실행."""

    def __init__(self, *, question: dict, label: str, repeat: int):
        self.question = question
        self.label = label
        self.repeat = repeat
        self.layer = ""
        self.answer = ""          # 화면에 나간 문장 (거절이면 준비된 문구)
        self.source = ""
        self.elapsed = 0.0        # 파이프라인 전체 시간
        self.llm_called = False
        self.http_calls = 0
        self.http_status: int | None = None
        self.http_error = ""
        self.raw_answer = ""      # 모델 원문의 answer 필드 (검증 전 — 없으면 빈 문자열)
        self.raw_content = ""     # 모델이 돌려준 content 통째
        self.reasoning_len = 0
        self.json_ok: bool | None = None
        self.guard_ok: bool | None = None
        self.guard_reason = ""

    # ── 파생 지표 (raw_answer 기준 — 검증에 걸린 답도 잰다) ──────────────────
    @property
    def raw_len(self) -> int | None:
        return len(self.raw_answer) if self.raw_answer else None

    @property
    def raw_sentences(self) -> int | None:
        return sentence_count(self.raw_answer) if self.raw_answer else None


def _extract_raw_answer(content: str) -> str:
    """모델 원문 content에서 `answer` 필드만 꺼낸다. 못 꺼내면 빈 문자열."""
    try:
        payload = llm_base._loads_lenient(content)
    except Exception:  # noqa: BLE001
        return ""
    value = payload.get("answer")
    return value.strip() if isinstance(value, str) else ""


def _run_once(question: dict, label: str, repeat: int) -> Run:
    """파이프라인을 그대로 태운다 — provider만 갈아 끼운 상태다."""
    run = Run(question=question, label=label, repeat=repeat)
    before = len(_calls)

    t0 = time.perf_counter()
    reply = chat.answer(question["text"])
    run.elapsed = time.perf_counter() - t0

    run.layer = reply.layer
    run.answer = reply.answer
    run.source = reply.source
    run.llm_called = reply.llm_called

    made = _calls[before:]
    run.http_calls = len(made)
    if made:
        last = made[-1]
        run.http_status = last.status
        run.http_error = last.error
        run.raw_content = last.raw_content
        run.reasoning_len = last.reasoning_len
        run.raw_answer = _extract_raw_answer(last.raw_content)

    if reply.llm_called:
        # 층 이름이 실패 원인을 그대로 들고 있다.
        run.json_ok = reply.layer not in ("L4-호출실패", "L4-예외")
        run.guard_ok = reply.layer == "L4-생성"
        if not run.guard_ok:
            run.guard_reason = reply.layer
            # 검증 실패면 무엇에 걸렸는지 원문에 직접 물어본다(로그보다 정확하다).
            if reply.layer == "L4-검증실패" and run.raw_answer:
                run.guard_reason = f"L4-검증실패({text_guard.check_chat(run.raw_answer)})"
    return run


# ══════════════════════════════════════════════════════════════════════════════
# 집계·표
# ══════════════════════════════════════════════════════════════════════════════


def _pct(n: int, d: int) -> str:
    return "—" if d == 0 else f"{round(n * 100 / d)}% ({n}/{d})"


def _rate_limited(runs: list[Run]) -> list[Run]:
    """429(요청 제한)로 실패한 실행 — **모델 품질이 아니라 티어 용량 문제다.**

    분모에서 빼지 않는다(실측 가용성도 사실이다). 다만 표에서 분리해 보여야
    "EXAONE 통과율 50%"가 모델 성적으로 오독되지 않는다.
    """
    return [r for r in runs if r.llm_called and r.http_status == 429]


def _summary(runs: list[Run]) -> dict[str, str]:
    llm_runs = [r for r in runs if r.llm_called]
    http_ok = [r for r in llm_runs if r.http_status == 200]
    limited = _rate_limited(llm_runs)
    ok_times = [r.elapsed for r in http_ok]
    parsed = [r for r in llm_runs if r.raw_answer]          # JSON에서 answer를 꺼낸 것
    passed = [r for r in llm_runs if r.guard_ok]
    times = [r.elapsed for r in llm_runs]
    three = [r for r in parsed if (r.raw_sentences or 0) <= 3]
    within = [r for r in parsed if (r.raw_len or 0) <= text_guard.CHAT_MAX_LEN]
    return {
        "LLM 호출 수": str(len(llm_runs)),
        "HTTP 성공": _pct(len(http_ok), len(llm_runs)),
        "└ 429 요청 제한 (티어 용량)": f"{len(limited)}회" if limited else "0회",
        "JSON 파싱 성공률": _pct(len(parsed), len(llm_runs)),
        "검증 통과율": _pct(len(passed), len(llm_runs)),
        "└ 검증 통과율 (응답 받은 것만)": _pct(len(passed), len(http_ok)),
        "3문장 이내 준수율": _pct(len(three), len(parsed)),
        f"{text_guard.CHAT_MAX_LEN}자 이내 준수율": _pct(len(within), len(parsed)),
        "평균 응답(초)": f"{sum(times) / len(times):.1f}" if times else "—",
        "└ 평균 응답(초) (응답 받은 것만)": f"{sum(ok_times) / len(ok_times):.1f}" if ok_times else "—",
        "최대 응답(초)": f"{max(times):.1f}" if times else "—",
        "사고 과정(reasoning) 평균 글자": (
            f"{sum(r.reasoning_len for r in llm_runs) / len(llm_runs):.0f}" if llm_runs else "—"
        ),
    }


def _md_table(headers: list[str], rows: list[list[str]]) -> str:
    out = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    for row in rows:
        out.append("| " + " | ".join(str(c).replace("\n", " ").replace("|", "\\|") for c in row) + " |")
    return "\n".join(out)


def main() -> int:
    if not EVAL_PATH.exists():
        print(f"[중단] 고정 질문 파일이 없습니다 — {EVAL_PATH}")
        return 1
    questions: list[dict] = json.loads(EVAL_PATH.read_text(encoding="utf-8"))["questions"]

    name_a = (os.environ.get("MODEL_A", "") or "upstage").strip()
    name_b = (os.environ.get("MODEL_B", "") or "exaone").strip()
    provider_a, provider_b = llm.get_provider(name_a), llm.get_provider(name_b)
    for p in (provider_a, provider_b):
        if not p.available:
            print(f"[중단] {p.name} API 키 없음 ({p.key_env}) — 두 모델이 다 있어야 비교다.")
            return 1

    # 켜 두지 않으면 L4를 통째로 건너뛴다 — 잴 것이 없어진다.
    os.environ["CHATBOT_LLM"] = "on"

    lineup = [("A", provider_a), ("B", provider_b)]
    results: dict[str, list[Run]] = {}
    for label, provider in lineup:
        # ⚠ 이 도구가 서비스 코드에 하는 **유일한** 개입 — provider 선택만 갈아 끼운다.
        chat.llm.chat_provider = lambda p=provider: p  # type: ignore[assignment]
        runs: list[Run] = []
        for q in questions:
            for i in range(REPEATS):
                run = _run_once(q, label, i + 1)
                runs.append(run)
                mark = "LLM" if run.llm_called else "규칙"
                print(
                    f"[{label}:{provider.model}] {q['id']}#{i + 1} {mark} {run.layer}"
                    f" {run.elapsed:.1f}초 | {(run.raw_answer or run.answer)[:40]}"
                )
        results[label] = runs

    total_http = len(_calls)
    blocked = sum(1 for c in _calls if c.budget_blocked)

    # ── 보고서 ────────────────────────────────────────────────────────────
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(KST)
    out_path = OUT_DIR / f"model_ab_{stamp:%Y%m%d}.md"

    L: list[str] = []
    L.append("# 국내 모델 2종 실측 비교 (부록 A)")
    L.append("")
    L.append(f"- 실행: {stamp:%Y-%m-%d %H:%M} KST")
    L.append(f"- 고정 질문 {len(questions)}개 × {REPEATS}회 × 2모델 · 같은 시스템 프롬프트·같은 4단 검증")
    L.append(f"- 프롬프트: `CHAT_SYSTEM_PROMPT` ({len(CHAT_SYSTEM_PROMPT)}자, 두 모델 동일)")
    L.append(
        f"- 검증: `text_guard.check_chat` — 숫자 전면 금지 · {text_guard.CHAT_MAX_LEN}자 상한"
        " · 금지 표현 · 등급 단어"
    )
    L.append(f"- 생성 파라미터: temperature {llm.CHAT_TEMPERATURE} · max_tokens {chat.MAX_OUTPUT_TOKENS}")
    L.append(f"- **총 HTTP 호출 {total_http}회** (상한 {CALL_BUDGET}회" + (f" · 예산 차단 {blocked}회" if blocked else "") + ")")
    L.append("")

    L.append("## 1. 지표")
    L.append("")
    metrics = list(_summary(results["A"]).keys())
    sums = {label: _summary(runs) for label, runs in results.items()}
    L.append(_md_table(["지표", "A", "B"], [[m, sums["A"][m], sums["B"][m]] for m in metrics]))
    L.append("")
    L.append(
        "> **호출 수가 질문 수보다 적은 것이 정상이다.** 사전 직격(L2)·판정 요구 차단(L1)·"
        "범위 밖(L3)은 LLM을 부르지 않는다 — 자연어 질문 4개만 모델을 탄다."
    )
    L.append("")
    L.append(
        "> **3문장·글자 수 준수율은 검증 전 원문 기준이다.** 통과한 답만 재면 상한 초과를 "
        "검증이 이미 버려서 100%가 나온다 — 그건 모델 성적이 아니라 우리 그물의 성적이다."
    )
    L.append("")

    # 429 각주 — 모델 성적과 티어 용량을 갈라 놓는다
    for label, provider in lineup:
        limited = _rate_limited(results[label])
        if limited:
            L.append(
                f"> 각주: **{label}의 실패 {len(limited)}건은 HTTP 429(요청 제한)다 —"
                " 모델이 틀린 답을 낸 것이 아니라 응답을 아예 받지 못했다.**"
                f" `{provider.base_url}`의 동시요청 한도이며, 우리 호출부는 이미"
                f" {llm_base.MAX_ATTEMPTS}회까지 {llm_base.RATE_LIMIT_BACKOFF_SECONDS}초 간격으로"
                " 재시도한 뒤 폴백한 결과다."
                " 분모에서 빼지 않았다 — **실측 가용성도 성적의 일부**이기 때문이다."
                " 모델 문장 품질만 보려면 `└ (응답 받은 것만)` 줄을 보라."
            )
            L.append("")

    # 추론 모드 각주
    for label, provider in lineup:
        llm_runs = [r for r in results[label] if r.llm_called]
        max_reason = max((r.reasoning_len for r in llm_runs), default=0)
        if provider.name == "exaone":
            if max_reason == 0:
                L.append(
                    f"> 각주: **{label}는 사고 모드를 끄고 호출했다**"
                    " (`chat_template_kwargs={\"enable_thinking\": false}`)."
                    " 전 호출에서 `reasoning_content` 길이 0으로 확인됨 — 옵션이 실제로 먹었다."
                )
            else:
                L.append(
                    f"> 각주: ⚠ **{label}의 사고 모드가 꺼지지 않았다.**"
                    " `enable_thinking=false`를 보냈으나 `reasoning_content`가"
                    f" 최대 {max_reason}자 돌아왔다 — 켠 채로 잰 수치다."
                )
            L.append("")

    L.append("## 2. 가드레일은 모델과 무관하다 (L1 · L3)")
    L.append("")
    rows = []
    for q in questions:
        if q["kind"] not in ("verdict", "off_topic"):
            continue
        cells = []
        for label in ("A", "B"):
            layers = sorted({r.layer for r in results[label] if r.question["id"] == q["id"]})
            calls = sum(r.http_calls for r in results[label] if r.question["id"] == q["id"])
            cells.append(f"{' / '.join(layers)} · LLM {calls}회")
        rows.append([q["id"], q["kind"], q["text"], *cells])
    L.append(_md_table(["id", "종류", "질문", "A 차단 지점", "B 차단 지점"], rows))
    L.append("")
    L.append(
        "> 두 열이 같다 = **거절이 모델 성능에 의존하지 않는다.** 규칙이 LLM 앞에 있기 때문이다."
    )
    L.append("")

    L.append("## 3. 질문별 답변 원문 (블라인드)")
    L.append("")
    L.append("> 모델명을 A/B로만 적었다 — 팀 블라인드 투표용. 정답은 §5.")
    L.append("> `원문`은 검증 **전** 모델이 낸 문장이고, `화면`은 실제로 사용자에게 나간 문장이다.")
    L.append("")
    for q in questions:
        L.append(f"### {q['id']} · {q['text']}")
        L.append("")
        L.append(f"- 종류 `{q['kind']}` · 기대: {q['expect']}")
        L.append("")
        body = []
        for label in ("A", "B"):
            for r in [x for x in results[label] if x.question["id"] == q["id"]]:
                shown = r.raw_answer or (r.http_error or "—") if r.llm_called else "(LLM 미호출)"
                body.append(
                    [
                        f"{label}#{r.repeat}",
                        r.layer,
                        f"{r.elapsed:.1f}s",
                        str(r.raw_len or "—"),
                        str(r.raw_sentences or "—"),
                        shown,
                        r.answer if r.answer != r.raw_answer else "(원문 그대로)",
                    ]
                )
        L.append(_md_table(["회차", "결론 지점", "시간", "자수", "문장", "원문(검증 전)", "화면"], body))
        L.append("")

    L.append("## 4. 실패한 호출")
    L.append("")
    fails = [
        (label, r)
        for label in ("A", "B")
        for r in results[label]
        if r.llm_called and not r.guard_ok
    ]
    if not fails:
        L.append("없음 — 두 모델의 모든 LLM 호출이 검증을 통과했다.")
    else:
        L.append(
            _md_table(
                ["모델", "질문", "회차", "실패 지점", "HTTP", "원문 일부"],
                [
                    [
                        label,
                        r.question["id"],
                        f"#{r.repeat}",
                        r.guard_reason or r.layer,
                        str(r.http_status or r.http_error or "—"),
                        (r.raw_answer or r.raw_content or r.http_error)[:80],
                    ]
                    for label, r in fails
                ],
            )
        )
    L.append("")
    L.append("> 성공분만 골라 평균 내지 않았다. 위 실패는 §1 분모에 그대로 들어가 있다.")
    L.append("")

    L.append("## 5. A/B 정답 공개")
    L.append("")
    L.append(
        _md_table(
            ["라벨", "provider", "**실제 호출 모델 문자열**", "엔드포인트"],
            [
                [label, p.name, f"`{p.model}`", f"`{p.base_url}`"]
                for label, p in lineup
            ],
        )
    )
    L.append("")
    L.append("> 위 모델 문자열 2개가 확약서에 그대로 들어가는 값이다.")
    L.append("")

    out_path.write_text("\n".join(L), encoding="utf-8")
    print(f"\n[완료] {out_path}  (총 HTTP 호출 {total_http}회 / 상한 {CALL_BUDGET})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
