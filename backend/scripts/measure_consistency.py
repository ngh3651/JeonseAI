r"""일관성 측정 — **같은 종이 등기부를 여러 번 찍으면 판정이 같은가** (2026-10-22, P1-1 · P2-2 숫자).

NOW.md P1-1 완료 조건: "같은 종이 등기부를 10번 찍어 판정 일치 9회 이상, 나머지는 반드시 재촬영 안내".
지금까지 시험은 전부 화면 캡처였다. 이 도구가 **종이 촬영본**으로 그 숫자를 잰다.

입력 폴더 모양 (등기부 하나 = 폴더 하나, 촬영 한 번 = 하위 폴더 하나):

    촬영묶음/
      등기부A/
        01/  page_1.jpg page_2.jpg …     ← 1번째로 찍은 묶음(쪽 순서 = 파일 이름 순)
        02/  …
        …
      등기부B/
        01/ …

각 묶음을 **실제 분석 경로 그대로**(`report_builder.analyze` — 촬영 검사 → IE ∥ OCR → 규칙 판정) 돌리고,
등기부마다 아래를 잰다:
- **판정 등급 일치율** — 가장 많이 나온 등급과 같은 회차 비율(재촬영 안내로 거절된 회차는 따로 센다)
- **주요 필드 일치율** — 주소·전용면적·집주인 수·근저당/압류 등 유효 항목 지문(접수일·금액)·선순위 합계
- **재촬영 안내** — 거절(분석 전) · 확인 필요(분석 후) 회차 수
- **처리 시간** — 회차별 초(가운데 값·최대)

결과는 `backend/out/consistency_<시각>.md`(표) + `.json`(원자료)로 쓴다. `out/`은 git에 안 올라간다.
⚠ 개인정보: 실명·주소 원문을 쓰지 않는다 — 주소·지문은 6자리 해시, 집주인은 사람 수만.
⚠ 판정·기준값을 바꾸지 않는다. 재기만 한다.

실행 (크레딧 사용 — 묶음 하나 = IE 1회 + OCR 장수만큼 + 설명 1회):
    cd backend
    python scripts/measure_consistency.py ../촬영묶음 --deposit 120000000
    python scripts/measure_consistency.py ../촬영묶음 --deposit 120000000 --market-price 200000000
    python scripts/measure_consistency.py --dry-run          # 키 없이 합성 픽스처로 표 모양만 확인(크레딧 0원)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import statistics
import sys
import tempfile
import time
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_BACKEND_ROOT))

OUT_DIR = _BACKEND_ROOT / "out"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".heic"}
_DEVICE = "measure-consistency-0001"  # 측정 전용 기기 id — 앱 기록과 섞이지 않게


# ══════════════════════════════════════════════════════════════════════════════
# 자료구조
# ══════════════════════════════════════════════════════════════════════════════


@dataclass
class Shot:
    """촬영 한 번(묶음 하나)의 결과 — 원문 없이 해시·개수·등급만."""

    name: str
    pages: int
    seconds: float
    outcome: str  # analyzed | rejected | error
    grade: str | None = None
    fields: dict[str, str] = field(default_factory=dict)  # 필드 이름 → 6자리 해시
    capture_issues: list[str] = field(default_factory=list)  # ["2쪽 blurry", …]
    error: str | None = None


@dataclass
class Registry:
    name: str
    shots: list[Shot]


def _h(value: object) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, default=str).encode()).hexdigest()[:6]


# ══════════════════════════════════════════════════════════════════════════════
# 한 묶음 분석
# ══════════════════════════════════════════════════════════════════════════════


def _field_hashes(extract, report) -> dict[str, str]:
    """판정에 들어가는 '주요 필드' → 해시. 값은 남기지 않는다."""
    from app.services import compare

    snap = compare.build_snapshot(extract, report=report, page_count=0, manual_market_price=None, name_salt=b"m" * 16)
    out = {
        "주소": _h(snap.address),
        "전용면적": _h(snap.area_sqm),
        "집주인 수": _h(len(snap.owner_keys)),
        "선순위 합계": _h(report.seniorDebtAmount),
    }
    for name, fps in snap.entries.items():
        label = compare.FIELD_LABELS.get(name, name)
        out[label] = _h(sorted((fp.key, fp.amount, fp.receipt_date) for fp in fps))
    return out


def analyze_bundle(images: list[tuple[str, bytes]], *, deposit: int, market_price: int | None) -> Shot:
    """실제 분석 경로 그대로 한 번. 촬영 검사 거절은 '재촬영 안내'로 센다(크레딧 0원)."""
    from app.services import capture_check, extraction, report_builder

    captured: dict = {}
    real_extract = extraction.extract_registry

    def spy(imgs, **kw):  # 판정 재료(IE 결과)를 옆에서 받아 둔다 — 경로는 그대로
        result = real_extract(imgs, **kw)
        captured["extract"] = result
        return result

    t0 = time.perf_counter()
    check = capture_check.precheck(images)
    if capture_check.should_reject(check):
        assert check is not None
        return Shot(
            name="",
            pages=len(images),
            seconds=time.perf_counter() - t0,
            outcome="rejected",
            capture_issues=[f"{p.index + 1}쪽 {'/'.join(p.issues)}" for p in check.pages if p.severe],
        )
    extraction.extract_registry = spy
    try:
        report = report_builder.analyze(
            images, deposit=deposit, market_price=market_price, alias=None, device_id=_DEVICE, capture=check
        )
    except Exception as e:  # noqa: BLE001 — 한 묶음 실패가 측정 전체를 멈추지 않게
        return Shot(name="", pages=len(images), seconds=time.perf_counter() - t0, outcome="error",
                    error=f"{type(e).__name__}: {getattr(e, 'detail', '')}"[:120])
    finally:
        extraction.extract_registry = real_extract
    seconds = time.perf_counter() - t0
    issues = [
        f"{p.index + 1}쪽 {'/'.join(p.issues)}" for p in (report.captureCheck.pages if report.captureCheck else [])
    ]
    return Shot(
        name="",
        pages=len(images),
        seconds=seconds,
        outcome="analyzed",
        grade=report.grade,
        fields=_field_hashes(captured["extract"], report) if "extract" in captured else {},
        capture_issues=issues,
    )


def _read_bundle(folder: Path) -> list[tuple[str, bytes]]:
    files = sorted(p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in IMAGE_EXTS)
    return [(p.name, p.read_bytes()) for p in files]


def collect(root: Path, *, deposit: int, market_price: int | None) -> list[Registry]:
    registries: list[Registry] = []
    for reg_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        bundles = sorted(p for p in reg_dir.iterdir() if p.is_dir())
        if not bundles:  # 하위 폴더 없이 사진만 있으면 그 폴더 자체를 한 묶음으로
            bundles = [reg_dir]
        shots: list[Shot] = []
        for b in bundles:
            images = _read_bundle(b)
            if not images:
                continue
            print(f"  {reg_dir.name}/{b.name}: 사진 {len(images)}장 분석 중…", flush=True)
            shot = analyze_bundle(images, deposit=deposit, market_price=market_price)
            shot.name = b.name
            print(f"    → {shot.outcome} {shot.grade or ''} ({shot.seconds:.1f}초)"
                  f"{' · ' + ', '.join(shot.capture_issues) if shot.capture_issues else ''}", flush=True)
            shots.append(shot)
        if shots:
            registries.append(Registry(reg_dir.name, shots))
    return registries


# ══════════════════════════════════════════════════════════════════════════════
# 집계 · 표
# ══════════════════════════════════════════════════════════════════════════════


def summarize(reg: Registry) -> dict:
    analyzed = [s for s in reg.shots if s.outcome == "analyzed"]
    rejected = [s for s in reg.shots if s.outcome == "rejected"]
    errors = [s for s in reg.shots if s.outcome == "error"]
    grades = Counter(s.grade for s in analyzed)
    top_grade, top_count = grades.most_common(1)[0] if grades else (None, 0)
    field_names = sorted({k for s in analyzed for k in s.fields})
    field_agree: dict[str, float] = {}
    for name in field_names:
        values = Counter(s.fields.get(name) for s in analyzed)
        field_agree[name] = values.most_common(1)[0][1] / len(analyzed)
    all_fields_same = sum(
        1 for s in analyzed if all(s.fields.get(n) == Counter(x.fields.get(n) for x in analyzed).most_common(1)[0][0]
                                   for n in field_names)
    )
    seconds = [s.seconds for s in analyzed]
    flagged = [s for s in analyzed if s.capture_issues]
    # 완료 조건: 판정 일치 회차 + (다른 판정이 나왔지만 재촬영 안내가 붙은 회차) — 안내 없이 틀린 회차가 '놓친 것'
    silent_miss = [s for s in analyzed if s.grade != top_grade and not s.capture_issues]
    return {
        "name": reg.name,
        "shots": len(reg.shots),
        "analyzed": len(analyzed),
        "rejected": len(rejected),
        "errors": len(errors),
        "top_grade": top_grade,
        "grade_agree": top_count,
        "grade_agree_pct": (top_count / len(analyzed) * 100) if analyzed else 0.0,
        "grades": dict(grades),
        "field_agree": field_agree,
        "all_fields_same": all_fields_same,
        "flagged": len(flagged),
        "silent_miss": len(silent_miss),
        "sec_median": statistics.median(seconds) if seconds else 0.0,
        "sec_max": max(seconds) if seconds else 0.0,
    }


def render_markdown(summaries: list[dict], registries: list[Registry], *, deposit: int, market_price: int | None,
                    dry_run: bool) -> str:
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = [
        f"# 일관성 측정 — 같은 등기부를 여러 번 찍으면 판정이 같은가 ({now})",
        "",
        "> `backend/scripts/measure_consistency.py`가 만들었다. 실명·주소 원문 없음(해시·개수만).",
        f"> 입력: 보증금 {deposit:,}원 · 시세 {'입력 ' + format(market_price, ',') + '원' if market_price else '자동 조회'}"
        + (" · **합성 픽스처(--dry-run) — 실제 촬영 측정이 아니다**" if dry_run else ""),
        "",
        "## 요약",
        "",
        "| 등기부 | 촬영 | 분석됨 | 분석 전 거절 | 오류 | 판정 일치 | 가장 많은 등급 | 주요 필드 전부 일치 | 확인 필요 안내 | 안내 없이 다른 판정 | 처리 시간(가운데/최대) |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for s in summaries:
        lines.append(
            f"| {s['name']} | {s['shots']} | {s['analyzed']} | {s['rejected']} | {s['errors']}"
            f" | **{s['grade_agree']}/{s['analyzed']} ({s['grade_agree_pct']:.0f}%)** | {s['top_grade'] or '-'}"
            f" | {s['all_fields_same']}/{s['analyzed']} | {s['flagged']} | {s['silent_miss']}"
            f" | {s['sec_median']:.1f}초 / {s['sec_max']:.1f}초 |"
        )
    lines += [
        "",
        "- **완료 조건(NOW.md P1-1)**: 10번 찍어 판정 일치 9회 이상, 나머지는 반드시 재촬영 안내"
        " → '안내 없이 다른 판정'이 **0**이어야 한다.",
        "",
        "## 주요 필드별 일치율",
        "",
    ]
    for s in summaries:
        if not s["field_agree"]:
            continue
        lines.append(f"### {s['name']}")
        lines.append("")
        lines.append("| 필드 | 일치율 |")
        lines.append("|---|---|")
        for name, pct in s["field_agree"].items():
            lines.append(f"| {name} | {pct * 100:.0f}% |")
        lines.append("")
    lines += ["## 회차별", "", "| 등기부 | 회차 | 장수 | 결과 | 등급 | 촬영 안내 | 초 |", "|---|---|---|---|---|---|---|"]
    for reg in registries:
        for shot in reg.shots:
            lines.append(
                f"| {reg.name} | {shot.name} | {shot.pages} | {shot.outcome} | {shot.grade or '-'}"
                f" | {', '.join(shot.capture_issues) or '-'} | {shot.seconds:.1f} |"
            )
    return "\n".join(lines) + "\n"


def write_outputs(registries: list[Registry], *, deposit: int, market_price: int | None, dry_run: bool,
                  out_dir: Path) -> tuple[Path, Path]:
    summaries = [summarize(r) for r in registries]
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    md = out_dir / f"consistency_{stamp}{'_dryrun' if dry_run else ''}.md"
    js = md.with_suffix(".json")
    md.write_text(render_markdown(summaries, registries, deposit=deposit, market_price=market_price, dry_run=dry_run),
                  encoding="utf-8")
    js.write_text(json.dumps({"summaries": summaries, "registries": [
        {"name": r.name, "shots": [s.__dict__ for s in r.shots]} for r in registries
    ]}, ensure_ascii=False, indent=2), encoding="utf-8")
    return md, js


# ══════════════════════════════════════════════════════════════════════════════
# --dry-run — 키 없이 합성 픽스처로 (크레딧 0원)
# ══════════════════════════════════════════════════════════════════════════════


def _dry_run_folder(root: Path) -> None:
    """합성 '촬영 묶음' — 등기부 1개 × 4회: 선명 3회 + 심하게 흐린 1회(분석 전 거절)."""
    from PIL import Image, ImageDraw, ImageFilter, ImageFont

    def page(blur: float = 0.0) -> bytes:
        import io

        im = Image.new("L", (1240, 1754), 250)
        d = ImageDraw.Draw(im)
        font = ImageFont.load_default(size=22)
        for i, y in enumerate(range(100, 1600, 42)):
            d.text((60, y), f"{i % 9 + 1}  2004-06-25  MORTGAGE  max 36,000,000 KRW  No.{41414 + i}", font=font, fill=25)
        d.text((1060, 1680), "1/1", font=font, fill=25)
        if blur:
            im = im.filter(ImageFilter.GaussianBlur(blur))
        buf = io.BytesIO()
        im.convert("RGB").save(buf, "JPEG", quality=90)
        return buf.getvalue()

    reg = root / "합성등기부"
    for i, blur in enumerate((0.0, 0.0, 0.0, 4.0), start=1):
        shot = reg / f"{i:02d}"
        shot.mkdir(parents=True)
        (shot / "page_1.jpg").write_bytes(page(blur))


def _install_dry_run_fakes() -> None:
    """외부 호출을 전부 가짜로 — IE·OCR·설명. 판정·촬영 검사·리포트 조립은 실물이다."""
    import requests

    from app.services import extraction, ocr

    ie_raw = {
        "address": "서울특별시 ○○구 ○○동 1-1",
        "exclusive_area_sqm": 44.2,
        "current_owners": [{"name": "가나다", "share": "단독"}],
        "ownership_changes": [], "provisional_seizures": [], "provisional_dispositions": [], "seizures": [],
        "auction_commencements": [], "trust_registrations": [],
        "mortgages": [{"rank_number": 1, "max_claim_amount": 36000000, "mortgagee": "○○은행", "is_canceled": False}],
        "jeonse_rights": [], "lease_registrations": [],
    }

    class _Resp:
        status_code = 200
        text = ""

        def __init__(self, payload):
            self._p = payload

        def json(self):
            return self._p

    def fake_post(url, *args, **kwargs):
        if url == extraction.UPSTAGE_URL:
            return _Resp({"choices": [{"message": {"content": json.dumps(ie_raw, ensure_ascii=False)}}]})
        if url == ocr.OCR_URL:
            words = [{"text": "1/1", "confidence": 0.99,
                      "boundingBox": {"vertices": [{"x": 1060, "y": 1680}, {"x": 1090, "y": 1680},
                                                   {"x": 1090, "y": 1700}, {"x": 1060, "y": 1700}]}}]
            return _Resp({"pages": [{"id": 0, "width": 1240, "height": 1754, "words": words}]})
        if url.endswith("/chat/completions"):
            return _Resp({"choices": [{"message": {"content": json.dumps({"headline": "확인이 필요해요", "evidences": []})}}],
                          "usage": {}})
        raise AssertionError(f"dry-run이 막지 않은 외부 호출: {url}")

    requests.post = fake_post  # type: ignore[assignment]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="같은 등기부를 여러 번 찍었을 때 판정 일치율을 잰다")
    parser.add_argument("folder", nargs="?", help="촬영 묶음 폴더 (등기부/회차/사진)")
    parser.add_argument("--deposit", type=int, default=120_000_000, help="예정 보증금(원)")
    parser.add_argument("--market-price", type=int, default=None, help="시세(원) — 안 주면 자동 조회")
    parser.add_argument("--dry-run", action="store_true", help="키 없이 합성 픽스처로 (크레딧 0원)")
    parser.add_argument("--out", type=Path, default=OUT_DIR, help="결과를 쓸 폴더 (기본 backend/out)")
    args = parser.parse_args(argv)

    logging.getLogger("jeonseai").setLevel(logging.WARNING)  # 분석 로그는 끄고 진행 상황만 찍는다

    with tempfile.TemporaryDirectory() as tmp:
        # 측정 기록은 앱 기록 DB와 섞지 않는다 — 임시 DATA_DIR. 캐시도 끈다(같은 사진을 일부러 다시 넣는 측정이다).
        os.environ["DATA_DIR"] = str(Path(tmp) / "data")
        os.environ["ANALYSIS_CACHE_HOURS"] = "0"
        if args.dry_run:
            os.environ["UPSTAGE_API_KEY"] = "dry-run"
            os.environ["MOLIT_API_KEY"] = ""
            os.environ["LLM_STRUCTURE_PROVIDER"] = "off"
            os.environ["SAVE_RAW_RESPONSES"] = ""
            root = Path(tmp) / "bundles"
            _dry_run_folder(root)
            _install_dry_run_fakes()
        else:
            if not args.folder:
                parser.error("촬영 묶음 폴더를 주거나 --dry-run 을 쓰세요")
            root = Path(args.folder)
            if not root.is_dir():
                parser.error(f"폴더가 없어요: {root}")
            print("⚠ 실제 분석을 돌립니다 — 묶음마다 Upstage 크레딧을 씁니다 (IE 1회 + OCR 장수 + 설명 1회)")

        registries = collect(root, deposit=args.deposit, market_price=args.market_price)
        if not registries:
            print("분석할 묶음이 없어요 — 폴더 모양: <폴더>/<등기부>/<회차>/사진들")
            return 1
        md, js = write_outputs(registries, deposit=args.deposit, market_price=args.market_price,
                               dry_run=args.dry_run, out_dir=args.out)
    print(f"\n결과: {md}\n원자료: {js}")
    for s in (summarize(r) for r in registries):
        print(f"  {s['name']}: 판정 일치 {s['grade_agree']}/{s['analyzed']} · 분석 전 거절 {s['rejected']}"
              f" · 안내 없이 다른 판정 {s['silent_miss']} · 가운데 {s['sec_median']:.1f}초")
    return 0


if __name__ == "__main__":
    sys.exit(main())
