#!/usr/bin/env python3

"""Generate and verify the frontend contracts owned by the backend DTOs."""

from __future__ import annotations

import argparse
import collections.abc
import difflib
import importlib.util
import json
import sys
import types
import typing
from dataclasses import dataclass
from pathlib import Path
from typing import Any, get_args, get_origin, get_type_hints, is_typeddict


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BACKEND_DIR = REPO_ROOT / "backend"
DEFAULT_FRONTEND_DIR = REPO_ROOT / "frontend"


class ContractGenerationError(RuntimeError):
    """Raised when a backend annotation cannot be represented faithfully."""


@dataclass(frozen=True)
class ContractSpec:
    name: str
    source_relative_path: Path
    output_relative_path: Path
    exports: tuple[str, ...]
    external_types: tuple[str, ...] = ()
    typescript_imports: tuple[tuple[str, str], ...] = ()


CONTRACT_SPECS = (
    ContractSpec(
        name="activitywatch",
        source_relative_path=Path("src/utils/activitywatch_event_dto.py"),
        output_relative_path=Path("src/shared/contracts/activitywatch.generated.ts"),
        exports=(
            "EventData",
            "AggregatedEvent",
        ),
    ),
    ContractSpec(
        name="scope",
        source_relative_path=Path("src/scope/activity_scope_dto.py"),
        output_relative_path=Path("src/shared/contracts/scope.generated.ts"),
        exports=("ActivityScopeResponse",),
    ),
    ContractSpec(
        name="timeline",
        source_relative_path=Path("src/timeline/timeline_dto.py"),
        output_relative_path=Path("src/shared/contracts/timeline.generated.ts"),
        exports=("TimelineSegment", "TimelineLane", "TimelineResponse"),
    ),
    ContractSpec(
        name="summary",
        source_relative_path=Path("src/summary/summary_dto.py"),
        output_relative_path=Path("src/shared/contracts/summary.generated.ts"),
        exports=(
            "SummaryWindow",
            "SummaryByPeriodEntry",
            "SummaryResponse",
        ),
        external_types=("AggregatedEvent",),
        typescript_imports=(("AggregatedEvent", "./activitywatch.generated"),),
    ),
    ContractSpec(
        name="browser",
        source_relative_path=Path("src/browser/browser_dto.py"),
        output_relative_path=Path("src/shared/contracts/browser.generated.ts"),
        exports=("BrowserResponse",),
        external_types=("AggregatedEvent",),
        typescript_imports=(("AggregatedEvent", "./activitywatch.generated"),),
    ),
    ContractSpec(
        name="daily_checkins",
        source_relative_path=Path(
            "src/daily_checkins/daily_checkin_dto.py"
        ),
        output_relative_path=Path(
            "src/shared/contracts/daily-checkins.generated.ts"
        ),
        exports=("DailyCheckInDTO", "DailyCheckInListDTO"),
    ),
    ContractSpec(
        name="review",
        source_relative_path=Path("src/review/review_dto.py"),
        output_relative_path=Path("src/shared/contracts/review.generated.ts"),
        exports=(
            "ReviewHighlight",
            "ReviewResponse",
        ),
    ),
    ContractSpec(
        name="model_output",
        source_relative_path=Path("src/model_output/model_output_dto.py"),
        output_relative_path=Path("src/shared/contracts/model-output.generated.ts"),
        exports=(
            "ModelOutputScale",
            "ModelOutputCounterfactualShift",
            "ModelOutputCounterfactual",
            "ModelOutputResult",
            "InsightConfirmationState",
            "ModelOutputReport",
            "ModelOutputResponse",
        ),
    ),
    ContractSpec(
        name="model_feedback",
        source_relative_path=Path("src/model_feedback/model_feedback_dto.py"),
        output_relative_path=Path("src/shared/contracts/model-feedback.generated.ts"),
        exports=(
            "ModelFeedbackDTO",
            "ModelFeedbackResponse",
            "ModelFeedbackSubmission",
        ),
    ),
)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Write or check all frontend contracts generated from backend DTOs."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--write",
        action="store_true",
        help="Regenerate all frontend contract files.",
    )
    mode.add_argument(
        "--check",
        action="store_true",
        help="Fail if any generated frontend contract is stale.",
    )
    parser.add_argument(
        "--backend-dir",
        type=Path,
        default=DEFAULT_BACKEND_DIR,
        help="Backend repository containing the contract-owning DTO modules.",
    )
    parser.add_argument(
        "--frontend-dir",
        type=Path,
        default=DEFAULT_FRONTEND_DIR,
        help="Frontend repository receiving the generated TypeScript files.",
    )
    return parser.parse_args(argv)


def load_module(source_path: Path, contract_name: str):
    if not source_path.is_file():
        raise ContractGenerationError(f"Contract source does not exist: {source_path}")

    module_name = f"_trustme_contract_source_{contract_name}"
    spec = importlib.util.spec_from_file_location(module_name, source_path)
    if spec is None or spec.loader is None:
        raise ContractGenerationError(f"Failed to load contract source: {source_path}")

    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except Exception as error:
        raise ContractGenerationError(
            f"Failed to import contract source {source_path}: {error}"
        ) from error
    return module


def _unsupported(annotation: Any, context: str) -> ContractGenerationError:
    return ContractGenerationError(
        f"Unsupported Python type for {context}: {annotation!r}"
    )


def _render_literal(annotation: Any, context: str) -> str:
    values = get_args(annotation)
    if not values:
        raise _unsupported(annotation, context)

    rendered: list[str] = []
    for value in values:
        if value is None or isinstance(value, (str, int, float, bool)):
            rendered.append(json.dumps(value, ensure_ascii=False))
            continue
        raise _unsupported(annotation, context)
    return " | ".join(dict.fromkeys(rendered))


def _render_array_type(item_type: str) -> str:
    if " | " in item_type:
        return f"({item_type})[]"
    return f"{item_type}[]"


def render_ts_type(
    annotation: Any,
    *,
    context: str,
    declared_types: frozenset[type] = frozenset(),
) -> str:
    """Render one supported Python annotation without lossy fallbacks."""
    if annotation is Any:
        return "unknown"
    if annotation is type(None):
        return "null"
    if annotation is str:
        return "string"
    if annotation in (int, float):
        return "number"
    if annotation is bool:
        return "boolean"

    if is_typeddict(annotation):
        if annotation not in declared_types:
            raise ContractGenerationError(
                f"TypedDict {annotation.__name__} used by {context} is not exported"
            )
        return annotation.__name__

    origin = get_origin(annotation)
    args = get_args(annotation)

    if origin in (typing.Union, types.UnionType):
        if not args:
            raise _unsupported(annotation, context)
        members = [
            render_ts_type(arg, context=context, declared_types=declared_types)
            for arg in args
        ]
        return " | ".join(dict.fromkeys(members))

    if origin is typing.Literal:
        return _render_literal(annotation, context)

    if origin is typing.Annotated:
        if not args:
            raise _unsupported(annotation, context)
        return render_ts_type(
            args[0], context=context, declared_types=declared_types
        )

    if origin in (typing.Required, typing.NotRequired):
        if len(args) != 1:
            raise _unsupported(annotation, context)
        return render_ts_type(
            args[0], context=context, declared_types=declared_types
        )

    if origin in (
        list,
        set,
        frozenset,
        collections.abc.Sequence,
        collections.abc.Iterable,
    ):
        if len(args) != 1:
            raise _unsupported(annotation, context)
        item_type = render_ts_type(
            args[0], context=context, declared_types=declared_types
        )
        return _render_array_type(item_type)

    if origin is tuple:
        if len(args) == 2 and args[1] is Ellipsis:
            item_type = render_ts_type(
                args[0], context=context, declared_types=declared_types
            )
            return _render_array_type(item_type)
        if not args:
            raise _unsupported(annotation, context)
        members = [
            render_ts_type(arg, context=context, declared_types=declared_types)
            for arg in args
        ]
        return f"[{', '.join(members)}]"

    if origin in (dict, collections.abc.Mapping):
        if len(args) != 2:
            raise _unsupported(annotation, context)
        key_type = render_ts_type(
            args[0], context=context, declared_types=declared_types
        )
        if key_type not in ("string", "number"):
            raise ContractGenerationError(
                f"Unsupported Record key type for {context}: {args[0]!r}"
            )
        value_type = render_ts_type(
            args[1], context=context, declared_types=declared_types
        )
        return f"Record<{key_type}, {value_type}>"

    raise _unsupported(annotation, context)


def render_property_name(name: str) -> str:
    if name.isidentifier():
        return name
    return json.dumps(name, ensure_ascii=False)


def render_typeddict(
    name: str,
    typed_dict: type,
    *,
    module_globals: dict[str, Any],
    declared_types: frozenset[type],
) -> str:
    try:
        annotations = get_type_hints(
            typed_dict,
            globalns=module_globals,
            localns=module_globals,
            include_extras=True,
        )
    except Exception as error:
        raise ContractGenerationError(
            f"Failed to resolve annotations for {name}: {error}"
        ) from error

    optional_keys = getattr(typed_dict, "__optional_keys__", frozenset())
    lines = [f"export interface {name} {{"]
    for field_name, annotation in annotations.items():
        optional_suffix = (
            "?"
            if field_name in optional_keys
            or get_origin(annotation) is typing.NotRequired
            else ""
        )
        field_context = f"{name}.{field_name}"
        ts_type = render_ts_type(
            annotation,
            context=field_context,
            declared_types=declared_types,
        )
        lines.append(
            f"  {render_property_name(field_name)}{optional_suffix}: {ts_type};"
        )
    lines.append("}")
    return "\n".join(lines)


def generate_contract(
    module,
    source_path: Path,
    exports: tuple[str, ...],
    *,
    external_types: tuple[str, ...] = (),
    typescript_imports: tuple[tuple[str, str], ...] = (),
) -> str:
    typed_dicts: list[tuple[str, type]] = []
    for name in exports:
        exported = getattr(module, name, None)
        if exported is None or not is_typeddict(exported):
            raise ContractGenerationError(
                f"{name} is not a TypedDict in {source_path}"
            )
        typed_dicts.append((name, exported))

    external_typed_dicts: list[type] = []
    for name in external_types:
        external = getattr(module, name, None)
        if external is None or not is_typeddict(external):
            raise ContractGenerationError(
                f"{name} is not an imported TypedDict in {source_path}"
            )
        external_typed_dicts.append(external)

    declared_types = frozenset(
        [*(typed_dict for _, typed_dict in typed_dicts), *external_typed_dicts]
    )
    interfaces = [
        render_typeddict(
            name,
            typed_dict,
            module_globals=vars(module),
            declared_types=declared_types,
        )
        for name, typed_dict in typed_dicts
    ]
    try:
        source_label = source_path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        source_label = source_path.resolve().as_posix()
    header = [
        "// This file is generated. Do not edit it by hand.",
        f"// Source: {source_label} via scripts/sync_frontend_contracts.py",
        "",
    ]
    if typescript_imports:
        header.extend(
            f"import type {{ {name} }} from '{module_path}';"
            for name, module_path in typescript_imports
        )
        header.append("")
    return "\n".join(header + interfaces) + "\n"


def build_contracts(
    backend_dir: Path,
    frontend_dir: Path,
) -> list[tuple[Path, str]]:
    backend_source_root = backend_dir / "src"
    backend_source_root_string = str(backend_source_root)
    if backend_source_root_string not in sys.path:
        sys.path.insert(0, backend_source_root_string)

    generated: list[tuple[Path, str]] = []
    for contract in CONTRACT_SPECS:
        source_path = backend_dir / contract.source_relative_path
        output_path = frontend_dir / contract.output_relative_path
        module = load_module(source_path, contract.name)
        generated.append(
            (
                output_path,
                generate_contract(
                    module,
                    source_path,
                    contract.exports,
                    external_types=contract.external_types,
                    typescript_imports=contract.typescript_imports,
                ),
            )
        )
    return generated


def write_contracts(contracts: list[tuple[Path, str]]) -> None:
    for output_path, generated in contracts:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = output_path.with_suffix(output_path.suffix + ".tmp")
        temporary_path.write_text(generated, encoding="utf-8")
        temporary_path.replace(output_path)
        print(f"Wrote {output_path}")


def check_contracts(contracts: list[tuple[Path, str]]) -> bool:
    is_current = True
    for output_path, generated in contracts:
        if output_path.is_file():
            current = output_path.read_text(encoding="utf-8")
        else:
            current = ""
        if current == generated:
            continue

        is_current = False
        print(f"Frontend contract is stale: {output_path}", file=sys.stderr)
        diff = difflib.unified_diff(
            current.splitlines(keepends=True),
            generated.splitlines(keepends=True),
            fromfile=str(output_path),
            tofile=f"{output_path} (generated)",
        )
        sys.stderr.writelines(diff)
    return is_current


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        contracts = build_contracts(
            args.backend_dir.resolve(),
            args.frontend_dir.resolve(),
        )
        if args.write:
            write_contracts(contracts)
            return 0
        if check_contracts(contracts):
            print("Frontend contracts are up to date.")
            return 0
        return 1
    except ContractGenerationError as error:
        print(f"Contract generation failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
