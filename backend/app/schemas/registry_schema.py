"""등기부등본(등기사항전부증명서) 정보추출 스키마.

이 파일은 STEP 2-A(스키마 설계) 산출물입니다. **아직 API를 호출하지 않습니다.**
Upstage Information Extract에 이미지와 함께 넘길 JSON Schema를 정의합니다.

설계 원칙
- 체크리스트(표제부 / 갑구 / 을구)를 그대로 반영한다.
- "말소 여부"가 핵심이다. 등기부등본(말소사항 포함)에는 말소된 항목도 함께 나오므로,
  각 등기 항목마다 `is_canceled`(말소 여부) 필드를 두어 유효/말소를 구분한다.
- 여러 개일 수 있는 항목(근저당권, 가압류 등)은 **배열**로 둔다.
- 가압류·가처분·압류·경매·신탁 등도 단순 boolean("있다/없다")이 아니라 **항목 배열**로 둔다.
  이유: 항목마다 말소 여부가 다를 수 있어, "말소된 가압류"와 "유효한 가압류"를 구분해야
  하기 때문. 위험판단 로직에서 "유효한(=is_canceled=false) 항목이 하나라도 있는가"로
  '여부'를 계산한다.
- 필드 키는 영문 snake_case로 두고, 의미는 `description`(한국어)에 적는다.
  이유: JSON 키에 대한 인코딩/제약 리스크를 피하고 표준 JSON Schema 관례를 따르기 위함.
  (사람이 읽는 설명은 docs/registry-schema.md 참고)

────────────────────────────────────────────────────────────────────────
[확인 필요 — 다음 단계(STEP 2-B)에서 Upstage 공식 문서로 검증할 것]
1. Information Extract에 스키마를 넘기는 정확한 형태.
   - 본 파일은 OpenAI 호환 `response_format`(type=json_schema) 방식을 가정한다.
   - Upstage가 별도의 `schema`/`document_schema` 파라미터를 요구할 수도 있으므로,
     실제 호출 전에 console.upstage.ai/docs 에서 파라미터 이름을 확인해야 한다.
2. 정확한 endpoint / model 이름 (예: "information-extract"). 아래는 자리표시자.
3. 중첩 깊이(object 안 object 안 array) 지원 한계. 본 스키마는 3~4단계 중첩을 쓴다.
4. 금액 필드의 number 추출 신뢰도. 등기부는 "금 300,000,000원"처럼 표기되므로
   숫자 파싱이 흔들리면 string으로 받고 후처리하는 방안도 고려한다.
5. `required` / `additionalProperties` 존중 여부. 우선 최소한으로만 사용한다.
────────────────────────────────────────────────────────────────────────
"""

from typing import Any

# ── 재사용 조각: 모든 등기 항목이 공통으로 갖는 말소 여부 필드 ──
_IS_CANCELED_FIELD: dict[str, Any] = {
    "type": "boolean",
    "description": (
        "말소 여부. 등기부등본(말소사항 포함)에서 빨간 취소선(밑줄)이 그어져 "
        "말소된 항목이면 true, 현재 유효한 항목이면 false."
    ),
}


def _entry(properties: dict[str, Any], description: str) -> dict[str, Any]:
    """배열의 각 원소(등기 항목 하나)를 표현하는 object 스키마를 만든다.

    모든 항목에 공통으로 `is_canceled`를 추가한다.
    """
    props: dict[str, Any] = dict(properties)
    props["is_canceled"] = _IS_CANCELED_FIELD
    return {
        "type": "array",
        "description": description,
        "items": {
            "type": "object",
            "properties": props,
        },
    }


# 가압류·가처분·압류·경매개시결정처럼 "제3자의 권리 주장/처분제한" 성격 항목이
# 공통으로 갖는 필드 묶음.
def _claim_like_entry(description: str) -> dict[str, Any]:
    return _entry(
        {
            "rank_number": {
                "type": "string",
                "description": "순위번호(갑구 순위번호). 예: '3', '3-1'",
            },
            "purpose": {"type": "string", "description": "등기목적"},
            "receipt_date": {
                "type": "string",
                "description": "접수일자. 가능하면 YYYY-MM-DD 형식",
            },
            "cause": {"type": "string", "description": "등기원인(예: 법원 결정)"},
            "claimant": {
                "type": "string",
                "description": "권리자/청구채권자(가압류권자, 압류권자 등)",
            },
            "claim_amount": {
                "type": "number",
                "description": "청구금액(원 단위 숫자). 기재가 없으면 생략 가능",
            },
        },
        description,
    )


# ── 전체 스키마 ──
REGISTRY_JSON_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        # ───────────── 표제부 ─────────────
        "property_description": {
            "type": "object",
            "description": "표제부 - 부동산(건물)의 기본 표시 정보",
            "properties": {
                "address": {
                    "type": "string",
                    "description": "소재지(주소). 도로명 또는 지번 주소 전체",
                },
                "exclusive_area_sqm": {
                    "type": "number",
                    "description": "건물 전용면적(㎡, 제곱미터). 숫자만",
                },
            },
        },
        # ───────────── 갑구 (소유권) ─────────────
        "ownership_section": {
            "type": "object",
            "description": "갑구 - 소유권에 관한 사항",
            "properties": {
                "current_owners": {
                    "type": "array",
                    "description": (
                        "현재 유효한(말소되지 않은) 소유자 목록. 공동소유면 여러 명"
                    ),
                    "items": {
                        "type": "object",
                        "properties": {
                            "name": {"type": "string", "description": "소유자 이름"},
                            "share": {
                                "type": "string",
                                "description": "지분(예: '1/2', '단독'). 단독이면 '단독' 또는 '1/1'",
                            },
                        },
                    },
                },
                "ownership_changes": _entry(
                    {
                        "rank_number": {
                            "type": "string",
                            "description": "순위번호. 예: '2', '2-1'",
                        },
                        "purpose": {
                            "type": "string",
                            "description": "등기목적(예: 소유권이전, 소유권보존)",
                        },
                        "receipt_date": {
                            "type": "string",
                            "description": "접수일자. 가능하면 YYYY-MM-DD",
                        },
                        "cause": {
                            "type": "string",
                            "description": "등기원인(예: 매매, 상속, 증여)",
                        },
                        "cause_date": {
                            "type": "string",
                            "description": "등기원인 일자. 가능하면 YYYY-MM-DD",
                        },
                        "holder": {
                            "type": "string",
                            "description": "권리자(해당 등기로 소유권을 취득한 사람)",
                        },
                    },
                    "소유권 변동 이력(보존/이전 등). 무자본 갭투자 의심 판단에 사용",
                ),
                "provisional_seizures": _claim_like_entry(
                    "가압류 목록(각 항목별 말소 여부 포함)"
                ),
                "provisional_dispositions": _claim_like_entry(
                    "가처분 목록(각 항목별 말소 여부 포함)"
                ),
                "seizures": _claim_like_entry("압류 목록(각 항목별 말소 여부 포함)"),
                "auction_commencements": _claim_like_entry(
                    "경매개시결정 목록(각 항목별 말소 여부 포함)"
                ),
                "trust_registrations": _entry(
                    {
                        "rank_number": {"type": "string", "description": "순위번호"},
                        "receipt_date": {
                            "type": "string",
                            "description": "접수일자. 가능하면 YYYY-MM-DD",
                        },
                        "trustee": {
                            "type": "string",
                            "description": "수탁자(신탁을 받은 자, 예: 신탁회사)",
                        },
                    },
                    "신탁등기 목록(각 항목별 말소 여부 포함)",
                ),
            },
        },
        # ───────────── 을구 (소유권 이외의 권리) ─────────────
        "encumbrance_section": {
            "type": "object",
            "description": "을구 - 소유권 이외의 권리에 관한 사항",
            "properties": {
                "mortgages": _entry(
                    {
                        "rank_number": {
                            "type": "string",
                            "description": "순위번호(을구). 선순위/후순위 판단에 사용",
                        },
                        "max_claim_amount": {
                            "type": "number",
                            "description": "채권최고액(원 단위 숫자). 예: 360,000,000 → 360000000",
                        },
                        "debtor": {"type": "string", "description": "채무자"},
                        "mortgagee": {
                            "type": "string",
                            "description": "근저당권자(돈을 빌려준 채권자, 예: OO은행)",
                        },
                        "receipt_date": {
                            "type": "string",
                            "description": "접수일자. 가능하면 YYYY-MM-DD",
                        },
                    },
                    "근저당권 목록. 선순위채권 규모 산정에 사용(각 항목별 말소 여부 포함)",
                ),
                "jeonse_rights": _entry(
                    {
                        "rank_number": {"type": "string", "description": "순위번호(을구)"},
                        "deposit_amount": {
                            "type": "number",
                            "description": "전세금(원 단위 숫자)",
                        },
                        "holder": {
                            "type": "string",
                            "description": "전세권자(전세권을 가진 사람)",
                        },
                        "receipt_date": {
                            "type": "string",
                            "description": "접수일자. 가능하면 YYYY-MM-DD",
                        },
                    },
                    "전세권 설정 목록(각 항목별 말소 여부 포함)",
                ),
                "lease_registrations": _entry(
                    {
                        "rank_number": {"type": "string", "description": "순위번호(을구)"},
                        "deposit_amount": {
                            "type": "number",
                            "description": "임차보증금(원 단위 숫자)",
                        },
                        "holder": {
                            "type": "string",
                            "description": "임차권자(임차권등기명령을 받은 임차인)",
                        },
                        "receipt_date": {
                            "type": "string",
                            "description": "접수일자. 가능하면 YYYY-MM-DD",
                        },
                    },
                    (
                        "임차권등기명령에 의한 임차권 목록. 존재하면 과거 보증금 미반환 "
                        "사고 이력 신호(각 항목별 말소 여부 포함)"
                    ),
                ),
            },
        },
    },
}


# 스키마 식별용 이름(응답 포맷 래퍼에 사용).
REGISTRY_SCHEMA_NAME = "real_estate_registry"


def build_response_format() -> dict[str, Any]:
    """Upstage Information Extract 호출 시 넘길 response_format 래퍼를 만든다.

    [확인 필요] OpenAI 호환 `response_format`(type=json_schema)를 가정한 형태다.
    실제 파라미터 이름/구조는 STEP 2-B에서 Upstage 공식 문서로 검증한 뒤 확정한다.
    """
    return {
        "type": "json_schema",
        "json_schema": {
            "name": REGISTRY_SCHEMA_NAME,
            "schema": REGISTRY_JSON_SCHEMA,
        },
    }
