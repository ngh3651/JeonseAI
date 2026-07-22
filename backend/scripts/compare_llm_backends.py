"""국내 LLM 3종(Solar Pro / SKT A.X / LG EXAONE) 역할별 비교 하네스.

⚠ 격리 원칙: 이 스크립트는 제품 코드를 **import(읽기)만** 하고 수정하지 않는다.
   제품의 LLM 경로는 여전히 Solar 고정이며, 이 하네스는 비교 실측 전용이다.
⚠ 크레딧 보호: 키가 없는 프로바이더는 자동 제외되고, --run 없이는 어떤 호출도 하지 않는다.

비교 축 (미션 지정 4축):
  ① 한국어 설명 품질  → 사람 채점 (이 하네스가 채점 시트를 생성, 빈 칸으로 출력)
  ② 스키마 준수율     → 제품과 동일한 pydantic(extra="forbid") 검증 통과율 + 금지어 검출률
  ③ 지연시간          → 호출별 wall-clock, 반복 중앙값
  ④ 비용·안정성       → usage 토큰 집계 + HTTP 오류/재시도 횟수 (단가는 시트에 수기 기입)

역할(태스크) 4종 — 제품·후보 기능의 실제 프롬프트를 그대로 사용:
  explanation  : E-2 리포트 설명 생성 (app.services.explanation의 시스템 프롬프트·스키마)
  precedent    : 판례 설명 (app.services.precedent.explainer의 시스템 프롬프트·스키마)
  tagging      : [후보 2a] 판례 자동 태깅·구조화 (하네스 자체 프롬프트 — 제품 미반영)
  case_compare : [후보 2d] 판정×판례 비교 추론 (하네스 자체 프롬프트 — 제품 미반영)

프로바이더 설정 (환경변수 — backend/.env 또는 셸):
  Solar  : UPSTAGE_API_KEY (기존 키 그대로. base/model 기본값 내장)
  A.X    : AX_BASE_URL / AX_MODEL / AX_API_KEY          (OpenAI 호환 chat/completions 가정)
  EXAONE : EXAONE_BASE_URL / EXAONE_MODEL / EXAONE_API_KEY
           (FriendliAI serverless 경유 시 base=https://api.friendli.ai/serverless/v1 예상 —
            실측 전 조사 보고서의 확정값으로 대체할 것)

사용:
  python scripts/compare_llm_backends.py --list              # 설정 상태·필요 키 점검 (호출 0)
  python scripts/compare_llm_backends.py --run               # 키 있는 프로바이더 전 역할 실측
  python scripts/compare_llm_backends.py --run --roles explanation --repeat 5
  → 결과: data/llm_bench/run-<시각>.json + 같은 이름 .md (사람 채점 시트)
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
from pathlib import Path

import requests
from dotenv import load_dotenv
from pydantic import ValidationError

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")

# 제품 코드 import — 읽기 전용 (프롬프트·스키마·금지어를 실제 제품과 동일하게 쓰기 위함)
from app.schemas.internal import RegistryExtract  # noqa: E402
from app.services import rule_engine  # noqa: E402
from app.services.explanation import (  # noqa: E402
    _BANNED_PHRASES,
    _SYSTEM_PROMPT as EXPLANATION_SYSTEM_PROMPT,
    _verdict_for_prompt,
    ExplanationPayload,
)
from app.services.precedent.explainer import (  # noqa: E402
    _SYSTEM_PROMPT as PRECEDENT_SYSTEM_PROMPT,
    _ExplanationList,
)
from app.services.precedent.retrieval import HybridRetriever  # noqa: E402
from app.services.precedent.service import PrecedentService, tags_from_verdict  # noqa: E402

OUT_DIR = _BACKEND_ROOT / "data" / "llm_bench"
FIXTURE_DIR = _BACKEND_ROOT / "tests" / "fixtures" / "registry"
REQUEST_TIMEOUT = 90


# ── 프로바이더 정의 ─────────────────────────────────────────────────────────

def _providers() -> dict[str, dict]:
    """키가 설정된 프로바이더만 활성화된다. 값 출처는 전부 환경변수."""
    return {
        "solar": {
            "base_url": os.environ.get("SOLAR_BENCH_BASE_URL", "https://api.upstage.ai/v1/solar"),
            "model": os.environ.get("SOLAR_BENCH_MODEL", "solar-pro2"),
            "api_key": os.environ.get("UPSTAGE_API_KEY", "").strip(),
            "extra": {"reasoning_effort": "low"},  # 제품 설정과 동일 (decisions.md 2026-07-07)
            "note": "제품 현행 (기존 UPSTAGE_API_KEY 재사용)",
        },
        # 기본값은 2026-07-22 조사 확정 경로(docs/rag-expansion-review-2026-07-22.md §3.4).
        # 키는 절대 코드에 넣지 않는다 — backend/.env로만.
        "ax": {
            "base_url": os.environ.get("AX_BASE_URL", "https://guest-api.sktax.chat/v1"),
            "model": os.environ.get("AX_MODEL", "ax4"),
            "api_key": os.environ.get("AX_API_KEY", "").strip(),
            "extra": _extra_json("AX_EXTRA_JSON"),
            "note": "SKT A.X 무료 게스트 API — AX_API_KEY 필요(공개 게스트 키, §3.4)",
        },
        "exaone": {
            "base_url": os.environ.get("EXAONE_BASE_URL", "https://api.friendli.ai/serverless/v1"),
            "model": os.environ.get("EXAONE_MODEL", "LGAI-EXAONE/K-EXAONE-236B-A23B"),
            "api_key": os.environ.get("EXAONE_API_KEY", "").strip(),
            # K-EXAONE은 기본 thinking 모드 — 켜두면 reasoning이 max_tokens를 소진해
            # content가 비는 것을 실측으로 확인(2026-07-22). 제품 용도(빠른 결정적 JSON)에
            # 맞춰 비활성화가 기본. EXAONE_EXTRA_JSON으로 오버라이드 가능.
            "extra": _extra_json("EXAONE_EXTRA_JSON")
            or {"chat_template_kwargs": {"enable_thinking": False}},
            # FriendliAI serverless 레이트리밋(429) 실측 확인 — 호출 간 간격을 둔다
            "throttle_s": float(os.environ.get("EXAONE_THROTTLE_S", "15")),
            "note": "LG K-EXAONE (FriendliAI serverless) — EXAONE_API_KEY(flp_) 필요",
        },
    }


def _extra_json(env_name: str) -> dict:
    raw = os.environ.get(env_name, "").strip()
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except ValueError:
        print(f"⚠ {env_name} JSON 해석 실패 — 무시합니다: {raw[:60]}")
        return {}


# ── 역할(태스크) 입력 구성 — 픽스처 → 실제 판정 → 실제 프롬프트 ─────────────

def _fixture_verdict(name: str):
    data = json.loads((FIXTURE_DIR / f"{name}.json").read_text(encoding="utf-8"))
    extract = RegistryExtract.from_raw(data["registry"])
    inputs = data.get("inputs", {})
    return rule_engine.evaluate(
        extract,
        deposit=inputs.get("deposit", 120_000_000),
        market_price=inputs.get("market_price"),
        blacklist_entries=data.get("blacklist", []),
    )


# [후보 2a] 자동 태깅 프롬프트 — 하네스 전용 (제품 미반영. 채택 시 별도 설계·게이트 필수)
TAGGING_SYSTEM_PROMPT = """당신은 판례 분류기입니다. 판례의 사건명·판시사항을 읽고 전세 위험 유형 태그를 부여하세요.
허용 태그(이 목록 밖 금지): ["전세가율", "선순위 채권", "신탁등기", "압류·가압류", "경매", "임차권등기", "보증보험", "대항력"]
다음 JSON 형식으로만 응답하세요: {"tags": ["..."], "reason": "한 문장"}
해당 태그가 없으면 {"tags": [], "reason": "..."}. 목록에 없는 태그를 만들지 마세요."""

# [후보 2d] 판정×판례 비교 추론 프롬프트 — 하네스 전용 (제품 미반영)
CASE_COMPARE_SYSTEM_PROMPT = """당신은 전세 위험 분석 앱의 '판례 비교 통역사'입니다. 입력된 판정 요약과 판례 요지를 비교해 설명만 하세요.
규칙: 판정(등급·수치)을 바꾸거나 새로 만들지 않기. 입력에 없는 사실·수치·판례 언급 금지. 모든 문장 "~해요/~하세요"로. "안전합니다"류 단정 금지.
다음 JSON 형식으로만 응답하세요 (다른 텍스트 금지):
{"same_points": ["판정과 판례의 같은 점 1~2개"], "different_points": ["다른 점 1~2개"], "case_outcome": "판례에서 임차인이 겪은 결과 1문장", "lesson": "이 매물 사용자에게 주는 교훈 1문장"}"""


def _build_role_inputs() -> dict[str, dict]:
    """역할별 (system, user, validator) — 모든 프로바이더에 동일 입력을 준다."""
    verdict = _fixture_verdict("mortgage_heavy")  # 위험 매물 — 설명 난도가 가장 높은 케이스

    roles: dict[str, dict] = {}

    roles["explanation"] = {
        "system": EXPLANATION_SYSTEM_PROMPT,
        "user": "판정 JSON:\n" + json.dumps(_verdict_for_prompt(verdict), ensure_ascii=False),
        "validate": lambda text: ExplanationPayload.model_validate(json.loads(text)),
    }

    # 판례 역할 입력 — 실제 검색 결과를 그대로 사용 (인덱스 필요: scripts/ingest_precedents.py 선행)
    try:
        svc = PrecedentService(retriever=HybridRetriever())
        matches = svc.search_by_tags(tags_from_verdict(verdict))
    except Exception:
        matches = []
    if matches:
        payload = {
            "판정_요약": {"위험_태그": tags_from_verdict(verdict), "종합등급": verdict.grade.value},
            "판례_목록": [
                {
                    "case_id": m.doc.case_id,
                    "사건번호": m.doc.case_no,
                    "법원": m.doc.court,
                    "요지": m.doc.holding[:600],
                    "결과": m.doc.outcome,
                    "겹친_위험_태그": m.matched_tags,
                }
                for m in matches
            ],
        }
        roles["precedent"] = {
            "system": PRECEDENT_SYSTEM_PROMPT,
            "user": json.dumps(payload, ensure_ascii=False),
            "validate": lambda text: _ExplanationList.model_validate(json.loads(text)),
        }
        top = matches[0]
        roles["case_compare"] = {
            "system": CASE_COMPARE_SYSTEM_PROMPT,
            "user": json.dumps(
                {
                    "판정_요약": {
                        "종합등급": verdict.grade.value,
                        "위험_태그": tags_from_verdict(verdict),
                        "선순위채권합계_원": verdict.senior_debt_amount,
                        "보증금_원": verdict.deposit,
                    },
                    "판례": {"사건번호": top.doc.case_no, "요지": top.doc.holding[:800],
                             "결과": top.doc.outcome},
                },
                ensure_ascii=False,
            ),
            "validate": lambda text: _require_keys(
                json.loads(text), {"same_points", "different_points", "case_outcome", "lesson"}
            ),
        }

    # 태깅 역할 — 실제 수집 원문 1건 (raw 폴더 첫 파일)
    raws = sorted((_BACKEND_ROOT / "data" / "precedents" / "raw").glob("prec-*.json"))
    if raws:
        rd = json.loads(raws[0].read_text(encoding="utf-8"))
        roles["tagging"] = {
            "system": TAGGING_SYSTEM_PROMPT,
            "user": json.dumps(
                {"사건명": rd.get("case_name"), "판시사항": (rd.get("holding_points") or rd.get("holding_summary") or "")[:1200]},
                ensure_ascii=False,
            ),
            "validate": lambda text: _validate_tags(json.loads(text)),
        }
    return roles


_ALLOWED_TAGS = {"전세가율", "선순위 채권", "신탁등기", "압류·가압류", "경매", "임차권등기", "보증보험", "대항력"}


def _require_keys(obj: dict, keys: set[str]):
    extra = set(obj) - keys
    missing = keys - set(obj)
    if extra or missing:
        raise ValueError(f"스키마 불일치 — 누락 {missing or '없음'} · 여분 {extra or '없음'}")
    return obj


def _validate_tags(obj: dict):
    _require_keys(obj, {"tags", "reason"})
    bad = [t for t in obj["tags"] if t not in _ALLOWED_TAGS]
    if bad:
        raise ValueError(f"허용 목록 밖 태그: {bad}")
    return obj


# ── 호출·측정 ───────────────────────────────────────────────────────────────

def _call(provider: dict, system: str, user: str) -> tuple[str, dict, float]:
    body = {
        "model": provider["model"],
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "temperature": 0.3,
        "max_tokens": 1500,
        "response_format": {"type": "json_object"},
        **provider["extra"],
    }
    t0 = time.perf_counter()
    resp = requests.post(
        f"{provider['base_url'].rstrip('/')}/chat/completions",
        headers={"Authorization": f"Bearer {provider['api_key']}", "Content-Type": "application/json"},
        json=body,
        timeout=REQUEST_TIMEOUT,
    )
    elapsed = time.perf_counter() - t0
    resp.raise_for_status()
    data = resp.json()
    message = data["choices"][0]["message"]
    content = message.get("content")
    if not content:
        # thinking 모드 등으로 content가 비면(reasoning만 존재) 빈 출력으로 처리 — 스키마 실패로 집계
        keys = ", ".join(message.keys())
        content = ""
        print(f"    ⚠ content 없음 (message 키: {keys}, finish: {data['choices'][0].get('finish_reason')})")
    return content, data.get("usage", {}), elapsed


_RATE_LIMIT_RETRIES = 4
_RATE_LIMIT_BACKOFF_S = 20.0


def _call_with_backoff(provider: dict, system: str, user: str) -> tuple[str, dict, float]:
    """429(레이트리밋)는 오류가 아니라 대기 신호 — 백오프 후 재시도한다."""
    for attempt in range(_RATE_LIMIT_RETRIES + 1):
        try:
            return _call(provider, system, user)
        except requests.exceptions.HTTPError as e:
            if e.response is not None and e.response.status_code == 429 and attempt < _RATE_LIMIT_RETRIES:
                wait = float(e.response.headers.get("Retry-After") or _RATE_LIMIT_BACKOFF_S)
                print(f"    429 레이트리밋 — {wait:.0f}초 대기 후 재시도 ({attempt + 1}/{_RATE_LIMIT_RETRIES})")
                time.sleep(wait)
                continue
            raise
    raise RuntimeError("unreachable")


def _measure(provider_name: str, provider: dict, role_name: str, role: dict, repeat: int) -> dict:
    latencies, schema_ok, banned_hits, errors, usages, samples = [], 0, 0, 0, [], []
    throttle = float(provider.get("throttle_s", 0) or 0)
    for i in range(repeat):
        if throttle and (latencies or errors or i > 0):
            time.sleep(throttle)
        try:
            content, usage, elapsed = _call_with_backoff(provider, role["system"], role["user"])
            latencies.append(elapsed)
            usages.append(usage)
            samples.append(content)
            try:
                role["validate"](content)
                schema_ok += 1
            except (ValueError, ValidationError, KeyError):
                pass
            if any(p in content for p in _BANNED_PHRASES):
                banned_hits += 1
        except Exception as e:  # 응답 구조 이상 포함 — 개별 실패가 전체 실행을 죽이지 않게
            errors += 1
            samples.append(f"[호출 실패] {type(e).__name__}: {str(e)[:200]}")
        print(f"  {provider_name}/{role_name} {i + 1}/{repeat} "
              f"({latencies[-1]:.1f}s)" if latencies else f"  {provider_name}/{role_name} {i + 1}/{repeat} 실패")
    total_tokens = sum(u.get("total_tokens", 0) for u in usages)
    return {
        "provider": provider_name,
        "model": provider["model"],
        "role": role_name,
        "calls": repeat,
        "errors": errors,
        "schema_pass": f"{schema_ok}/{repeat - errors}" if repeat > errors else "0/0",
        "banned_phrase_hits": banned_hits,
        "latency_median_s": round(statistics.median(latencies), 2) if latencies else None,
        "latency_all_s": [round(x, 2) for x in latencies],
        "total_tokens": total_tokens,
        "samples": samples,
    }


# ── 리포트 ─────────────────────────────────────────────────────────────────

def _write_reports(results: list[dict]) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    (OUT_DIR / f"run-{stamp}.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    lines = [
        f"# LLM 3종 비교 실측 시트 — {stamp}",
        "",
        "품질(①) 열은 **사람 채점**(1~5): 비전문가 이해 용이성·해요체·용어 풀이. 단가는 수기 기입.",
        "",
        "| 역할 | 프로바이더 | 모델 | ②스키마 통과 | 금지어 | ③지연 중앙값(s) | ④토큰 | ④오류 | ①품질(수기) | 단가 메모 |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in results:
        lines.append(
            f"| {r['role']} | {r['provider']} | {r['model']} | {r['schema_pass']} "
            f"| {r['banned_phrase_hits']} | {r['latency_median_s']} | {r['total_tokens']} "
            f"| {r['errors']} | ☐ | ☐ |"
        )
    lines += ["", "## 출력 샘플 (품질 채점용)", ""]
    for r in results:
        lines.append(f"### {r['role']} / {r['provider']}")
        for i, s in enumerate(r["samples"], 1):
            lines.append(f"- 시도 {i}: `{s[:400]}`")
        lines.append("")
    (OUT_DIR / f"run-{stamp}.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"\n결과 저장: {OUT_DIR / f'run-{stamp}.json'} / .md (품질 열은 사람 채점)")


def main() -> None:
    ap = argparse.ArgumentParser(description="국내 LLM 3종 역할별 비교 하네스")
    ap.add_argument("--list", action="store_true", help="설정 상태만 출력 (호출 0)")
    ap.add_argument("--run", action="store_true", help="실측 실행 (크레딧 소모)")
    ap.add_argument("--roles", nargs="*", help="실행할 역할 (기본: 준비된 전부)")
    ap.add_argument("--providers", nargs="*", help="실행할 프로바이더 (기본: 키 있는 전부)")
    ap.add_argument("--repeat", type=int, default=3, help="역할·프로바이더당 반복 (기본 3)")
    args = ap.parse_args()

    providers = _providers()
    ready = {k: v for k, v in providers.items() if v["api_key"] and v["base_url"] and v["model"]}

    print("=== 프로바이더 설정 상태 ===")
    for name, p in providers.items():
        status = "✅ 준비됨" if name in ready else "⛔ 키/설정 누락"
        print(f"  {name:7} {status} — {p['note']}")
        if name not in ready:
            missing = [k for k, v in [("base_url", p["base_url"]), ("model", p["model"]),
                                       ("api_key", p["api_key"])] if not v]
            print(f"          누락: {', '.join(missing)}")

    roles = _build_role_inputs()
    print(f"\n준비된 역할: {list(roles)} (판례 인덱스 없으면 precedent/case_compare 제외됨)")

    if not args.run:
        print("\n--run 없이는 호출하지 않습니다. 키 주입 후 --run으로 실측하세요.")
        return
    if not ready:
        print("\n실행할 프로바이더가 없습니다 — 환경변수를 설정하세요.")
        return

    if args.providers:
        ready = {k: v for k, v in ready.items() if k in args.providers}
    if args.roles:
        roles = {k: v for k, v in roles.items() if k in args.roles}

    results = []
    for role_name, role in roles.items():
        for pname, p in ready.items():
            print(f"\n[{role_name} × {pname}] 반복 {args.repeat}회 (⚠ 크레딧 소모)")
            results.append(_measure(pname, p, role_name, role, args.repeat))
    _write_reports(results)


if __name__ == "__main__":
    main()
