#!/usr/bin/env python3

"""Compose ActivityWatch with the Trustme backend, XAI runtime, and frontend."""

from __future__ import annotations

import argparse
import json
import shutil
import tempfile
from pathlib import Path

try:
    from scripts.activitywatch_patches import apply_activitywatch_patches
except ModuleNotFoundError:  # Direct execution adds scripts/, not the repository root.
    from activitywatch_patches import apply_activitywatch_patches


REPO_ROOT = Path(__file__).resolve().parents[1]

DEFAULT_ACTIVITYWATCH_DIR = REPO_ROOT / "activitywatch"
DEFAULT_BACKEND_DIR = REPO_ROOT / "backend"
DEFAULT_XAI_DIR = REPO_ROOT / "trustme-xai"
DEFAULT_CONFIG_DIR = REPO_ROOT / "config"
DEFAULT_FRONTEND_ARTIFACT_DIR = REPO_ROOT / "frontend" / "dist"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "build" / "composed" / "activitywatch"
DEFAULT_BRANDING_DIR = REPO_ROOT / "frontend" / "media" / "logo"

FILE_SOURCE_MAP = {
    "aw_server/dashboard_controller.py": "dashboard_controller.py",
    "aw_server/runtime.py": "runtime.py",
    "aw_server/routes.py": "routes.py",
    "aw_server/server_api.py": "server_api.py",
}

DIR_SOURCE_MAP = {
    "aw_server/browser": "browser",
    "aw_server/cache": "cache",
    "aw_server/daily_checkins": "daily_checkins",
    # Keep the backend source folder named `config`, but avoid shadowing
    # ActivityWatch's existing aw_server.config module in the composed tree.
    "aw_server/trustme_config": "config",
    "aw_server/model_feedback": "model_feedback",
    "aw_server/model_output": "model_output",
    "aw_server/notifications": "notifications",
    "aw_server/settings": "settings",
    "aw_server/review": "review",
    "aw_server/sync": "sync",
    "aw_server/hardware": "hardware",
    "aw_server/remote": "remote",
    "aw_server/scope": "scope",
    "aw_server/summary": "summary",
    "aw_server/timeline": "timeline",
    "aw_server/utils": "utils",
}

CONFIG_SOURCE_MAP = {
    "aw_server/settings/aw-category-export.json": "aw-category-export.json",
}

INTERNAL_IMPORT_TARGETS = {
    "browser": "aw_server.browser",
    "cache": "aw_server.cache",
    "daily_checkins": "aw_server.daily_checkins",
    "config": "aw_server.trustme_config",
    "dashboard_controller": "aw_server.dashboard_controller",
    "hardware": "aw_server.hardware",
    "model_feedback": "aw_server.model_feedback",
    "model_output": "aw_server.model_output",
    "notifications": "aw_server.notifications",
    "remote": "aw_server.remote",
    "review": "aw_server.review",
    "routes": "aw_server.routes",
    "runtime": "aw_server.runtime",
    "server_api": "aw_server.server_api",
    "settings": "aw_server.settings",
    "scope": "aw_server.scope",
    "summary": "aw_server.summary",
    "sync": "aw_server.sync",
    "timeline": "aw_server.timeline",
    "utils": "aw_server.utils",
}

REMOVED_FLAT_IMPORT_ROOTS = {
    "activity",
    "api",
    "aw_dirs",
    "dashboard",
    "dashboard_cache",
    "exceptions",
    "main",
    "ssh_config",
    "surveys",
    "version",
    "warmup",
}

IGNORED_SOURCE_NAMES = {
    ".git",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    "__pycache__",
    "build",
    "dist",
    "htmlcov",
    "node_modules",
    "target",
}

REQUIRED_ACTIVITYWATCH_PATHS = (
    "Makefile",
    "aw.spec",
    "LICENSE.txt",
    "CITATION.cff",
    "aw-core",
    "aw-client",
    "aw-server",
    "aw-qt",
    "aw-watcher-afk",
    "aw-watcher-window",
    "aw-watcher-input",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compose ActivityWatch, the Trustme backend and XAI runtime, config, "
            "and the built Vue frontend into one buildable tree."
        )
    )
    parser.add_argument("--activitywatch-dir", default=DEFAULT_ACTIVITYWATCH_DIR)
    parser.add_argument("--backend-dir", default=DEFAULT_BACKEND_DIR)
    parser.add_argument("--xai-dir", default=DEFAULT_XAI_DIR)
    parser.add_argument("--config-dir", default=DEFAULT_CONFIG_DIR)
    parser.add_argument(
        "--frontend-artifact-dir", default=DEFAULT_FRONTEND_ARTIFACT_DIR
    )
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--branding-dir", default=DEFAULT_BRANDING_DIR)
    return parser.parse_args()


def validate_categorization_config(path: Path) -> None:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise RuntimeError(f"Missing categorization config: {path}") from None
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid categorization JSON at {path}: {exc}") from exc

    categories = document.get("categories") if isinstance(document, dict) else None
    if not isinstance(categories, list) or not categories:
        raise RuntimeError(f"{path}: categories must be a non-empty list")
    for index, category in enumerate(categories):
        if not isinstance(category, dict):
            raise RuntimeError(f"{path}: category {index} must be an object")
        name = category.get("name")
        if not isinstance(name, list) or not name or not all(
            isinstance(part, str) and part.strip() for part in name
        ):
            raise RuntimeError(f"{path}: category {index} has an invalid name")
        rule = category.get("rule")
        if not isinstance(rule, dict) or rule.get("type") not in {
            None,
            "none",
            "regex",
        }:
            raise RuntimeError(f"{path}: category {index} has an invalid rule")


def resolve_backend_source_root(backend_dir: Path) -> Path:
    source_root = backend_dir.resolve() / "src"
    if not source_root.is_dir():
        raise RuntimeError(f"Backend source directory not found: {source_root}")
    return source_root


def resolve_backend_file_map(backend_dir: Path) -> dict[str, Path]:
    source_root = resolve_backend_source_root(backend_dir)
    file_map = {
        relative_dst: source_root / relative_src
        for relative_dst, relative_src in FILE_SOURCE_MAP.items()
    }
    missing = [path for path in file_map.values() if not path.is_file()]
    if missing:
        raise RuntimeError(f"Backend source files not found: {', '.join(map(str, missing))}")
    return file_map


def resolve_backend_dir_map(backend_dir: Path) -> dict[str, Path]:
    source_root = resolve_backend_source_root(backend_dir)
    dir_map = {
        relative_dst: source_root / relative_src
        for relative_dst, relative_src in DIR_SOURCE_MAP.items()
    }
    missing = [path for path in dir_map.values() if not path.is_dir()]
    if missing:
        raise RuntimeError(
            f"Backend feature directories not found: {', '.join(map(str, missing))}"
        )
    return dir_map


def resolve_xai_package_dir(xai_dir: Path) -> Path:
    package_dir = xai_dir.resolve() / "src" / "trustme_xai"
    required_paths = (
        package_dir / "__init__.py",
        package_dir / "contracts.py",
        package_dir / "action_classifier.joblib",
        package_dir / "current.joblib",
        package_dir / "feature_pipeline" / "category_rules.json",
        package_dir / "feature_pipeline" / "behavior_state_model.json",
        package_dir / "inference" / "compact_aw_v2.json",
    )
    missing = [path for path in required_paths if not path.exists()]
    if missing:
        raise RuntimeError(
            "XAI runtime package is incomplete; missing: "
            + ", ".join(map(str, missing))
        )
    return package_dir


def resolve_config_file_map(config_dir: Path) -> dict[str, Path]:
    resolved_config_dir = config_dir.resolve()
    file_map = {
        relative_dst: resolved_config_dir / relative_src
        for relative_dst, relative_src in CONFIG_SOURCE_MAP.items()
    }
    validate_categorization_config(
        file_map["aw_server/settings/aw-category-export.json"]
    )
    return file_map


def validate_activitywatch_source(activitywatch_dir: Path) -> None:
    if not activitywatch_dir.is_dir():
        raise RuntimeError(f"ActivityWatch source directory not found: {activitywatch_dir}")
    missing = [
        relative_path
        for relative_path in REQUIRED_ACTIVITYWATCH_PATHS
        if not (activitywatch_dir / relative_path).exists()
    ]
    if missing:
        raise RuntimeError(
            "ActivityWatch source is incomplete; missing: " + ", ".join(missing)
        )


def validate_frontend_artifact(frontend_artifact_dir: Path) -> None:
    if not frontend_artifact_dir.is_dir():
        raise RuntimeError(
            f"Frontend artifact directory not found: {frontend_artifact_dir}. "
            "Run the frontend build stage first."
        )
    if not (frontend_artifact_dir / "index.html").is_file():
        raise RuntimeError(
            f"Frontend artifact has no index.html: {frontend_artifact_dir}"
        )


def _copy_ignore(_directory: str, names: list[str]) -> set[str]:
    return set(names) & IGNORED_SOURCE_NAMES


def copy_activitywatch_source(source_dir: Path, output_dir: Path) -> None:
    shutil.copytree(
        source_dir,
        output_dir,
        symlinks=True,
        ignore=_copy_ignore,
    )


def copy_path(source: Path, destination: Path) -> None:
    if source.is_dir():
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(
            source,
            destination,
            symlinks=True,
            ignore=shutil.ignore_patterns("__pycache__", "dev_preview.py"),
        )
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def rewrite_import_line(line: str) -> str:
    indent = line[: len(line) - len(line.lstrip())]
    stripped = line.lstrip()
    if stripped.startswith(("from backend_overlay", "import backend_overlay")):
        raise RuntimeError(
            f"Removed backend_overlay import cannot be assembled: {line.rstrip()}"
        )

    if stripped.startswith("from "):
        module_name, separator, remainder = stripped[5:].partition(" import ")
        if not separator:
            return line
        root_name = module_name.split(".", 1)[0]
        if root_name in REMOVED_FLAT_IMPORT_ROOTS:
            raise RuntimeError(f"Removed flat import cannot be assembled: {line.rstrip()}")
        target_root = INTERNAL_IMPORT_TARGETS.get(root_name)
        if target_root is None:
            return line
        suffix = module_name[len(root_name) :]
        return indent + f"from {target_root}{suffix} import {remainder}"

    if stripped.startswith("import "):
        import_payload = stripped[7:]
        module_name = import_payload.split(maxsplit=1)[0].rstrip(",")
        root_name = module_name.split(".", 1)[0]
        if root_name in REMOVED_FLAT_IMPORT_ROOTS:
            raise RuntimeError(f"Removed flat import cannot be assembled: {line.rstrip()}")
        target_root = INTERNAL_IMPORT_TARGETS.get(root_name)
        if target_root is None:
            return line
        suffix = module_name[len(root_name) :]
        remainder = import_payload[len(module_name) :]
        return indent + f"import {target_root}{suffix}{remainder}"

    return line


def rewrite_python_imports(data: str) -> str:
    return "".join(rewrite_import_line(line) for line in data.splitlines(keepends=True))


def rewrite_python_file(path: Path) -> None:
    if path.suffix == ".py":
        path.write_text(
            rewrite_python_imports(path.read_text(encoding="utf-8")),
            encoding="utf-8",
        )


def rewrite_tree(path: Path) -> None:
    if path.is_file():
        rewrite_python_file(path)
        return
    for file_path in path.rglob("*.py"):
        rewrite_python_file(file_path)


def assert_assembled_imports(server_dir: Path) -> None:
    removed_qualified_roots = {
        "aw_server.dashboard",
        "aw_server.ssh_config",
    }
    for path in server_dir.rglob("*.py"):
        data = path.read_text(encoding="utf-8")
        if "trustme_api" in data or "trustme_api_legacy" in data:
            raise RuntimeError(f"Legacy package name survived composition: {path}")
        for line in data.splitlines():
            stripped = line.lstrip()
            if stripped.startswith(("from backend_overlay", "import backend_overlay")):
                raise RuntimeError(
                    f"Removed backend_overlay import survived composition: {path}: {line}"
                )
            imported_module = ""
            if stripped.startswith("from "):
                imported_module = stripped[5:].partition(" import ")[0]
            elif stripped.startswith("import "):
                imported_module = stripped[7:].split(maxsplit=1)[0].rstrip(",")
            if any(
                imported_module == removed_root
                or imported_module.startswith(f"{removed_root}.")
                for removed_root in removed_qualified_roots
            ):
                raise RuntimeError(
                    f"Removed qualified backend import survived composition: {path}: {line}"
                )
            if rewrite_import_line(line) != line:
                raise RuntimeError(
                    f"Flat backend import survived composition: {path}: {line}"
                )


def _validate_distinct_paths(source_dirs: tuple[Path, ...], output_dir: Path) -> None:
    for source_dir in source_dirs:
        if (
            output_dir == source_dir
            or output_dir.is_relative_to(source_dir)
            or source_dir.is_relative_to(output_dir)
        ):
            raise RuntimeError(
                "Composition output and source directories cannot overlap: "
                f"{output_dir}, {source_dir}"
            )


def compose_activitywatch(
    *,
    activitywatch_dir: Path,
    backend_dir: Path,
    xai_dir: Path,
    config_dir: Path,
    frontend_artifact_dir: Path,
    output_dir: Path,
    branding_dir: Path,
) -> Path:
    """Build one complete tree and publish it only after composition succeeds."""
    activitywatch_dir = activitywatch_dir.expanduser().resolve()
    backend_dir = backend_dir.expanduser().resolve()
    xai_dir = xai_dir.expanduser().resolve()
    config_dir = config_dir.expanduser().resolve()
    frontend_artifact_dir = frontend_artifact_dir.expanduser().resolve()
    # Keep the final path itself unresolved so an existing output symlink is
    # replaced as a link instead of following it and deleting its target.
    output_dir = output_dir.expanduser().absolute()
    branding_dir = branding_dir.expanduser().resolve()

    validate_activitywatch_source(activitywatch_dir)
    validate_frontend_artifact(frontend_artifact_dir)
    file_map = resolve_backend_file_map(backend_dir)
    dir_map = resolve_backend_dir_map(backend_dir)
    xai_package_dir = resolve_xai_package_dir(xai_dir)
    config_file_map = resolve_config_file_map(config_dir)
    _validate_distinct_paths(
        (
            activitywatch_dir,
            backend_dir,
            xai_dir,
            config_dir,
            frontend_artifact_dir,
            branding_dir,
        ),
        output_dir,
    )

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    staging_parent = Path(
        tempfile.mkdtemp(prefix=f".{output_dir.name}-compose-", dir=output_dir.parent)
    )
    staged_tree = staging_parent / "activitywatch"
    try:
        copy_activitywatch_source(activitywatch_dir, staged_tree)
        server_dir = staged_tree / "aw-server"

        legacy_settings_module = server_dir / "aw_server" / "settings.py"
        if legacy_settings_module.exists():
            legacy_settings_module.unlink()

        for relative_destination, source in file_map.items():
            destination = server_dir / relative_destination
            copy_path(source, destination)
            rewrite_tree(destination)

        for relative_destination, source in dir_map.items():
            destination = server_dir / relative_destination
            copy_path(source, destination)
            rewrite_tree(destination)

        # XAI is an independently versioned runtime input. Keep its top-level
        # package name because current.joblib records trustme_xai.modeling paths.
        copy_path(xai_package_dir, server_dir / "trustme_xai")

        for relative_destination, source in config_file_map.items():
            copy_path(source, server_dir / relative_destination)

        static_dir = server_dir / "aw_server" / "static"
        if static_dir.exists():
            shutil.rmtree(static_dir)
        shutil.copytree(frontend_artifact_dir, static_dir, symlinks=True)

        apply_activitywatch_patches(staged_tree, branding_dir=branding_dir)
        assert_assembled_imports(server_dir)

        if output_dir.exists():
            if output_dir.is_symlink() or not output_dir.is_dir():
                output_dir.unlink()
            else:
                shutil.rmtree(output_dir)
        staged_tree.replace(output_dir)
    finally:
        shutil.rmtree(staging_parent, ignore_errors=True)

    return output_dir


def main() -> None:
    args = parse_args()
    output_dir = compose_activitywatch(
        activitywatch_dir=Path(args.activitywatch_dir),
        backend_dir=Path(args.backend_dir),
        xai_dir=Path(args.xai_dir),
        config_dir=Path(args.config_dir),
        frontend_artifact_dir=Path(args.frontend_artifact_dir),
        output_dir=Path(args.output_dir),
        branding_dir=Path(args.branding_dir),
    )
    print(f"Composed ActivityWatch tree: {output_dir}")


if __name__ == "__main__":
    main()
