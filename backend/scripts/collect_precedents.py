"""법제처 국가법령정보 공동활용 Open API 판례 수집 스크립트.

목표 상태(미션): **키(OC)만 꽂으면 대량 수집이 도는 것.**
- 목록 검색(lawSearch.do?target=prec) → 판례일련번호 → 본문(lawService.do) 2단 호출.
- 결과는 backend/data/precedents/raw/prec-<일련번호>.json 로 저장 (원본 필드 보존).
- 이후 `python scripts/ingest_precedents.py`가 청킹→임베딩→벡터DB 적재를 담당한다.

OC(API 인증값):
- 정식: open.law.go.kr 회원가입 → OPEN API 활용신청(승인 1~2일) → 발급 OC를
  backend/.env의 `LAW_API_OC`에 저장.
- 개발: `OC=test`(가이드 샘플 값)가 2026-07-22 현재 실동작함을 확인 — 단 언제 막힐지
  보장이 없으므로 프로덕션·대량 수집은 반드시 정식 OC로.

사용 예:
  # 사건번호로 특정 판례 수집 (시드 구축)
  python scripts/collect_precedents.py --nb "2005다4529"
  # 검색어로 대법원 판례 대량 수집
  python scripts/collect_precedents.py --query "임대차 보증금" --org 400201 --max 200
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

import requests
from dotenv import load_dotenv

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))

# Windows 콘솔(cp949)에서 한글·기호 출력 깨짐 방지
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

RAW_DIR = _BACKEND_ROOT / "data" / "precedents" / "raw"
SEARCH_URL = "http://www.law.go.kr/DRF/lawSearch.do"
SERVICE_URL = "http://www.law.go.kr/DRF/lawService.do"
REQUEST_INTERVAL_SECONDS = 0.5  # 공공 API 예의상 호출 간격 (트래픽 제한 명시 없음)
TIMEOUT = 30


def _load_oc(cli_oc: str | None) -> str:
    if cli_oc:
        return cli_oc
    load_dotenv(dotenv_path=_BACKEND_ROOT / ".env")
    oc = os.environ.get("LAW_API_OC", "").strip()
    if oc:
        return oc
    print("⚠ LAW_API_OC가 없어 개발용 OC=test로 호출합니다 (대량 수집은 정식 OC 필요)")
    return "test"


def _get_json(url: str, params: dict) -> dict:
    resp = requests.get(url, params=params, timeout=TIMEOUT)
    resp.raise_for_status()
    data = resp.json()
    # 에러 응답 형태: {"Law": {...,"result":"...검증에 실패..."}} 또는 최상위 result
    text = json.dumps(data, ensure_ascii=False)
    if "검증에 실패" in text:
        raise RuntimeError(f"법제처 API 사용자 검증 실패 — OC·IP 등록 확인 필요: {text[:200]}")
    return data


def search_precedents(
    oc: str, *, query: str | None = None, nb: str | None = None, org: str | None = None,
    search_scope: int = 1, display: int = 100, page: int = 1,
) -> tuple[int, list[dict]]:
    """판례 목록 검색 — (전체 건수, 항목 목록) 반환. 항목 값은 전부 문자열이다."""
    params: dict = {"OC": oc, "target": "prec", "type": "JSON", "display": display, "page": page}
    if query:
        params["query"] = query
        params["search"] = search_scope
    if nb:
        params["nb"] = nb
    if org:
        params["org"] = org
    data = _get_json(SEARCH_URL, params)
    body = data.get("PrecSearch", {})
    total = int(body.get("totalCnt", "0"))
    items = body.get("prec", [])
    if isinstance(items, dict):  # 결과 1건이면 dict로 오는 공공 API 관행 방어
        items = [items]
    return total, items


def fetch_precedent(oc: str, prec_id: str) -> dict:
    """판례 본문 조회 — 판시사항·판결요지·참조조문·판례내용 포함 원본 dict."""
    data = _get_json(SERVICE_URL, {"OC": oc, "target": "prec", "type": "JSON", "ID": prec_id})
    return data.get("PrecService", data)


def _clean(text: str | None) -> str:
    """본문 필드의 HTML 태그·이스케이프를 걷어낸다."""
    if not text:
        return ""
    text = re.sub(r"<br\s*/?>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    return text.replace("&nbsp;", " ").strip()


def save_raw(detail: dict, *, oc: str) -> Path:
    """본문 응답을 raw JSON으로 저장 — 원본 필드 보존 + 파이프라인용 매핑 필드 병기."""
    prec_id = str(detail.get("판례정보일련번호", "")).strip()
    if not prec_id:
        raise ValueError("판례정보일련번호가 없는 응답입니다")
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    out = {
        "_source": "law.go.kr Open API (lawService.do?target=prec)",
        "_collected_at": time.strftime("%Y-%m-%d"),
        "prec_id": prec_id,
        "case_no": _clean(detail.get("사건번호")),
        "case_name": _clean(detail.get("사건명")),
        "court": _clean(detail.get("법원명")),
        "decided": _clean(detail.get("선고일자")),  # 본문 API는 8자리 무구분(예: 20250415)
        "case_type": _clean(detail.get("사건종류명")),
        "holding_points": _clean(detail.get("판시사항")),
        "holding_summary": _clean(detail.get("판결요지")),
        "ref_articles": _clean(detail.get("참조조문")),
        "ref_precedents": _clean(detail.get("참조판례")),
        "full_text": _clean(detail.get("판례내용")),
        "source_url": f"https://www.law.go.kr/DRF/lawService.do?OC={oc}&target=prec&ID={prec_id}&type=HTML",
        "raw": detail,  # 원본 전체 보존 (필드 추가 대비)
    }
    path = RAW_DIR / f"prec-{prec_id}.json"
    path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def collect(
    oc: str, *, query: str | None, nb: str | None, org: str | None,
    search_scope: int, max_count: int,
) -> list[Path]:
    saved: list[Path] = []
    page = 1
    while len(saved) < max_count:
        total, items = search_precedents(
            oc, query=query, nb=nb, org=org, search_scope=search_scope, page=page
        )
        if not items:
            break
        print(f"목록 {page}페이지: {len(items)}건 (전체 {total}건)")
        for item in items:
            if len(saved) >= max_count:
                break
            prec_id = str(item.get("판례일련번호", "")).strip()
            if not prec_id:
                continue
            target = RAW_DIR / f"prec-{prec_id}.json"
            if target.exists():
                print(f"  건너뜀(이미 있음): {item.get('사건번호')}")
                saved.append(target)
                continue
            time.sleep(REQUEST_INTERVAL_SECONDS)
            try:
                detail = fetch_precedent(oc, prec_id)
                path = save_raw(detail, oc=oc)
                print(f"  저장: {item.get('사건번호')} → {path.name}")
                saved.append(path)
            except Exception as e:  # 개별 실패는 건너뛰고 계속 (대량 수집 내성)
                print(f"  실패({item.get('사건번호')}): {type(e).__name__}: {str(e)[:100]}")
        if page * 100 >= total:
            break
        page += 1
        time.sleep(REQUEST_INTERVAL_SECONDS)
    return saved


def main() -> None:
    ap = argparse.ArgumentParser(description="법제처 Open API 판례 수집")
    ap.add_argument("--query", help="검색어 (판례명 검색)")
    ap.add_argument("--nb", help="사건번호로 검색 (예: 2005다4529)")
    ap.add_argument("--org", help="법원종류 (대법원 400201, 하위법원 400202)")
    ap.add_argument("--search", type=int, default=1, help="검색범위 1=판례명 2=본문 (기본 1)")
    ap.add_argument("--max", type=int, default=20, help="최대 수집 건수 (기본 20)")
    ap.add_argument("--oc", help="API 인증값 (기본: .env LAW_API_OC → 없으면 test)")
    args = ap.parse_args()

    if not args.query and not args.nb:
        ap.error("--query 또는 --nb 중 하나는 필요합니다")

    oc = _load_oc(args.oc)
    saved = collect(
        oc, query=args.query, nb=args.nb, org=args.org,
        search_scope=args.search, max_count=args.max,
    )
    print(f"\n완료: {len(saved)}건 → {RAW_DIR}")
    print("다음 단계: python scripts/ingest_precedents.py (청킹→임베딩→벡터DB 적재)")


if __name__ == "__main__":
    main()
