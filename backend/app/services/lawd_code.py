"""법정동코드 로더 — 등기부 주소 → 국토부 실거래가 API용 `LAWD_CD` **후보 목록**.

왜 "후보 목록"인가 (2026-07-29 설계):
우리가 필요한 것은 최신 행정코드가 아니라 **실거래가 API가 받아주는 코드**다. 행정구역
개편은 최근인데(전남광주통합특별시 2026-07-01 출범 — 4주 전), API에 쌓인 과거 거래는
옛 코드로 신고돼 있고 등기부 주소도 옛 표기일 수 있다. 어느 쪽을 받는지는 실호출
전까지 알 수 없으므로, 코드 하나를 고르지 않고 **우선순위가 있는 후보들**을 돌려준다.
호출부가 순서대로 시도해 데이터가 나오는 첫 코드를 쓰고, 어느 코드가 통했는지 로그에 남긴다.

⚠ 이 모듈은 **판정에 개입하지 않는다.** 위험 등급·임계값과 무관하며, 매칭 실패는
  "시세를 모른다"로 이어질 뿐이다(전세가율·선순위는 지금처럼 '확인 필요'로 남는다).
  추측으로 비슷한 코드를 돌려주지 않는다 — 틀린 시세는 없는 시세보다 나쁘다.

데이터 출처: 행정표준코드관리시스템(code.go.kr) '법정동 코드 전체자료'
  → `backend/data/lawd_codes.txt` (탭 구분 3컬럼: 법정동코드 / 법정동명 / 폐지여부)
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

_log = logging.getLogger("jeonseai")

_BACKEND_ROOT = Path(__file__).resolve().parents[2]
LAWD_CODE_FILE = _BACKEND_ROOT / "data" / "lawd_codes.txt"

# 인코딩 — **실측으로 확정했다(추측 아님).**
# 2026-07-29 확인: 파일 앞 4000바이트를 네 가지로 디코드해 본 결과
#   utf-8 → UnicodeDecodeError · utf-16 → UnicodeDecodeError
#   cp949 → 성공, 헤더가 '법정동코드\t법정동명\t폐지여부'로 정상 복원
# BOM 없음. cp949는 euc-kr의 상위집합이라 euc-kr로도 열리지만, 확장 한글이 섞였을 때
# 깨지지 않도록 넓은 쪽(cp949)을 명시한다. 총 53,388행.
FILE_ENCODING = "cp949"

MISSING_FILE_GUIDE = (
    "법정동 코드 파일이 없습니다. code.go.kr(행정표준코드관리시스템)에서 "
    "'법정동 코드 전체자료'를 받아 backend/data/lawd_codes.txt 에 두세요."
)


class LawdCodeError(Exception):
    """법정동코드 파일을 읽을 수 없음 — 설정/자산 문제.

    `extraction.ExtractionError`를 쓰지 않는 이유: 저건 HTTP 상태코드 + 사용자용 문구를
    갖는 **API 호출 실패** 계약이다. 이건 외부 호출이 아니라 로컬 자산 누락이고,
    아직 사용자 화면에 닿는 경로도 없다(CLI 전용). HTTP 성격 에러는 STEP 2의
    `market_price.py`가 기존 패턴대로 만든다.
    """


# ── 시도 명칭 변경 표 (확정본) ───────────────────────────────────────────────
#
# 출처: 각 특별자치도/통합시 출범(설치법 시행)일. 코드 앞 2자리는
#       backend/data/lawd_codes.txt 에서 실제로 확인한 값이다(기억으로 적지 않았다).
# 기준일: 2026-07-29 (lawd_codes.txt 스냅샷 — 행 수·인코딩은 backend/data/README.md 부록)
#
# ⚠ 존재/폐지 판정 근거: **아래 날짜가 아니라 파일의 3번째 컬럼(`폐지여부`)이다.**
#   코드는 `존재`/`폐지` 문자열만 읽고(`SigunguRow.active`), 이 표의 날짜는 어떤 로직에도
#   쓰이지 않는다 — 사람이 "왜 두 코드가 공존하나"를 알기 위한 설명일 뿐이다.
#   그래서 파일을 새로 받으면 존재/폐지가 자동으로 따라 바뀌고, 이 표는 손대지 않아도 된다
#   (새 개편이 생겼을 때만 행을 추가한다).
#
#   강원도(42)      ↔ 강원특별자치도(51)      2023-06-11
#   전라북도(45)    ↔ 전북특별자치도(52)      2024-01-18
#   제주도(49)      ↔ 제주특별자치도(50)      2006-07-01
#   광주광역시(29)  → 전남광주통합특별시(12)  2026-07-01
#   전라남도(46)    → 전남광주통합특별시(12)  2026-07-01
#
# ⚠ 개편되면 **코드 앞자리가 바뀐다**(강원 42→51). 이름만 바뀌는 게 아니다.
#   그래서 옛 이름 행은 '폐지'로 남고 새 이름 행이 따로 생긴다 — 둘 다 후보로 쓴다.
#
# ⚠ 광주·전남은 **2:1 통합**이라 역방향이 1:1이 아니다(12 → 29 또는 46).
#   접미사만 보고 짝을 찾지 않는다 — "광주광역시 서구"와 "대구광역시 서구"를 잘못
#   이을 수 있기 때문. 아래 표에 적힌 쌍만 쓰고, 실제 선택은 **법정동명 전체 접두
#   일치**가 가른다(예: '전남광주통합특별시 목포시' → '전라남도 목포시'는 존재하고
#   '광주광역시 목포시'는 없으므로 후자는 자연히 탈락한다).
#
# 여기 없는 옛 표기(예: '광주직할시'(24) — 1995년 이전)는 의도적으로 넣지 않았다.
# 표에 없는 이름을 임의로 추가하지 말 것 — 추가하려면 출처·시행일을 함께 적는다.


@dataclass(frozen=True)
class _SidoRename:
    old_name: str
    old_prefix: str  # 법정동코드 앞 2자리
    new_name: str
    new_prefix: str
    effective: str  # 출범일 (YYYY-MM-DD)


_SIDO_RENAMES: tuple[_SidoRename, ...] = (
    _SidoRename("강원도", "42", "강원특별자치도", "51", "2023-06-11"),
    _SidoRename("전라북도", "45", "전북특별자치도", "52", "2024-01-18"),
    _SidoRename("제주도", "49", "제주특별자치도", "50", "2006-07-01"),
    _SidoRename("광주광역시", "29", "전남광주통합특별시", "12", "2026-07-01"),
    _SidoRename("전라남도", "46", "전남광주통합특별시", "12", "2026-07-01"),
)


@lru_cache(maxsize=1)
def _sido_aliases() -> dict[str, tuple[str, ...]]:
    """시도명 → 같은 지역을 가리키는 다른 표기들. 위 표에서만 만든다(양방향)."""
    aliases: dict[str, set[str]] = {}
    for r in _SIDO_RENAMES:
        aliases.setdefault(r.old_name, set()).add(r.new_name)
        aliases.setdefault(r.new_name, set()).add(r.old_name)
    return {name: tuple(sorted(alts)) for name, alts in aliases.items()}


# ── 파일 로딩 ────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class SigunguRow:
    """실거래가 API에 보낼 수 있는 시군구 단위 행."""

    code: str  # 법정동코드 10자리
    name: str  # 법정동명 전체 경로 (예: '경기도 수원시 장안구')
    active: bool  # 폐지여부 == '존재'

    @property
    def lawd_cd(self) -> str:
        """실거래가 API의 LAWD_CD — 법정동코드 앞 5자리."""
        return self.code[:5]

    @property
    def tokens(self) -> tuple[str, ...]:
        return tuple(self.name.split())


def _is_sigungu(code: str) -> bool:
    """시군구 행인가.

    법정동코드 10자리 자리별 의미: [1-2]=시도 [3-5]=시군구 [6-8]=읍면동 [9-10]=리
    시군구 행 = [3-5]가 '000'이 아니면서 [6-10]이 전부 '0'.

    세종특별자치시(3611000000)도 이 규칙을 통과한다 — [3-5]='110'이라 시도 행이
    아니라 시군구 행으로 잡히고, LAWD_CD는 36110이 된다. 별도 예외가 필요 없다.
    """
    return len(code) == 10 and code.isdigit() and code[2:5] != "000" and code[5:] == "00000"


@lru_cache(maxsize=1)
def _load_rows() -> tuple[SigunguRow, ...]:
    """lawd_codes.txt에서 시군구 행만 뽑아 온다. **폐지 행도 버리지 않는다.**

    폐지 행을 남기는 이유: 실거래가 API에 쌓인 과거 신고는 옛 코드로 들어가 있을 수
    있다. 최신 코드만 들고 있으면 개편 지역에서 조회가 통째로 비게 된다.
    """
    if not LAWD_CODE_FILE.exists():
        raise LawdCodeError(MISSING_FILE_GUIDE)

    try:
        text = LAWD_CODE_FILE.read_text(encoding=FILE_ENCODING)
    except UnicodeDecodeError as e:  # 인코딩이 바뀌었으면 조용히 깨지지 말고 멈춘다
        raise LawdCodeError(
            f"법정동 코드 파일을 {FILE_ENCODING}로 읽지 못했습니다. "
            "code.go.kr에서 다시 받아 주세요."
        ) from e
    except OSError as e:
        raise LawdCodeError(f"법정동 코드 파일을 열지 못했습니다: {e}") from e

    rows: list[SigunguRow] = []
    for line in text.splitlines()[1:]:  # 첫 줄은 헤더
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        code, name, status = parts[0].strip(), parts[1].strip(), parts[2].strip()
        if not _is_sigungu(code) or not name:
            continue
        rows.append(SigunguRow(code=code, name=name, active=(status == "존재")))

    if not rows:
        raise LawdCodeError(
            "법정동 코드 파일에서 시군구 행을 하나도 찾지 못했습니다. 파일 형식을 확인해 주세요."
        )
    return tuple(rows)


@lru_cache(maxsize=1)
def _index() -> dict[tuple[str, ...], tuple[SigunguRow, ...]]:
    """법정동명 토큰 튜플 → 그 이름을 가진 행들.

    같은 이름이 여러 코드로 존재할 수 있다 — 실측: '경기도 부천시 원미구'가
    41192(존재)와 41195(폐지) 둘 다다. 그래서 값이 리스트다.
    """
    index: dict[tuple[str, ...], list[SigunguRow]] = {}
    for row in _load_rows():
        index.setdefault(row.tokens, []).append(row)
    return {k: tuple(v) for k, v in index.items()}


@lru_cache(maxsize=1)
def _max_name_tokens() -> int:
    return max(len(t) for t in _index())


# ── 주소 → 후보 ──────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class LawdCandidate:
    """실거래가 API에 시도해 볼 코드 하나."""

    lawd_cd: str  # 5자리
    name: str  # 매칭된 법정동명 (로그·검증용)
    active: bool  # '존재' 행이면 True
    matched_tokens: int  # 몇 토큰까지 일치했나 (구 > 시 우선순위 근거)


def _address_head(address: str) -> str:
    """주소에서 시도·시군구가 들어 있는 앞부분만 남긴다.

    `formatting.short_address`와 같은 관례를 쓴다 — 등기부는 '지번, 도로명'을 병기하는
    경우가 있어 **첫 콤마 앞**만 본다. (short_address는 반대로 '동'부터의 꼬리를
    돌려주므로 함수 자체는 재사용할 수 없고, 콤마 관례만 맞췄다.)

    OCR 헤더에서 오는 '[집합건물]' 같은 대괄호 표기는 앞에서 떼어 낸다.
    """
    head = (address or "").split(",")[0].strip()
    while head.startswith("["):
        close = head.find("]")
        if close == -1:
            break
        head = head[close + 1 :].strip()
    return head


def _address_variants(tokens: tuple[str, ...]) -> list[tuple[str, ...]]:
    """시도 표기를 바꾼 주소 변형들(원본 포함). 위 정규화 표에서만 만든다."""
    if not tokens:
        return []
    variants = [tokens]
    for alias in _sido_aliases().get(tokens[0], ()):
        variants.append((alias,) + tokens[1:])
    return variants


def lawd_candidates(address: str) -> list[LawdCandidate]:
    """등기부 주소 → 시도해 볼 LAWD_CD 후보 목록 (우선순위 순).

    우선순위: **'존재' 행이 먼저, '폐지' 행이 나중.** 같은 상태 안에서는 더 길게
    일치한 쪽(구 > 시)이 먼저다 — '경기도 수원시 장안구'는 '경기도 수원시'(41110)와
    '경기도 수원시 장안구'(41111)에 모두 걸리는데, 실거래가 API가 받는 것은 구 단위다.

    ⚠ 이 순서는 **임시**다. '존재 먼저'가 맞는지는 STEP 2에서 강원 춘천시로
      42110(폐지)과 51110(존재)을 둘 다 찔러 확인한 뒤 근거와 함께 확정한다.
      과거 거래가 옛 코드로 신고돼 있다면 순서가 뒤집힐 수 있다.

    ⚠ 최장 일치 하나만 남기지 않고 **걸린 것을 모두 담는다.** 실측 근거:
      '경기도 부천시 원미구'는 41192(존재)와 41195(폐지)로 두 번 나오고,
      상위 행 '경기도 부천시'(41190)는 존재다. 최장 일치만 취하면 폐지 구가 뽑혀
      현행 코드(41190)를 잃는다. 모두 담고 순서로 가린다.

    못 찾으면 빈 목록. 추측하지 않는다.
    """
    tokens = tuple(_address_head(address).split())
    if not tokens:
        _warn_unmatched(tokens)
        return []

    index = _index()
    limit = _max_name_tokens()
    found: dict[str, LawdCandidate] = {}  # lawd_cd → 후보 (중복 제거)

    for variant in _address_variants(tokens):
        for size in range(1, min(limit, len(variant)) + 1):
            for row in index.get(variant[:size], ()):
                existing = found.get(row.lawd_cd)
                if existing is None or size > existing.matched_tokens:
                    found[row.lawd_cd] = LawdCandidate(
                        lawd_cd=row.lawd_cd,
                        name=row.name,
                        active=row.active,
                        matched_tokens=size,
                    )

    if not found:
        _warn_unmatched(tokens)
        return []

    # 존재 → 폐지, 그 다음 긴 일치 우선. 마지막 코드 정렬은 결과 안정성용(테스트 고정).
    return sorted(
        found.values(),
        key=lambda c: (not c.active, -c.matched_tokens, c.lawd_cd),
    )


def lawd_codes(address: str) -> list[str]:
    """`lawd_candidates`의 코드만 뽑은 편의 함수 (우선순위 순)."""
    return [c.lawd_cd for c in lawd_candidates(address)]


def _warn_unmatched(tokens: tuple[str, ...]) -> None:
    """매칭 실패를 조용히 넘기지 않는다.

    ⚠ 주소 전체·이름·상세번지는 찍지 않는다 — 로그에 개인정보를 남기지 않기 위해
      **시도+시군구까지(앞 2토큰)만** 남긴다.
    """
    head = " ".join(tokens[:2]) if tokens else "(빈 주소)"
    _log.warning(f"[시세] 법정동코드 매칭 실패 — 주소: {head}")
