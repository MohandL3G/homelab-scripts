#!/usr/bin/env python3
"""
Zerobyte CLI Helper for Antigravity Agent.

Interacts with Zerobyte's HTTP REST API (/api/v1) using ZEROBYTE_API_KEY
and optional ZEROBYTE_BASE_URL from /root/.env (default: http://192.168.0.100:4096).
"""

import argparse
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

ENV_FILE = "/root/.env"
DEFAULT_BASE_URL = "http://192.168.0.100:4096"

SENSITIVE_KEYS = {
    "password",
    "secret",
    "token",
    "apikey",
    "api_key",
    "resticpassword",
    "restic_password",
    "credentialhash",
    "credential_hash",
    "exportpassphrase",
    "export_passphrase",
    "accesskey",
    "access_key",
    "secretaccesskey",
    "secret_access_key",
    "clientsecret",
    "client_secret",
    "passphrase",
}

CONTEXT: Dict[str, str] = {
    "base_url": DEFAULT_BASE_URL,
    "api_key": "",
}


def load_raw_env() -> Dict[str, str]:
    """Read /root/.env and overlay process environment variables."""
    env_vars: Dict[str, str] = {}
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                env_vars[k.strip()] = v.strip().strip("'\"")
    env_vars.update(os.environ)
    return env_vars


def init_context(base_url_override: Optional[str] = None) -> None:
    """Resolve Zerobyte base URL and API key without exposing credentials."""
    env = load_raw_env()
    api_key = env.get("ZEROBYTE_API_KEY", "").strip()
    if not api_key:
        print("Error: ZEROBYTE_API_KEY not found in /root/.env or environment.", file=sys.stderr)
        sys.exit(1)
    base_url = (base_url_override or env.get("ZEROBYTE_BASE_URL") or DEFAULT_BASE_URL).strip().rstrip("/")
    CONTEXT["base_url"] = base_url
    CONTEXT["api_key"] = api_key


def redact_secrets(obj: Any) -> Any:
    """Recursively mask sensitive fields in API payloads before printing."""
    if isinstance(obj, dict):
        cleaned: Dict[str, Any] = {}
        for k, v in obj.items():
            if k.lower() in SENSITIVE_KEYS and v not in (None, ""):
                cleaned[k] = "<REDACTED>"
            else:
                cleaned[k] = redact_secrets(v)
        return cleaned
    if isinstance(obj, list):
        return [redact_secrets(item) for item in obj]
    return obj


def api_request(
    method: str,
    path: str,
    data: Optional[Any] = None,
    query: Optional[Dict[str, Any]] = None,
    raw_bytes: bool = False,
) -> Any:
    """Perform an authenticated HTTP request against Zerobyte."""
    url = f"{CONTEXT['base_url']}{path if path.startswith('/') else '/' + path}"
    if query:
        filtered = {k: v for k, v in query.items() if v is not None}
        if filtered:
            sep = "&" if "?" in url else "?"
            url = f"{url}{sep}{urllib.parse.urlencode(filtered)}"

    headers = {
        "X-API-Key": CONTEXT["api_key"],
        "Accept": "application/json, text/plain, */*",
    }
    body: Optional[bytes] = None
    if data is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode("utf-8")

    req = urllib.request.Request(url, data=body, headers=headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            if raw_bytes:
                return raw
            if not raw:
                return {"status": resp.status, "ok": True}
            ctype = resp.headers.get("Content-Type", "")
            text = raw.decode("utf-8", "replace")
            if "json" in ctype or text.lstrip().startswith(("{", "[")):
                try:
                    return json.loads(text)
                except json.JSONDecodeError:
                    return text
            return text
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", "replace")
        print(f"API Error ({e.code} {e.reason}) on {method.upper()} {path}: {err_body}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Connection Error on {method.upper()} {path}: {e.reason}", file=sys.stderr)
        sys.exit(1)


def require_confirmed(confirmed: bool, action: str) -> None:
    """Block destructive or recovery-mutating operations without --confirmed."""
    if not confirmed:
        print(
            f"Safety block: '{action}' requires explicit user confirmation and --confirmed.",
            file=sys.stderr,
        )
        sys.exit(2)


def load_json_arg(json_str: Optional[str], file_path: Optional[str]) -> Any:
    """Parse JSON from an inline string or file path."""
    if file_path:
        with open(file_path, "r", encoding="utf-8") as f:
            return json.load(f)
    if json_str is not None:
        return json.loads(json_str)
    return None


def fmt_bytes(num: Optional[int]) -> str:
    """Format byte counts into human-readable units."""
    if num is None:
        return "-"
    val = float(num)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(val) < 1024.0:
            return f"{val:.2f} {unit}" if unit != "B" else f"{int(val)} B"
        val /= 1024.0
    return f"{val:.2f} PB"


def fmt_ts(ts: Optional[Any]) -> str:
    """Convert epoch milliseconds or ISO timestamp to UTC string."""
    if ts is None or ts == "":
        return "-"
    if isinstance(ts, (int, float)):
        secs = ts / 1000.0 if ts > 1e12 else float(ts)
        return datetime.datetime.fromtimestamp(secs, tz=datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return str(ts)


def print_table(headers: List[str], rows: List[List[Any]]) -> None:
    """Render an aligned ASCII table."""
    str_rows = [[str(c) for c in r] for r in rows]
    widths = [len(h) for h in headers]
    for r in str_rows:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], len(c))
    fmt = "  ".join(f"{{:<{w}}}" for w in widths)
    print(fmt.format(*headers))
    print(fmt.format(*("-" * w for w in widths)))
    for r in str_rows:
        print(fmt.format(*r))


def emit(data: Any, as_json: bool) -> None:
    """Print redacted JSON payload."""
    safe = redact_secrets(data)
    if as_json or not isinstance(safe, str):
        print(json.dumps(safe, indent=2, ensure_ascii=False))
    else:
        print(safe)


def resolve_by_identifier(items: List[Dict[str, Any]], ident: str, kind: str) -> Dict[str, Any]:
    """Match an item by shortId, id, or case-insensitive name."""
    ident_l = ident.strip().lower()
    for key in ("shortId", "id"):
        for item in items:
            if str(item.get(key, "")).lower() == ident_l:
                return item
    matches = [item for item in items if str(item.get("name", "")).lower() == ident_l]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        print(f"Error: Multiple {kind} entries named '{ident}'. Use shortId instead.", file=sys.stderr)
        sys.exit(1)
    print(f"Error: {kind} '{ident}' not found.", file=sys.stderr)
    sys.exit(1)


def resolve_volume(ident: str) -> Dict[str, Any]:
    return resolve_by_identifier(api_request("GET", "/api/v1/volumes"), ident, "volume")


def resolve_repo(ident: str) -> Dict[str, Any]:
    return resolve_by_identifier(api_request("GET", "/api/v1/repositories"), ident, "repository")


def resolve_backup(ident: str) -> Dict[str, Any]:
    return resolve_by_identifier(api_request("GET", "/api/v1/backups"), ident, "backup")


def wait_for_task(task_id: str, timeout_s: int = 600, poll_s: float = 2.0) -> Dict[str, Any]:
    """Poll /api/v1/tasks/{taskId} until completion or timeout."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        task = api_request("GET", f"/api/v1/tasks/{urllib.parse.quote(task_id)}")
        status = str(task.get("status", "")).lower()
        if status in ("succeeded", "completed", "failed", "error", "cancelled", "canceled"):
            return task
        time.sleep(poll_s)
    print(f"Timed out waiting for task {task_id} after {timeout_s}s.", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Subcommand Handlers
# ---------------------------------------------------------------------------


def handle_system(args: argparse.Namespace) -> None:
    ep = "/api/v1/system/info" if args.action == "info" else "/api/v1/system/updates"
    emit(api_request("GET", ep), as_json=True)


def handle_volumes(args: argparse.Namespace) -> None:
    act = args.action
    if act == "list":
        vols = api_request("GET", "/api/v1/volumes")
        if args.json:
            emit(vols, True)
            return
        rows = [
            [v.get("shortId"), v.get("id"), v.get("name"), v.get("type"), v.get("status"), fmt_ts(v.get("lastHealthCheck"))]
            for v in vols
        ]
        print_table(["SHORT_ID", "ID", "NAME", "TYPE", "STATUS", "LAST_CHECK"], rows)
    elif act == "get":
        vol = resolve_volume(args.volume)
        emit(api_request("GET", f"/api/v1/volumes/{vol['shortId']}"), as_json=True)
    elif act == "create":
        payload = load_json_arg(args.json_body, args.file)
        if payload is None:
            print("Error: Provide --json-body or --file.", file=sys.stderr)
            sys.exit(1)
        emit(api_request("POST", "/api/v1/volumes", data=payload), as_json=True)
    elif act == "update":
        vol = resolve_volume(args.volume)
        payload = load_json_arg(args.json_body, args.file)
        if payload is None:
            print("Error: Provide --json-body or --file.", file=sys.stderr)
            sys.exit(1)
        emit(api_request("PUT", f"/api/v1/volumes/{vol['shortId']}", data=payload), as_json=True)
    elif act in ("mount", "unmount", "health-check"):
        vol = resolve_volume(args.volume)
        emit(api_request("POST", f"/api/v1/volumes/{vol['shortId']}/{act}"), as_json=True)
    elif act == "test-connection":
        payload = load_json_arg(args.json_body, args.file)
        if payload is None:
            print("Error: Provide --json-body or --file.", file=sys.stderr)
            sys.exit(1)
        emit(api_request("POST", "/api/v1/volumes/test-connection", data=payload), as_json=True)
    elif act == "files":
        vol = resolve_volume(args.volume)
        res = api_request(
            "GET",
            f"/api/v1/volumes/{vol['shortId']}/files",
            query={"path": args.path, "offset": args.offset, "limit": args.limit},
        )
        if args.json:
            emit(res, True)
            return
        entries = res.get("files", res) if isinstance(res, dict) else res
        if not isinstance(entries, list):
            emit(res, True)
            return
        rows = [[e.get("type", "-"), fmt_bytes(e.get("size")), e.get("name", e.get("path", "-"))] for e in entries]
        print_table(["TYPE", "SIZE", "NAME"], rows)
    elif act == "delete":
        require_confirmed(args.confirmed, f"volumes delete {args.volume}")
        vol = resolve_volume(args.volume)
        emit(api_request("DELETE", f"/api/v1/volumes/{vol['shortId']}"), as_json=True)


def handle_repos(args: argparse.Namespace) -> None:
    act = args.action
    if act == "list":
        repos = api_request("GET", "/api/v1/repositories")
        if args.json:
            emit(repos, True)
            return
        rows = []
        for r in repos:
            stats = r.get("stats") or {}
            rows.append([
                r.get("shortId"),
                r.get("name"),
                r.get("type"),
                r.get("status"),
                stats.get("snapshots_count", "-"),
                fmt_bytes(stats.get("total_size")),
            ])
        print_table(["SHORT_ID", "NAME", "TYPE", "STATUS", "SNAPSHOTS", "SIZE"], rows)
    elif act == "get":
        repo = resolve_repo(args.repo)
        emit(api_request("GET", f"/api/v1/repositories/{repo['shortId']}"), as_json=True)
    elif act == "stats":
        repo = resolve_repo(args.repo)
        emit(api_request("GET", f"/api/v1/repositories/{repo['shortId']}/stats"), as_json=True)
    elif act == "refresh-stats":
        repo = resolve_repo(args.repo)
        emit(api_request("POST", f"/api/v1/repositories/{repo['shortId']}/stats/refresh"), as_json=True)
    elif act == "doctor":
        repo = resolve_repo(args.repo)
        emit(api_request("POST", f"/api/v1/repositories/{repo['shortId']}/doctor"), as_json=True)
    elif act == "unlock":
        require_confirmed(args.confirmed, f"repos unlock {args.repo}")
        repo = resolve_repo(args.repo)
        emit(api_request("POST", f"/api/v1/repositories/{repo['shortId']}/unlock"), as_json=True)
    elif act == "exec":
        require_confirmed(args.confirmed, f"repos exec {args.repo} {args.command}")
        repo = resolve_repo(args.repo)
        res = api_request(
            "POST",
            f"/api/v1/repositories/{repo['shortId']}/exec",
            data={"command": args.command, "args": args.exec_args},
        )
        emit(res, as_json=args.json)
    elif act == "delete":
        require_confirmed(args.confirmed, f"repos delete {args.repo}")
        repo = resolve_repo(args.repo)
        emit(api_request("DELETE", f"/api/v1/repositories/{repo['shortId']}"), as_json=True)


def handle_snapshots(args: argparse.Namespace) -> None:
    act = args.action
    repo = resolve_repo(args.repo)
    sid = repo["shortId"]
    if act == "list":
        query = {}
        if args.backup:
            b = resolve_backup(args.backup)
            query["backupId"] = b["shortId"]
        snaps = api_request("GET", f"/api/v1/repositories/{sid}/snapshots", query=query)
        if args.json:
            emit(snaps, True)
            return
        rows = []
        for s in snaps:
            summary = s.get("summary") or {}
            rows.append([
                s.get("short_id") or str(s.get("id", ""))[:8],
                fmt_ts(s.get("time")),
                ",".join(s.get("tags") or []) or "-",
                summary.get("total_files_processed", "-"),
                fmt_bytes(s.get("size") or summary.get("total_bytes_processed")),
                len(s.get("paths") or []),
            ])
        print_table(["SNAPSHOT", "TIME", "TAGS", "FILES", "SIZE", "PATHS"], rows)
    elif act == "get":
        emit(api_request("GET", f"/api/v1/repositories/{sid}/snapshots/{args.snapshot_id}"), as_json=True)
    elif act == "files":
        res = api_request(
            "GET",
            f"/api/v1/repositories/{sid}/snapshots/{args.snapshot_id}/files",
            query={"path": args.path, "offset": args.offset, "limit": args.limit},
        )
        if args.json:
            emit(res, True)
            return
        entries = res.get("files", res) if isinstance(res, dict) else res
        if not isinstance(entries, list):
            emit(res, True)
            return
        rows = [[e.get("type", "-"), fmt_bytes(e.get("size")), e.get("path") or e.get("name", "-")] for e in entries]
        print_table(["TYPE", "SIZE", "PATH"], rows)
    elif act == "refresh":
        emit(api_request("POST", f"/api/v1/repositories/{sid}/snapshots/refresh"), as_json=True)
    elif act == "tag":
        payload: Dict[str, Any] = {"snapshotIds": args.snapshot_ids}
        if args.add:
            payload["add"] = args.add
        if args.remove:
            payload["remove"] = args.remove
        if args.set_tags:
            payload["set"] = args.set_tags
        emit(api_request("POST", f"/api/v1/repositories/{sid}/snapshots/tag", data=payload), as_json=True)
    elif act == "delete":
        require_confirmed(args.confirmed, f"snapshots delete in {args.repo}")
        emit(
            api_request(
                "DELETE",
                f"/api/v1/repositories/{sid}/snapshots",
                data={"snapshotIds": args.snapshot_ids},
            ),
            as_json=True,
        )


def handle_backups(args: argparse.Namespace) -> None:
    act = args.action
    if act == "list":
        backups = api_request("GET", "/api/v1/backups")
        if args.json:
            emit(backups, True)
            return
        rows = [
            [
                b.get("shortId"),
                b.get("name"),
                (b.get("volume") or {}).get("name", b.get("volumeId")),
                (b.get("repository") or {}).get("name", b.get("repositoryId")),
                "on" if b.get("enabled") else "off",
                b.get("cronExpression"),
                b.get("lastBackupStatus") or "-",
                fmt_ts(b.get("lastBackupAt")),
            ]
            for b in backups
        ]
        print_table(["SHORT_ID", "NAME", "VOLUME", "REPO", "ENABLED", "CRON", "LAST_STATUS", "LAST_RUN"], rows)
    elif act == "get":
        b = resolve_backup(args.backup)
        emit(api_request("GET", f"/api/v1/backups/{b['shortId']}"), as_json=True)
    elif act == "by-volume":
        v = resolve_volume(args.volume)
        emit(api_request("GET", f"/api/v1/backups/volume/{v['shortId']}"), as_json=True)
    elif act == "create":
        payload = load_json_arg(args.json_body, args.file)
        if payload is None:
            print("Error: Provide --json-body or --file.", file=sys.stderr)
            sys.exit(1)
        emit(api_request("POST", "/api/v1/backups", data=payload), as_json=True)
    elif act == "update":
        b = resolve_backup(args.backup)
        payload = load_json_arg(args.json_body, args.file)
        if payload is None:
            print("Error: Provide --json-body or --file.", file=sys.stderr)
            sys.exit(1)
        emit(api_request("PATCH", f"/api/v1/backups/{b['shortId']}", data=payload), as_json=True)
    elif act == "run":
        b = resolve_backup(args.backup)
        res = api_request("POST", f"/api/v1/backups/{b['shortId']}/run")
        if args.wait and isinstance(res, dict) and res.get("taskId"):
            res = wait_for_task(res["taskId"], timeout_s=args.timeout)
        emit(res, as_json=True)
    elif act == "forget":
        require_confirmed(args.confirmed, f"backups forget {args.backup}")
        b = resolve_backup(args.backup)
        res = api_request("POST", f"/api/v1/backups/{b['shortId']}/forget")
        if args.wait and isinstance(res, dict) and res.get("taskId"):
            res = wait_for_task(res["taskId"], timeout_s=args.timeout)
        emit(res, as_json=True)
    elif act == "delete":
        require_confirmed(args.confirmed, f"backups delete {args.backup}")
        b = resolve_backup(args.backup)
        emit(api_request("DELETE", f"/api/v1/backups/{b['shortId']}"), as_json=True)


def handle_restore(args: argparse.Namespace) -> None:
    require_confirmed(args.confirmed, f"restore {args.snapshot_id} from {args.repo}")
    repo = resolve_repo(args.repo)
    payload: Dict[str, Any] = {"snapshotId": args.snapshot_id}
    if args.include:
        payload["include"] = args.include
    if args.kind:
        payload["selectedItemKind"] = args.kind
    if args.exclude:
        payload["exclude"] = args.exclude
    if args.target_path:
        payload["targetPath"] = args.target_path
    if args.overwrite:
        payload["overwrite"] = args.overwrite
    if args.delete_extra:
        payload["delete"] = True
    emit(api_request("POST", f"/api/v1/repositories/{repo['shortId']}/restore", data=payload), as_json=True)


def handle_tasks(args: argparse.Namespace) -> None:
    act = args.action
    if act == "list":
        tasks = api_request("GET", "/api/v1/tasks", query={"kind": args.kind})
        if args.json:
            emit(tasks, True)
            return
        rows = [
            [t.get("id"), t.get("kind"), t.get("status"), t.get("resourceType"), t.get("resourceId"), fmt_ts(t.get("createdAt"))]
            for t in (tasks if isinstance(tasks, list) else [])
        ]
        print_table(["TASK_ID", "KIND", "STATUS", "RESOURCE", "RESOURCE_ID", "CREATED"], rows)
    elif act == "get":
        emit(api_request("GET", f"/api/v1/tasks/{urllib.parse.quote(args.task_id)}"), as_json=True)
    elif act == "history":
        hist = api_request("GET", "/api/v1/tasks/history", query={"kind": args.kind, "outcome": args.outcome, "page": args.page})
        if args.json:
            emit(hist, True)
            return
        items = hist.get("items", hist.get("tasks", hist)) if isinstance(hist, dict) else hist
        if not isinstance(items, list):
            emit(hist, True)
            return
        rows = [
            [t.get("id"), t.get("kind"), t.get("status") or t.get("outcome"), t.get("resourceName") or t.get("resourceId"), fmt_ts(t.get("finishedAt") or t.get("createdAt"))]
            for t in items
        ]
        print_table(["TASK_ID", "KIND", "OUTCOME", "RESOURCE", "TIME"], rows)
    elif act == "cancel":
        emit(api_request("POST", f"/api/v1/tasks/{urllib.parse.quote(args.task_id)}/cancel"), as_json=True)


def handle_notifications(args: argparse.Namespace) -> None:
    if args.action == "list":
        dests = api_request("GET", "/api/v1/notifications/destinations")
        if args.json:
            emit(dests, True)
            return
        rows = [[d.get("id"), d.get("name"), (d.get("config") or {}).get("type", "-"), d.get("enabled")] for d in dests]
        print_table(["ID", "NAME", "TYPE", "ENABLED"], rows)
    elif args.action == "test":
        emit(api_request("POST", f"/api/v1/notifications/destinations/{args.id}/test"), as_json=True)


def handle_api(args: argparse.Namespace) -> None:
    method = args.method.upper()
    if method == "DELETE":
        require_confirmed(args.confirmed, f"api DELETE {args.path}")
    payload = load_json_arg(args.json_body, args.file)
    emit(api_request(method, args.path, data=payload), as_json=True)


# ---------------------------------------------------------------------------
# Argument Parser
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="Output redacted JSON")
    common.add_argument("--base-url", help="Override Zerobyte base URL")

    parser = argparse.ArgumentParser(
        description="Zerobyte API CLI Helper (uses ZEROBYTE_API_KEY from /root/.env)",
        parents=[common],
    )
    sub = parser.add_subparsers(dest="group", required=True)

    # system
    sys_p = sub.add_parser("system", help="System info and updates", parents=[common])
    sys_sub = sys_p.add_subparsers(dest="action", required=True)
    sys_sub.add_parser("info", help="Show server runtime & backend capabilities", parents=[common])
    sys_sub.add_parser("updates", help="Check available Zerobyte updates", parents=[common])

    # volumes
    vol_p = sub.add_parser("volumes", help="Manage backup source volumes", parents=[common])
    vol_sub = vol_p.add_subparsers(dest="action", required=True)
    vol_sub.add_parser("list", help="List all volumes", parents=[common])
    for name in ("get", "mount", "unmount", "health-check"):
        p = vol_sub.add_parser(name, help=f"{name} a volume", parents=[common])
        p.add_argument("volume", help="Volume name, shortId, or id")
    v_create = vol_sub.add_parser("create", help="Create a volume from JSON", parents=[common])
    v_create.add_argument("--json-body", help="Inline JSON payload")
    v_create.add_argument("--file", help="Path to JSON payload file")
    v_upd = vol_sub.add_parser("update", help="Update a volume from JSON", parents=[common])
    v_upd.add_argument("volume", help="Volume name, shortId, or id")
    v_upd.add_argument("--json-body", help="Inline JSON payload")
    v_upd.add_argument("--file", help="Path to JSON payload file")
    v_test = vol_sub.add_parser("test-connection", help="Test a volume config", parents=[common])
    v_test.add_argument("--json-body", help="Inline JSON payload")
    v_test.add_argument("--file", help="Path to JSON payload file")
    v_files = vol_sub.add_parser("files", help="Browse files inside a mounted volume", parents=[common])
    v_files.add_argument("volume", help="Volume name, shortId, or id")
    v_files.add_argument("--path", default="/", help="Directory path inside volume")
    v_files.add_argument("--offset", type=int, default=0, help="Pagination offset")
    v_files.add_argument("--limit", type=int, default=100, help="Pagination limit")
    v_del = vol_sub.add_parser("delete", help="Delete a volume (requires --confirmed)", parents=[common])
    v_del.add_argument("volume", help="Volume name, shortId, or id")
    v_del.add_argument("--confirmed", action="store_true", help="Confirm destructive action")

    # repos
    rep_p = sub.add_parser("repos", help="Manage Restic repositories", parents=[common])
    rep_sub = rep_p.add_subparsers(dest="action", required=True)
    rep_sub.add_parser("list", help="List repositories", parents=[common])
    for name in ("get", "stats", "refresh-stats", "doctor"):
        p = rep_sub.add_parser(name, help=f"{name} repository", parents=[common])
        p.add_argument("repo", help="Repository name, shortId, or id")
    for name in ("unlock", "delete"):
        p = rep_sub.add_parser(name, help=f"{name} repository (requires --confirmed)", parents=[common])
        p.add_argument("repo", help="Repository name, shortId, or id")
        p.add_argument("--confirmed", action="store_true", help="Confirm destructive/lock action")
    r_exec = rep_sub.add_parser("exec", help="Run restic command (dev panel, requires --confirmed)", parents=[common])
    r_exec.add_argument("repo", help="Repository name, shortId, or id")
    r_exec.add_argument("command", help="Restic command")
    r_exec.add_argument("exec_args", nargs="*", help="Arguments")
    r_exec.add_argument("--confirmed", action="store_true", help="Confirm action")

    # snapshots
    snp_p = sub.add_parser("snapshots", help="Inspect or manage repository snapshots", parents=[common])
    snp_sub = snp_p.add_subparsers(dest="action", required=True)
    s_list = snp_sub.add_parser("list", help="List snapshots in a repository", parents=[common])
    s_list.add_argument("repo", help="Repository name, shortId, or id")
    s_list.add_argument("--backup", help="Filter by backup schedule name or shortId")
    s_get = snp_sub.add_parser("get", help="Get snapshot details", parents=[common])
    s_get.add_argument("repo", help="Repository name, shortId, or id")
    s_get.add_argument("snapshot_id", help="Snapshot ID (full or prefix)")
    s_files = snp_sub.add_parser("files", help="List files inside a snapshot", parents=[common])
    s_files.add_argument("repo", help="Repository name, shortId, or id")
    s_files.add_argument("snapshot_id", help="Snapshot ID")
    s_files.add_argument("--path", default="/", help="Path inside snapshot")
    s_files.add_argument("--offset", type=int, default=0, help="Pagination offset")
    s_files.add_argument("--limit", type=int, default=100, help="Pagination limit")
    s_ref = snp_sub.add_parser("refresh", help="Refresh snapshot cache", parents=[common])
    s_ref.add_argument("repo", help="Repository name, shortId, or id")
    s_tag = snp_sub.add_parser("tag", help="Add/remove/set snapshot tags", parents=[common])
    s_tag.add_argument("repo", help="Repository name, shortId, or id")
    s_tag.add_argument("snapshot_ids", nargs="+", help="Snapshot ID(s)")
    s_tag.add_argument("--add", action="append", help="Tag to add")
    s_tag.add_argument("--remove", action="append", help="Tag to remove")
    s_tag.add_argument("--set", dest="set_tags", action="append", help="Replace tags")
    s_del = snp_sub.add_parser("delete", help="Delete snapshots (requires --confirmed)", parents=[common])
    s_del.add_argument("repo", help="Repository name, shortId, or id")
    s_del.add_argument("snapshot_ids", nargs="+", help="Snapshot ID(s)")
    s_del.add_argument("--confirmed", action="store_true", help="Confirm deletion")

    # backups
    bkp_p = sub.add_parser("backups", help="Manage and run backup schedules", parents=[common])
    bkp_sub = bkp_p.add_subparsers(dest="action", required=True)
    bkp_sub.add_parser("list", help="List backup schedules", parents=[common])
    b_get = bkp_sub.add_parser("get", help="Get backup schedule details", parents=[common])
    b_get.add_argument("backup", help="Backup name, shortId, or id")
    b_vol = bkp_sub.add_parser("by-volume", help="List schedules for a volume", parents=[common])
    b_vol.add_argument("volume", help="Volume name, shortId, or id")
    b_create = bkp_sub.add_parser("create", help="Create backup schedule from JSON", parents=[common])
    b_create.add_argument("--json-body", help="Inline JSON payload")
    b_create.add_argument("--file", help="Path to JSON payload file")
    b_upd = bkp_sub.add_parser("update", help="Patch backup schedule from JSON", parents=[common])
    b_upd.add_argument("backup", help="Backup name, shortId, or id")
    b_upd.add_argument("--json-body", help="Inline JSON payload")
    b_upd.add_argument("--file", help="Path to JSON payload file")
    b_run = bkp_sub.add_parser("run", help="Trigger an immediate backup run", parents=[common])
    b_run.add_argument("backup", help="Backup name, shortId, or id")
    b_run.add_argument("--wait", action="store_true", help="Wait for task completion")
    b_run.add_argument("--timeout", type=int, default=600, help="Wait timeout seconds")
    b_fgt = bkp_sub.add_parser("forget", help="Apply retention policy (requires --confirmed)", parents=[common])
    b_fgt.add_argument("backup", help="Backup name, shortId, or id")
    b_fgt.add_argument("--wait", action="store_true", help="Wait for task completion")
    b_fgt.add_argument("--timeout", type=int, default=600, help="Wait timeout seconds")
    b_fgt.add_argument("--confirmed", action="store_true", help="Confirm retention prune")
    b_del = bkp_sub.add_parser("delete", help="Delete backup schedule (requires --confirmed)", parents=[common])
    b_del.add_argument("backup", help="Backup name, shortId, or id")
    b_del.add_argument("--confirmed", action="store_true", help="Confirm deletion")

    # restore
    rst_p = sub.add_parser("restore", help="Restore snapshot data", parents=[common])
    rst_sub = rst_p.add_subparsers(dest="action", required=True)
    r_run = rst_sub.add_parser("run", help="Start a snapshot restore (requires --confirmed)", parents=[common])
    r_run.add_argument("repo", help="Repository name, shortId, or id")
    r_run.add_argument("snapshot_id", help="Snapshot ID")
    r_run.add_argument("--include", action="append", help="Path to include (repeatable)")
    r_run.add_argument("--kind", choices=["file", "dir"], help="Selected item kind")
    r_run.add_argument("--exclude", action="append", help="Pattern to exclude (repeatable)")
    r_run.add_argument("--target-path", help="Target path (default: original location)")
    r_run.add_argument("--overwrite", choices=["always", "if-changed", "if-newer", "never"], help="Overwrite behavior")
    r_run.add_argument("--delete-extra", action="store_true", help="Delete extra files at target")
    r_run.add_argument("--confirmed", action="store_true", help="Confirm restore operation")

    # tasks
    tsk_p = sub.add_parser("tasks", help="Inspect or cancel background tasks", parents=[common])
    tsk_sub = tsk_p.add_subparsers(dest="action", required=True)
    t_list = tsk_sub.add_parser("list", help="List active tasks", parents=[common])
    t_list.add_argument("--kind", help="Filter by task kind")
    t_get = tsk_sub.add_parser("get", help="Get task status", parents=[common])
    t_get.add_argument("task_id", help="Task UUID")
    t_hist = tsk_sub.add_parser("history", help="List past tasks", parents=[common])
    t_hist.add_argument("--kind", help="Filter by task kind")
    t_hist.add_argument("--outcome", help="Filter by outcome")
    t_hist.add_argument("--page", type=int, default=1, help="Page number")
    t_can = tsk_sub.add_parser("cancel", help="Cancel an active task", parents=[common])
    t_can.add_argument("task_id", help="Task UUID")

    # notifications
    ntf_p = sub.add_parser("notifications", help="Manage notification destinations", parents=[common])
    ntf_sub = ntf_p.add_subparsers(dest="action", required=True)
    ntf_sub.add_parser("list", help="List notification destinations", parents=[common])
    n_test = ntf_sub.add_parser("test", help="Send test notification", parents=[common])
    n_test.add_argument("id", help="Destination ID")

    # raw api
    api_p = sub.add_parser("api", help="Call any Zerobyte API endpoint directly", parents=[common])
    api_p.add_argument("method", choices=["GET", "POST", "PUT", "PATCH", "DELETE"], help="HTTP method")
    api_p.add_argument("path", help="Endpoint path (e.g. /api/v1/agents)")
    api_p.add_argument("--json-body", help="Inline JSON payload")
    api_p.add_argument("--file", help="Path to JSON payload file")
    api_p.add_argument("--confirmed", action="store_true", help="Required for DELETE requests")

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    init_context(args.base_url)

    dispatch = {
        "system": handle_system,
        "volumes": handle_volumes,
        "repos": handle_repos,
        "snapshots": handle_snapshots,
        "backups": handle_backups,
        "restore": handle_restore,
        "tasks": handle_tasks,
        "notifications": handle_notifications,
        "api": handle_api,
    }
    dispatch[args.group](args)


if __name__ == "__main__":
    main()
