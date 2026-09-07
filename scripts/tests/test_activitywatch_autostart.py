"""Exercise the packaged tray configuration against isolated user TOML files."""

import importlib.util
from pathlib import Path
import shutil

from aw_core import dirs
import pytest
import tomlkit

from scripts.activitywatch_patches import overlay_aw_qt_branding


ROOT = Path(__file__).resolve().parents[2]
STANDARD_MODULES = ["aw-server", "aw-watcher-afk", "aw-watcher-window"]


@pytest.fixture
def tray_config(tmp_path, monkeypatch):
    tray = tmp_path / "composed" / "aw-qt"
    (tray / "aw_qt").mkdir(parents=True)
    (tray / "media" / "logo").mkdir(parents=True)
    for filename in ("config.py", "trayicon.py"):
        shutil.copyfile(
            ROOT / "activitywatch" / "aw-qt" / "aw_qt" / filename,
            tray / "aw_qt" / filename,
        )
    overlay_aw_qt_branding(tray, ROOT / "frontend" / "media" / "logo")

    def config_dir(appname):
        path = tmp_path / "user-config" / appname
        path.mkdir(parents=True, exist_ok=True)
        return str(path)

    monkeypatch.setattr(dirs, "get_config_dir", config_dir)
    spec = importlib.util.spec_from_file_location(
        "packaged_tray_config", tray / "aw_qt" / "config.py",
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module, Path(config_dir("aw-qt")) / "aw-qt.toml"


@pytest.mark.parametrize("testing", [False, True])
def test_fresh_install_starts_input_watcher(tray_config, testing):
    module, _path = tray_config
    assert module.AwQtSettings(testing).autostart_modules == [
        *STANDARD_MODULES, "aw-watcher-input",
    ]


@pytest.mark.parametrize("testing", [False, True])
@pytest.mark.parametrize("existing_modules", [STANDARD_MODULES, []])
def test_old_config_is_updated_without_removing_user_settings(
    tray_config, testing, existing_modules, monkeypatch,
):
    module, path = tray_config
    original = {
        "aw-qt": {"autostart_modules": [*existing_modules, "custom-watcher"]},
        "aw-qt-testing": {"autostart_modules": existing_modules},
        "custom": {"keep": "unchanged"},
    }
    path.write_text(tomlkit.dumps(original), encoding="utf-8")

    settings = module.AwQtSettings(testing)
    saved = tomlkit.loads(path.read_text(encoding="utf-8"))
    for section in ("aw-qt", "aw-qt-testing"):
        assert saved[section]["autostart_modules"] == [
            *original[section]["autostart_modules"], "aw-watcher-input",
        ]
    assert saved["custom"] == original["custom"]
    assert settings.autostart_modules == saved[
        "aw-qt-testing" if testing else "aw-qt"
    ]["autostart_modules"]

    def unexpected_write(*args):
        pytest.fail("An already-updated config must not be rewritten")

    monkeypatch.setattr(module, "save_config_toml", unexpected_write)
    assert module.AwQtSettings(testing).autostart_modules == settings.autostart_modules


def test_existing_input_watcher_is_not_duplicated_or_rewritten(tray_config):
    module, path = tray_config
    existing = '''# Keep this comment and my startup order.
[aw-qt]
autostart_modules = ["aw-watcher-input", "aw-server", "custom-watcher"]

[aw-qt-testing]
autostart_modules = ["aw-watcher-input"]
'''
    path.write_text(existing, encoding="utf-8")
    assert module.AwQtSettings(False).autostart_modules == [
        "aw-watcher-input", "aw-server", "custom-watcher",
    ]
    assert module.AwQtSettings(True).autostart_modules == ["aw-watcher-input"]
    assert path.read_text(encoding="utf-8") == existing
