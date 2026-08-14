"""등기부 대조 — 기준 서류와 이번에 뗀 서류의 **항목을 그대로 맞춰본다**.

이 계층의 단 하나의 일: 계약 여정(S-11)에서 사용자가 잔금을 보내기 전에 등기부를 다시
뗐을 때, **그 사이에 무엇이 달라졌는지** 말해 주는 것이다.

지켜야 하는 경계 (CLAUDE.md 3절):
- **규칙 기반이다. LLM이 개입하지 않는다.** 문구도 값에서 결정되는 고정 문장이며,
  이 파일 밖에서 문장을 지어내지 않는다. 화면 하단 고지("AI가 판단하지 않았어요")가
  거짓말이 되지 않게 하는 것이 이 파일의 책임이다.
- **판정을 만들지 않는다.** 등급은 두 리포트가 이미 각자 규칙 엔진에서 받은 값이고,
  여기서는 **그 둘을 나란히 놓기만** 한다.
- **보수적 편향**: 못 읽은 항목은 "달라진 게 없다"가 아니라 **"대조하지 못했다"**로
  말한다. 같은 집인지 확신할 수 없으면 숫자를 아예 보여주지 않는다 — 다른 집끼리
  비교한 숫자는 틀린 결론으로 이어지고, 그 결론이 잔금을 보내게 만든다.

개인정보:
스냅샷에 **소유자 실명을 저장하지 않는다.** 비교는 프로세스마다 새로 만드는 소금(salt)을
섞은 해시로 하고, 화면에는 `김○○`만 나간다. 해시는 서버가 살아 있는 동안만 뜻이 있고
(이력 저장소도 메모리다), 소금이 매번 달라 사전 대입으로 이름을 되찾을 수 없다.
"""

from __future__ import annotations

import hashlib
import logging
import re
import secrets
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, datetime

from ..schemas.contract import CompareDoc, CompareResult, CompareRow, Report
from ..schemas.internal import Grade, RegistryExtract
from .formatting import format_won, mask_name

_log = logging.getLogger("jeonseai")

#: 이름 해시용 소금 — 프로세스마다 새로 만든다(재시작하면 옛 스냅샷도 함께 사라진다).
_SALT = secrets.token_bytes(16)

#: 등급 심각도 — 안전도가 내려갔는지 올라갔는지 판단용. `internal.Grade`와 같은 순서다.
_SEVERITY = {Grade.GOOD.value: 0, Grade.CAUTION.value: 1, Grade.DANGER.value: 2}

#: 추출 필드 → 사람이 읽는 등기 항목 이름.
FIELD_LABELS: dict[str, str] = {
    "mortgages": "근저당권",
    "jeonse_rights": "전세권",
    "lease_registrations": "임차권등기",
    "seizures": "압류",
    "provisional_seizures": "가압류",
    "provisional_dispositions": "가처분",
    "auction_commencements": "경매개시결정",
    "trust_registrations": "신탁등기",
}

#: 금액이 붙는 항목 — 상세 문구에 "채권최고액 …"을 적을 수 있는 것들.
_AMOUNT_LABELS = {
    "mortgages": "채권최고액",
    "jeonse_rights": "전세금",
    "lease_registrations": "임차보증금",
}


@dataclass(frozen=True)
class Group:
    """화면에 한 줄(카드 1장)로 나가는 대조 묶음."""

    id: str
    fields: tuple[str, ...]
    title_added: str
    title_removed: str
    title_same: str
    title_unknown: str
    subtitle: str
    empty_detail: str


#: 대조 묶음 — **사용자가 이름을 부를 수 있는 단위**로 묶는다.
#: (등기 필드 10종을 그대로 나열하면 무엇을 봐야 하는지 알 수 없다)
GROUPS: tuple[Group, ...] = (
    Group(
        id="debt",
        fields=("mortgages", "jeonse_rights", "lease_registrations"),
        title_added="새로 생긴 빚이 있어요",
        title_removed="없어진 빚이 있어요",
        title_same="빚 · 그대로예요",
        title_unknown="빚 · 대조하지 못했어요",
        subtitle="나보다 먼저 돈 받아갈 빚 (근저당권·전세권·임차권등기)",
        empty_detail="양쪽 모두 없음",
    ),
    Group(
        id="seizure",
        fields=(
            "seizures",
            "provisional_seizures",
            "provisional_dispositions",
            "auction_commencements",
            "trust_registrations",
        ),
        title_added="새로 생긴 압류·가압류가 있어요",
        title_removed="없어진 압류·가압류가 있어요",
        title_same="압류·가압류 · 그대로예요",
        title_unknown="압류·가압류 · 대조하지 못했어요",
        subtitle="압류 · 가압류 · 가처분 · 경매 · 신탁등기",
        empty_detail="양쪽 모두 없음",
    ),
)


# ── 스냅샷 ───────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Fingerprint:
    """등기 항목 1건을 견주기 위한 지문. **말소되지 않은 항목만** 만든다."""

    field: str
    label: str
    key: str
    amount: int | None
    amount_unknown: bool
    receipt_date: str | None  # 'YYYY-MM-DD' (해석 실패면 None)


@dataclass(frozen=True)
class RegistrySnapshot:
    """대조의 기준이 되는 등기부 스냅샷. 실명·주민번호는 담지 않는다."""

    report_id: str
    alias: str
    address: str | None
    unique_number: str | None
    area_sqm: float | None
    viewed_at: str | None  # 'YYYY.MM.DD'
    analyzed_at: str  # ISO 8601
    grade: str
    deposit: int
    manual_market_price: int | None
    owner_keys: tuple[str, ...]
    owner_display: str
    entries: dict[str, tuple[Fingerprint, ...]] = field(default_factory=dict)
    missing_fields: tuple[str, ...] = ()
    page_count: int = 0


def _name_key(name: str | None) -> str:
    """소유자 이름 → 비교용 해시. 실명은 어디에도 남기지 않는다."""
    normalized = re.sub(r"\s+", "", (name or "")).strip()
    if not normalized:
        return "이름없음"
    return hashlib.sha256(_SALT + normalized.encode("utf-8")).hexdigest()[:16]


def _owner_display(names: list[str]) -> str:
    """화면 표기 — `김○○`, 공동명의면 `김○○ 외 1명`."""
    masked = [mask_name(n) for n in names if (n or "").strip()]
    if not masked:
        return "이름을 읽지 못했어요"
    if len(masked) == 1:
        return masked[0]
    return f"{masked[0]} 외 {len(masked) - 1}명"


_DATE_RE = re.compile(r"(\d{4})\s*[-.년/]?\s*(\d{1,2})\s*[-.월/]?\s*(\d{1,2})")


def normalize_date(value: object) -> str | None:
    """접수일자 문자열 → 'YYYY-MM-DD'. 해석 못 하면 None (지어내지 않는다)."""
    if not isinstance(value, str):
        return None
    m = _DATE_RE.search(value.strip())
    if not m:
        return None
    year, month, day = (int(x) for x in m.groups())
    try:
        return date(year, month, day).isoformat()
    except ValueError:
        return None


def _fingerprints(extract: RegistryExtract, field_name: str) -> list[Fingerprint]:
    """말소되지 않은 항목만 지문으로 만든다 (말소 여부를 모르면 유효로 본다)."""
    out: list[Fingerprint] = []
    label = FIELD_LABELS.get(field_name, field_name)
    for item in getattr(extract, field_name, []) or []:
        if not getattr(item, "is_active", True):
            continue
        receipt = normalize_date(getattr(item, "receipt_date", None))
        amount = getattr(item, "amount", None)
        amount_unknown = bool(getattr(item, "amount_unknown", False))
        # ⚠ 지문은 **종류 · 접수일 · 금액**만으로 만든다.
        #   순위번호·등기목적을 넣었다가 뺐다: IE가 같은 서류에서도 `rank_number`를
        #   읽을 때가 있고 못 읽을 때가 있어(실측 로그의 "rank_number 있는 것 N건"),
        #   그러면 **같은 근저당이 '없어진 것 1건 + 새로 생긴 것 1건'으로 갈라져**
        #   있지도 않은 새 빚을 경고하게 된다. 셋 다 비면 종류만 남아 개수 비교가 된다.
        key = "|".join(
            [label, receipt or "", str(amount if amount is not None else "")]
        )
        out.append(
            Fingerprint(
                field=field_name,
                label=label,
                key=key,
                amount=amount,
                amount_unknown=amount_unknown,
                receipt_date=receipt,
            )
        )
    return out


def build_snapshot(
    extract: RegistryExtract,
    *,
    report: Report,
    page_count: int,
    manual_market_price: int | None,
) -> RegistrySnapshot:
    """분석이 끝난 직후, 그 추출 결과를 다음 대조의 기준으로 남긴다."""
    owner_names = [str(o.name or "") for o in extract.current_owners]
    return RegistrySnapshot(
        report_id=report.id,
        alias=report.alias,
        address=extract.address,
        unique_number=extract.unique_number,
        area_sqm=extract.exclusive_area_sqm,
        viewed_at=report.registryViewedAt,
        analyzed_at=report.analyzedAt,
        grade=report.grade,
        deposit=report.deposit,
        manual_market_price=manual_market_price,
        owner_keys=tuple(sorted(_name_key(n) for n in owner_names)),
        owner_display=_owner_display(owner_names),
        entries={
            name: tuple(_fingerprints(extract, name))
            for name in FIELD_LABELS
        },
        missing_fields=tuple(extract.missing_fields),
        page_count=page_count,
    )


# ── 같은 집인지 ──────────────────────────────────────────────────────────────

_NUM_RE = re.compile(r"\d+(?:-\d+)?")


def _digits(value: str | None) -> str:
    return re.sub(r"\D", "", value or "")


def _address_tokens(address: str | None) -> list[str]:
    """주소에서 번지·동·호 숫자만 뽑는다 — 표기가 흔들려도 남는 뼈대."""
    if not address:
        return []
    return _NUM_RE.findall(re.sub(r"\s+", "", address))


def address_relation(a: str | None, b: str | None) -> str:
    """두 주소의 관계: `same` | `different` | `unclear`.

    ⚠ **애매하면 `different`가 아니라 `unclear`다.** 표기 차이(도로명/지번, '서울'/
      '서울특별시', 동호수 유무)로 다른 집이라고 단정하면 멀쩡한 대조가 막힌다.
      반대로 확신 없이 같다고 하면 다른 집 숫자를 비교하게 된다 — 그래서 셋으로 나눈다.
    """
    if not a or not b:
        return "unclear"
    na, nb = re.sub(r"\s+", "", a), re.sub(r"\s+", "", b)
    if na == nb:
        return "same"
    ta, tb = _address_tokens(a), _address_tokens(b)
    if not ta or not tb:
        return "unclear"
    if sorted(ta) == sorted(tb):
        return "same"
    if set(ta).isdisjoint(tb):
        return "different"
    return "unclear"


def identity(base: RegistrySnapshot, cur: RegistrySnapshot) -> tuple[str, str | None]:
    """같은 집인가 — (`same` | `different` | `unclear`, 무엇으로 확인했는지)."""
    bn, cn = _digits(base.unique_number), _digits(cur.unique_number)
    if bn and cn:
        # 고유번호는 부동산마다 하나뿐이라 이것만으로 갈린다.
        return ("same" if bn == cn else "different", "고유번호")

    relation = address_relation(base.address, cur.address)
    if relation == "different":
        return ("different", "소재지")
    if relation == "same":
        # 주소가 같아도 전용면적이 다르면 다른 호실일 수 있다 (같은 지번 다세대).
        if base.area_sqm and cur.area_sqm and abs(base.area_sqm - cur.area_sqm) > 0.5:
            return ("different", "소재지·전용면적")
        return ("same", "소재지")
    return ("unclear", None)


# ── 대조 ─────────────────────────────────────────────────────────────────────


def _consume(base_items: list[Fingerprint], cur_items: list[Fingerprint]):
    """양쪽 지문을 상쇄하고 남은 것 = 새로 생긴 것 / 없어진 것."""
    base_count = Counter(f.key for f in base_items)
    cur_count = Counter(f.key for f in cur_items)

    added_keys = cur_count - base_count
    removed_keys = base_count - cur_count

    def pick(items: list[Fingerprint], keys: Counter) -> list[Fingerprint]:
        remaining = Counter(keys)
        picked: list[Fingerprint] = []
        for f in items:
            if remaining[f.key] > 0:
                remaining[f.key] -= 1
                picked.append(f)
        return picked

    return pick(cur_items, added_keys), pick(base_items, removed_keys)


def _summary(items: list[Fingerprint]) -> str:
    """`근저당권 1건 · 전세권 1건` 형태의 앞머리."""
    counts = Counter(f.label for f in items)
    return " · ".join(f"{label} {n}건" for label, n in counts.items())


def _detail(items: list[Fingerprint]) -> str:
    """상세 박스 — 첫 줄은 **건수와 금액**, 다음 줄부터 접수일.

    화면이 첫 줄만 굵게 그리므로(시안), "무엇이 얼마나"가 한 줄에 있어야 한다.
    금액을 못 읽은 항목이 있으면 그 사실을 마지막 줄에 남긴다 — 0으로 치지 않는다.
    """
    head = _summary(items)
    amounts = [f.amount for f in items if f.amount is not None]
    if amounts:
        fields = {f.field for f in items if f.amount is not None}
        label = (
            _AMOUNT_LABELS.get(next(iter(fields)), "금액")
            if len(fields) == 1
            else "금액 합계"
        )
        head = f"{head} · {label} {format_won(sum(amounts))}"

    lines = [head]
    for f in items:
        if f.receipt_date:
            y, m, d = f.receipt_date.split("-")
            lines.append(f"{y}년 {int(m)}월 {int(d)}일 접수")
    if any(f.amount_unknown for f in items):
        lines.append("금액을 읽지 못한 항목이 있어요 — 등기부 원본을 확인하세요")
    return "\n".join(lines)


def _group_rows(
    base: RegistrySnapshot, cur: RegistrySnapshot
) -> tuple[list[CompareRow], int, set[str]]:
    """묶음별 대조 → (행 목록, 대조한 묶음 수, 못 본 묶음 id)."""
    rows: list[CompareRow] = []
    compared = 0
    unknown: set[str] = set()

    for group in GROUPS:
        missing_here = [f for f in group.fields if f in cur.missing_fields]
        missing_base = [f for f in group.fields if f in base.missing_fields]
        if missing_here or missing_base:
            unknown.add(group.id)
            if missing_here:
                subtitle = (
                    f"이번에 올린 사진 {cur.page_count}장에서 그 쪽을 찾지 못했어요. "
                    "빠진 쪽에 내용이 있을 수 있어요"
                )
            else:
                subtitle = "기준이 된 서류에서 그 쪽을 읽지 못해 견줄 수 없어요"
            rows.append(
                CompareRow(
                    kind="unknown",
                    tone="caution",
                    marker="?",
                    title=group.title_unknown,
                    subtitle=subtitle,
                    action="recapture" if missing_here else None,
                    actionLabel="빠진 쪽 찍어서 올리기" if missing_here else None,
                )
            )
            continue

        compared += 1
        base_items = [f for name in group.fields for f in base.entries.get(name, ())]
        cur_items = [f for name in group.fields for f in cur.entries.get(name, ())]
        added, removed = _consume(base_items, cur_items)

        if added:
            rows.append(
                CompareRow(
                    kind="added",
                    tone="danger",
                    marker="+",
                    title=group.title_added,
                    subtitle=group.subtitle,
                    detail=_detail(added),
                    receiptDate=min(
                        (f.receipt_date for f in added if f.receipt_date), default=None
                    ),
                )
            )
        if removed:
            rows.append(
                CompareRow(
                    kind="removed",
                    tone="neutral",
                    marker="−",
                    title=group.title_removed,
                    # 없어진 것도 '안전해졌다'로 말하지 않는다 — 말소 여부는 등기부를 봐야 안다.
                    subtitle="기준 서류에 있던 항목이 이번 서류에는 없어요",
                    detail=_detail(removed),
                )
            )
        if not added and not removed:
            detail = _summary(cur_items) + " · 변동 없음" if cur_items else group.empty_detail
            rows.append(
                CompareRow(
                    kind="same",
                    tone="neutral",
                    marker="=",
                    title=group.title_same,
                    detail=detail,
                )
            )

    return rows, compared, unknown


def _owner_row(base: RegistrySnapshot, cur: RegistrySnapshot) -> tuple[CompareRow, bool]:
    """집주인 행 → (행, 대조했는가)."""
    if "current_owners" in cur.missing_fields or not cur.owner_keys:
        return (
            CompareRow(
                kind="unknown",
                tone="caution",
                marker="?",
                title="집주인 · 대조하지 못했어요",
                subtitle=f"이번에 올린 사진 {cur.page_count}장에서 소유자 칸을 찾지 못했어요",
                action="recapture",
                actionLabel="빠진 쪽 찍어서 올리기",
            ),
            False,
        )
    if base.owner_keys != cur.owner_keys:
        return (
            CompareRow(
                kind="changed",
                tone="danger",
                marker="≠",
                title="집주인이 달라요",
                subtitle="계약 상대가 등기부상 소유자와 같은지 다시 확인하세요",
                detail=f"기준 {base.owner_display} → 이번 {cur.owner_display}",
            ),
            True,
        )
    return (
        CompareRow(
            kind="same",
            tone="neutral",
            marker="=",
            title="집주인 · 그대로예요",
            detail=f"{cur.owner_display} · 변동 없음",
        ),
        True,
    )


def _grade_row(
    base: RegistrySnapshot, cur: RegistrySnapshot, *, debt_unknown: bool
) -> tuple[CompareRow, bool]:
    """안전도 행 → (행, 대조했는가). 빚을 못 봤으면 등급도 견주지 않는다."""
    if debt_unknown:
        return (
            CompareRow(
                kind="unknown",
                tone="caution",
                marker="?",
                title="안전도 · 대조하지 못했어요",
                subtitle="빚을 못 봐서 등급을 다시 매길 수 없어요",
            ),
            False,
        )
    before, after = base.grade, cur.grade
    if before == after:
        return (
            CompareRow(
                kind="same",
                tone="neutral",
                marker="=",
                title="안전도 · 그대로예요",
                detail=f"{after} · 변동 없음",
                gradeBefore=before,
                gradeAfter=after,
            ),
            True,
        )
    worse = _SEVERITY.get(after, 1) > _SEVERITY.get(before, 1)
    return (
        CompareRow(
            kind="grade",
            tone="danger" if worse else "neutral",
            marker="!" if worse else "=",
            title="안전도가 내려갔어요" if worse else "안전도가 올라갔어요",
            subtitle=None if worse else "그래도 잔금 직전에는 한 번 더 확인하세요",
            gradeBefore=before,
            gradeAfter=after,
        ),
        True,
    )


def _doc(snapshot: RegistrySnapshot) -> CompareDoc:
    return CompareDoc(
        reportId=snapshot.report_id,
        alias=snapshot.alias,
        address=snapshot.address,
        viewedAt=snapshot.viewed_at,
        analyzedAt=snapshot.analyzed_at,
        grade=snapshot.grade,
        pageCount=snapshot.page_count,
    )


def _days_between(base: RegistrySnapshot, cur: RegistrySnapshot) -> int | None:
    """두 서류를 뗀 날의 차이(일). 한쪽이라도 못 읽었으면 None — 계산하지 않는다."""
    def parse(value: str | None) -> date | None:
        if not value:
            return None
        try:
            return datetime.strptime(value.strip(), "%Y.%m.%d").date()
        except ValueError:
            return None

    a, b = parse(base.viewed_at), parse(cur.viewed_at)
    if a is None or b is None:
        return None
    return abs((b - a).days)


def no_baseline_result(report: Report) -> CompareResult:
    """기준이 없어 대조할 수 없을 때 — **비난이 아니라 초대 톤**(S-11 6c).

    사진을 받기 전에 부르는 화면이다. 찍게 해 놓고 마지막에 못 한다고 말하지 않는다.
    """
    viewed = report.registryViewedAt
    subject = f"{viewed} 등기부는" if viewed else "이 등기부는"
    return CompareResult(
        result="no_baseline",
        headline="이 분석은 비교 기준으로 쓸 수 없어요",
        subline=(
            f"{subject} 비교에 필요한 정보가 남아 있지 않아요. "
            "지금 한 번 떼어 기준을 만들어 두면, 다음에 뗄 때부터 달라진 점을 알려드릴 수 있어요."
        ),
        baseline=CompareDoc(
            reportId=report.id,
            alias=report.alias,
            address=report.address,
            viewedAt=viewed,
            analyzedAt=report.analyzedAt,
            grade=report.grade,
        ),
        current=CompareDoc(),
        totalCount=0,
        comparedCount=0,
    )


def different_property_result(
    base: RegistrySnapshot, cur: RegistrySnapshot, *, basis: str | None
) -> CompareResult:
    """다른 집이라 대조를 **차단**한다 — 숫자를 아예 내보내지 않는다 (S-11 6d)."""
    return CompareResult(
        result="different_property",
        headline="같은 집이 아닌 것 같아요",
        subline=(
            "이번에 올린 등기부는 먼저 분석한 집과 다른 집이에요. "
            "대조는 같은 집끼리만 할 수 있어요."
        ),
        baseline=_doc(base),
        # ⚠ 이번 서류는 **날짜만** 보낸다. 등급·주소를 실으면 화면이 그것을 그리게 되고,
        #   기준 매물의 보증금으로 계산된 등급이라 그 집의 판정으로 읽히면 안 된다.
        current=CompareDoc(viewedAt=cur.viewed_at, pageCount=cur.page_count),
        identityBasis=basis,
        notices=[
            f"{basis or '소재지'}가 기준과 달라요"
            if basis
            else "같은 집인지 확인할 수 없었어요",
            "다른 집끼리 숫자를 비교하면 틀린 결론이 나와서, 대조 결과는 보여드리지 않아요",
        ],
        totalCount=0,
        comparedCount=0,
    )


def compare(base: RegistrySnapshot, cur: RegistrySnapshot) -> CompareResult:
    """두 스냅샷을 맞춰본다. **여기서 새 판정이 생기지 않는다.**"""
    relation, basis = identity(base, cur)
    if relation == "different":
        return different_property_result(base, cur, basis=basis)

    notices: list[str] = []

    owner_row, owner_ok = _owner_row(base, cur)
    group_rows, group_compared, unknown_groups = _group_rows(base, cur)
    grade_row, grade_ok = _grade_row(base, cur, debt_unknown="debt" in unknown_groups)

    rows = [owner_row, *group_rows, grade_row]
    total = 2 + len(GROUPS)  # 집주인 + 묶음들 + 안전도
    compared = int(owner_ok) + group_compared + int(grade_ok)
    unknown_count = total - compared

    # 같은 집인지 확인하지 못한 것도 **대조하지 못한 것**이다. 개수(위 4가지)와는 별개로
    # 결과 자체를 '일부 대조 불가'로 떨어뜨린다 — 확인 못 한 채 "그대로예요"만 보이면
    # 사용자는 이 서류가 그 집 것이라고 믿게 된다.
    identity_unclear = relation == "unclear"
    if identity_unclear:
        notices.append(
            "같은 집인지는 확인하지 못했어요 — 고유번호가 보이는 1쪽을 함께 올리면 확인할 수 있어요"
        )
    elif basis == "소재지":
        notices.append("같은 집인지 소재지로 확인했어요 (고유번호는 두 서류에서 읽지 못했어요)")

    # 심각한 것부터 — 못 본 것은 '그대로'보다 앞에 온다(침묵이 안심으로 읽히지 않게).
    order = {"added": 0, "changed": 1, "removed": 2, "grade": 3, "unknown": 4, "same": 5}
    rows.sort(key=lambda r: order.get(r.kind, 9))

    changed_count = sum(1 for r in rows if r.kind in ("added", "removed", "changed", "grade"))
    days = _days_between(base, cur)

    if unknown_count or identity_unclear:
        result = "partial"
        headline = "일부는 대조하지 못했어요"
        subline = f"{total}가지 중 {compared}가지만 맞춰봤어요"
    elif changed_count:
        result = "changed"
        headline = f"달라진 점이 {changed_count}가지 있어요"
        subline = f"{total}가지를 모두 맞춰봤어요"
    else:
        result = "changed"
        headline = "달라진 점은 없었어요"
        subline = f"{total}가지를 모두 맞춰봤어요 · 그래도 잔금 직전에 한 번 더 확인하세요"

    if days is not None:
        subline = f"{subline} · 두 서류는 {days}일 차이"

    _log.info(
        f"[대조] {result} — 기준 {base.report_id}({base.viewed_at}) ↔ 이번 {cur.report_id}"
        f"({cur.viewed_at}) | 달라진 항목 {changed_count} / 못 본 항목 {unknown_count}"
        f" | 같은 집 확인: {basis or '못 함'}"
    )

    return CompareResult(
        result=result,
        headline=headline,
        subline=subline,
        baseline=_doc(base),
        current=_doc(cur),
        daysBetween=days,
        comparedCount=compared,
        totalCount=total,
        rows=rows,
        notices=notices,
        identityBasis=basis,
        newReportId=cur.report_id,
    )
