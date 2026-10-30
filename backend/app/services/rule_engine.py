"""규칙 엔진 — 등기부 추출 결과 + 사용자 입력 → 위험 판정(RuleVerdict).

가드레일(CLAUDE.md 3절): 위험 판정은 이 모듈만 만든다. LLM은 판정 JSON을 받아
설명 문장만 생성하며(E-2), 이 모듈의 출력을 바꿀 수 없다.

보수적 편향의 구조적 강제:
- 모든 "유효" 판단은 `is_canceled is not True` — 말소 여부 불명은 유효로 간주.
- 금액 해석 실패(None)는 합산에서 빠지는 대신 '금액 미상'으로 등급을 끌어올린다(0 치환 금지).
- 문서 불완전(주소·소유자 미추출, 배열 키 누락)이면 모든 근거 카드의 하한을
  '확인 필요'로 강제한다(`floor_caution` 단일 지점).

판정 수치는 thresholds.py 상수만 사용한다(출처는 docs/decisions.md와 1:1).
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

from ..schemas.internal import (
    EvidenceVerdict,
    Grade,
    MoneyEntry,
    RegistryExtract,
    RuleVerdict,
    floor_caution,
    worst,
)
from . import price_normalize, thresholds as T
from .formatting import format_won, mask_name, mask_person_name, round_half_up

# 판정 출처 문구([판정] sourceText — 계약 §2.2). 리포트 화면 칩에 그대로 노출되므로
# 사용자 언어로 짧게 유지한다 ("검증 중"·"수동 대조" 같은 내부 프로세스 용어 금지 —
# 서연 리뷰 2026-07-07). 임시값·검증 대기 추적은 화면이 아니라 thresholds.py 주석과
# decisions.md(2026-07-06 기준 ①②③·임시 조치)가 담당한다 — rule-auditor 대조 지점.
_SRC_JEONSE = "HUG 담보인정비율 90% · 부동산원 80% 기준"
_SRC_SENIOR = "HUG 전세보증금반환보증 가입요건"
_SRC_OWNERSHIP = "HUG 가입요건(권리침해) · 법제처 생활법령정보(신탁)"
_SRC_LEASE = "주택임대차보호법 제3조의3"
_SRC_INSURANCE = "HUG 가입요건 — 등기부만으로 최종 확인 불가"
_SRC_BLACKLIST = "HUG 안심전세포털 공개 명단"
_SRC_PENDING = "등기예규 제1815호 · 신청사건 처리중 표시"

_DATA_DIR = Path(__file__).resolve().parents[2] / "data"

# 명단 미구축(대조 불가) 상태 라벨 — 종합 계산 임시 제외 판별에도 사용
# (임시 조치: 김시원 명단 데이터 도착 시 원복 — decisions.md 2026-07-06)
BLACKLIST_PENDING_LABEL = "명단 대조 아직 안 됨"

# 소유권 이상 신호로 보는 갑구 필드 (필드명, 한글 라벨)
_OWNERSHIP_FIELDS = (
    ("trust_registrations", "신탁등기"),
    ("seizures", "압류"),
    ("provisional_seizures", "가압류"),
    ("provisional_dispositions", "가처분"),
    ("auction_commencements", "경매개시결정"),
)


def load_blacklist() -> list[dict]:
    """악성임대인 공개 명단 — 서버가 받아 이름을 가려 둔 명단(`blacklist_source`, 2026-10-31)이 있으면 그것.

    없으면 예전처럼 data/blacklist.json의 실제 항목(is_sample 아님)만 — 지금은 견본뿐이라 빈 목록(대조 불가).
    ⚠ 실명 명단을 저장소에 넣지 않는다(공개 저장소). 받은 명단은 서버 볼륨에 가린 채로만 있다.
    """
    from . import blacklist_source

    hashed = blacklist_source.load()
    if hashed:
        return hashed
    try:
        raw = json.loads((_DATA_DIR / "blacklist.json").read_text(encoding="utf-8"))
        entries = raw.get("entries", [])
        return [e for e in entries if isinstance(e, dict) and not e.get("is_sample")]
    except (OSError, ValueError):
        return []


def evaluate(
    extract: RegistryExtract,
    *,
    deposit: int,
    market_price: int | None = None,
    blacklist_entries: list[dict] | None = None,
    supplementary: object | None = None,  # 추가 서류 확인(소액임차인 등) 대비 자리 — 팀 미결, 미사용
    blacklist_override: EvidenceVerdict | None = None,
) -> RuleVerdict:
    """추출 결과와 입력값으로 근거 카드 5종을 판정하고 종합 등급을 결합한다."""
    if blacklist_entries is None:
        blacklist_entries = load_blacklist()

    # 단독·다가구(통건물 등기) 판별 — 전세가율 판정을 보류시키는 안전망.
    # 주소가 없을 때도 True가 되지만 그쪽은 doc_incomplete가 이미 막고 있어 방향이 같다.
    whole_building = price_normalize.is_whole_building(extract.address or "")

    ev_jeonse = _judge_jeonse_ratio(deposit, market_price, whole_building=whole_building)
    ev_senior, senior_total = _judge_senior_debt(extract, deposit, market_price)
    ev_ownership = _judge_ownership(extract)
    # 다시 판정(보증금·시세 고치기, 2026-10-29)은 이름을 가린 등기부로 한다 — 실명이 있어야 하는 명단 대조는
    # 분석 때 실명으로 낸 **결과**를 그대로 쓴다(보증금·시세와 무관한 판정이다).
    ev_blacklist = (
        copy.deepcopy(blacklist_override)
        if blacklist_override is not None
        else _judge_blacklist(extract, blacklist_entries)
    )
    # 보증보험은 위 세 카드의 결과를 본다(2026-10-31 — 등기부로 볼 수 있는 가입 조건을 모두 통과하면 '양호')
    ev_insurance = _judge_insurance(
        extract, supplementary, ev_jeonse=ev_jeonse, ev_senior=ev_senior, ev_blacklist=ev_blacklist
    )

    evidences = [ev_jeonse, ev_senior, ev_ownership, ev_insurance, ev_blacklist]
    # 잔금 당일 빈틈 (2026-10-31) — '신청사건 처리중'이 찍힌 등기부. 있을 때만 카드가 생긴다.
    ev_pending = _judge_pending(extract)
    if ev_pending is not None:
        evidences.append(ev_pending)

    # 문서 신뢰도 게이트: 불완전하면 어떤 항목도 '양호'가 될 수 없다 (단일 강제 지점)
    doc_flags = _doc_flags(extract)
    if extract.doc_incomplete:
        reason = incomplete_reason(extract)
        for ev in evidences:
            if ev.grade is Grade.GOOD:
                ev.grade = floor_caution(ev.grade)
                ev.status_label = ev.status_label or "확인 필요"
                note = f"{reason} — 그래서 결과를 확정하지 않았어요"
                ev.detail_text = f"{ev.detail_text} · {note}" if ev.detail_text else note
                # 이 카드가 '확인 필요'인 **진짜 이유**(2026-10-29 QA). 이 집 수치 때문이 아니라 사진 때문이다 —
                # 설명(AI·준비된 문구)·홈 요약 줄·판례 태그가 이 표시를 보고 "수치가 높다"고 말하지 않는다.
                # 등급 계산은 위 두 줄에서 이미 끝났다 — 이 값은 등급을 움직이지 않는다.
                ev.facts["capped_reason"] = reason

    # 종합 등급: worst-of. 단 insurance의 '확인 필요'는 계산에서 제외(위험이면 반영).
    # 화면에는 insurance를 항상 표시한다 — 계산 제외일 뿐 숨기지 않는다. (decisions.md 2026-07-06)
    pool = [ev.grade for ev in (ev_jeonse, ev_senior, ev_ownership)]
    # 악성임대인 '명단 대조 아직 안 됨'(명단 미구축)도 임시로 계산 제외 — 매물 위험이 아니라
    # 우리 데이터 준비 상태의 문제이기 때문. 카드는 항상 표시. 김시원 명단 도착 시 원복.
    # (decisions.md 2026-07-06 임시 조치)
    if ev_blacklist.status_label != BLACKLIST_PENDING_LABEL:
        pool.append(ev_blacklist.grade)
    if ev_insurance.grade is Grade.DANGER:
        pool.append(ev_insurance.grade)
    # 처리 중인 신청은 이 집의 지금 상태다 — 무엇인지 확인될 때까지 종합도 '양호'가 될 수 없다(확인 필요).
    if ev_pending is not None:
        pool.append(ev_pending.grade)
    overall = worst(pool)

    return RuleVerdict(
        grade=overall,
        gauge_progress=_gauge(overall, evidences),
        deposit=deposit,
        market_price=market_price,
        senior_debt_amount=senior_total,
        address=extract.address,
        evidences=evidences,
        doc_flags=doc_flags,
        # 2026-08-05: 설명 재료. **어떤 판정에도 쓰이지 않는다** — 위 pool/overall 계산은
        # 이 줄 앞에서 이미 끝났고, 여기서 값을 바꿔도 등급은 움직이지 않는다.
        ownership_history=_ownership_history(extract),
    )


def _ownership_history(extract: RegistryExtract) -> dict:
    """소유권 이전 이력 요약 — 횟수와 최근 이전일. **설명 전용.**

    스키마 description이 이 배열을 "무자본 갭투자 의심 판단에 사용"이라 적어 두었지만
    (registry_schema.py), 지금 규칙 엔진은 이 값으로 판정하지 않는다. 판정을 새로 만드는
    것은 권위 출처가 필요한 일이라 이번 범위 밖이고, 여기서는 **설명 재료로만** 넘긴다.
    """
    active = [e for e in extract.ownership_changes if e.is_active]
    dates = []
    for e in active:
        raw = e.model_dump().get("receipt_date")
        if raw:
            dates.append(str(raw))
    out: dict = {"change_count": len(active)}
    if dates:
        out["latest_receipt_date"] = max(dates)  # 'YYYY-MM-DD' 문자열이라 사전순 = 시간순
    return out


# ── 근거 카드별 판정 ─────────────────────────────────────────────────────────


# 단독·다가구 전세가율 보류 문구 (계산 제외 판별에도 쓰인다)
WHOLE_BUILDING_PENDING_LABEL = "이 집 유형에는 쓸 수 없어요"


def _judge_jeonse_ratio(
    deposit: int, market_price: int | None, *, whole_building: bool = False
) -> EvidenceVerdict:
    # ── 단독·다가구 안전망 [2026-08-03] ──────────────────────────────────────
    # 다가구는 등기부가 **건물 1개에 1부**라, 앞순위 세입자들의 보증금 합계가
    # 등기부에 나오지 않는다. 건물 시세 20억에 내 보증금 2억이면 전세가율 10%지만,
    # 앞선 7세대가 18억을 넣어 놨다면 경매에서 한 푼도 못 받는다.
    # 즉 이 유형의 **낮은 전세가율은 안전 신호가 아니라 의미 없는 숫자**다.
    # 그래서 시세를 알아도 '양호'를 만들지 않는다 — 계산 자체를 하지 않는다.
    if whole_building:
        return EvidenceVerdict(
            id="jeonse_ratio",
            grade=Grade.CAUTION,
            status_label=WHOLE_BUILDING_PENDING_LABEL,
            detail_text=(
                "단독·다가구로 보여 보증금 비율을 쓰지 않았어요 — 이 유형은 등기부가 건물 1개에 "
                "1부뿐이라 **나보다 먼저 들어온 세입자들의 보증금 합계가 등기부에 나오지 않아요.** "
                "시세 대비 내 보증금 비율이 낮게 나와도 안전하다는 뜻이 아니에요. "
                "임대인에게 '전입세대 열람내역'과 '확정일자 부여현황'을 요구해 앞순위 보증금을 "
                "직접 확인하세요."
            ),
            source_text=_SRC_JEONSE,
            action_label="앞순위 보증금 확인하기",
            facts={
                "jeonse_ratio_pct": None,
                "deposit": deposit,
                "market_price": market_price,
                "whole_building": True,
            },
        )

    if market_price is None or market_price <= 0:
        return EvidenceVerdict(
            id="jeonse_ratio",
            grade=Grade.CAUTION,
            status_label="확인 필요",
            detail_text=None,
            source_text=_SRC_JEONSE,
            action_label="시세 입력하기",
            facts={"jeonse_ratio_pct": None, "deposit": deposit, "market_price": None},
        )

    ratio_raw = deposit / market_price * 100
    pct = round_half_up(ratio_raw)  # 표시용 — 비교는 원값으로
    # 비교는 반올림 전 원값: 90.2%가 90%로 내려가 '초과' 판정을 놓치면 미탐(false negative)
    # 방향의 완화가 되므로 금지 (rule-auditor 2026-07-06 지적 반영, decisions.md '초과' 문언대로)
    if ratio_raw > T.JEONSE_RATIO_DANGER_PCT:
        grade = Grade.DANGER
    elif ratio_raw > T.JEONSE_RATIO_CAUTION_PCT:
        grade = Grade.CAUTION
    else:
        grade = Grade.GOOD
    detail = (
        # 2026-08-03: "입력 시세"라고 못 박지 않는다 — 이 값은 사용자가 넣은 것일 수도,
        # 공공데이터에서 자동으로 찾아온 것일 수도 있다. 출처는 marketPriceSource가 따로 밝힌다.
        #
        # [D25 · 2026-08-14] 앞머리를 `전세가율 {pct}%`에서 풀어 썼다. 이 회색 박스에는
        # 용어 툴팁이 붙지 않아(툴팁은 설명문 전용) '전세가율'이 설명 없는 벽으로 남았다.
        # ⚠ `%` 문자는 반드시 남아야 한다 — 판례 태그 파생(`tags_from_report`)이 이 글자로
        #   "실측 비율이 있는 카드"를 가린다. 여기서 %가 사라지면 판례 매칭이 조용히 빈다.
        f"보증금이 시세의 {pct}%예요 — 보증금 {format_won(deposit)} / 시세 {format_won(market_price)}"
        f" (주의 기준 {T.JEONSE_RATIO_CAUTION_PCT}% · 위험 기준 {T.JEONSE_RATIO_DANGER_PCT}%)"
    )
    return EvidenceVerdict(
        id="jeonse_ratio",
        grade=grade,
        detail_text=detail,
        source_text=_SRC_JEONSE,
        facts={
            "jeonse_ratio_pct": pct,
            "deposit": deposit,
            "market_price": market_price,
            # 원값 비교 결과(표시값 pct로 다시 견주지 않게 — 2026-10-31 감사). 판정은 위 grade가 이미 냈다.
            "over_caution": ratio_raw > T.JEONSE_RATIO_CAUTION_PCT,
            # 2026-08-05: **판정에 실제로 쓰인 기준선**을 설명 재료로 함께 넘긴다.
            # "안전선은 80%인데 이 집은 60%" 같은 문장을 쓰려면 LLM이 80을 알아야 한다.
            # 값은 thresholds.py 상수 그대로이며 여기서 판정에 다시 쓰이지 않는다.
            "thresholds": {
                "caution_over_pct": T.JEONSE_RATIO_CAUTION_PCT,
                "danger_over_pct": T.JEONSE_RATIO_DANGER_PCT,
                "source": _SRC_JEONSE,
            },
        },
    )


def _judge_senior_debt(
    extract: RegistryExtract, deposit: int, market_price: int | None
) -> tuple[EvidenceVerdict, int]:
    active_mortgages = [m for m in extract.mortgages if m.is_active]
    active_jeonse = [j for j in extract.jeonse_rights if j.is_active]
    active_lease = [l for l in extract.lease_registrations if l.is_active]

    known_amounts = [e.amount for e in (*active_mortgages, *active_jeonse) if e.amount is not None]
    unknown_count = sum(1 for e in (*active_mortgages, *active_jeonse) if e.amount_unknown)
    total_known = sum(known_amounts)

    # 비교는 반올림 전 원값(초과 판정 완화 금지 — 보수적 편향), 표시는 반올림값
    senior_raw: float | None = None
    combined_raw: float | None = None
    senior_pct: int | None = None
    combined_pct: int | None = None
    if market_price and market_price > 0:
        senior_raw = total_known / market_price * 100
        combined_raw = (total_known + deposit) / market_price * 100
        senior_pct = round_half_up(senior_raw)
        combined_pct = round_half_up(combined_raw)

    # [D25 · 2026-08-14] 사유 문구를 쉬운 말로. **숫자·건수·기준값은 한 글자도 바꾸지
    # 않는다** — `text_guard.collect_allowed`가 이 문자열의 수를 허용 목록으로 삼아
    # LLM 문장을 검증하므로, 수가 바뀌면 설명이 통째로 폴백된다.
    # ⚠ `임차권등기`는 판례 태그 파생(`tags_from_report`)이 이 글자를 찾으므로 남긴다.
    reasons: list[str] = []
    if active_lease:
        # 임차권등기 = 과거 보증금 미반환 사고의 증거 (주임법 §3-3, 조건부 채택)
        reasons.append(
            f"임차권등기 {len(active_lease)}건 — 전에 살던 세입자가 보증금을 못 받았다는 기록이에요"
        )
    if senior_raw is not None and senior_raw > T.SENIOR_DEBT_RATIO_DANGER_PCT:
        reasons.append(
            f"나보다 먼저 받아갈 빚이 시세의 {senior_pct}%로,"
            f" 위험 기준 {T.SENIOR_DEBT_RATIO_DANGER_PCT}%를 넘어요"
        )
    if combined_raw is not None and combined_raw > T.COMBINED_RATIO_DANGER_PCT:
        reasons.append(
            f"내 보증금까지 더하면 시세의 {combined_pct}%로,"
            f" 위험 기준 {T.COMBINED_RATIO_DANGER_PCT}%를 넘어요"
        )

    if reasons:
        grade = Grade.DANGER
        status = None
    elif unknown_count > 0:
        grade = Grade.CAUTION
        status = "확인 필요"
        reasons.append(f"금액을 못 읽은 빚 {unknown_count}건 — 원본 등기부로 확인해 주세요")
    elif market_price is None and total_known > 0:
        grade = Grade.CAUTION
        status = "확인 필요"
        # 2026-08-03: 자동 조회가 실패했을 수도 있으므로 "미입력"(사용자 탓)이 아니라
        # "알 수 없음"(사실)으로 말한다.
        reasons.append("시세를 알 수 없어요 — 빚이 많은 편인지 비율로 따져볼 수 없어요")
    else:
        grade = Grade.GOOD
        status = None

    # [D25 · 2026-08-14] `유효 채권최고액 등 합계 … (말소 제외)`를 쉬운 말로.
    # 이 한 줄에 '유효 · 채권최고액 · 말소' 세 개가 몰려 있어, 부동산을 모르는 사람에게는
    # 가장 중요한 숫자가 읽히지 않는 벽이었다. **숫자·건수는 그대로다.**
    parts = [f"지금 살아 있는 빚 {format_won(total_known)}"]
    parts.append(f"{len(active_mortgages)}건")
    if active_jeonse:
        parts.append(f"나보다 먼저 받아갈 전세권 {len(active_jeonse)}건")
    if active_lease:
        parts.append(f"임차권등기 {len(active_lease)}건")
    if unknown_count:
        parts.append(f"금액을 못 읽은 것 {unknown_count}건")
    detail = " · ".join(parts) + " (이미 지워진 빚은 뺐어요)"
    if reasons:
        detail += " — " + " / ".join(reasons)

    source = _SRC_LEASE if active_lease else _SRC_SENIOR
    verdict = EvidenceVerdict(
        id="senior_debt",
        grade=grade,
        status_label=status,
        detail_text=detail,
        source_text=source,
        facts={
            "senior_debt_total": total_known,
            "mortgage_count": len(active_mortgages),
            "jeonse_right_count": len(active_jeonse),
            "lease_registration_count": len(active_lease),
            "unknown_amount_count": unknown_count,
            "senior_ratio_pct": senior_pct,
            "combined_ratio_pct": combined_pct,
            # 2026-10-31 감사: 위 두 값은 **반올림한 표시값**이라 기준과 다시 견주면 60.3%가 '60% 이하'로 보인다.
            #   판정에 쓴 원값 비교 결과를 그대로 옮겨 둔다(화면의 ✓·색이 이 값을 쓴다). 판정은 위에서 이미 끝났다.
            "senior_over_limit": None if senior_raw is None else senior_raw > T.SENIOR_DEBT_RATIO_DANGER_PCT,
            "combined_over_limit": None if combined_raw is None else combined_raw > T.COMBINED_RATIO_DANGER_PCT,
            # ── 2026-08-05 설명 재료 (판정에 쓰이지 않음) ──────────────────────
            "thresholds": {
                "senior_danger_over_pct": T.SENIOR_DEBT_RATIO_DANGER_PCT,
                "combined_danger_over_pct": T.COMBINED_RATIO_DANGER_PCT,
                "source": _SRC_SENIOR,
            },
            # 근저당 한 건 한 건의 얼굴. `RegistryEntry`가 extra="allow"라 IE 원본 필드가
            # 객체에 살아 있는데(감사 §A-4-⑴) 지금까지 설명까지 오지 못했다.
            # ⚠ 채무자는 개인 이름일 수 있어 마스킹한다. 근저당권자는 기관명이면 그대로,
            #   개인으로 보이면 마스킹한다(2026-10-21 — 개인 사채가 있다).
            "mortgages": [_mortgage_fact(m) for m in active_mortgages],
        },
    )
    return verdict, total_known


def _mortgage_fact(m: MoneyEntry) -> dict:
    """근저당 1건 → 설명용 사실 묶음. **판정에 쓰지 않는다.**

    `RegistryEntry.model_config`가 `extra="allow"`라 IE가 준 원본 키가 그대로 살아 있다.
    없는 키는 넣지 않는다 — LLM이 빈 값을 보고 문장을 지어내지 않게 한다.
    """
    raw = m.model_dump()
    out: dict = {}
    if raw.get("rank_number"):
        out["rank_number"] = str(raw["rank_number"])
    if raw.get("receipt_date"):
        out["receipt_date"] = str(raw["receipt_date"])
    if raw.get("mortgagee"):
        # 은행 등 기관명은 공개 정보라 그대로, 개인으로 보이면 `홍○○` (2026-10-21)
        out["mortgagee"] = mask_person_name(str(raw["mortgagee"]))
    if raw.get("debtor"):
        out["debtor"] = mask_name(str(raw["debtor"]))  # 개인 이름 가능 → 마스킹
    if m.amount is not None:
        out["max_claim_amount"] = m.amount
    elif m.amount_unknown:
        out["amount_unknown"] = True
    return out


def _judge_ownership(extract: RegistryExtract) -> EvidenceVerdict:
    counts = {
        label: sum(1 for e in getattr(extract, field) if e.is_active)
        for field, label in _OWNERSHIP_FIELDS
    }
    total = sum(counts.values())

    # [D25 · 2026-08-14] `(유효 기준, 말소 제외)`를 쉬운 말로.
    # ⚠ 라벨(신탁등기·압류·가압류·가처분·경매개시결정)은 **그대로 둔다** —
    #   판례 태그 파생(`tags_from_report`)이 이 글자들을 그대로 찾는다.
    if total > 0:
        found = " · ".join(f"{label} {n}건" for label, n in counts.items() if n > 0)
        grade = Grade.DANGER
        detail = f"{found} (지금 살아 있는 것만 세었어요 · 이미 지워진 건 뺐어요)"
    else:
        grade = Grade.GOOD
        detail = (
            "지금 살아 있는 신탁등기·압류·가압류·가처분·경매개시결정은 없었어요"
            " (이미 지워진 건 뺐어요)"
        )

    return EvidenceVerdict(
        id="ownership",
        grade=grade,
        detail_text=detail,
        source_text=_SRC_OWNERSHIP,
        facts={"signals": counts, "signal_total": total},
    )


_SRC_INSURANCE_OK = "HUG 전세보증금반환보증 가입요건(선순위채권 60% · 담보인정비율 90% · 권리침해 없음)"


def _judge_insurance(
    extract: RegistryExtract,
    supplementary: object | None,
    *,
    ev_jeonse: EvidenceVerdict | None = None,
    ev_senior: EvidenceVerdict | None = None,
    ev_blacklist: EvidenceVerdict | None = None,
) -> EvidenceVerdict:
    """보증보험 — 등기부로 볼 수 있는 HUG 가입요건을 따진다.

    2026-10-31 (규혁 "안전한 집도 보증보험은 늘 확인 필요인가?"): 등기부로 볼 수 있는 가입요건을 **모두** 통과하면
    '양호'다. 통과 조건(전부 thresholds.py·decisions.md 2026-07-06의 HUG 기준 그대로 — 새 수치 없음):
      ① 권리침해 없음(신탁·압류·가압류·가처분·경매·임차권등기)  ② 빚 ≤ 시세의 60%·빚+보증금 ≤ 90%
         (= 빚 카드 '양호', 금액 못 읽은 빚 없음)  ③ 전세가율 80% 이하(= 전세가율 카드 '양호' — 시세를 알고,
         단독·다가구 아님. HUG 90%보다 한 칸 보수적: 보증기관이 매기는 집값은 우리 시세와 다를 수 있다)
      ④ 악성임대인 공개 명단과 **맞춰 봤고** 같은 이름이 없음(= 명단 카드 '양호'. 명단을 아직 못 받았으면 모르는 것이다)
      ⑤ 처리 중인 등기 신청(신청사건) 없음 — 있으면 아직 안 적힌 빚이 있을 수 있다.
    하나라도 모르면(시세 없음·명단 대조 전 등) 예전처럼 '확인 필요'. ①②③만 통과했으면 무엇을 기다리는지(waiting_for) 밝힌다.
    사진이 빠졌으면 문서 게이트가 다시 '확인 필요'로 올린다. (규칙 감사 2026-10-31 — ④⑤ 보강)
    '양호'여도 "가입된다"고 말하지 않는다 — 보증기관이 집값을 따로 매기고 집주인도 본다(설명 문구).

    supplementary: 추가 서류(전입세대열람 등) 확인 로직이 붙을 자리 — 팀 미결, 사용하지 않는다.
    """
    disqualify = [
        f"{label} {n}건"
        for field, label in _OWNERSHIP_FIELDS
        for n in [sum(1 for e in getattr(extract, field) if e.is_active)]
        if n > 0
    ]
    lease_count = sum(1 for l in extract.lease_registrations if l.is_active)
    if lease_count:
        disqualify.append(f"임차권등기 {lease_count}건")

    if disqualify:
        return EvidenceVerdict(
            id="insurance",
            grade=Grade.DANGER,
            # [D25] '가입 결격 신호'는 보험 약관 어휘다. 출처 표기(HUG …)는 그대로 둔다.
            detail_text=(
                "보증보험에 못 들 수 있는 신호: "
                + " · ".join(disqualify)
                + " (HUG 권리침해 결격 사유)"
            ),
            source_text=_SRC_INSURANCE,
            facts={"disqualify_signals": disqualify},
        )
    registry_ok = (
        ev_jeonse is not None
        and ev_jeonse.grade is Grade.GOOD
        and ev_senior is not None
        and ev_senior.grade is Grade.GOOD
        and ev_senior.facts.get("senior_ratio_pct") is not None
        and not ev_senior.facts.get("unknown_amount_count")
    )
    # ④ 명단: **맞춰 봤고 같은 이름이 없을 때만**(명단 카드 '양호') 통과다. 명단을 아직 못 받았거나·집주인 이름을 못 읽었거나·
    #    같은 이름이 있으면 '모른다'다 — 규칙 감사(2026-10-31): 예전 줄은 '일치가 안 나옴'만 봐서 명단이 없을 때도 통과로 셌다.
    blacklist_ok = ev_blacklist is not None and ev_blacklist.grade is Grade.GOOD
    # 처리 중인 등기 신청이 있으면 아직 안 적힌 빚이 있을 수 있다 — 끝난 등기부로 다시 볼 때까지 확정하지 않는다(감사 경고 3).
    pending = bool(getattr(extract, "pending_application", False))
    if registry_ok and blacklist_ok and not pending:
        senior_pct = ev_senior.facts.get("senior_ratio_pct")
        combined_pct = ev_senior.facts.get("combined_ratio_pct")
        ratio_pct = ev_jeonse.facts.get("jeonse_ratio_pct")
        return EvidenceVerdict(
            id="insurance",
            grade=Grade.GOOD,
            detail_text=(
                "등기부로 볼 수 있는 가입 조건을 모두 통과했어요 · "
                f"빚은 시세의 {senior_pct}% (기준 {T.SENIOR_DEBT_RATIO_DANGER_PCT}% 이하) · "
                f"빚과 보증금을 더하면 {combined_pct}% (기준 {T.COMBINED_RATIO_DANGER_PCT}% 이하) · "
                f"보증금은 시세의 {ratio_pct}% · 압류·가압류·가처분·경매·신탁·임차권등기 없음"
            ),
            source_text=_SRC_INSURANCE_OK,
            facts={
                "disqualify_signals": [],
                "registry_conditions_passed": True,
                "senior_ratio_pct": senior_pct,
                "combined_ratio_pct": combined_pct,
                "jeonse_ratio_pct": ratio_pct,
            },
        )
    if registry_ok:
        # 등기부 조건(①②③)은 통과했지만 ④ 명단 또는 처리 중인 신청 때문에 확정하지 않는다 — 무엇을 기다리는지 밝힌다
        waiting: list[str] = []
        reasons: list[str] = []
        if pending:
            waiting.append("pending")
            reasons.append("처리 중인 등기 신청이 있어 끝난 등기부로 다시 볼 때까지 확정하지 않았어요")
        if not blacklist_ok:
            waiting.append("blacklist")
            label = ev_blacklist.status_label if ev_blacklist is not None else None
            if label == BLACKLIST_PENDING_LABEL:
                reasons.append("악성임대인 공개 명단과 아직 맞춰 보지 못해 확정하지 않았어요")
            elif ev_blacklist is not None and str(label or "").startswith("명단 일치"):
                reasons.append("공개 명단에 같은 이름이 있어 확정하지 않았어요")
            else:
                reasons.append("집주인 이름을 못 읽어 공개 명단과 맞춰 보지 못해 확정하지 않았어요")
        return EvidenceVerdict(
            id="insurance",
            grade=Grade.CAUTION,
            status_label="확인 필요",
            detail_text=(
                "등기부로 볼 수 있는 빚·압류 조건은 통과했어요 · "
                f"빚은 시세의 {ev_senior.facts.get('senior_ratio_pct')}% · "
                f"빚과 보증금을 더하면 {ev_senior.facts.get('combined_ratio_pct')}% · "
                f"보증금은 시세의 {ev_jeonse.facts.get('jeonse_ratio_pct')}% · "
                + " · ".join(reasons)
            ),
            source_text=_SRC_INSURANCE,
            facts={
                "disqualify_signals": [],
                "registry_conditions_passed": False,
                "waiting_for": waiting,
                "senior_ratio_pct": ev_senior.facts.get("senior_ratio_pct"),
                "combined_ratio_pct": ev_senior.facts.get("combined_ratio_pct"),
                "jeonse_ratio_pct": ev_jeonse.facts.get("jeonse_ratio_pct"),
            },
        )
    return EvidenceVerdict(
        id="insurance",
        grade=Grade.CAUTION,
        status_label="확인 필요",
        detail_text=(
            "등기부만으로는 보증보험에 들 수 있는지 알 수 없어요. "
            "보증기관에 직접 확인해 주세요"
        ),
        source_text=_SRC_INSURANCE,
        facts={"disqualify_signals": []},
    )


def _judge_blacklist(extract: RegistryExtract, entries: list[dict]) -> EvidenceVerdict:
    owner_names = [o.name.strip() for o in extract.current_owners if o.name and o.name.strip()]

    if not owner_names:
        return EvidenceVerdict(
            id="blacklist",
            grade=Grade.CAUTION,
            status_label="확인 필요",
            detail_text="집주인 이름을 읽지 못해 명단과 맞춰보지 못했어요",
            source_text=_SRC_BLACKLIST,
            facts={"matched": [], "list_size": len(entries)},
        )
    if not entries:
        return EvidenceVerdict(
            id="blacklist",
            grade=Grade.CAUTION,
            status_label=BLACKLIST_PENDING_LABEL,
            detail_text=(
                "악성임대인 명단과 아직 맞춰보지 못했어요(자료 준비 중) — "
                "안심전세포털에서 직접 확인해 주세요"
            ),
            source_text=_SRC_BLACKLIST,
            facts={"matched": [], "list_size": 0},
        )

    # ⚠ 맞춰보기는 실명으로 하되(서버가 받은 명단은 이름 열쇠로만 있다 — blacklist_source), 리포트(저장됨)·
    #   설명 재료에는 **가린 이름만** 남긴다(2026-10-21 개인정보). 사용자는 자기 사진에서 전체 이름을 볼 수 있다.
    from . import blacklist_source

    matched = blacklist_source.match(owner_names, entries)
    if matched:
        # 동명이인 가능성 때문에 '위험' 단정 대신 강한 '확인 필요' + 직접 확인 유도
        return EvidenceVerdict(
            id="blacklist",
            grade=Grade.CAUTION,
            status_label="명단 일치 · 직접 확인 필요",
            detail_text=(
                f"공개 명단에 같은 이름이 있어요: {', '.join(matched)}. "
                "이름만 같은 다른 사람일 수 있어요(단정이 아니에요)"
            ),
            source_text=_SRC_BLACKLIST,
            facts={"matched": matched, "list_size": len(entries)},
        )
    return EvidenceVerdict(
        id="blacklist",
        grade=Grade.GOOD,
        detail_text=(
            f"공개 명단 {len(entries)}건과 맞춰봤어요. 같은 이름은 없었어요"
            " (명단에 없다고 안심할 수는 없어요)"
        ),
        source_text=_SRC_BLACKLIST,
        facts={"matched": [], "list_size": len(entries)},
    )


def _judge_pending(extract: RegistryExtract) -> EvidenceVerdict | None:
    """'신청사건 처리중' — 등기소에 접수됐지만 아직 등기부에 적히지 않은 신청이 있다 (2026-10-31).

    출처: 등기예규 제1815호(부동산등기사항증명서 발급처리지침) 2.다.1) — 신청사건이 처리 중인 등기기록은
    첫 면 상단에 신청사건 정보를, 매 장에 '신청사건처리중'을 음영으로 표시하고, 마지막 장에 "처리 결과에 따라
    등기기록의 내용이 **접수 시로 소급해서** 변경될 수 있다"는 뜻을 적어 발급한다. 9.나.4) 열람도 같다.

    왜 '확인 필요'인가(위험도 양호도 아니다): 신청 내용이 새 근저당일 수도, 빚을 지우는 말소일 수도 있다.
    무엇인지 모르는 변화가 접수 시점부터 효력을 갖게 되므로, 확인될 때까지 돈을 보내면 안 된다 — 잔금 당일의 빈틈.
    """
    if not extract.pending_application:
        return None
    return EvidenceVerdict(
        id="pending",
        grade=Grade.CAUTION,
        status_label="확인 필요",
        detail_text=(
            "이 등기부를 뗀 날 등기소에서 처리 중인 신청이 있었어요(신청사건 처리중). "
            "그 내용은 아직 이 서류에 적혀 있지 않아요"
        ),
        source_text=_SRC_PENDING,
        action_label="무슨 신청인지 묻기",
        facts={"pending_application": True, "known_kind": None},
    )


# ── 종합 파생 ────────────────────────────────────────────────────────────────


def incomplete_reason(extract: RegistryExtract) -> str:
    """문서가 불완전한 이유 한 줄 — 사진 점검이 준 이유가 먼저, 없으면 추출이 비운 칸으로."""
    if extract.pages_incomplete_reason:
        return extract.pages_incomplete_reason
    if extract.address is None:
        return "등기부에서 주소를 읽지 못했어요"
    if not extract.current_owners:
        return "등기부에서 집주인 이름을 읽지 못했어요"
    if extract.missing_fields:
        return "등기부 일부 항목을 읽지 못했어요"
    return "등기부 쪽이 빠졌거나 잘 안 읽혔을 수 있어요"


def _doc_flags(extract: RegistryExtract) -> list[str]:
    flags: list[str] = []
    if extract.address is None:
        flags.append("주소 미추출")
    if not extract.current_owners:
        flags.append("현재 소유자 미추출")
    for key in extract.missing_fields:
        flags.append(f"{key} 항목 누락")
    if extract.pages_incomplete:
        flags.append("사진 쪽 빠짐·잘 안 읽힘")
    return flags


def _gauge(overall: Grade, evidences: list[EvidenceVerdict]) -> float:
    """gaugeProgress = 근거 점수 평균을 종합 등급 구간에 클램프 (decisions.md 2026-07-06)."""
    avg = sum(T.EVIDENCE_SCORE[e.grade] for e in evidences) / len(evidences)
    lo, hi = T.GAUGE_BANDS[overall]
    return round(min(hi, max(lo, avg)), 2)
