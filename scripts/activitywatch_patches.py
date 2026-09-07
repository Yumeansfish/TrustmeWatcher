#!/usr/bin/env python3

"""Small, asserted Trustme patches for the pinned ActivityWatch source tree."""

from __future__ import annotations

import shutil
from pathlib import Path


ROOT_SPEC_VERSION_SOURCE = '''# Get the current release version
current_release = subprocess.run(
    shlex.split("git describe --tags --abbrev=0"),
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    encoding="utf8",
).stdout.strip()
print("bundling activitywatch version " + current_release)
'''

ROOT_SPEC_VERSION_REPLACEMENT = '''def required_environment_value(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"Required build environment variable is not set: {name}")
    return value


# Release identity belongs to the Trustme build, not the vendored Git checkout.
current_release = required_environment_value("RELEASE_VERSION")
app_name = required_environment_value("APP_NAME")
bundle_identifier = required_environment_value("BUNDLE_ID")
print(f"bundling {app_name} version {current_release}")
'''

ROOT_SPEC_SERVER_DATAS_SOURCE = '''    datas=[
        (aws_location / "aw_server/static", "aw_server/static"),
        (restx_path / "templates", "flask_restx/templates"),
        (restx_path / "static", "flask_restx/static"),
        (aw_core_path / "schemas", "aw_core/schemas"),
    ],
'''

ROOT_SPEC_SERVER_DATAS_REPLACEMENT = '''    datas=[
        (aws_location / "aw_server/static", "aw_server/static"),
        (aws_location / "aw_server/settings/aw-category-export.json", "aw_server/settings"),
        (aws_location / "trustme_xai/action_classifier.joblib", "trustme_xai"),
        (aws_location / "trustme_xai/current.joblib", "trustme_xai"),
        (
            aws_location / "trustme_xai/feature_pipeline/category_rules.json",
            "trustme_xai/feature_pipeline",
        ),
        (
            aws_location / "trustme_xai/feature_pipeline/behavior_state_model.json",
            "trustme_xai/feature_pipeline",
        ),
        (
            aws_location / "trustme_xai/inference/compact_aw_v2.json",
            "trustme_xai/inference",
        ),
        (restx_path / "templates", "flask_restx/templates"),
        (restx_path / "static", "flask_restx/static"),
        (aw_core_path / "schemas", "aw_core/schemas"),
    ],
    hiddenimports=[
        "numpy._core._exceptions",
        "scipy._cyutility",
        "sklearn.externals.array_api_compat.numpy.fft",
        "sklearn.externals.array_api_compat.numpy.linalg",
        "sklearn._cyutility",
        "sklearn.ensemble._forest",
        "sklearn.ensemble._hist_gradient_boosting.gradient_boosting",
        "sklearn.impute._base",
        "sklearn.pipeline",
        "sklearn.tree._classes",
        "sklearn.tree._partitioner",
        "sklearn.tree._tree",
    ],
'''

SERVER_SPEC_DATAS_SOURCE = '''    datas=[
        ("aw_server/static", "aw_server/static"),
        (os.path.join(restx_path, "templates"), "flask_restx/templates"),
        (os.path.join(restx_path, "static"), "flask_restx/static"),
        (os.path.join(aw_core_path, "schemas"), "aw_core/schemas"),
    ],
    hiddenimports=[],
'''

SERVER_SPEC_DATAS_REPLACEMENT = '''    datas=[
        ("aw_server/static", "aw_server/static"),
        ("aw_server/settings/aw-category-export.json", "aw_server/settings"),
        ("trustme_xai/action_classifier.joblib", "trustme_xai"),
        ("trustme_xai/current.joblib", "trustme_xai"),
        (
            "trustme_xai/feature_pipeline/category_rules.json",
            "trustme_xai/feature_pipeline",
        ),
        (
            "trustme_xai/feature_pipeline/behavior_state_model.json",
            "trustme_xai/feature_pipeline",
        ),
        (
            "trustme_xai/inference/compact_aw_v2.json",
            "trustme_xai/inference",
        ),
        (os.path.join(restx_path, "templates"), "flask_restx/templates"),
        (os.path.join(restx_path, "static"), "flask_restx/static"),
        (os.path.join(aw_core_path, "schemas"), "aw_core/schemas"),
    ],
    hiddenimports=[
        "numpy._core._exceptions",
        "scipy._cyutility",
        "sklearn.externals.array_api_compat.numpy.fft",
        "sklearn.externals.array_api_compat.numpy.linalg",
        "sklearn._cyutility",
        "sklearn.ensemble._forest",
        "sklearn.ensemble._hist_gradient_boosting.gradient_boosting",
        "sklearn.impute._base",
        "sklearn.pipeline",
        "sklearn.tree._classes",
        "sklearn.tree._partitioner",
        "sklearn.tree._tree",
    ],
'''

SERVER_MAKEFILE_VERSION_SOURCE = (
    "VERSION=$$(grep -oP '__version__ = \"v\\K[^\"]+' aw_server/__about__.py | "
    "head -n1); echo $$VERSION; poetry version $$VERSION\n"
)

SERVER_MAKEFILE_VERSION_REPLACEMENT = (
    "VERSION=$$(python -c 'from aw_server.__about__ import __version__; "
    'print(__version__.lstrip("v"))\'); echo $$VERSION; poetry version $$VERSION\n'
)

TRAY_ICON_SOURCE = '''    if sys.platform == "darwin":
        icon = QIcon("icons:black-monochrome-logo.png")
        # Allow macOS to use filters for changing the icon's color
        icon.setIsMask(True)
    else:
        icon = QIcon("icons:logo.png")
'''

TRAY_ICON_REPLACEMENT = '''    icon = QIcon("icons:logo.png")
'''

AW_QT_AUTOSTART_SOURCE = '''default_config = """
[aw-qt]
autostart_modules = ["aw-server", "aw-watcher-afk", "aw-watcher-window"]

[aw-qt-testing]
autostart_modules = ["aw-server", "aw-watcher-afk", "aw-watcher-window"]
""".strip()
'''

AW_QT_AUTOSTART_REPLACEMENT = '''default_config = """
[aw-qt]
autostart_modules = [
    "aw-server",
    "aw-watcher-afk",
    "aw-watcher-window",
    "aw-watcher-input",
]

[aw-qt-testing]
autostart_modules = [
    "aw-server",
    "aw-watcher-afk",
    "aw-watcher-window",
    "aw-watcher-input",
]
""".strip()
'''

AW_QT_LOAD_CONFIG_SOURCE = '''        config = load_config_toml("aw-qt", default_config)
'''

AW_QT_LOAD_CONFIG_REPLACEMENT = '''        config = load_config_toml("aw-qt", default_config)
        # Existing ActivityWatch startup lists override the bundled defaults.
        updated = False
        for section in ("aw-qt", "aw-qt-testing"):
            modules = config[section]["autostart_modules"]
            if "aw-watcher-input" not in modules:
                modules.append("aw-watcher-input")
                updated = True
        if updated:
            save_config_toml("aw-qt", tomlkit.dumps(config))
'''

REQUIRED_BRANDING_FILES = frozenset(
    {
        "black-monochrome-logo.png",
        "logo-128.png",
        "logo.icns",
        "logo.ico",
        "logo.png",
        "logo.svg",
    }
)


def replace_exactly_once(
    path: Path,
    source: str,
    replacement: str,
    *,
    expectation: str,
) -> None:
    """Replace one pinned-upstream fragment and reject any source drift."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise RuntimeError(f"Required ActivityWatch file not found: {path}") from None

    occurrences = text.count(source)
    if occurrences != 1:
        raise RuntimeError(
            f"Expected exactly one {expectation} in {path}; found {occurrences}"
        )
    path.write_text(text.replace(source, replacement, 1), encoding="utf-8")


def patch_aw_server(server_dir: Path) -> None:
    """Connect the composed server and include Trustme runtime data."""
    replace_exactly_once(
        server_dir / "aw_server" / "main.py",
        "from .server import _start",
        "from .runtime import _start",
        expectation="upstream aw-server entrypoint import",
    )
    replace_exactly_once(
        server_dir / "aw-server.spec",
        SERVER_SPEC_DATAS_SOURCE,
        SERVER_SPEC_DATAS_REPLACEMENT,
        expectation="aw-server PyInstaller datas block",
    )
    replace_exactly_once(
        server_dir / "Makefile",
        SERVER_MAKEFILE_VERSION_SOURCE,
        SERVER_MAKEFILE_VERSION_REPLACEMENT,
        expectation="GNU grep aw-server version command",
    )


def overlay_aw_qt_branding(aw_qt_dir: Path, branding_dir: Path) -> None:
    """Install Trustme defaults and branding in the ActivityWatch tray app."""
    if not branding_dir.is_dir():
        raise RuntimeError(f"Branding directory not found: {branding_dir}")
    missing = sorted(
        filename
        for filename in REQUIRED_BRANDING_FILES
        if not (branding_dir / filename).is_file()
    )
    if missing:
        raise RuntimeError(
            f"Branding directory is missing required files: {', '.join(missing)}"
        )

    logo_target_dir = aw_qt_dir / "media" / "logo"
    if not logo_target_dir.is_dir():
        raise RuntimeError(f"Upstream aw-qt logo directory not found: {logo_target_dir}")

    replace_exactly_once(
        aw_qt_dir / "aw_qt" / "trayicon.py",
        TRAY_ICON_SOURCE,
        TRAY_ICON_REPLACEMENT,
        expectation="aw-qt macOS monochrome tray icon branch",
    )
    replace_exactly_once(
        aw_qt_dir / "aw_qt" / "config.py",
        AW_QT_AUTOSTART_SOURCE,
        AW_QT_AUTOSTART_REPLACEMENT,
        expectation="aw-qt default autostart module configuration",
    )
    replace_exactly_once(
        aw_qt_dir / "aw_qt" / "config.py",
        "from aw_core.config import load_config_toml\n",
        "from aw_core.config import load_config_toml, save_config_toml\n",
        expectation="aw-qt configuration imports",
    )
    replace_exactly_once(
        aw_qt_dir / "aw_qt" / "config.py",
        AW_QT_LOAD_CONFIG_SOURCE,
        AW_QT_LOAD_CONFIG_REPLACEMENT,
        expectation="aw-qt persisted autostart configuration",
    )
    shutil.rmtree(logo_target_dir)
    shutil.copytree(branding_dir, logo_target_dir)


def patch_root_aw_spec(spec_path: Path) -> None:
    """Teach ActivityWatch's app spec about Trustme identity and assets."""
    replace_exactly_once(
        spec_path,
        "import os\nimport platform\nimport shlex\nimport subprocess\nfrom pathlib import Path\n",
        "import os\nimport platform\nfrom pathlib import Path\n",
        expectation="root aw.spec imports",
    )
    replace_exactly_once(
        spec_path,
        ROOT_SPEC_VERSION_SOURCE,
        ROOT_SPEC_VERSION_REPLACEMENT,
        expectation="git-derived ActivityWatch release version",
    )
    replace_exactly_once(
        spec_path,
        ROOT_SPEC_SERVER_DATAS_SOURCE,
        ROOT_SPEC_SERVER_DATAS_REPLACEMENT,
        expectation="root aw.spec server datas block",
    )
    replace_exactly_once(
        spec_path,
        '        name="ActivityWatch.app",',
        '        name=f"{app_name}.app",',
        expectation="root aw.spec app name",
    )
    replace_exactly_once(
        spec_path,
        '        bundle_identifier="net.activitywatch.ActivityWatch",',
        "        bundle_identifier=bundle_identifier,",
        expectation="root aw.spec bundle identifier",
    )


def apply_activitywatch_patches(
    activitywatch_dir: Path,
    *,
    branding_dir: Path,
) -> None:
    """Apply every Trustme-owned source difference to one composed tree."""
    patch_aw_server(activitywatch_dir / "aw-server")
    overlay_aw_qt_branding(activitywatch_dir / "aw-qt", branding_dir)
    patch_root_aw_spec(activitywatch_dir / "aw.spec")
