"""시그니처 계약 — **목이 덮어 가린 자리**를 정적으로 지킨다.

왜 이 파일이 생겼나 (2026-07-28):
백엔드 테스트 298건이 전부 통과한 상태로 실기기 첫 실행에서 500이 났다. 원인은 전날 밤
provider 추상화로 바뀐 시그니처 세 자리였다:

    UpstageSolarProvider._payload() takes 4 positional arguments but 5 were given
    build_highlights() got an unexpected keyword argument 'check'

세 자리 모두 **테스트가 정확히 피해 간 자리**다. 가드레일 테스트는
`explanation._call_solar`를 목으로 바꿔치기하므로 그 아래의 `provider.chat` →
`_payload`가 한 번도 실행되지 않았고, `build_highlights`는 테스트가 직접
`(extract, ocr)`로만 불러서 `report_builder`가 쓰는 `check=` 경로를 태우지 않았다.
**목이 깨진 함수를 덮고 있었다.**

목을 없앨 수는 없다(실 API 호출은 크레딧이다). 대신 **목이 가린 이음매를 정적으로**
검사한다. 이 파일은 개별 함수를 알지 못한다 — 패키지 전체를 훑으므로 나중에 추가되는
함수·provider·호출부에도 자동으로 적용된다.

두 가지를 본다:
  A. **오버라이드 호환성** — 부모가 부르는 방식 그대로 자식을 부를 수 있는가.
     (오늘의 `_payload`. 부모는 인자 4개로 부르는데 자식은 3개만 받았다.)
  B. **호출부 바인딩** — 정적으로 잡히는 `모듈.함수(...)` 호출을 `Signature.bind`에
     실제로 태워 본다. (오늘의 `build_highlights(check=...)`.)

⚠ 이 파일은 판정 로직을 검사하지 않는다. 형태만 본다.
"""

from __future__ import annotations

import ast
import importlib
import inspect
import pkgutil
from pathlib import Path

import pytest

import app

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
_SOURCE_DIRS = ("app", "tests", "scripts")


def _all_app_modules() -> list:
    """`app.*` 전체를 실제로 import 한다 — import 자체가 깨져도 여기서 잡힌다."""
    mods = []
    failures = []
    for info in pkgutil.walk_packages(app.__path__, prefix="app."):
        try:
            mods.append(importlib.import_module(info.name))
        except Exception as e:  # noqa: BLE001
            failures.append(f"{info.name}: {type(e).__name__}: {e}")
    assert not failures, "app 하위 모듈 import 실패:\n  " + "\n  ".join(failures)
    return mods


APP_MODULES = _all_app_modules()


# ══════════════════════════════════════════════════════════════════════════════
# A. 오버라이드 호환성 — 부모가 부르는 대로 자식이 받는가
# ══════════════════════════════════════════════════════════════════════════════


def _iter_overrides():
    """(클래스, 부모, 메서드명, 부모 시그니처, 자식 시그니처) 전수."""
    seen = set()
    for mod in APP_MODULES:
        for _, cls in inspect.getmembers(mod, inspect.isclass):
            if not cls.__module__.startswith("app.") or cls in seen:
                continue
            seen.add(cls)
            for base in cls.__mro__[1:]:
                if not base.__module__.startswith("app."):
                    continue
                for name, child_fn in vars(cls).items():
                    if not inspect.isfunction(child_fn):
                        continue
                    parent_fn = vars(base).get(name)
                    if not inspect.isfunction(parent_fn):
                        continue
                    yield (
                        cls,
                        base,
                        name,
                        inspect.signature(parent_fn),
                        inspect.signature(child_fn),
                    )


def test_모든_오버라이드는_부모가_부르는_방식으로_불릴_수_있다():
    """오늘의 `_payload`가 정확히 이 검사에 걸린다.

    부모가 `self._payload(messages, max_tokens, json_mode, temperature)`로 **위치인자
    4개**를 넘기는데 자식이 3개만 받으면, 그 자식 provider는 **부를 때마다 TypeError**다.
    설명 생성은 폴백이 받아내지만(explanation.py), 폴백이 없는 자리에서는 그대로 500이다.
    """
    broken = []
    for cls, base, name, parent_sig, child_sig in _iter_overrides():
        positional = [
            p
            for p in parent_sig.parameters.values()
            if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)
        ]
        kwargs = {
            n: object()
            for n, p in parent_sig.parameters.items()
            if p.kind is p.KEYWORD_ONLY
        }
        try:
            child_sig.bind(*[object()] * len(positional), **kwargs)
        except TypeError as e:
            broken.append(
                f"{cls.__module__}.{cls.__name__}.{name}\n"
                f"        부모 {base.__name__}{parent_sig}\n"
                f"        자식 {cls.__name__}{child_sig}\n"
                f"        → {e}"
            )
    assert not broken, "부모 시그니처로 부를 수 없는 오버라이드:\n    " + "\n    ".join(broken)


# ══════════════════════════════════════════════════════════════════════════════
# B. 호출부 바인딩 — `모듈.함수(...)`를 실제 시그니처에 태워 본다
# ══════════════════════════════════════════════════════════════════════════════

_MODULE_BY_SHORT_NAME = {m.__name__.rsplit(".", 1)[-1]: m for m in APP_MODULES}


def _module_aliases(tree: ast.AST) -> dict:
    """`from ..services import highlight` / `import app.x as y` 를 실물 모듈에 붙인다.

    인스턴스 메서드(`self.foo()`, `obj.foo()`)는 **일부러 건드리지 않는다** — 정적으로
    타입을 못 믿어 오탐이 난다. 모듈 별칭을 통한 호출만 봐도 오늘의 세 건 중
    `build_highlights`가 잡힌다.
    """
    aliases: dict = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            for alias in node.names:
                target = _MODULE_BY_SHORT_NAME.get(alias.name)
                if target is not None:
                    aliases[alias.asname or alias.name] = target
        elif isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.startswith("app."):
                    try:
                        aliases[alias.asname or alias.name] = importlib.import_module(alias.name)
                    except Exception:  # noqa: BLE001, S110 — 못 불러오면 그냥 검사 대상에서 뺀다
                        pass
    return aliases


def _source_files() -> list[Path]:
    return sorted(p for d in _SOURCE_DIRS for p in (_BACKEND_ROOT / d).rglob("*.py"))


def test_정적으로_잡히는_호출은_전부_실제_시그니처에_바인딩된다():
    """오늘의 `build_highlights(check=...)`가 정확히 이 검사에 걸린다.

    `report_builder`는 `check=doc_check`를 넘기는데 `highlight.build_highlights`에는
    그런 인자가 없었다. 두 파일 다 테스트가 있었지만 **둘을 잇는 호출**은 아무도 안 태웠다.
    """
    broken = []
    checked = 0
    for path in _source_files():
        # `utf-8-sig` — 윈도우 도구(PowerShell `Set-Content -Encoding UTF8` 등)가 BOM을
        # 붙여 놓으면 `ast.parse`가 U+FEFF로 넘어진다. 파이썬 자신은 BOM을 무시하고 잘
        # 돌아가므로, 그것 때문에 **감사기만 죽는** 것은 앞뒤가 바뀐 일이다.
        tree = ast.parse(path.read_text(encoding="utf-8-sig"))
        aliases = _module_aliases(tree)
        if not aliases:
            continue
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            fn = node.func
            if not isinstance(fn, ast.Attribute) or not isinstance(fn.value, ast.Name):
                continue
            module = aliases.get(fn.value.id)
            target = getattr(module, fn.attr, None) if module is not None else None
            if not inspect.isfunction(target):
                continue
            # *args / **kwargs 전개는 정적으로 개수를 셀 수 없다 — 건너뛴다
            if any(isinstance(a, ast.Starred) for a in node.args) or any(
                k.arg is None for k in node.keywords
            ):
                continue
            checked += 1
            try:
                inspect.signature(target).bind(
                    *[object()] * len(node.args), **{k.arg: object() for k in node.keywords}
                )
            except TypeError as e:
                broken.append(
                    f"{path.relative_to(_BACKEND_ROOT)}:{node.lineno}\n"
                    f"        호출 {ast.unparse(node.func)}(...)\n"
                    f"        정의 {target.__module__}.{target.__qualname__}"
                    f"{inspect.signature(target)}\n"
                    f"        → {e}"
                )
    assert not broken, "호출부와 정의부가 어긋난 자리:\n    " + "\n    ".join(broken)
    # 검사가 **조용히 0건이 되는 것**이 가장 위험하다(별칭 해석이 깨지면 전부 통과한다).
    assert checked >= 100, f"정적 호출 검사가 {checked}건뿐 — 별칭 해석이 깨졌는지 확인"


# ══════════════════════════════════════════════════════════════════════════════
# 이 파일 자체가 살아 있는지 — 검사기가 진짜 잡는지 확인한다
# ══════════════════════════════════════════════════════════════════════════════


def test_검사기_자체가_어긋난_시그니처를_잡는다():
    """오늘의 두 버그를 그대로 재현해 검사 로직이 실제로 걸러내는지 본다.

    감사 도구가 **아무것도 못 잡는 상태로 통과**하는 것이 가장 흔한 실패다.
    """

    class Parent:
        def _payload(self, messages, max_tokens, json_mode, temperature):  # noqa: ANN001
            ...

    class Child(Parent):
        def _payload(self, messages, max_tokens, json_mode):  # noqa: ANN001 — 오늘의 버그
            ...

    parent_sig = inspect.signature(Parent._payload)
    child_sig = inspect.signature(Child._payload)
    positional = [
        p for p in parent_sig.parameters.values()
        if p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD)
    ]
    with pytest.raises(TypeError):
        child_sig.bind(*[object()] * len(positional))

    def build_highlights(extract, ocr, cross=None):  # noqa: ANN001 — 오늘의 버그
        ...

    with pytest.raises(TypeError):
        inspect.signature(build_highlights).bind(object(), object(), cross=None, check=None)
