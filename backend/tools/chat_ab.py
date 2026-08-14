"""용어 챗봇 모델 비교 하네스 — 제안서에 붙일 **실측표**를 만든다 (2026-08-14 S-12).

⚠ **서비스 코드가 아니라 도구다.** 앱·서버는 이 파일을 import하지 않는다.

무엇을 재나:
같은 질문 10개를 **같은 프롬프트·같은 검증**으로 두 모델에 태운다. 재는 것은 넷이다.
  ① 검증 통과율  ② JSON 파싱 성공률  ③ 3문장 이내 비율  ④ 평균/최대 응답 시간

⚠ **파이프라인 전체를 돌린다**(`chat.answer`가 아니라 그 안의 생성 계층만 부르지 않는다).
  판정 요구·범위 밖 질문은 L1·L3가 LLM 이전에 막으므로 **모델과 무관하게 결과가 같다** —
  그 사실 자체가 보고할 결과다("가드레일은 모델 성능에 의존하지 않는다").

쓰는 법:
    # A만 (기본): Solar
    backend/.venv/Scripts/python.exe tools/chat_ab.py
    # A + B: B는 환경변수로만 켠다 (OpenAI 호환이면 provider 이름만 주면 된다)
    CHAT_PROVIDER_B=exaone backend/.venv/Scripts/python.exe tools/chat_ab.py

크레딧: 질문 10개 중 **자연어 4개만** LLM을 탄다(나머지는 규칙·사전에서 끝난다).
        4문항 × 3회 = 모델당 12회. A만 12회, A+B 24회.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))

from app.services import chat, llm, text_guard  # noqa: E402
from app.services.llm.prompts import CHAT_SYSTEM_PROMPT  # noqa: E402

KST = timezone(timedelta(hours=9))
EVAL_PATH = _BACKEND_ROOT / "data" / "chat_eval.json"
OUT_DIR = _BACKEND_ROOT / "out"

#: 질문당 반복 횟수 — 흔들림(같은 질문에 다른 답)을 보려면 1회로는 알 수 없다.
REPEATS = 3

#: 문장 수 세기 — 마침표·물음표·느낌표로 끊는다.
_SENTENCE_RE = re.compile(r"[.!?。]+")


def sentence_count(text: str) -> int:
    return len([s for s in _SENTENCE_RE.split(text or "") if s.strip()])


class Run:
    """한 번의 호출 결과."""

    def __init__(self, *, question: dict, provider_label: str):
        self.question = question
        self.provider_label = provider_label
        self.layer = ""
        self.answer = ""
        self.source = ""
        self.elapsed = 0.0
        self.llm_called = False
        self.json_ok: bool | None = None  # LLM을 안 탄 질문은 None(해당 없음)
        self.guard_ok: bool | None = None
        self.reject_reason = ""
        #: 답변에 밑줄(툴팁)이 붙은 용어 — 답이 얼마나 '우리 사전과 맞물리는가'의 지표
        self.tooltips: list[str] = []


def _run_once(question: dict, provider, provider_label: str) -> Run:
    """파이프라인을 그대로 태운다 — 다만 provider만 갈아 끼운다."""
    run = Run(question=question, provider_label=provider_label)
    t0 = time.perf_counter()
    reply = chat.answer(question["text"])
    run.elapsed = time.perf_counter() - t0
    run.layer = reply.layer
    run.answer = reply.answer
    run.source = reply.source
    run.llm_called = reply.llm_called
    run.tooltips = list(reply.term_glossary)
    if reply.llm_called:
        # 층 이름이 실패 원인을 그대로 들고 있다(L4-스키마·L4-검증실패…).
        run.json_ok = reply.layer not in ("L4-스키마", "L4-호출실패", "L4-예외")
        run.guard_ok = reply.layer == "L4-생성"
        if reply.layer != "L4-생성":
            run.reject_reason = reply.layer
    return run


def _pct(n: int, d: int) -> str:
    return "—" if d == 0 else f"{round(n * 100 / d)}%"


def _summary_rows(runs: list[Run]) -> dict:
    llm_runs = [r for r in runs if r.llm_called]
    ok = [r for r in llm_runs if r.guard_ok]
    times = [r.elapsed for r in llm_runs]
    short = [r for r in ok if sentence_count(r.answer) <= 3]
    return {
        "호출 수": len(llm_runs),
        "JSON 파싱 성공률": _pct(sum(1 for r in llm_runs if r.json_ok), len(llm_runs)),
        "검증 통과율": _pct(len(ok), len(llm_runs)),
        "3문장 이내 비율": _pct(len(short), len(ok)),
        "평균 응답(초)": f"{sum(times) / len(times):.1f}" if times else "—",
        "최대 응답(초)": f"{max(times):.1f}" if times else "—",
    }


def _md_table(headers: list[str], rows: list[list[str]]) -> str:
    out = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    for row in rows:
        out.append("| " + " | ".join(row) + " |")
    return "\n".join(out)


def main() -> int:
    data = json.loads(EVAL_PATH.read_text(encoding="utf-8"))
    questions: list[dict] = data["questions"]

    provider_a = llm.chat_provider()
    if not provider_a.available:
        print(f"[중단] A 모델({provider_a.name}) API 키가 없습니다 — 잴 것이 없습니다.")
        return 1

    b_name = (os.environ.get("CHAT_PROVIDER_B", "") or "").strip()
    provider_b = llm.get_provider(b_name) if b_name else None
    if provider_b is not None and not provider_b.available:
        print(f"[안내] B 모델({provider_b.name}) 키가 없어 A만 돌립니다.")
        provider_b = None

    lineup: list[tuple[str, object]] = [("A", provider_a)]
    if provider_b is not None:
        lineup.append(("B", provider_b))

    # 켜 두지 않으면 L4를 통째로 건너뛴다 — 하네스가 잴 것이 없어진다.
    os.environ["CHATBOT_LLM"] = "on"

    results: dict[str, list[Run]] = {}
    for label, provider in lineup:
        # ⚠ provider를 갈아 끼우는 것이 이 도구가 서비스 코드에 하는 **유일한** 개입이다.
        chat.llm.chat_provider = lambda p=provider: p  # type: ignore[assignment]
        runs: list[Run] = []
        for q in questions:
            for i in range(REPEATS):
                run = _run_once(q, provider, label)
                runs.append(run)
                mark = "LLM" if run.llm_called else "규칙"
                print(
                    f"[{label}] {q['id']}#{i + 1} {mark} {run.layer} {run.elapsed:.1f}초"
                    f" | {run.answer[:40]}"
                )
        results[label] = runs

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(KST)
    out_path = OUT_DIR / f"chat_ab_{stamp:%Y%m%d}.md"

    lines: list[str] = []
    lines.append("# 용어 챗봇 모델 비교 (S-12)")
    lines.append("")
    lines.append(f"- 실행: {stamp:%Y-%m-%d %H:%M} KST · 질문 {len(questions)}개 × {REPEATS}회")
    lines.append(f"- 프롬프트: `CHAT_SYSTEM_PROMPT` ({len(CHAT_SYSTEM_PROMPT)}자, 두 모델 동일)")
    lines.append(f"- 검증: `text_guard.check_chat` (숫자 전면 금지 · {text_guard.CHAT_MAX_LEN}자 상한 · 금지 표현 · 등급 단어)")
    lines.append(f"- 생성 파라미터: temperature {llm.CHAT_TEMPERATURE} · max_tokens {chat.MAX_OUTPUT_TOKENS}")
    for label, provider in lineup:
        lines.append(f"- **{label}** = `{provider.name}` / 모델 `{provider.model}`")
    if provider_b is None:
        lines.append("- **B** = 없음 (`CHAT_PROVIDER_B` 미설정 또는 키 없음) — 추정치를 만들지 않았다")
    lines.append("")

    lines.append("## 1. 요약")
    lines.append("")
    metrics = ["호출 수", "JSON 파싱 성공률", "검증 통과율", "3문장 이내 비율", "평균 응답(초)", "최대 응답(초)"]
    summaries = {label: _summary_rows(runs) for label, runs in results.items()}
    lines.append(
        _md_table(
            ["지표", *summaries.keys()],
            [[m, *[str(summaries[label][m]) for label in summaries]] for m in metrics],
        )
    )
    lines.append("")
    lines.append(
        "> 호출 수가 질문 수보다 적은 것이 정상이다 — 사전 직격(L2)·판정 요구 차단(L1)·"
        "범위 밖(L3)은 **LLM을 부르지 않는다**."
    )
    lines.append("")

    lines.append("## 2. 가드레일은 모델과 무관하다")
    lines.append("")
    rows = []
    for q in questions:
        if q["kind"] not in ("verdict", "off_topic"):
            continue
        cells = []
        for label in results:
            layers = {r.layer for r in results[label] if r.question["id"] == q["id"]}
            cells.append(" / ".join(sorted(layers)))
        rows.append([q["id"], q["text"], *cells])
    lines.append(_md_table(["id", "질문", *[f"{k} 차단 지점" for k in results]], rows))
    lines.append("")
    lines.append("> 두 열이 같다 = **거절이 모델 성능에 의존하지 않는다.** 규칙이 앞에 있기 때문이다.")
    lines.append("")

    lines.append("## 3. 질문별 답변 원문 (블라인드)")
    lines.append("")
    lines.append("> 모델명을 A/B로만 적었다 — 팀 블라인드 투표용.")
    lines.append("")
    for q in questions:
        lines.append(f"### {q['id']} · {q['text']}")
        lines.append("")
        lines.append(f"- 종류: `{q['kind']}` · 기대: {q['expect']}")
        lines.append("")
        body = []
        for label in results:
            first = next(
                (r for r in results[label] if r.question["id"] == q["id"]),
                None,
            )
            if first is None:
                continue
            answer = first.answer.replace("\n", " ")
            body.append(
                [label, first.layer, first.source, ", ".join(first.tooltips) or "—", answer]
            )
        lines.append(
            _md_table(
                ["모델", "결론 지점", "출처 라벨", "밑줄 용어", "답변 원문(1회차)"], body
            )
        )
        lines.append("")

    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"\n[완료] {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
