import logging
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

import aw_datastore
import flask.json.provider
from aw_datastore import Datastore
from flask import (
    Blueprint,
    Flask,
    current_app,
    send_from_directory,
)
from flask_cors import CORS

from . import rest
from .api import ServerAPI
from .custom_static import get_custom_static_blueprint
from .log import FlaskLogHandler

logger = logging.getLogger(__name__)


def _resolve_static_folder() -> str:
    """Locate bundled web assets in source and PyInstaller layouts."""
    module_path = Path(__file__).resolve()
    candidates = [module_path.parent / "static"]

    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        bundle_root = Path(meipass).resolve()
        candidates.extend(
            [bundle_root / "aw_server" / "static", bundle_root / "static"]
        )

    for candidate in candidates:
        if candidate.is_dir():
            return str(candidate)

    # The source tree does not contain generated web assets until its build step.
    # Keep imports and API-only tests usable; Flask will return 404 for missing assets.
    return str(candidates[0])


static_folder = _resolve_static_folder()

root = Blueprint("root", __name__, url_prefix="/")


class AWFlask(Flask):
    def __init__(
        self,
        host: str,
        testing: bool,
        storage_method=None,
        cors_origins: Optional[List[str]] = None,
        custom_static: Optional[Dict[str, str]] = None,
        static_folder=static_folder,
        static_url_path="",
        api_factory: Optional[Callable[..., Any]] = None,
    ):
        name = "aw-server"
        self.json_provider_class = CustomJSONProvider
        # only prettyprint JSON if testing (due to perf)
        self.json_provider_class.compact = not testing

        # Initialize Flask
        Flask.__init__(
            self,
            name,
            static_folder=static_folder,
            static_url_path=static_url_path,
        )
        self.config["HOST"] = host  # needed for host-header check
        resolved_cors_origins = list(cors_origins or [])
        with self.app_context():
            _config_cors(resolved_cors_origins, testing)

        # Initialize datastore and API
        if storage_method is None:
            storage_method = aw_datastore.get_storage_methods()["memory"]
        db = Datastore(storage_method, testing=testing)
        resolved_api_factory = ServerAPI if api_factory is None else api_factory
        self.api = resolved_api_factory(db=db, testing=testing)

        self.register_blueprint(root)
        self.register_blueprint(rest.blueprint)
        self.register_blueprint(get_custom_static_blueprint(custom_static or {}))


class CustomJSONProvider(flask.json.provider.DefaultJSONProvider):
    # encoding/decoding of datetime as iso8601 strings
    # encoding of timedelta as second floats
    def default(self, obj, *args, **kwargs):
        try:
            if isinstance(obj, datetime):
                return obj.isoformat()
            if isinstance(obj, timedelta):
                return obj.total_seconds()
        except TypeError:
            pass
        return super().default(obj)


@root.route("/")
def static_root():
    return current_app.send_static_file("index.html")


@root.route("/css/<path:path>")
def static_css(path):
    app_static_folder = current_app.static_folder or static_folder
    return send_from_directory(os.path.join(app_static_folder, "css"), path)


@root.route("/js/<path:path>")
def static_js(path):
    app_static_folder = current_app.static_folder or static_folder
    return send_from_directory(os.path.join(app_static_folder, "js"), path)


def _config_cors(cors_origins: List[str], testing: bool):
    if cors_origins:
        logger.warning(
            "Running with additional allowed CORS origins specified through config "
            "or CLI argument (could be a security risk): {}".format(cors_origins)
        )

    if testing:
        # Used for development of aw-webui
        cors_origins.append("http://127.0.0.1:27180/*")

    # TODO: This could probably be more specific
    #       See https://github.com/ActivityWatch/aw-server/pull/43#issuecomment-386888769
    cors_origins.append("moz-extension://*")

    # See: https://flask-cors.readthedocs.org/en/latest/
    CORS(current_app, resources={r"/api/*": {"origins": cors_origins}})


# Only to be called from aw_server.main function!
def _start(
    storage_method,
    host: str,
    port: int,
    testing: bool = False,
    cors_origins: Optional[List[str]] = None,
    custom_static: Optional[Dict[str, str]] = None,
    api_factory: Optional[Callable[..., Any]] = None,
):
    app = AWFlask(
        host,
        testing=testing,
        storage_method=storage_method,
        cors_origins=cors_origins,
        custom_static=custom_static,
        api_factory=api_factory,
    )
    try:
        app.run(
            debug=testing,
            host=host,
            port=port,
            request_handler=FlaskLogHandler,
            use_reloader=False,
            threaded=True,
        )
    except OSError as e:
        logger.exception(e)
        raise e
