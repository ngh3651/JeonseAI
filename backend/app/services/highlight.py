"""IE 결과 ↔ OCR 좌표 매칭 — 사진 위에 무엇을 어디에 표시할지 정한다.

⚠ **표시 전용이다.** 여기서 나온 어떤 값도 위험 등급·점수·근거 카드를 바꾸지 않는다.
  규칙 엔진은 IE 결과만 보고 이미 판정을 끝냈고, 이 모듈은 그 판정 결과 중 "사진에서
  가리킬 수 있는 것"만 골라 좌표를 붙인다.

설계 원칙 (지시서 + risk-scoring 규칙의 보수적 편향과 같은 방향):
1. **부분 매칭 금지.** 앵커가 하나라도 안 맞으면 좌표 없음으로 둔다.
   틀린 위치에 칠하는 것보다 안 칠하는 것이 낫다.
   단 **금액 칸이 원래 없는 항목 유형**(압류·경매개시결정·신탁)은 예외다 — 2026-07-28.
   자세한 근거는 아래 "앵커 개수를 항목 유형에 따라 나눈 이유" 참고.
2. **말소된 항목에는 절대 좌표를 내보내지 않는다.** 사용자가 "이미 없어진 빚"을
   현재 위험으로 오해하는 것이 이 기능의 최악의 오류다.
3. **실패는 조용히 넘어가되 로그에는 이유를 남긴다.** 아침에 형광펜이 안 보일 때
   (a)OCR 실패 (b)매칭 실패 (c)앱 렌더 실패 중 무엇인지 로그만으로 가려야 한다.
4. **로그에 개인정보를 남기지 않는다.** 실명은 `김○○`으로 마스킹하고 좌표·개수만 남긴다.

매칭 대상은 **IE 결과가 기준**이다(OCR이 본 것 전부가 아니라). 규칙 엔진이 판정에 쓴
항목만 표시해야 리포트 내용과 사진 표시가 어긋나지 않는다. 예를 들어 갑구에 이름이
5명 보여도 IE의 `current_owners`가 2명이면 **현재 소유자 2명만** 칠한다 — 이미 지분을
넘긴 옛 소유자를 칠하면 사용자가 그 사람을 임대인으로 오인할 수 있다.

예외는 **OCR 전용 3종**(토지 별도등기·공동담보목록·신청사건 처리중)이다. IE 스키마에
그 필드가 없어 IE 기준으로 삼을 대상이 없다. 이들은 종이에 인쇄된 문구를 그대로
가리키기만 하고, **판정에는 어떤 영향도 주지 않는다**(인터뷰 §R4는 판정 승격을 권고하지만
등급을 바꾸려면 권위 출처 + decisions.md 선기록이 필요하다 — 2026-07-28 보류).

────────────────────────────────────────────────────────────────────────────
앵커 개수를 항목 유형에 따라 나눈 이유 (2026-07-28, 실측 근거)

"부분 매칭 금지"의 **원래 이유**는 "같은 금액이 여러 줄에 나와 항목을 지목할 수 없다"였다
(말소분과 유효분이 같은 금액을 갖는다). 그런데 **금액 칸이 아예 없는 유형**은 그 위험이
성립하지 않는다.

실측(`out/ocr_page_*.json`, 크레딧 0원):
- 갑구 압류·가압류 행의 순위번호는 `find_rank()`로 **6/6(100%)** 잡힌다.
- 청구금액은 **3/6**만 있다. 있는 3건은 전부 **가압류**이고, **압류에는 문서상 청구금액 칸이
  원래 없다**(세금 체납 등으로 인한 압류는 금액을 적지 않는다).
- 등기목적 키워드는 활성 항목 **8/8이 순위번호와 같은 줄**에 있다.

→ 금액 칸이 있는 유형(근저당·전세권·가압류·임차권)은 **3앵커**(순위번호+등기목적+금액),
  금액 칸이 없는 유형(압류·경매개시결정·신탁)은 **2앵커**(순위번호+등기목적).
  두 앵커 모두 **같은 줄**에 있을 것을 요구하는 조건은 그대로다.
────────────────────────────────────────────────────────────────────────────
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field, replace

from ..schemas.contract import Highlight, HighlightBox
from ..schemas.internal import MoneyEntry, RegistryEntry, RegistryExtract, parse_amount
from .cross_check import CrossCheck, to_notes as cross_check_notes
from .formatting import eun_neun, format_won, mask_name  # mask_name: 2026-08-05 formatting으로 이관(re-export)
from .ocr import OcrResult
from .ocr_layout import (
    DocumentCheck,
    Line,
    OcrPage,
    RegistryItem,
    build_items,
    check_document,
)
# 'N번○○말소' 대상 순위를 읽는 정규식. **한 벌만 둔다** — 여기서 다시 쓰면 두 곳이
# 갈라져 "말소를 보는 눈"이 경로마다 달라진다(그 갈림이 바로 D17의 사고였다).
from .ocr_layout import _CANCEL_TARGET as CANCEL_TARGET_RE

_log = logging.getLogger("jeonseai")

# 같은 종류를 몇 개까지 칠할 것인가 (2026-07-28 A-3).
#
# 표시 종류가 3개(이름·근저당·전세권)에서 15종(`len(_SPECS)`)으로 늘면서, 압류가 8건인 등기부에서는
# 갑구가 통째로 주황 띠가 된다(findings §9.5 "[보류] 표시 종류가 늘면 줄무늬가 될 수 있다").
# 형광펜의 목적은 "여기를 보세요"인데 다 칠하면 아무 데도 가리키지 않는 것과 같다.
#
# ⚠ 이건 **표시 상한이지 판정 상한이 아니다.** 잘린 항목도 리포트의 '근거 살펴보기'에는 전부
#   반영돼 있고, 잘렸다는 사실을 `checkedNotes`로 사용자에게 반드시 말한다(침묵 금지).
MAX_MARKS_PER_KIND = 5

# ── 화면에서 끈 표시 종류 — **지우지 않고 끈다** ──────────────────────────────
#
# [D16 · 2026-08-14] `area`(전용면적)를 껐다.
#
# 왜: 전용면적은 위험이 아니라 '대조할 곳'인데, 실기기에서 표제부 한복판의
# `39.52㎡`에 형광펜·번호 뱃지·하단 카드가 전부 붙어 같은 화면의 위험 표시와
# 시선을 나눠 가졌다. 게다가 안내 문구("계약서에 적힌 면적과 같은 숫자인지
# 확인하세요")는 **계약서가 아직 없는 사람**에게는 그 자리에서 할 수 없는 일이다.
# 가리키는 곳을 줄여 따져볼 곳에 시선이 모이게 한다.
#
# ⚠ **매칭을 없앤 것이 아니다.** `_match_area`와 2026-07-29 진단(A절)에서 고친
#   ASCII `m2` 단위 규칙은 그대로 살아 있고, 그 규칙의 테스트도 그대로다.
#   여기서는 **매칭에 성공한 후보를 표시 목록에서 뺄 뿐**이다.
# ⚠ 되돌리는 법: 이 집합을 `frozenset()`으로 비우면 끝이다. 다른 곳은 손대지 않았다.
# ⚠ 뱃지 번호는 이 필터 **뒤에** 매겨진다(아래 ⑤) — ②가 비어 ①③④…가 되지 않는다.
_DISABLED_KINDS: frozenset[str] = frozenset({"area"})


def _rx(pattern: str) -> re.Pattern[str]:
    return re.compile(pattern)


# ══════════════════════════════════════════════════════════════════════════════
# 표시 종류 정의 — 새 종류는 여기 한 줄만 추가한다
# ══════════════════════════════════════════════════════════════════════════════
#
# `order` = **등기부를 읽는 순서**다. 카드 캐러셀·뱃지 번호가 이 순서를 따르므로,
# 순서 자체가 "등기부는 이렇게 읽는 겁니다"라는 가이드가 된다 (2026-07-28 A-3.3).
#   표제부(주소·면적·별도등기) → 표지(서류 종류) → 갑구(소유자 → 압류 계열)
#   → 을구(근저당 → 전세권 → 임차권 → 공동담보) → 문서 상태(신청사건) → 꼬리말(열람일)
#
# 문구 원칙 (2026-07-27 페르소나 리뷰 반영, 새 종류에도 그대로 적용):
# - 사용자가 **직접 할 수 있는 행동**으로 끝낸다. "은행에서 확인하세요" 같은, 남의 대출
#   잔액을 은행이 알려줄 리 없는 지시는 "이 앱은 현실을 모른다"로 읽혀 경고 전체를 무시하게 한다.
# - 어려운 말은 **쉬운 말 먼저, 괄호에 원래 말**.
# - **행동을 첫 문장에** 둔다 (2026-07-28 페르소나 2인 지적). 카드 캐러셀은 `body`의
#   **첫 문장만** 요약으로 보여주므로(`analysis_report.dart`), 상황 설명이 먼저 오면
#   카드에는 무서운 사실만 남고 할 일은 시트를 열어야 보인다 —
#   "심장이 내려앉았는데 뭘 하라는 말이 없어요"(지수).
# - 화면에 없는 이름으로 안내하지 않는다. 근거 목록의 실제 화면 제목은 **'근거 살펴보기'**다
#   ("리포트의 '근거 살펴보기'"라고 하면 사용자가 그게 어디인지 못 찾는다).
# - 법적 단정("전원 동의가 필요합니다") 대신 권고형 — 판정이 아닌 조언 계층이며,
#   권위 출처 없이 단정하면 앱 전체 신뢰가 흔들린다(risk-scoring 3절 톤과도 일치).
# ⚠ 전부 **고정 템플릿**이다. LLM을 개입시키지 않는다(결정 ④).

_SRC_HEADER = "등기부 표제부 — 이 앱이 사진에서 직접 찾은 위치"
_SRC_COVER = "등기부 표지 — 이 앱이 사진에서 직접 찾은 위치"
_SRC_GAP = "등기부 갑구 — 이 앱이 사진에서 직접 찾은 위치"
_SRC_EUL = "등기부 을구 — 이 앱이 사진에서 직접 찾은 위치"
_SRC_FOOTER = "등기부 꼬리말 — 이 앱이 사진에서 직접 찾은 위치"


@dataclass(frozen=True)
class MarkSpec:
    """표시 1종의 문구·순서·출처. 좌표를 어떻게 찾는지는 아래 매칭 규칙이 정한다."""

    kind: str
    order: int
    body: str
    source: str


_SPECS: dict[str, MarkSpec] = {
    # ── 표제부 ────────────────────────────────────────────────────────────
    "address": MarkSpec(
        kind="address",
        order=10,
        body=(
            "계약서(아직 없다면 중개사가 보여준 매물 정보)에 적힌 주소, 그리고 실제로 "
            "보러 간 집의 현관 호수가 이 주소와 글자 하나까지 같은지 확인하세요.\n"
            "하나라도 다르면 다른 집의 등기부예요 — 그날은 서명하지 말고, 이 호수의 "
            "등기부를 다시 떼어 달라고 하세요.\n"
            "특히 빌라·다세대주택은 같은 건물에 비슷한 호수가 많아 서류가 바뀌기 쉬워요."
        ),
        source=_SRC_HEADER,
    ),
    "area": MarkSpec(
        kind="area",
        order=20,
        body=(
            "계약서(아직 없다면 매물 정보)에 적힌 면적과 같은 숫자인지 확인하세요. "
            "다르면 다른 호수의 등기부일 수 있어요.\n"
            "광고에 나오는 공급면적(분양면적)과 여기 적힌 전용면적은 원래 다른 숫자예요. "
            "계약서와 맞춰볼 것은 이 전용면적이에요."
        ),
        source=_SRC_HEADER,
    ),
    "separate_land": MarkSpec(
        kind="separate_land",
        order=30,
        body=(
            "중개사에게 '토지 등기부도 함께 보여 달라'고 해서, 땅에 얼마의 빚이 "
            "있는지 확인하세요.\n"
            "건물과 별개로 땅에 따로 걸린 빚이 있다는 표시예요(토지 별도등기). "
            "그 내용은 이 등기부에 나오지 않아요. 금액을 알게 되면 이 앱에 함께 올려 "
            "다시 분석해 보세요."
        ),
        source=_SRC_HEADER,
    ),
    # ── 표지 ──────────────────────────────────────────────────────────────
    "doc_title": MarkSpec(
        kind="doc_title",
        order=40,
        body=(
            "여기에 '말소사항 포함'이라고 적혀 있는지 보세요. 다르게 적혀 있다면 "
            "중개사에게 '말소사항 포함 등기사항전부증명서'로 다시 떼어 달라고 하세요.\n"
            "'요약'이나 '현재 유효사항'만 있는 서류에는 지워진 옛 기록이 빠져 있어요. "
            "그러면 이 분석에도 빠지는 게 생겨 위험을 놓칠 수 있어요."
        ),
        source=_SRC_COVER,
    ),
    # ── 갑구 ──────────────────────────────────────────────────────────────
    "owner": MarkSpec(kind="owner", order=50, body="", source=_SRC_GAP),  # body는 개인/법인 분기
    "provisional_seizure": MarkSpec(
        kind="provisional_seizure",
        order=60,
        body=(
            "이 가압류가 언제 풀리는지 중개사에게 확인하고, 풀린 것을 등기부에서 "
            "직접 확인한 뒤에 계약하세요.\n"
            "집주인에게 돈을 받을 사람이 이 집을 묶어 둔 상태예요(가압류). "
            "재판 결과에 따라 집이 경매로 넘어갈 수 있어요."
        ),
        source=_SRC_GAP,
    ),
    "seizure": MarkSpec(
        kind="seizure",
        order=61,
        body=(
            "이 압류가 풀린 것을 등기부에서 직접 확인한 뒤에 계약하세요. 아직 "
            "풀리지 않았다면 계약을 미루는 것이 안전해요.\n"
            "세금이나 빚을 갚지 않아 국가·기관이 이 집을 묶어 둔 상태예요(압류). "
            "그대로 두면 나라가 파는 경매(공매)나 일반 경매로 넘어갈 수 있어요.\n"
            "등기부는 인터넷등기소나 가까운 등기소에서 누구나 다시 뗄 수 있어요."
        ),
        source=_SRC_GAP,
    ),
    "auction": MarkSpec(
        kind="auction",
        order=62,
        body=(
            "이 집은 지금 계약하면 안 돼요. 기록이 정리된 것을 등기부에서 확인하기 "
            "전에는 계약금을 보내지 마세요.\n"
            "경매가 이미 시작됐다는 기록이에요(경매개시결정). 경매로 넘어가면 보증금을 "
            "돌려받지 못할 수 있어요.\n"
            "중개사에게 이 기록이 어떻게 정리되는지 물어보고, 답이 분명하지 않으면 "
            "이 매물은 넘기는 것이 안전해요."
        ),
        source=_SRC_GAP,
    ),
    "trust": MarkSpec(
        kind="trust",
        order=63,
        body=(
            "중개사에게 '신탁원부(신탁 내용이 적힌 서류)'를 보여 달라고 하세요. "
            "거기에 누구와 계약해야 하는지, 신탁회사 동의가 필요한지가 적혀 있어요.\n"
            "등기부상 집 주인이 신탁회사로 되어 있어요(신탁등기). 이때는 등기부에 적힌 "
            "집주인이 아니라 신탁회사가 계약 상대인 경우가 많아요.\n"
            "확인 전에는 계약금을 보내지 마세요. 동의 없이 한 계약은 보증금을 "
            "돌려받지 못할 수 있어요."
        ),
        source=_SRC_GAP,
    ),
    # ── 을구 ──────────────────────────────────────────────────────────────
    "mortgage": MarkSpec(
        kind="mortgage",
        order=70,
        body=(
            "집이 경매로 넘어가면, 이 돈을 빌려준 곳이 내 보증금보다 먼저 돈을 가져갑니다. "
            "그만큼 내가 못 받을 수 있어요.\n"
            "등기부에 적힌 이 금액은 실제 빚보다 크게 잡아 둔 한도(채권최고액)예요. "
            "지금 남은 빚이 얼마인지는 중개사에게 '집주인 대출 잔액 확인서(부채증명원)'를 요청해 확인하세요."
        ),
        source=_SRC_EUL,
    ),
    "jeonse": MarkSpec(
        kind="jeonse",
        order=71,
        body=(
            "나보다 먼저 들어온 세입자가 이 집에 권리를 걸어 둔 것입니다. "
            "집이 경매로 넘어가면 그 사람이 내 보증금보다 먼저 돈을 가져갑니다.\n"
            "이 전세권이 언제 없어지는지 중개사에게 확인하고, 없어진 뒤에 계약하는 것이 안전합니다."
        ),
        source=_SRC_EUL,
    ),
    "lease_registration": MarkSpec(
        kind="lease_registration",
        order=72,
        body=(
            "그 보증금이 지금 정리됐는지 중개사에게 확인하고, 정리된 것을 등기부에서 "
            "직접 확인한 뒤에 계약하세요.\n"
            "전에 살던 세입자가 보증금을 돌려받지 못해 법원에 신청해 남긴 기록이에요"
            "(임차권등기명령). 이 집에서 보증금 사고가 실제로 있었다는 뜻이에요."
        ),
        source=_SRC_EUL,
    ),
    "joint_collateral": MarkSpec(
        kind="joint_collateral",
        order=73,
        body=(
            "중개사에게 '공동담보목록'을 보여 달라고 해서 몇 채가 함께 묶여 있는지 "
            "확인하세요.\n"
            "이 집 하나만이 아니라 여러 집이 함께 담보로 묶여 있다는 표시예요(공동담보). "
            "묶인 집이 많을수록 다른 집 문제로 이 집까지 넘어갈 위험이 커져요.\n"
            "채수를 알게 되면 이 앱에 다시 올려 분석해 보세요."
        ),
        source=_SRC_EUL,
    ),
    # ── 문서 상태 · 꼬리말 ────────────────────────────────────────────────
    "pending_application": MarkSpec(
        kind="pending_application",
        order=80,
        body=(
            "무슨 신청이 진행 중인지 중개사에게 확인하고, 처리가 끝난 뒤 등기부를 "
            "다시 떼어 이 앱에 올려 보세요.\n"
            "등기부에 뭔가를 새로 적어 달라는 신청이 접수돼 처리 중이에요(신청사건). "
            "이 종이에 아직 안 보이는 변화가 있다는 뜻이라, **이번 분석은 그 변화를 "
            "반영하지 못했어요.**"
        ),
        source=_SRC_COVER,
    ),
    "viewed_at": MarkSpec(
        kind="viewed_at",
        order=90,
        body=(
            "계약서에 서명하는 날, 그리고 **잔금을 보내는 날 아침**에 등기부를 다시 떼어 "
            "이 날짜가 그날인지 확인하세요.\n"
            "등기부는 뗀 그 순간의 사진이에요. 그 뒤에 새로 잡힌 빚은 이 종이에 없어요 — "
            "계약 직전·잔금 직전에 빚을 새로 잡는 수법이 실제로 있어요.\n"
            "잔금을 보낸 당일에 전입신고와 확정일자까지 마쳐야 보증금이 보호돼요."
        ),
        source=_SRC_FOOTER,
    ),
}

# 소유자 문구 (개인/법인 분기) — 기존 그대로. `_SPECS["owner"].body`는 쓰지 않는다.
_OWNER_BODY = (
    "계약서에 적힌 집주인(임대인) 이름, 그리고 계약 자리에 나온 사람의 신분증이 "
    "이 이름과 같은지 확인하세요. 하나라도 다르면 그날은 서명하지 마세요.\n"
    "대리인이 나왔다면 집주인의 위임장과 인감증명서를 함께 보여 달라고 하세요."
)

# 집주인이 법인일 때는 위 문구를 그대로 쓰면 **틀린 지시**가 된다.
# 계약 자리에 나오는 사람은 대표이사·직원이고, 그 사람 신분증에 '주식회사○○'이
# 적혀 있을 리가 없다. 그대로 따르면 정상 계약을 이상하다고 판단하거나,
# 반대로 확인 자체를 포기한다(2026-07-27 실호출: 소유자가 '주식회사가나다'인데
# 개인용 문구가 나갔다).
#
# 법인 여부는 **OCR이 읽은 등록번호 뒤 7자리**로 가른다 — 마스킹(`900101-*******`)이면
# 개인, 숫자(`110111-0000000`)면 법인이다(docs/ocr-highlight-findings.md §2.8).
# IE의 `current_owners`에는 이름·지분만 있어 법인 여부를 알 수 없다.
#
# ⚠ 고정 템플릿이다. LLM을 개입시키지 않는다(결정 ④). 표시 계층이라 등급·점수와 무관하다.
_OWNER_BODY_CORP = (
    "집주인이 사람이 아니라 회사(법인)예요. 계약 자리에 나오는 사람은 대표이사나 직원이라, "
    "그 사람 신분증에 이 이름이 적혀 있지 않은 것이 정상이에요.\n"
    "회사의 등기부(법인 등기사항전부증명서)를 보여 달라고 해서, 나온 사람이 거기 적힌 "
    "대표이사와 같은 사람인지 확인하세요.\n"
    "대표이사가 아닌 사람이 나왔다면 회사의 법인인감증명서와 위임장을 함께 보여 달라고 하고, "
    "계약서에 찍는 도장이 그 법인인감과 같은지도 확인하세요."
)
_OWNER_SOURCE = _SRC_GAP


# ══════════════════════════════════════════════════════════════════════════════
# 매칭 규칙 표
# ══════════════════════════════════════════════════════════════════════════════


@dataclass(frozen=True)
class RankedRule:
    """순위번호를 앵커로 쓰는 표 항목 (갑구·을구).

    `amount_attr`가 None이면 **2앵커**(순위번호+등기목적), 아니면 **3앵커**(+금액)다.
    """

    kind: str
    section: str
    purpose: re.Pattern[str]
    ie_field: str  # RegistryExtract 속성 이름
    amount_attr: str | None
    label: str  # 카드 제목 접두

    @property
    def anchors(self) -> int:
        return 3 if self.amount_attr else 2


# ⚠ `압류`는 `가압류`의 부분 문자열이다. 부정 전방탐색이 없으면 가압류 행이 압류로도
#   잡혀 같은 자리에 표시가 두 개 생긴다(실측: IE도 같은 순위번호를 두 배열에 중복 배정한다).
_RANKED_RULES: tuple[RankedRule, ...] = (
    RankedRule("mortgage", "을구", _rx(r"근저당권설정"), "mortgages", "amount", "집에 잡힌 빚 (근저당권)"),
    RankedRule("jeonse", "을구", _rx(r"전세권설정"), "jeonse_rights", "amount", "다른 사람의 전세권"),
    RankedRule(
        "lease_registration", "을구", _rx(r"임차권"), "lease_registrations",
        "deposit_amount", "다른 세입자의 임차권등기",
    ),
    RankedRule(
        "provisional_seizure", "갑구", _rx(r"가압류"), "provisional_seizures",
        "claim_amount", "집이 묶여 있어요 (가압류)",
    ),
    RankedRule("seizure", "갑구", _rx(r"(?<!가)압류"), "seizures", None, "집이 묶여 있어요 (압류)"),
    RankedRule("auction", "갑구", _rx(r"경매개시결정"), "auction_commencements", None,
               "경매가 이미 시작됐어요 (경매개시결정)"),
    RankedRule("trust", "갑구", _rx(r"신탁"), "trust_registrations", None,
               "집 명의가 신탁회사에 있어요 (신탁등기)"),
)


@dataclass(frozen=True)
class TextRule:
    """IE 스키마에 없어 **OCR 텍스트로만** 잡는 표시 (인터뷰 §R4 3종).

    ⚠ 표시만 한다. 판정(등급·점수)에는 어떤 영향도 주지 않는다 — 등급을 바꾸려면
      권위 출처 + decisions.md 선기록이 필요하다(2026-07-28 보류 결정).
    """

    kind: str
    pattern: re.Pattern[str]
    label: str
    # 이 문자열이 같은 줄에 있으면 무시한다 ('별도등기 없음' 같은 부정 표기 방어)
    negative: re.Pattern[str] | None = None


# 말소 표식 — 텍스트 규칙이 **취소선 그어진 기재를 칠하지 않도록** 보는 글자.
# 넓게 잡는다(= 애매하면 안 칠한다). 이 판정은 표시만 줄이고 등급·점수와 무관하다.
_CANCEL_HINT = _rx(r"말소")
# ⚠ 다만 **모든 등기부에 인쇄되는 상투구**는 말소 표식이 아니다.
#   표지  : "등기사항전부증명서(**말소사항** 포함)"
#   꼬리말: "* 실선으로 그어진 부분은 **말소사항**을 표시함."
#   이 둘을 빼지 않으면 표지·꼬리말에 걸리는 표시 종류가 영영 사라진다
#   (같은 함정을 `ocr_layout._CANCEL_ANY`가 2026-07-27에 이미 한 번 밟았다).
_CANCEL_BOILERPLATE = _rx(r"말소사항")

_TEXT_RULES: tuple[TextRule, ...] = (
    TextRule("separate_land", _rx(r"별도등기"), "땅에 따로 걸린 빚 (토지 별도등기)",
             negative=_rx(r"없음|없는")),
    TextRule("joint_collateral", _rx(r"공동담보|공동전세목록"), "여러 집이 함께 묶인 담보 (공동담보)"),
    TextRule("pending_application", _rx(r"신청사건"), "등기 변경이 진행 중이에요 (신청사건)"),
)

# 문서 스칼라 앵커
_ADDRESS_LINE = _rx(r"^\s*\[(집합건물|건물|토지)\]")
_DOC_TITLE = _rx(r"등기사항전부증명서")
_VIEWED_LINE = _rx(r"열람일시")
# 면적 단위 — **`m2`(ASCII)를 반드시 포함한다.**
#
# 실측(2026-07-29 진단, 저장된 원응답 2건): Document OCR은 `㎡`(U+33A1)를 **한 번도**
# 내보내지 않았다. 두 문서(4쪽·5쪽)의 면적 단위 20건이 전부 `m2`(m + U+0032)였고
# `㎡`·`m²`는 0건이었다. 숫자와 단위는 한 word로 붙어 온다(`55.56m2` conf 0.91).
# 예전 규칙(`㎡|m²`)은 면적 줄을 통째로 걸러내 **숫자를 보지도 못하고** 탈락시켰다 —
# 조명·해상도가 다른 두 문서가 똑같이 전용면적을 놓친 원인이 이것이다.
# 단위를 **같은 줄에 요구하는 조건 자체는 그대로다**(대지권비율·다른 층 면적과 구분).
_AREA_UNIT = _rx(r"㎡|m²|[mM]2")


def _normalize(
    box: tuple[float, float, float, float], page: OcrPage, pad_ratio: float = 0.0
) -> HighlightBox | None:
    """픽셀 bbox → 0~1 정규화. 원본 크기는 Pillow가 읽은 값(ocr.py)만 쓴다."""
    if page.width <= 0 or page.height <= 0:
        return None
    x0, y0, x1, y1 = box
    pad_x = (x1 - x0) * pad_ratio
    pad_y = (y1 - y0) * pad_ratio
    x0, y0 = max(0.0, x0 - pad_x), max(0.0, y0 - pad_y)
    x1 = min(float(page.width), x1 + pad_x)
    y1 = min(float(page.height), y1 + pad_y)
    if x1 <= x0 or y1 <= y0:
        return None
    return HighlightBox(
        x=round(x0 / page.width, 6),
        y=round(y0 / page.height, 6),
        w=round((x1 - x0) / page.width, 6),
        h=round((y1 - y0) / page.height, 6),
    )


def _union(boxes: list[tuple[float, float, float, float]]) -> tuple[float, float, float, float]:
    return (
        min(b[0] for b in boxes),
        min(b[1] for b in boxes),
        max(b[2] for b in boxes),
        max(b[3] for b in boxes),
    )


def _apply_page_order(
    pages: list[OcrPage], order: list[int] | None
) -> tuple[list[OcrPage], dict[int, int], bool]:
    """(문서 순서로 다시 세운 페이지들, 문서→업로드 인덱스, **실제로 정렬했는가**).

    세 번째 값이 중요하다: 방어 분기로 정렬을 **취소**했는데도 "자동으로 맞췄어요"라고
    말하면, 뒤섞인 순서로 항목을 이은 상태(말소 판정이 어긋날 수 있는 상태)를
    "고쳤다"고 알리는 셈이 된다.

    `order`가 None이면 아무것도 하지 않는다 — 두 인덱스가 같다(항등 사상).
    정렬할 때는 각 페이지의 `.index`를 **문서 순서로 다시 매긴다.** `build_items`와
    `_match_owner`("가장 마지막 등기를 쓴다")가 전부 `.index`를 시간 순서로 믿기 때문이다.
    업로드 인덱스를 그대로 두면 그 판단이 조용히 뒤집힌다.
    """
    if not order:
        return list(pages), {p.index: p.index for p in pages}, False
    by_upload = {p.index: p for p in pages}
    ordered: list[OcrPage] = []
    to_upload: dict[int, int] = {}
    for doc_index, upload_index in enumerate(order):
        src = by_upload.get(upload_index)
        if src is None:  # 방어 — `_resolve_order`가 보장하지만 조용히 어긋나면 정렬을 포기한다
            _log.info(f"[사진점검] ⚠ 정렬 대상 업로드 인덱스 {upload_index}를 찾지 못함 → 정렬 취소")
            return list(pages), {p.index: p.index for p in pages}, False
        ordered.append(replace(src, index=doc_index))
        to_upload[doc_index] = upload_index
    _log.info(f"[사진점검] 사진 순서를 문서 순서로 재배열: 업로드 {order} → 1..{len(order)}쪽")
    return ordered, to_upload, True


def _active_rights_items(items: list[RegistryItem], section: str) -> list[RegistryItem]:
    """해당 구역에서 **말소되지 않은** 항목만. 말소 행 자체도 대상에서 뺀다."""
    return [
        it
        for it in items
        if it.section == section and not it.canceled and not it.is_cancel_record
    ]


def _words_matching(line: Line, pattern: re.Pattern[str]) -> list[tuple[float, float, float, float]]:
    """줄 안에서 정규식에 기여한 **word들의 bbox**만 골라낸다.

    줄 전체를 칠하면 옆 칸까지 번진다(실측: 문자 단위 정규식이 '매매'+'홍길동'을 한
    덩어리로 삼켜 bbox가 181px로 번졌다 — findings §2.8·§9.5).
    """
    joined, owner = line.concat()
    idxs: set[int] = set()
    for m in pattern.finditer(joined):
        idxs |= set(owner[m.start() : m.end()])
    return [line.words[i].box for i in sorted(idxs)]


def _entry_amount(entry: RegistryEntry, attr: str) -> int | None:
    """항목의 금액 — MoneyEntry는 이미 파싱된 `amount`, 나머지는 원본 필드를 파싱한다.

    ⚠ `internal.py`(판정 경로)를 건드리지 않기 위해 여기서 파싱한다.
      `parse_amount`는 실패 시 **None**을 준다(0 치환 금지 — 위험 축소이므로).
    """
    if attr == "amount" and isinstance(entry, MoneyEntry):
        return entry.amount
    return parse_amount(getattr(entry, attr, None))


# ══════════════════════════════════════════════════════════════════════════════
# 소유자 이름
# ══════════════════════════════════════════════════════════════════════════════


def _match_owner(
    name: str, items: list[RegistryItem], pages: dict[int, OcrPage]
) -> tuple[int, tuple[float, float, float, float], str] | str:
    """이름이 갑구의 유효 항목에서 발견되면 (page_index, bbox, 개인/법인), 아니면 실패 사유.

    세 번째 값(`kind`)은 **OCR이 읽은 등록번호 형태**에서 온다 — 문구를 개인용/법인용으로
    가르는 유일한 근거다(IE는 소유자의 등록번호를 주지 않는다).
    """
    target = name.strip()
    if not target:
        return "이름이 비어 있음"

    hits = [
        (it, hit)
        for it in _active_rights_items(items, "갑구")
        for hit in it.names
        if hit.name == target
    ]
    if not hits:
        # 왜 못 찾았는지를 갈라서 남긴다 — 아침 진단의 핵심
        anywhere = [hit for it in items for hit in it.names if hit.name == target]
        if not anywhere:
            return "이름 word 미검출 (갑구·을구 어디에도 없음)"
        where = ", ".join(f"{h.page_index}:L{h.line_index}" for h in anywhere[:3])
        return f"갑구 유효 항목 밖에서만 발견됨 ({where}) — 말소되었거나 을구 채무자 표기"

    # 같은 이름이 여러 번 나오면 **가장 마지막(최신) 등기**를 쓴다.
    # 갑구는 위에서 아래로 시간순이라, 아래쪽이 현재 지분을 만든 등기다.
    hits.sort(key=lambda pair: (pair[1].page_index, pair[1].box[1]))
    _, hit = hits[-1]
    if hit.page_index not in pages:
        return f"좌표가 있는 페이지({hit.page_index})의 OCR 결과가 없음"
    return hit.page_index, hit.box, hit.kind


# ══════════════════════════════════════════════════════════════════════════════
# 순위 항목 (3앵커 / 2앵커 공용)
# ══════════════════════════════════════════════════════════════════════════════


def _match_ranked(
    rule: RankedRule,
    rank: str,
    amount: int | None,
    items: list[RegistryItem],
    pages: dict[int, OcrPage],
) -> tuple[int, tuple[float, float, float, float]] | str:
    """순위번호 + 등기목적 (+ 3앵커면 금액) 이 **같은 줄**에 다 있어야 좌표를 준다.

    2앵커(금액 칸이 원래 없는 유형)의 박스는 **순위번호 ~ 등기목적**이다. 줄 전체 폭을
    쓰지 않는 것이 의도적이다 — 압류가 여러 건이면 갑구가 통째로 가로 띠가 된다.
    """
    if not rank:
        return "순위번호 없음 — 같은 종류의 다른 항목과 구분할 수 없음"
    if rule.amount_attr and amount is None:
        return "금액 미상 — 앵커로 쓸 금액 문자열이 없음"

    candidates = [it for it in _active_rights_items(items, rule.section) if it.rank == rank]
    if not candidates:
        canceled = [
            it for it in items if it.section == rule.section and it.rank == rank and it.canceled
        ]
        if canceled:
            return (
                f"OCR에서는 {rule.section} 순위{rank}가 말소로 확인됨 — 표시하지 않음"
                f" (근거: {canceled[0].cancel_evidence})"
            )
        return f"{rule.section} 순위{rank} 항목을 사진에서 찾지 못함"

    item = candidates[0]
    if not rule.purpose.search(item.purpose):
        return (
            f"{rule.section} 순위{rank}의 등기목적이 '{rule.kind}'와 맞지 않음"
            f" (읽힌 값 '{item.purpose[:20]}')"
        )
    if not item.rank_box:
        return f"{rule.section} 순위{rank}의 순위번호 좌표가 없음"

    for page_index, _, line in item.lines:
        if page_index != item.rank_page_index or line.index != item.rank_line_index:
            continue
        if page_index not in pages:
            return f"좌표가 있는 페이지({page_index})의 OCR 결과가 없음"

        if rule.amount_attr:
            amount_text = f"{amount:,}"
            money_words = [w for w in line.words if amount_text in w.text]
            if not money_words:
                return f"앵커 '{amount_text}'이 순위번호와 같은 줄({page_index}:L{line.index})에 없음"
            return page_index, _union([item.rank_box] + [w.box for w in money_words])

        # 2앵커 — 등기목적 키워드 word가 순위번호와 같은 줄에 있어야 한다.
        #
        # ⚠ **등기목적 칸 안에서만** 찾는다. 줄 전체에서 찾으면 옆 칸(등기원인)의 같은
        #   단어까지 잡아 박스가 줄 전체로 번진다 — 등기부는 등기원인에 등기목적과 같은
        #   말을 그대로 적는 일이 흔하다(`등기목적: 압류` / `등기원인: 2020년5월6일 압류`).
        #   실측으로 박스 폭이 9.9% → 45.1%로 부풀었다(2026-07-28).
        band_words = [w for w in line.words if any(w is pw for pw in item.purpose_words)]
        purpose_boxes = (
            _words_matching(Line(index=line.index, words=band_words), rule.purpose)
            if band_words
            else []
        )
        if not purpose_boxes:
            return (
                f"등기목적 앵커가 순위번호와 같은 줄({page_index}:L{line.index})의"
                " 등기목적 칸에 없음 — 옆 칸 글자를 끌어와 칠하지 않는다"
            )
        return page_index, _union([item.rank_box] + purpose_boxes)

    return f"{rule.section} 순위{rank}의 순위번호 줄을 찾지 못함"


# ══════════════════════════════════════════════════════════════════════════════
# OCR 텍스트 감지 (IE 스키마에 없는 것)
# ══════════════════════════════════════════════════════════════════════════════


def _line_owners(items: list[RegistryItem]) -> dict[tuple[int, int], RegistryItem]:
    """(페이지, 줄) → 그 줄이 속한 등기 항목. 표 밖의 줄은 키가 없다."""
    owners: dict[tuple[int, int], RegistryItem] = {}
    for item in items:
        for page_index, _, line in item.lines:
            owners[(page_index, line.index)] = item
    return owners


def _canceled_by_line_text(items: list[RegistryItem]) -> set[tuple[str, str]]:
    """줄 **원문**에서 'N번○○말소'를 훑어 (구역, 순위) 말소 집합을 만든다.

    `_apply_cancellations`(ocr_layout)가 이미 같은 일을 하는데 왜 또 하나:
    그쪽은 **등기목적 칸 텍스트**(`item.purpose`)만 보고, 대상도 갑구·을구로 한정돼 있다.
    표제부(대지권의 표시)는 컬럼 밴드가 갑구·을구 헤더와 달라 `purpose`가 통째로 비고,
    구역 자체도 판정 대상에서 빠져 있다 — 그래서 `2번 별도등기 중 일부 말소`가
    기록돼 있는데도 표제부 순위2가 '유효'로 남았다(2026-08-14 D17 실측).

    ⚠ **이 결과는 표시 억제에만 쓴다.** `RegistryItem.canceled`를 건드리지 않으므로
      `cancel_reliable`·`money_allowed`·순위 항목 매칭은 조금도 영향받지 않는다.
      즉 이 함수는 형광펜을 **덜 칠하게만** 할 수 있다(보수적 편향과 같은 방향).

    ⚠ 훑기 전에 **순위번호 word를 뺀다.** 표는 순위번호와 등기목적이 다른 칸인데
      줄로 이어붙이면 한 덩어리가 된다: `3` + `2번별도등기중일부말소` → `32번…말소`.
      그러면 `(\\d{1,3})번`이 욕심껏 `32`를 집어 **있지도 않은 순위32가 말소됐다**가
      되고, 정작 말소된 순위2는 유효로 남는다(실측 — 이 한 글자 때문에 D17의 ③이
      1차 수정에서 살아남았다). `_apply_cancellations`가 이 함정을 피하는 이유도
      같다 — 그쪽은 등기목적 칸(`purpose`)만 보므로 순위번호가 애초에 안 섞인다.
    """
    canceled: set[tuple[str, str]] = set()
    for item in items:
        for page_index, _, line in item.lines:
            words = line.words
            if page_index == item.rank_page_index and line.index == item.rank_line_index:
                words = [w for w in words if w.box != item.rank_box]
            for m in CANCEL_TARGET_RE.finditer("".join(w.text for w in words)):
                canceled.add((item.section, m.group(1)))
    return canceled


def _match_text_rule(
    rule: TextRule,
    pages: list[OcrPage],
    items: list[RegistryItem],
) -> list[tuple[int, tuple[float, float, float, float]]]:
    """문구가 인쇄된 자리들 중 **말소되지 않은 것만** 돌려준다.

    ── 2026-08-14 D17: 여기가 비어 있었다 ─────────────────────────────────────
    순위 항목 경로(`_match_ranked`)는 처음부터 `_active_rights_items`로 말소분을
    걸러냈는데, 이 텍스트 규칙 경로는 **OCR 줄을 그대로 훑기만 해서 말소 여부를
    아예 보지 않았다.** 그 결과 실기기에서:
      - `공동담보목록 제2020-3966호` → 소속 을구 순위1은 `1번근저당권설정등기말소`로
        **이미 말소로 판정돼 있었는데도** 형광펜이 칠해졌다.
      - `별도등기 있음`(표제부 순위2) → 바로 아래 줄에 `2번 별도등기 중 일부 말소`,
        그 아래에 `3번 1토지에 관한 별도등기 말소`가 있는 **정리된 기재**인데 칠해졌다.
    등기부 인쇄물에는 빨간 취소선이 그어져 있지만 OCR은 선을 읽지 못한다
    (docs/ocr-highlight-findings.md §2.5) — 말소는 텍스트로만 드러나므로,
    그 텍스트를 보지 않으면 취소선 위에 형광펜을 칠하게 된다.

    ── 어느 줄을 버리는가 (하나라도 걸리면 버린다) ────────────────────────────
    ⑴ 그 줄이 속한 항목이 **말소**로 판정됐다 (`item.canceled`)
    ⑵ 그 줄이 속한 항목이 **말소 근거 행 자체**다 (`item.is_cancel_record`)
    ⑶ 그 줄이 속한 항목의 (구역, 순위)가 다른 줄의 'N번○○말소'에 지목됐다
       — 표제부처럼 ⑴이 계산되지 않는 구역을 메운다
    ⑷ 그 줄 자체에 `말소`가 인쇄돼 있다 (모든 등기부에 찍히는 상투구는 제외)
       — `2번별도등기중일부말소별도등기있음`처럼 **한 줄 안에서 스스로를 정리하는**
         기재는 ⑴~⑶ 어디에도 안 걸린다. 정규식이 `3번1토지에…`의 숫자 때문에
         대상 순위를 못 읽는 경우도 여기서 잡힌다.

    표 밖의 줄(표지·꼬리말)은 소속 항목이 없어 ⑴~⑶을 적용할 수 없다. 이때는
    **버리지 않는다** — 말소는 표(등기 항목)에만 있는 개념이고, 여기서 막으면
    표지에 인쇄되는 `신청사건`이 통째로 사라진다.
    """
    owners = _line_owners(items)
    canceled_ranks = _canceled_by_line_text(items)
    found: list[tuple[int, tuple[float, float, float, float]]] = []
    for page in pages:
        for line in page.lines:
            squeezed = line.squeezed
            if not rule.pattern.search(squeezed):
                continue
            if rule.negative and rule.negative.search(squeezed):
                continue  # '별도등기 없음' 같은 부정 표기 — 위험이 아니다

            owner = owners.get((page.index, line.index))
            if owner is not None:
                if owner.canceled or owner.is_cancel_record:
                    _log.info(
                        f"[매칭] — {rule.kind} 후보 {page.index}:L{line.index}는"
                        f" {owner.section} 순위{owner.rank}(말소)에 속해 칠하지 않음"
                    )
                    continue
                if owner.rank and (owner.section, owner.rank) in canceled_ranks:
                    _log.info(
                        f"[매칭] — {rule.kind} 후보 {page.index}:L{line.index}는"
                        f" {owner.section} 순위{owner.rank}를 지목한 말소 기재가 있어 칠하지 않음"
                    )
                    continue
            if _CANCEL_HINT.search(squeezed) and not _CANCEL_BOILERPLATE.search(squeezed):
                _log.info(
                    f"[매칭] — {rule.kind} 후보 {page.index}:L{line.index}는"
                    " 줄 자체에 말소 기재가 있어 칠하지 않음"
                )
                continue

            boxes = _words_matching(line, rule.pattern)
            if boxes:
                found.append((page.index, _union(boxes)))
    return found


# ══════════════════════════════════════════════════════════════════════════════
# 문서 스칼라 (주소 · 면적 · 서류 종류 · 열람일)
# ══════════════════════════════════════════════════════════════════════════════


def _first_line_match(
    pages: list[OcrPage], pattern: re.Pattern[str], *, use_display: bool = False
) -> tuple[int, Line] | None:
    """패턴에 맞는 **가장 앞쪽 페이지의 첫 줄**을 찾는다.

    주소 줄처럼 모든 쪽에 반복 인쇄되는 것은 첫 쪽 한 곳만 가리킨다 — 5쪽에 다 칠하면
    "확인할 곳"이 5개로 부풀어 개수 문구가 거짓말이 된다.
    """
    for page in sorted(pages, key=lambda p: p.index):
        for line in page.lines:
            hay = line.display if use_display else line.squeezed
            if pattern.search(hay):
                return page.index, line
    return None


def _match_area(pages: list[OcrPage], area: float) -> tuple[int, tuple[float, float, float, float]] | str:
    """IE가 읽은 전용면적 숫자가 **사진에도 그대로 있는** 자리를 찾는다.

    숫자만으로는 대지권 비율·다른 층 면적과 헷갈리므로 **같은 줄에 ㎡가 있을 것**을
    함께 요구한다(2앵커와 같은 사고방식).
    """
    # 84.98 → "84.98", 84.0 → "84" (등기부 표기가 소수점을 생략하는 경우 대비)
    candidates = {f"{area:g}", f"{area:.2f}".rstrip("0").rstrip(".")}
    for page in sorted(pages, key=lambda p: p.index):
        for line in page.lines:
            if not _AREA_UNIT.search(line.squeezed):
                continue
            for w in line.words:
                if any(c in w.text for c in candidates if c):
                    return page.index, w.box
    return f"전용면적 숫자를 ㎡가 있는 줄에서 찾지 못함 (IE 값 {area:g}㎡)"


# ══════════════════════════════════════════════════════════════════════════════
# 조립
# ══════════════════════════════════════════════════════════════════════════════


@dataclass
class _Candidate:
    """정렬·상한 적용 전의 표시 후보."""

    kind: str
    page: int
    box: HighlightBox
    title: str
    body: str
    caution: str | None
    source: str
    order: int
    amount: int | None = None
    rank: str | None = None
    id_hint: str = ""

    @property
    def sort_key(self) -> tuple:
        """상한(top-5)을 적용할 때의 우선순위 — 금액 큰 것 먼저, 금액이 없으면 순위 빠른 것 먼저."""
        if self.amount is not None:
            return (0, -self.amount, 0)
        try:
            rank_num = int(str(self.rank or "").split("-")[0])
        except (TypeError, ValueError):
            rank_num = 10**6
        return (1, rank_num, self.page)


@dataclass
class HighlightResult:
    """하이라이트 + 사용자에게 보여줄 안내."""

    highlights: list[Highlight]
    notice: str | None = None
    # 등기부 꼬리말의 열람일시 `YYYY.MM.DD` — **표시 전용**. 판정에 쓰지 않는다.
    # 등기부는 열람 시점의 스냅샷이라, 그 뒤에 잡힌 근저당은 이 서류에 없다.
    viewed_at: str | None = None
    # **"무엇을 찾아봤고 무엇을 왜 표시하지 않았는지"** 요약. 표시 전용이다.
    #
    # 왜 필요한가 (2026-07-27 페르소나 2인 공통 지적, 이번 리뷰 최다 지적):
    # 이 등기부는 근저당이 전부 말소돼 이름에만 형광펜이 칠해진다. 그런데 화면이
    # 그 사실을 **한 마디도 하지 않으면** 두 페르소나 모두 "AI가 을구를 안 봤나 보다,
    # 그럼 이 판정도 못 믿겠다"로 읽었다. 즉 **침묵이 신뢰를 깎는다.**
    # 반대로 "근저당 2건은 모두 말소된 것으로 확인해 표시하지 않았어요" 한 줄이 들어가면
    # 같은 화면이 "을구를 읽었고, 읽은 결과 뺐구나"라는 **가장 강한 신뢰 장치**가 된다.
    checked_notes: list[str] = field(default_factory=list)


def build_highlights(
    extract: RegistryExtract,
    ocr: OcrResult,
    cross: CrossCheck | None = None,
    check: DocumentCheck | None = None,
    canceled_excluded: int = 0,
) -> HighlightResult:
    """IE 결과 + OCR 좌표 → 계약의 `highlights`. 실패해도 예외를 던지지 않는다.

    `canceled_excluded`는 **말소 확인으로 위험 계산에서 뺀 항목 수**다(2026-08-14 D10,
    `cancellation.apply_confirmed_cancellations`가 센다). 표시에는 쓰지 않고 고지 문장
    하나만 바꾼다 — "사진에 표시하지 않았어요"와 "계산에서도 뺐어요"는 사용자에게
    전혀 다른 말이라, 뺐으면 뺐다고 해야 한다.

    `cross`는 두 번째 추출 경로(LLM 구조화)와의 대조 결과다. **표시와 고지에만** 쓴다 —
    이 값이 무엇이든 등급·점수는 바뀌지 않는다(판정은 IE 기준 유지).

    `check`는 **이미 끝난 사진 묶음 점검**이다. `report_builder`가 두 번째 경로에
    같은 순서를 먹이려고 한 번 먼저 돌리므로, 그 결과를 그대로 받아 쓴다. 주지 않으면
    여기서 직접 돌린다(단독 호출·테스트 경로). 받아 쓰는 이유는 낭비를 줄이려는 것보다
    **두 경로가 서로 다른 순서를 쓸 여지를 없애려는** 쪽이 크다 — 순서가 갈리면
    LLM은 A장을 읽고 형광펜은 B장에 간다.
    """
    if not ocr.pages:
        # **침묵 금지.** 예전에는 빈 결과만 돌려줘서 화면에 사진만 뜨고 범례·회색 줄이
        # 통째로 사라졌다 — 사용자는 "표시할 게 없다"와 "못 읽었다"를 구분할 수 없다
        # (이 기능 설계의 최우선 지적사항이 정확히 재발하는 자리다).
        _log.info("[매칭] 건너뜀 — OCR 결과 없음 (좌표 없이 리포트 완성)")
        return HighlightResult(
            [],
            notice="사진에서 글자를 읽지 못해 이번엔 표시를 못 했어요.",
            checked_notes=[
                "사진에서 글자를 읽지 못해 이번엔 아무것도 표시하지 않았어요 "
                "— 분석 결과는 리포트의 '근거 살펴보기'에서 확인하세요"
            ],
        )

    # ── 사진 묶음 점검: 같은 등기부인가 / 순서가 맞나 / 빠진 쪽은 없나 ──────
    # 호출부가 이미 돌렸으면 그 결과를 쓴다 (위 docstring 참고).
    if check is None:
        check = check_document(ocr.pages)
    for reason in check.reasons:
        _log.info(f"[사진점검] {reason}")
    if not check.ok_to_highlight_any:
        _log.info("[매칭] 중단 — 사진 묶음 점검 실패로 아무것도 표시하지 않음")
        # 표시를 못 하더라도 "언제 뗀 서류인가"는 알려준다 — 표시와 무관한 사실이다.
        # `checked_notes`도 반드시 채운다 — 뷰어에 안 들어간 사용자는 `notice`를 볼 수 없다.
        return HighlightResult(
            [],
            notice=check.notice,
            viewed_at=check.viewed_at,
            checked_notes=[
                (check.notice or "사진 묶음을 확인하지 못해 표시를 생략했어요")
                + " — 그래서 사진에는 아무것도 표시하지 않았어요"
            ],
        )

    # ── 사진 순서 자동 정렬 (2026-07-28) ────────────────────────────────────
    # 항목은 페이지를 걸쳐 이어지므로 **문서 순서**로 읽어야 말소 판정이 맞는다.
    # 그런데 뷰어는 **업로드 순서**로 사진을 보여준다. 그래서 두 인덱스를 갈라 쓴다:
    #   - 내부 해석(`build_items`·정렬·"가장 마지막 등기") → 문서 순서 인덱스
    #   - 앱으로 나가는 `Highlight.page` → **원래 업로드 인덱스**
    # 여기서 틀리면 **남의 사진에 형광펜이 간다.**
    ordered_pages, to_upload, reorder_applied = _apply_page_order(ocr.pages, check.page_order)
    items = build_items(ordered_pages)
    pages = {p.index: p for p in ordered_pages}  # 문서 순서 인덱스로 키를 잡는다

    canceled_items = [it for it in items if it.canceled]
    if canceled_items:
        reasons = "; ".join(f"{it.section} 순위{it.rank} ← {it.cancel_evidence}" for it in canceled_items)
        _log.info(f"[매칭] — 말소 항목 {len(canceled_items)}건은 대상에서 제외 ({reasons})")

    # 말소 근거 행이 있는데 **대상 항목을 못 찾았다면**, 무언가 말소됐는데 무엇인지 모른다는
    # 뜻이다. 이 상태로 금액을 칠하면 말소된 항목을 칠할 수 있다 → 금액 표시를 통째로 보류.
    unbound = [it for it in items if it.is_cancel_record and not it.cancel_bound]
    money_allowed = check.ok_to_highlight_money
    # **말소를 가려낼 수 있다고 믿어도 되는가.** `money_allowed`와 다른 축이다:
    #   - `money_allowed=False` (쪽 누락)      : 빠진 쪽에 말소 행이 있을 **수도** 있다 — 추정
    #   - `cancel_reliable=False` (말소 미결)  : 올린 쪽에 말소 행이 **있는데 대상을 못 찾았다** — 사실
    # 두 번째는 "우리 말소 판정이 지금 깨져 있다"는 구체적 증거라 훨씬 무겁다.
    cancel_reliable = True
    notice = check.notice
    if unbound:
        money_allowed = False
        cancel_reliable = False
        detail = "; ".join(f"{it.location} '{it.purpose[:24]}'" for it in unbound)
        _log.info(
            f"[매칭] ⚠ 말소 근거 행 {len(unbound)}건이 대상 항목을 못 찾음"
            f" → 표 항목 표시 전체 보류 ({detail})"
        )
        notice = notice or "말소된 항목을 정확히 가려내지 못해 등기 항목 표시는 생략했어요."

    candidates: list[_Candidate] = []
    failures: list[str] = []
    # "리포트에는 있는데 사진에서 위치를 못 짚은" 건수 — IE 필드 이름으로 센다.
    # 교차검증 고지 문장이 이 숫자를 써서 "개수가 왜 다른지"를 사용자가 스스로 풀게 한다.
    unplaced: dict[str, int] = {}

    # ── ① 소유자 이름 (갑구) ────────────────────────────────────────────────
    owner_names = [o.name.strip() for o in extract.current_owners if o.name and o.name.strip()]
    owner_count = len(owner_names)
    shared_note = (
        f"이 집은 {owner_count}명이 함께 가진 집이에요(공동명의). "
        f"계약서에 {owner_count}명 모두의 서명이나 도장이 있는 것이 가장 안전합니다. "
        "한 명만 나온다면 나머지 사람의 위임장과 인감증명서를 보여 달라고 하세요."
        if owner_count > 1
        else None
    )
    for i, name in enumerate(owner_names):
        matched = _match_owner(name, items, pages)
        if isinstance(matched, str):
            failures.append(f"갑구 소유자 {mask_name(name)} — {matched}")
            unplaced["current_owners"] = unplaced.get("current_owners", 0) + 1
            continue
        page_index, box, owner_kind = matched
        norm = _normalize(box, pages[page_index], pad_ratio=0.08)
        if norm is None:
            failures.append(f"갑구 소유자 {mask_name(name)} — 원본 크기를 몰라 정규화 실패")
            unplaced["current_owners"] = unplaced.get("current_owners", 0) + 1
            continue
        is_corp = owner_kind == "법인"
        if is_corp:
            _log.info(f"[매칭] 갑구 소유자 {mask_name(name)} — 등록번호 형태가 법인 → 법인용 문구 사용")
        candidates.append(
            _Candidate(
                kind="owner",
                page=page_index,
                box=norm,
                title=f"집주인 이름 · {name}",
                body=_OWNER_BODY_CORP if is_corp else _OWNER_BODY,
                caution=shared_note,
                source=_OWNER_SOURCE,
                order=_SPECS["owner"].order,
                rank=str(i),
                id_hint=f"owner-{i}",
            )
        )

    # ── ② 순위 항목 (3앵커 / 2앵커) ─────────────────────────────────────────
    for rule in _RANKED_RULES:
        entries = [e for e in getattr(extract, rule.ie_field, []) if e.is_active]
        # ── 언제 표 항목을 칠하지 않는가 (2026-07-28 자기 공격으로 다듬음) ──────
        #
        # ⑴ **말소 판정이 깨져 있으면 전부 막는다.** 올린 쪽에 말소 근거 행이 있는데
        #    대상을 못 찾은 상태(`cancel_reliable=False`)는 "무언가 말소됐는데 무엇인지
        #    모른다"는 **사실**이다. 이때 칠하면 말소된 항목을 칠할 수 있다.
        #
        # ⑵ **쪽 누락(`money_allowed=False`)은 금액 종류만 막는다.** 이건 추정이고,
        #    두 종류의 피해가 다르기 때문이다:
        #    - 금액 종류(근저당 등): "집에 잡힌 빚 5억"은 **사용자가 그대로 믿는 숫자**다.
        #      말소된 것을 칠하면 없는 빚을 5억으로 각인시킨다.
        #    - 2앵커 종류(압류·경매·신탁): 금액이 없고, 문구가 **스스로 교정한다**
        #      ("이 압류가 풀렸는지 등기부에서 직접 확인한 뒤에 계약하세요").
        #      여기까지 막으면 쪽이 한 장만 잘려도 가장 심각한 위험이 화면에서 사라진다.
        if not cancel_reliable:
            continue
        if rule.amount_attr and not money_allowed:
            continue
        for i, entry in enumerate(entries):
            rank = str(getattr(entry, "rank_number", "") or "").strip()
            amount = _entry_amount(entry, rule.amount_attr) if rule.amount_attr else None
            matched = _match_ranked(rule, rank, amount, items, pages)
            if isinstance(matched, str):
                failures.append(f"{rule.section} 순위{rank or '?'} {rule.label} — {matched}")
                unplaced[rule.ie_field] = unplaced.get(rule.ie_field, 0) + 1
                continue
            page_index, box = matched
            norm = _normalize(box, pages[page_index], pad_ratio=0.05)
            if norm is None:
                failures.append(f"{rule.section} 순위{rank} {rule.label} — 원본 크기를 몰라 정규화 실패")
                unplaced[rule.ie_field] = unplaced.get(rule.ie_field, 0) + 1
                continue
            spec = _SPECS[rule.kind]
            amount_text = f" · {format_won(amount)}" if amount is not None else ""
            candidates.append(
                _Candidate(
                    kind=rule.kind,
                    page=page_index,
                    box=norm,
                    title=f"{rule.label}{amount_text}",
                    body=spec.body,
                    caution=None,
                    source=spec.source,
                    order=spec.order,
                    amount=amount,
                    rank=rank,
                    id_hint=f"{rule.kind}-{i}",
                )
            )

    # ── ③ OCR 텍스트 감지 (IE 스키마에 없는 3종) ────────────────────────────
    for text_rule in _TEXT_RULES:
        spec = _SPECS[text_rule.kind]
        # ⚠ **문서당 첫 곳만** 칠한다. 이 3종은 여러 쪽에 반복 인쇄되는 고정 문구라
        #   전부 칠하면 **사실 1개가 표시 5개로 부풀어** 뱃지 개수가 거짓말이 된다
        #   (실측: 공동담보 4곳·별도등기 3곳이 각각 같은 사실이었다).
        #   주소 줄에는 이미 같은 규율을 적용해 두었는데(`_first_line_match`) 이 3종에만
        #   빠져 있었다 — 2026-07-28 페르소나 리뷰가 잡았다.
        # ⚠ `items`를 함께 넘긴다 — 말소된 기재에 칠하지 않기 위한 유일한 근거다(D17).
        for i, (page_index, box) in enumerate(
            _match_text_rule(text_rule, ordered_pages, items)[:1]
        ):
            norm = _normalize(box, pages[page_index], pad_ratio=0.08)
            if norm is None:
                continue
            candidates.append(
                _Candidate(
                    kind=text_rule.kind,
                    page=page_index,
                    box=norm,
                    title=text_rule.label,
                    body=spec.body,
                    caution=None,
                    source=spec.source,
                    order=spec.order,
                    rank=str(i),
                    id_hint=f"{text_rule.kind}-{i}",
                )
            )

    # ── ④ 문서 스칼라 (주소 · 면적 · 서류 종류 · 열람일) ────────────────────
    candidates += _document_candidates(extract, ordered_pages, pages, check.viewed_at, failures)

    # ── ④-b 화면에서 끈 종류를 뺀다 (D16 — `_DISABLED_KINDS` 참고) ──────────
    # **뱃지 번호를 매기기 전**에 뺀다. 뒤에서 빼면 ②가 비어 ①③④…가 되어,
    # 사용자는 "표시 하나가 사라졌다"로 읽는다.
    dropped_disabled = [c for c in candidates if c.kind in _DISABLED_KINDS]
    if dropped_disabled:
        candidates = [c for c in candidates if c.kind not in _DISABLED_KINDS]
        kinds = ", ".join(sorted({c.kind for c in dropped_disabled}))
        _log.info(f"[매칭] — 화면에서 끈 종류 {len(dropped_disabled)}건 제외 ({kinds})")

    # ── ⑤ 종류별 상한 → 읽는 순서 정렬 → 뱃지 번호 ──────────────────────────
    # 정렬은 **문서 순서**(c.page)로 하고, 앱에 내보낼 때만 **업로드 인덱스**로 되돌린다.
    kept, trimmed = _cap_per_kind(candidates)
    kept.sort(key=lambda c: (c.order, c.page, c.box.y, c.box.x))
    highlights = [
        Highlight(
            id=c.id_hint or f"{c.kind}-{i}",
            page=to_upload.get(c.page, c.page),
            kind=c.kind,
            badge=i + 1,
            box=c.box,
            title=c.title,
            body=c.body,
            caution=c.caution,
            source=c.source,
        )
        for i, c in enumerate(kept)
    ]

    _log.info(
        f"[매칭] 후보 {len(candidates)}건 → 표시 {len(highlights)}건"
        f" / 상한초과 생략 {sum(trimmed.values())}건 / 실패 {len(failures)}건"
    )
    for reason in failures:
        _log.info(f"[매칭] ✗ 실패: {reason}")

    notes = _build_checked_notes(
        extract=extract,
        items=items,
        highlights=highlights,
        money_allowed=money_allowed,
        owner_names=owner_names,
        trimmed=trimmed,
        cross=cross,
        unplaced=unplaced,
        reordered=reorder_applied,
        canceled_excluded=canceled_excluded,
    )
    if highlights:
        pages_used = sorted({h.page for h in highlights})
        _log.info(f"[응답] 좌표 {len(highlights)}건을 정규화하여 계약에 포함 (사진 {pages_used})")
    if notice:
        _log.info(f"[응답] 사용자 안내: {notice}")
    for note in notes:
        _log.info(f"[응답] 찾아본 것: {note}")
    return HighlightResult(
        highlights,
        notice=notice,
        checked_notes=notes,
        viewed_at=check.viewed_at,
    )


def _document_candidates(
    extract: RegistryExtract,
    ocr_pages: list[OcrPage],
    pages: dict[int, OcrPage],
    viewed_at: str | None,
    failures: list[str],
) -> list[_Candidate]:
    """주소·면적·서류 종류·열람일 — 표에 속하지 않는 '문서 자체'의 확인 지점.

    은행원이 볼펜으로 서명란을 짚어주듯, 등기부를 처음 보는 사람이 **어디를 봐야 하는지**
    종이 위에서 안내한다. 전부 `verify`(대조할 곳) 톤이라 위험 개수에 들어가지 않는다.
    """
    out: list[_Candidate] = []

    def add(kind: str, page_index: int, box: tuple[float, float, float, float], title: str,
            pad: float) -> None:
        norm = _normalize(box, pages[page_index], pad_ratio=pad)
        if norm is None:
            failures.append(f"{kind} — 원본 크기를 몰라 정규화 실패")
            return
        spec = _SPECS[kind]
        out.append(
            _Candidate(
                kind=kind, page=page_index, box=norm, title=title, body=spec.body,
                caution=None, source=spec.source, order=spec.order, id_hint=f"{kind}-0",
            )
        )

    # 주소 — IE가 주소를 읽지 못했으면 가리키지 않는다(IE 기준 원칙 유지).
    if extract.address:
        hit = _first_line_match(ocr_pages, _ADDRESS_LINE, use_display=True)
        if hit:
            page_index, line = hit
            add("address", page_index, line.box, "이 서류가 가리키는 집 (주소·동호수)", 0.04)
        else:
            failures.append("주소 — 표제부 주소 줄을 사진에서 찾지 못함")

    # 전용면적 — IE 숫자가 사진에도 있어야 한다
    if extract.exclusive_area_sqm:
        matched = _match_area(ocr_pages, extract.exclusive_area_sqm)
        if isinstance(matched, str):
            failures.append(f"전용면적 — {matched}")
        else:
            page_index, box = matched
            add("area", page_index, box, f"전용면적 · {extract.exclusive_area_sqm:g}㎡", 0.10)

    # 서류 종류 — '말소사항 포함'인지 종이에서 직접 보게 한다 (인터뷰 [16:00])
    hit = _first_line_match(ocr_pages, _DOC_TITLE)
    if hit:
        page_index, line = hit
        add("doc_title", page_index, line.box, "이 서류가 전체본인가 (지워진 기록까지 나오는가)", 0.04)

    # 열람일 — 이미 꼬리말에서 읽은 값이 있을 때만 (인터뷰 E3 '발급 당일 원칙')
    if viewed_at:
        hit = _first_line_match(ocr_pages, _VIEWED_LINE)
        if hit:
            page_index, line = hit
            add("viewed_at", page_index, line.box, f"이 서류를 뗀 날 · {viewed_at}", 0.04)

    return out


def _cap_per_kind(candidates: list[_Candidate]) -> tuple[list[_Candidate], dict[str, int]]:
    """같은 종류가 상한을 넘으면 상위 N건만 남긴다. (남긴 것, 종류별 생략 건수)

    정렬은 **금액 내림차순**, 금액이 없으면 **순위번호 오름차순**이다 — 가장 큰 빚과
    가장 앞선 순위가 사용자에게 가장 중요하다.
    """
    by_kind: dict[str, list[_Candidate]] = {}
    for c in candidates:
        by_kind.setdefault(c.kind, []).append(c)

    kept: list[_Candidate] = []
    trimmed: dict[str, int] = {}
    for kind, group in by_kind.items():
        if len(group) <= MAX_MARKS_PER_KIND:
            kept += group
            continue
        group.sort(key=lambda c: c.sort_key)
        kept += group[:MAX_MARKS_PER_KIND]
        trimmed[kind] = len(group) - MAX_MARKS_PER_KIND
        _log.info(
            f"[매칭] {kind} {len(group)}건 중 상위 {MAX_MARKS_PER_KIND}건만 표시"
            f" ({trimmed[kind]}건 생략 — 화면이 띠로 덮이는 것을 막기 위함)"
        )
    return kept, trimmed


# 종류 → 사용자 말 (checkedNotes 문장 조립용). 앱의 `MarkKind.countNoun`과 짝을 맞춘다.
_KIND_NOUN = {
    "address": ("집 주소", "곳"),
    "area": ("전용면적", "곳"),
    "separate_land": ("토지 별도등기", "곳"),
    "doc_title": ("서류 종류", "곳"),
    "owner": ("집주인 이름", "곳"),
    "provisional_seizure": ("가압류", "건"),
    "seizure": ("압류", "건"),
    "auction": ("경매개시결정", "건"),
    "trust": ("신탁등기", "건"),
    "mortgage": ("빚", "건"),
    "jeonse": ("전세권", "건"),
    "lease_registration": ("임차권등기", "건"),
    "joint_collateral": ("공동담보", "곳"),
    "pending_application": ("신청사건 처리중", "곳"),
    "viewed_at": ("서류를 뗀 날", "곳"),
}


def _build_checked_notes(
    *,
    extract: RegistryExtract,
    items: list[RegistryItem],
    highlights: list[Highlight],
    money_allowed: bool,
    owner_names: list[str],
    trimmed: dict[str, int],
    cross: CrossCheck | None = None,
    unplaced: dict[str, int] | None = None,
    reordered: bool = False,
    canceled_excluded: int = 0,
) -> list[str]:
    """**"무엇을 찾아봤고 무엇을 왜 표시하지 않았는지"** 를 사용자 말로 정리한다.

    이 함수가 하는 일은 설명뿐이다 — 판정을 만들지도, 바꾸지도 않는다.
    (2026-07-27 페르소나 2인 + 디자인 리뷰가 공통으로 지적한 최우선 항목:
     "표시가 없는 것"과 "안 본 것"이 화면에서 구분되지 않아 신뢰가 깎인다.)
    """
    notes: list[str] = []

    # ① 집주인 이름
    owner_marks = [h for h in highlights if h.kind == "owner"]
    if owner_marks:
        shared = " (공동명의)" if len(owner_names) > 1 else ""
        notes.append(f"집주인 이름 {len(owner_marks)}곳{shared} — 사진에서 찾아 표시했어요")
    elif owner_names:
        notes.append(
            f"집주인 이름 {len(owner_names)}명은 리포트에 반영됐지만, 사진에서 위치를 찾지 못했어요"
        )
    else:
        notes.append("집주인 이름을 등기부에서 읽지 못했어요 — 리포트의 '근거 살펴보기'를 확인하세요")

    # ② 근저당(집에 잡힌 빚) — **말소를 왜 뺐는지가 이 목록의 핵심**이다
    canceled_mortgages = [
        it for it in items if it.section == "을구" and it.canceled and "근저당" in it.purpose
    ]
    active_mortgages = [m for m in extract.mortgages if m.is_active]
    money_marks = [h for h in highlights if h.kind in ("mortgage", "jeonse", "lease_registration")]
    if canceled_mortgages:
        # 2026-08-14(D10): 말소분을 **위험 계산에서도** 빼기 시작했다. 예전 문구는
        # "표시하지 않았어요"까지만 말해서, 사진에는 안 보이는데 합계에는 들어 있는
        # 상태로 읽혔다(실제로 그랬다 — 그게 이 작업의 발단이다). 뺐으면 뺐다고 한다.
        # ⚠ 안전 조건에 걸려 계산에서 못 뺀 경우(`canceled_excluded == 0`)에는 예전 문구
        #   그대로다. 빼지도 않고 뺐다고 말하는 것이 가장 나쁘다.
        #
        # ── [D17b · 2026-08-14] "N건은 모두 말소" → "전체 N건 중 M건이 말소" ──────
        # 예전 문구는 `1건은 **모두** 말소된 것으로 확인해…`였다. 말소분만 세는 숫자라
        # 틀린 말은 아니었지만, `1건` + `모두`가 붙어 **"이 집 근저당은 총 1건이고 그게 다
        # 정리됐다"**로 읽혔다. 실제로는 유효 근저당이 3건(합계 14억) 더 있었고, 같은
        # 화면의 채권최고액에는 형광펜이 칠해져 있었다 — 화면이 스스로와 모순됐다.
        #
        # 짝이 되는 "지금 남아 있는 빚 3건을 표시했어요"는 아래에서 따로 만들지만,
        # 앱은 `kUnmarkedNoteMarkers`에 걸리는 문장만 그리므로(registry_viewer_screen.dart)
        # 그 문장은 화면에 **닿지 못한다.** 그래서 남은 건수를 **이 문장 안으로** 넣는다.
        # ⚠ 그래서 이 문장에는 `표시하지 않았`이 반드시 남아 있어야 한다(필터 통과 조건).
        active_count = len(active_mortgages)
        total_mortgages = len(canceled_mortgages) + active_count
        excluded_part = (
            "위험 계산에서 제외했고 사진에도 표시하지 않았어요"
            if canceled_excluded
            else "사진에 표시하지 않았어요"
        )
        # "나머지 N건" — **실제로 표시한 것과 어긋나지 않게** 센다. 유효분이 있는데
        # 위치를 못 짚었으면 "표시했어요"가 거짓이 되므로 그때는 다르게 말한다.
        mortgage_marks = [h for h in highlights if h.kind == "mortgage"]
        if active_count == 0:
            rest = " — 이미 정리된 빚이에요"
        elif len(mortgage_marks) == active_count:
            rest = f" — 나머지 {active_count}건은 사진에 표시했어요"
        else:
            rest = (
                f" — 나머지 {active_count}건 중 {len(mortgage_marks)}건만"
                " 사진에서 위치를 찾았어요"
            )
        notes.append(
            f"집에 잡힌 빚(근저당) {total_mortgages}건 중 {len(canceled_mortgages)}건은 "
            f"말소된 것으로 확인해 {excluded_part}{rest}"
        )
    if not money_allowed and (active_mortgages or extract.jeonse_rights):
        notes.append("빚 표시는 이번엔 생략했어요 — 위 안내를 확인해 주세요")
    elif active_mortgages and money_marks:
        notes.append(f"지금 남아 있는 빚 {len(money_marks)}건을 표시했어요")
    elif active_mortgages and not money_marks:
        notes.append(
            f"지금 남아 있는 빚 {len(active_mortgages)}건은 리포트에 반영됐지만, "
            "사진에서 위치를 찾지 못했어요 — 리포트의 '근거 살펴보기'에서 확인하세요"
        )
    elif not active_mortgages and not canceled_mortgages:
        # ⚠ **"없었어요"는 못 본 쪽이 없을 때만 할 수 있는 말이다.**
        #   쪽이 빠졌는데 "없다"고 하면 안전 단언이 되고, 빠진 쪽에 근저당이 있으면
        #   그게 곧 미탐이다(risk-scoring 3절 위반). 2026-07-28 gap-checker 지적.
        notes.append(
            "지금 남아 있는 빚(근저당)은 없었어요"
            if money_allowed
            else "못 본 쪽이 있어서 빚(근저당)이 없다고는 말할 수 없어요 — 위 안내를 확인해 주세요"
        )
    elif not active_mortgages:
        notes.append(
            "지금 남아 있는 빚(근저당)은 없어요"
            if money_allowed
            else "못 본 쪽이 있어서 빚(근저당)이 없다고는 말할 수 없어요 — 위 안내를 확인해 주세요"
        )

    # ③ 압류·가압류·신탁 등
    signal_fields = (
        extract.seizures + extract.provisional_seizures + extract.provisional_dispositions
        + extract.auction_commencements + extract.trust_registrations
    )
    active_signals = [e for e in signal_fields if e.is_active]
    signal_marks = [
        h for h in highlights
        if h.kind in ("seizure", "provisional_seizure", "auction", "trust")
    ]
    if active_signals and signal_marks:
        notes.append(
            f"압류·가압류·경매 같은 표시 {len(signal_marks)}곳을 사진에서 찾아 표시했어요 "
            "— 리포트의 '근거 살펴보기'도 꼭 보세요"
        )
    elif active_signals:
        # ⚠ 이 줄은 **반드시 화면에 나와야 한다.** 압류·가처분이 있는데 위치를 못 짚으면
        #   표시가 0건이 되는데, 이 문장까지 필터에 걸리면 **화면이 통째로 빈다**
        #   (가처분은 아직 매칭 규칙이 없어 항상 이 경로다 — 2026-07-28 gap-checker 지적).
        #   그래서 문장 끝을 앱 표식(`표시하지 않았`)에 맞춘다.
        notes.append(
            f"압류·가압류·신탁 같은 표시가 {len(active_signals)}건 있어요. "
            "사진에서 위치를 짚지 못해 표시하지 않았어요 "
            "— 리포트의 '근거 살펴보기'를 꼭 보세요"
        )
    elif money_allowed:
        notes.append("압류·가압류·신탁 같은 표시는 없었어요")
    else:
        notes.append("못 본 쪽이 있어서 압류·가압류가 없다고는 말할 수 없어요")

    # ④ 종류별 상한으로 생략한 것 — **침묵하지 않는다**(범용 슬롯)
    for kind, count in sorted(trimmed.items()):
        noun, unit = _KIND_NOUN.get(kind, (kind, "건"))
        total = count + MAX_MARKS_PER_KIND
        # ⚠ 문장 끝을 **"표시하지 않았어요"** 로 맞춘다. 앱은 `kUnmarkedNoteMarkers`
        #   (`표시하지 않았`·`찾지 못했`·`생략했`)에 걸리는 문장만 화면에 그린다
        #   (`registry_viewer_screen.dart`). 예전 문구는 "…5건만 표시했어요"로 끝나
        #   **어느 마커에도 안 걸려 화면에 아예 안 나왔다** — 스스로 "침묵 금지"라고
        #   써 놓고 침묵하고 있었다(2026-07-28 페르소나 2인이 각각 찾아냈다).
        notes.append(
            f"{eun_neun(noun)} {total}{unit} 중 큰 것부터 {MAX_MARKS_PER_KIND}{unit}만 "
            f"사진에 표시했어요. 나머지 {count}{unit}은 화면이 가려져서 표시하지 않았어요 "
            f"— 리포트의 '근거 살펴보기'에는 {total}{unit} 다 들어 있어요"
        )

    # ⑤ 사진 순서를 우리가 고쳤다면 그 사실을 말한다 — 조용히 고치면 사용자는
    #    "내가 순서대로 올렸는데 왜 표시가 이렇지?"를 영영 알 수 없다.
    if reordered:
        notes.append("사진 순서가 등기부 쪽수와 달라 자동으로 맞췄어요 — 다시 올리지 않으셔도 돼요")

    # ⑥ 교차검증 — **두 방법으로 읽어 봤다는 사실 자체가 가장 강한 신뢰 장치**다.
    #    두 경로가 어긋났을 때 조용히 넘어가지 않고 숫자를 그대로 말한다.
    if cross is not None:
        notes += cross_check_notes(cross, unplaced=unplaced)

    # ⚠ 이 안심 문장은 **정말 다 본 경우에만** 붙인다. 금액 보류·상한 생략·위치 실패가
    #   있는데 이 말을 하면 정확히 거짓말이 된다(2026-07-28 gap-checker 지적).
    if money_allowed and not trimmed and not (unplaced or {}):
        notes.append("표시가 적다는 건 확인할 게 적다는 뜻이에요. 못 읽었다는 뜻이 아니에요.")

    # [진단] checkedNotes 생성 결과 요약 — 개수/참·거짓만 (이름·번호 금지).
    _log.info(
        f"[찾아본것] {len(notes)}줄"
        f" | 말소제외 {len(canceled_mortgages)}건"
        f" | 상한생략 {sum(trimmed.values())}건"
        f" | 압류·가압류 문구: {'있음' if active_signals else '없음'}"
    )
    return notes
