from __future__ import annotations

import ipaddress
import os
import re
import secrets
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests
import yaml
from flask import Flask, abort, flash, redirect, render_template, request, session, url_for
from werkzeug.middleware.proxy_fix import ProxyFix

DEFAULT_ALLOW_CIDRS = ",".join(
    [
        "127.0.0.1/32",
        "::1/128",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "100.64.0.0/10",
    ]
)
NAME_RE = re.compile(r"^[A-Za-z0-9._+-]+$")
CRON_LINE_RE = re.compile(r"(?m)^cron:\s*.*$")


@dataclass
class RepoRecord:
    name: str
    state: str
    path: Path
    cron: str = ""
    storage_dir: str = ""
    image: str = ""
    upstream: str = ""
    rsync_host: str = ""
    rsync_path: str = ""
    size: int | None = None
    syncing: bool = False
    exit_code: int | None = None
    last_success: int | None = None
    prev_run: int | None = None
    next_run: int | None = None
    parse_error: str = ""
    exists_elsewhere: bool = False


def create_app(config_overrides: dict[str, Any] | None = None) -> Flask:
    app = Flask(__name__, template_folder="admin_templates", static_folder="admin_static")
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

    app.config.update(
        ADMIN_USERNAME=os.environ.get("ADMIN_USERNAME", "admin"),
        ADMIN_PASSWORD=os.environ.get("ADMIN_PASSWORD", "change-this-password"),
        ADMIN_SECRET_KEY=os.environ.get("ADMIN_SECRET_KEY") or secrets.token_hex(32),
        ADMIN_ALLOW_CIDRS=os.environ.get("ADMIN_ALLOW_CIDRS", DEFAULT_ALLOW_CIDRS),
        ADMIN_REPO_DIR=os.environ.get("ADMIN_REPO_DIR", "/etc/yuki/repos"),
        ADMIN_REPO_DISABLED_DIR=os.environ.get("ADMIN_REPO_DISABLED_DIR", "/etc/yuki/repos.disabled"),
        ADMIN_EXAMPLE_REPO_DIR=os.environ.get("ADMIN_EXAMPLE_REPO_DIR", "/app/deploy/yuki/repos"),
        ADMIN_YUKICTL_BIN=os.environ.get("ADMIN_YUKICTL_BIN", "/usr/local/bin/yukictl"),
        ADMIN_YUKI_URL=os.environ.get("ADMIN_YUKI_URL", os.environ.get("MIRROR_YUKI_URL", "http://127.0.0.1:9999/api/v1/metas")),
        ADMIN_GENERATE_INDEX_SCRIPT=os.environ.get("ADMIN_GENERATE_INDEX_SCRIPT", "/app/scripts/generate-index.sh"),
        ADMIN_GENERATE_TIMEOUT=os.environ.get("ADMIN_GENERATE_TIMEOUT", "300"),
        MIRROR_NAME=os.environ.get("MIRROR_NAME", "NX OpenAtom"),
        MIRROR_DOMAIN=os.environ.get("MIRROR_DOMAIN", "mirrors.njxzu.cn"),
        MIRROR_WEB_ROOT=os.environ.get("MIRROR_WEB_ROOT", "/srv/mirror/www"),
        MIRROR_ENV_FILE=os.environ.get("MIRROR_ENV_FILE", "/etc/njxzu-mirrors-container.env"),
        YUKI_LOG_DIR=os.environ.get("YUKI_LOG_DIR", "/var/log/yuki"),
    )
    if config_overrides:
        app.config.update(config_overrides)

    app.secret_key = app.config["ADMIN_SECRET_KEY"]
    app.config["ADMIN_ALLOW_NETWORKS"] = parse_cidrs(app.config["ADMIN_ALLOW_CIDRS"])
    app.config["ADMIN_REPO_DIR"] = Path(app.config["ADMIN_REPO_DIR"])
    app.config["ADMIN_REPO_DISABLED_DIR"] = Path(app.config["ADMIN_REPO_DISABLED_DIR"])
    app.config["ADMIN_EXAMPLE_REPO_DIR"] = Path(app.config["ADMIN_EXAMPLE_REPO_DIR"])
    app.config["MIRROR_WEB_ROOT"] = Path(app.config["MIRROR_WEB_ROOT"])
    app.config["YUKI_LOG_DIR"] = Path(app.config["YUKI_LOG_DIR"])
    app.config["ADMIN_GENERATE_INDEX_SCRIPT"] = Path(app.config["ADMIN_GENERATE_INDEX_SCRIPT"])
    app.config["ADMIN_GENERATE_TIMEOUT"] = int(app.config["ADMIN_GENERATE_TIMEOUT"])

    app.jinja_env.filters["filesize"] = format_filesize
    app.jinja_env.filters["ts_local"] = format_timestamp

    @app.context_processor
    def inject_template_helpers() -> dict[str, Any]:
        return {"csrf_token": ensure_csrf_token}

    @app.before_request
    def enforce_access_controls() -> Any:
        if not request.endpoint:
            return None
        if request.endpoint in {"static", "healthz"}:
            return None
        if not client_ip_allowed(app):
            abort(403)
        if request.method == "POST":
            validate_csrf()
        if request.endpoint == "login":
            return None
        if not session.get("admin_authenticated"):
            return redirect(url_for("login"))
        return None

    @app.errorhandler(ValueError)
    def handle_value_error(error: ValueError) -> Any:
        flash(str(error), "error")
        return redirect(request.referrer or url_for("dashboard"))

    @app.errorhandler(FileExistsError)
    def handle_file_exists(error: FileExistsError) -> Any:
        flash(str(error), "error")
        return redirect(request.referrer or url_for("dashboard"))

    @app.get("/healthz")
    def healthz() -> str:
        return "ok\n"

    @app.get("/login")
    @app.post("/login")
    def login() -> Any:
        if session.get("admin_authenticated"):
            return redirect(url_for("dashboard"))
        if request.method == "POST":
            username = request.form.get("username", "").strip()
            password = request.form.get("password", "")
            if username == app.config["ADMIN_USERNAME"] and password == app.config["ADMIN_PASSWORD"]:
                session["admin_authenticated"] = True
                flash("已登录内部管理页面。", "success")
                return redirect(url_for("dashboard"))
            flash("用户名或密码错误。", "error")
        return render_template("admin_login.html", brand=app.config["MIRROR_NAME"])

    @app.post("/logout")
    def logout() -> Any:
        session.clear()
        flash("已退出登录。", "success")
        return redirect(url_for("login"))

    @app.get("/")
    def dashboard() -> Any:
        enabled_dir = app.config["ADMIN_REPO_DIR"]
        disabled_dir = app.config["ADMIN_REPO_DISABLED_DIR"]
        example_dir = app.config["ADMIN_EXAMPLE_REPO_DIR"]

        enabled_dir.mkdir(parents=True, exist_ok=True)
        disabled_dir.mkdir(parents=True, exist_ok=True)

        meta_map, yuki_error = fetch_yuki_meta(app.config["ADMIN_YUKI_URL"])
        enabled = load_repo_records(enabled_dir, "enabled", meta_map)
        disabled = load_repo_records(disabled_dir, "disabled", meta_map)
        occupied = {repo.name for repo in enabled} | {repo.name for repo in disabled}
        examples = load_example_records(example_dir, occupied)

        disk_total, disk_used, disk_free = (None, None, None)
        try:
            usage = shutil.disk_usage(app.config["MIRROR_WEB_ROOT"])
            disk_total, disk_used, disk_free = usage.total, usage.used, usage.free
        except OSError:
            pass

        index_path = app.config["MIRROR_WEB_ROOT"] / "index.html"
        index_mtime = int(index_path.stat().st_mtime) if index_path.exists() else None

        return render_template(
            "admin_dashboard.html",
            brand=app.config["MIRROR_NAME"],
            domain=app.config["MIRROR_DOMAIN"],
            enabled_repos=enabled,
            disabled_repos=disabled,
            example_repos=examples,
            yuki_error=yuki_error,
            yuki_bin_exists=Path(app.config["ADMIN_YUKICTL_BIN"]).exists(),
            stats={
                "enabled_count": len(enabled),
                "disabled_count": len(disabled),
                "example_count": len(examples),
                "disk_total": disk_total,
                "disk_used": disk_used,
                "disk_free": disk_free,
                "index_mtime": index_mtime,
                "web_root": str(app.config["MIRROR_WEB_ROOT"]),
                "repo_dir": str(enabled_dir),
                "repo_disabled_dir": str(disabled_dir),
                "env_file": app.config["MIRROR_ENV_FILE"],
                "default_password": app.config["ADMIN_PASSWORD"] == "change-this-password",
            },
        )

    @app.post("/actions/refresh-index")
    def refresh_index() -> Any:
        code, detail = run_command(
            ["/bin/bash", str(app.config["ADMIN_GENERATE_INDEX_SCRIPT"])],
            timeout=app.config["ADMIN_GENERATE_TIMEOUT"],
            extra_env={"MIRROR_ENV_FILE": app.config["MIRROR_ENV_FILE"]},
        )
        if code == 0:
            flash("首页和 MirrorZ 元数据已刷新。", "success")
        else:
            flash(f"刷新首页失败：{detail}", "error")
        return redirect(url_for("dashboard", _anchor="overview"))

    @app.post("/actions/reload-yuki")
    def reload_yuki() -> Any:
        code, detail = run_yukictl(app, "reload")
        if code == 0:
            flash("已执行 yuki 配置重载。", "success")
        else:
            flash(f"yuki 重载失败：{detail}", "error")
        return redirect(url_for("dashboard", _anchor="enabled"))

    @app.post("/repos/<name>/cron")
    def update_repo_cron(name: str) -> Any:
        repo_name = validate_repo_name(name)
        state = request.form.get("state", "enabled")
        cron = request.form.get("cron", "").strip()
        repo_path = repo_path_for_state(app, repo_name, state)
        config = load_repo_config(repo_path)
        validate_cron_expression(repo_name, cron, config)
        raw_text = repo_path.read_text(encoding="utf-8")
        replacement = f'cron: "{cron}"'
        if CRON_LINE_RE.search(raw_text):
            new_text = CRON_LINE_RE.sub(replacement, raw_text, count=1)
        else:
            new_text = replacement + "\n" + raw_text
        atomic_write(repo_path, new_text)

        if state == "enabled":
            code, detail = run_yukictl(app, "reload")
            if code == 0:
                flash(f"{repo_name} 的定时任务已更新为 {cron}，并已重载 yuki。", "success")
            else:
                flash(f"{repo_name} 的定时任务已更新为 {cron}，但 yuki 重载失败：{detail}", "warning")
        else:
            flash(f"{repo_name} 的定时任务已更新为 {cron}。当前仓库仍处于停用状态。", "success")
        return redirect(url_for("dashboard", _anchor=anchor_for_state(state)))

    @app.post("/repos/<name>/enable")
    def enable_repo(name: str) -> Any:
        repo_name = validate_repo_name(name)
        src = repo_path_for_state(app, repo_name, "disabled")
        dst = repo_path_for_state(app, repo_name, "enabled", must_exist=False)
        move_repo_file(src, dst)
        code, detail = run_yukictl(app, "reload")
        if code == 0:
            flash(f"已启用仓库 {repo_name}。", "success")
        else:
            flash(f"已启用仓库 {repo_name}，但 yuki 重载失败：{detail}", "warning")
        return redirect(url_for("dashboard", _anchor="enabled"))

    @app.post("/repos/<name>/disable")
    def disable_repo(name: str) -> Any:
        repo_name = validate_repo_name(name)
        src = repo_path_for_state(app, repo_name, "enabled")
        dst = repo_path_for_state(app, repo_name, "disabled", must_exist=False)
        move_repo_file(src, dst)
        code, detail = run_yukictl(app, "reload")
        if code == 0:
            flash(f"已停用仓库 {repo_name}。", "success")
        else:
            flash(f"已停用仓库 {repo_name}，但 yuki 重载失败：{detail}", "warning")
        return redirect(url_for("dashboard", _anchor="disabled"))

    @app.post("/repos/<name>/delete")
    def delete_repo(name: str) -> Any:
        repo_name = validate_repo_name(name)
        state = request.form.get("state", "disabled")
        delete_data = request.form.get("delete_data") == "1"
        repo_path = repo_path_for_state(app, repo_name, state)
        config = load_repo_config(repo_path)
        storage_dir = config.get("storageDir")
        repo_path.unlink()

        extra_note = ""
        if delete_data and storage_dir:
            removed = delete_storage_dir_if_safe(app, Path(str(storage_dir)))
            extra_note = "，并已删除仓库目录" if removed else "，但仓库目录未删除（超出允许范围或不存在）"

        if state == "enabled":
            code, detail = run_yukictl(app, "reload")
            if code == 0:
                flash(f"已删除仓库 {repo_name} 的配置{extra_note}。", "success")
            else:
                flash(f"已删除仓库 {repo_name} 的配置{extra_note}，但 yuki 重载失败：{detail}", "warning")
        else:
            flash(f"已删除仓库 {repo_name} 的配置{extra_note}。", "success")
        return redirect(url_for("dashboard", _anchor=anchor_for_state(state)))

    @app.post("/repos/<name>/sync")
    def sync_repo(name: str) -> Any:
        repo_name = validate_repo_name(name)
        repo_path_for_state(app, repo_name, "enabled")
        code, detail = run_yukictl_background(app, "sync", repo_name)
        if code == 0:
            flash(f"已向 yuki 提交 {repo_name} 的同步请求。", "success")
        else:
            flash(f"仓库 {repo_name} 同步请求失败：{detail}", "error")
        return redirect(url_for("dashboard", _anchor="enabled"))

    @app.post("/examples/<name>/import")
    def import_example(name: str) -> Any:
        repo_name = validate_repo_name(name)
        target_state = request.form.get("target", "disabled")
        source = app.config["ADMIN_EXAMPLE_REPO_DIR"] / f"{repo_name}.yaml.example"
        if not source.exists():
            abort(404)
        for state in ("enabled", "disabled"):
            existing = repo_path_for_state(app, repo_name, state, must_exist=False)
            if existing.exists():
                flash(f"仓库 {repo_name} 已存在，无需重复导入。", "warning")
                return redirect(url_for("dashboard", _anchor=anchor_for_state(state)))

        target = repo_path_for_state(app, repo_name, target_state, must_exist=False)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

        if target_state == "enabled":
            code, detail = run_yukictl(app, "reload")
            if code == 0:
                flash(f"已从示例导入并启用仓库 {repo_name}。", "success")
            else:
                flash(f"已从示例导入并启用仓库 {repo_name}，但 yuki 重载失败：{detail}", "warning")
        else:
            flash(f"已从示例导入仓库 {repo_name}，当前为停用状态。", "success")
        return redirect(url_for("dashboard", _anchor=anchor_for_state(target_state)))

    return app


def ensure_csrf_token() -> str:
    token = session.get("csrf_token")
    if not token:
        token = secrets.token_urlsafe(24)
        session["csrf_token"] = token
    return token


def validate_csrf() -> None:
    session_token = ensure_csrf_token()
    form_token = request.form.get("csrf_token", "")
    if not form_token or form_token != session_token:
        abort(400)


def parse_cidrs(raw_value: str) -> list[ipaddress._BaseNetwork]:
    networks: list[ipaddress._BaseNetwork] = []
    for item in raw_value.split(","):
        cidr = item.strip()
        if not cidr:
            continue
        networks.append(ipaddress.ip_network(cidr, strict=False))
    return networks


def get_client_ip() -> str:
    forwarded = request.headers.get("X-Forwarded-For", "")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.remote_addr or ""


def client_ip_allowed(app: Flask) -> bool:
    ip_text = get_client_ip()
    try:
        ip_addr = ipaddress.ip_address(ip_text)
    except ValueError:
        return False
    for network in app.config["ADMIN_ALLOW_NETWORKS"]:
        if ip_addr in network:
            return True
    return False


def fetch_yuki_meta(yuki_url: str) -> tuple[dict[str, dict[str, Any]], str | None]:
    if not yuki_url:
        return {}, "未配置 yuki 状态接口。"
    try:
        response = requests.get(yuki_url, timeout=2)
        response.raise_for_status()
        payload = response.json()
        if not isinstance(payload, list):
            return {}, "yuki 状态接口返回格式异常。"
        return {
            str(item.get("name")): item
            for item in payload
            if isinstance(item, dict) and item.get("name")
        }, None
    except requests.exceptions.ConnectionError:
        return {}, "yuki 当前未运行（连不上 127.0.0.1:9999）。管理页仍可改 YAML，但 yuki 实时状态、重载与同步会被跳过。"
    except requests.RequestException as exc:
        return {}, f"无法访问 yuki 状态接口：{exc}"


def load_repo_records(directory: Path, state: str, meta_map: dict[str, dict[str, Any]]) -> list[RepoRecord]:
    repos: list[RepoRecord] = []
    if not directory.exists():
        return repos
    for path in sorted(directory.glob("*.yaml")):
        repos.append(load_repo_record(path, state, meta_map))
    return repos


def load_example_records(directory: Path, occupied_names: set[str]) -> list[RepoRecord]:
    repos: list[RepoRecord] = []
    if not directory.exists():
        return repos
    for path in sorted(directory.glob("*.yaml.example")):
        repo = load_repo_record(path, "example", {})
        repo.exists_elsewhere = repo.name in occupied_names
        repos.append(repo)
    return repos


def load_repo_record(path: Path, state: str, meta_map: dict[str, dict[str, Any]]) -> RepoRecord:
    name = repo_name_from_path(path)
    repo = RepoRecord(name=name, state=state, path=path)
    try:
        config = load_repo_config(path)
        envs = config.get("envs") or {}
        meta = meta_map.get(name, {})
        repo.cron = str(config.get("cron", ""))
        repo.storage_dir = str(config.get("storageDir", ""))
        repo.image = str(config.get("image", ""))
        repo.upstream = str(envs.get("$UPSTREAM") or envs.get("UPSTREAM") or meta.get("upstream") or "")
        repo.rsync_host = str(envs.get("RSYNC_HOST", ""))
        repo.rsync_path = str(envs.get("RSYNC_PATH", ""))
        repo.size = safe_int(meta.get("size"))
        repo.syncing = bool(meta.get("syncing")) if meta else False
        repo.exit_code = safe_int(meta.get("exitCode"))
        repo.last_success = safe_int(meta.get("lastSuccess"))
        repo.prev_run = safe_int(meta.get("prevRun"))
        repo.next_run = safe_int(meta.get("nextRun"))
    except Exception as exc:
        repo.parse_error = str(exc)
    return repo


def load_repo_config(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        loaded = yaml.safe_load(handle) or {}
    if not isinstance(loaded, dict):
        raise ValueError("仓库配置不是合法的 YAML 对象")
    return loaded


def repo_name_from_path(path: Path) -> str:
    if path.name.endswith(".yaml.example"):
        return path.name[: -len(".yaml.example")]
    return path.stem


def validate_repo_name(name: str) -> str:
    if not NAME_RE.match(name):
        abort(400)
    return name


def repo_path_for_state(app: Flask, name: str, state: str, must_exist: bool = True) -> Path:
    if state == "enabled":
        base_dir = app.config["ADMIN_REPO_DIR"]
    elif state == "disabled":
        base_dir = app.config["ADMIN_REPO_DISABLED_DIR"]
    else:
        abort(400)
    path = base_dir / f"{name}.yaml"
    if must_exist and not path.exists():
        abort(404)
    return path


def anchor_for_state(state: str) -> str:
    if state == "enabled":
        return "enabled"
    if state == "disabled":
        return "disabled"
    return "examples"


def move_repo_file(src: Path, dst: Path) -> None:
    if not src.exists():
        abort(404)
    if dst.exists():
        raise FileExistsError(f"{dst} 已存在")
    dst.parent.mkdir(parents=True, exist_ok=True)
    src.replace(dst)


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        handle.write(content)
        tmp_name = handle.name
    Path(tmp_name).replace(path)


def delete_storage_dir_if_safe(app: Flask, storage_dir: Path) -> bool:
    try:
        resolved = storage_dir.resolve(strict=False)
        web_root = app.config["MIRROR_WEB_ROOT"].resolve(strict=False)
    except OSError:
        return False
    if resolved == web_root:
        return False
    if web_root not in resolved.parents:
        return False
    if not resolved.exists():
        return False
    shutil.rmtree(resolved)
    return True


def run_yukictl(app: Flask, *args: str, timeout: int = 15) -> tuple[int, str]:
    binary = Path(app.config["ADMIN_YUKICTL_BIN"])
    if not binary.exists():
        return 127, f"未找到 {binary}"
    return run_command([str(binary), *args], timeout=timeout)


def run_yukictl_background(app: Flask, *args: str) -> tuple[int, str]:
    binary = Path(app.config["ADMIN_YUKICTL_BIN"])
    if not binary.exists():
        return 127, f"未找到 {binary}"
    try:
        subprocess.Popen(
            [str(binary), *args],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        return 0, "submitted"
    except OSError as exc:
        return 126, str(exc)


def run_command(command: list[str], timeout: int, extra_env: dict[str, str] | None = None) -> tuple[int, str]:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            check=False,
        )
        detail = completed.stderr.strip() or completed.stdout.strip() or "无输出"
        return completed.returncode, detail
    except subprocess.TimeoutExpired:
        return 124, f"命令执行超时：{' '.join(command)}"
    except OSError as exc:
        return 126, str(exc)


def safe_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def format_filesize(value: int | None) -> str:
    if value is None or value < 0:
        return "-"
    size = float(value)
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    for unit in units:
        if size < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(size)} {unit}"
            return f"{size:.1f} {unit}"
        size /= 1024
    return "-"


def format_timestamp(value: int | None) -> str:
    if value is None or value < 0:
        return "-"
    return __import__("datetime").datetime.fromtimestamp(value).strftime("%Y-%m-%d %H:%M:%S")


def validate_cron_expression(repo_name: str, cron: str, config: dict[str, Any]) -> None:
    parts = cron.split()
    if len(parts) != 5:
        raise ValueError("cron 表达式必须是 5 段。")
    field_ranges = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)]
    for field, (minimum, maximum) in zip(parts, field_ranges):
        validate_cron_field(field, minimum, maximum)

    envs = config.get("envs") or {}
    rsync_host = str(envs.get("RSYNC_HOST", ""))
    rsync_path = str(envs.get("RSYNC_PATH", ""))
    if rsync_host == "mirrors.ustc.edu.cn":
        raise ValueError("USTC 上游必须使用 rsync.mirrors.ustc.edu.cn。")
    if is_ustc_host(rsync_host):
        if rsync_host != "rsync.mirrors.ustc.edu.cn":
            raise ValueError("USTC 上游必须使用 rsync.mirrors.ustc.edu.cn。")
        validate_ustc_cron(repo_name, rsync_path, parts)


def validate_cron_field(field: str, minimum: int, maximum: int) -> None:
    for token in field.split(","):
        if not token:
            raise ValueError("cron 字段包含空项。")
        validate_cron_token(token, minimum, maximum)


def validate_cron_token(token: str, minimum: int, maximum: int) -> None:
    if token == "*":
        return
    if token.startswith("*/"):
        validate_number(token[2:], 1, maximum)
        return
    if "/" in token:
        base, step = token.split("/", 1)
        if not step:
            raise ValueError("cron 步长不能为空。")
        validate_number(step, 1, maximum)
        validate_cron_token(base, minimum, maximum)
        return
    if "-" in token:
        start, end = token.split("-", 1)
        validate_number(start, minimum, maximum)
        validate_number(end, minimum, maximum)
        if int(start) > int(end):
            raise ValueError("cron 范围起点不能大于终点。")
        return
    validate_number(token, minimum, maximum)


def validate_number(raw_value: str, minimum: int, maximum: int) -> None:
    if not raw_value.isdigit():
        raise ValueError(f"cron 字段包含非法值：{raw_value}")
    value = int(raw_value)
    if value < minimum or value > maximum:
        raise ValueError(f"cron 字段超出范围：{raw_value}")


def is_ustc_host(host: str) -> bool:
    return host == "rsync.mirrors.ustc.edu.cn" or host.endswith(".ustc.edu.cn")


def is_ustc_hot_repo(repo_name: str, rsync_path: str) -> bool:
    return repo_name.startswith("ubuntu") or rsync_path.startswith("ubuntu")


def validate_ustc_cron(repo_name: str, rsync_path: str, parts: list[str]) -> None:
    minute, hour, _dom, _month, _dow = parts
    if not minute.isdigit():
        raise ValueError("USTC 上游要求使用固定分钟。")
    if hour.isdigit():
        return
    if not is_ustc_hot_repo(repo_name, rsync_path):
        raise ValueError("USTC 普通仓库建议每天最多同步一次，例如 17 3 * * *。")
    if hour.startswith("*/") and hour[2:].isdigit() and int(hour[2:]) >= 6:
        return
    validate_ustc_hot_hour_list(hour)


def validate_ustc_hot_hour_list(hour_field: str) -> None:
    hour_values = hour_field.split(",")
    if not hour_values or len(hour_values) > 4:
        raise ValueError("USTC 热门仓库最多建议每天 4 次同步。")
    normalized: list[int] = []
    for item in hour_values:
        if not item.isdigit():
            raise ValueError("USTC 热门仓库请使用固定小时或 */6 这类表达式。")
        hour = int(item)
        if hour < 0 or hour > 23:
            raise ValueError("cron 小时字段超出范围。")
        normalized.append(hour)
    normalized = sorted(set(normalized))
    if len(normalized) != len(hour_values):
        raise ValueError("cron 小时字段不能重复。")
    first = normalized[0]
    prev = first
    for current in normalized[1:]:
        if current - prev < 6:
            raise ValueError("USTC 热门仓库同步间隔必须至少 6 小时。")
        prev = current
    if 24 + first - prev < 6:
        raise ValueError("USTC 热门仓库同步间隔必须至少 6 小时。")


app = create_app()


if __name__ == "__main__":
    bind = os.environ.get("ADMIN_BIND", "127.0.0.1:18081")
    host, _, port = bind.rpartition(":")
    app.run(host=host or "127.0.0.1", port=int(port or "18081"), debug=False)
