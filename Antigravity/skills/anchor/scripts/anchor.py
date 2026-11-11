#!/usr/bin/env python3
"""
Anchor CLI Helper for Antigravity Agent
Interact with self-hosted Anchor Notes instance (https://anchor.mohandl3g.ly)
"""

import sys
import os
import json
import re
import urllib.request
import urllib.error
import urllib.parse
from typing import Any, Dict, List, Optional, Tuple

ENV_FILE = "/root/.env"


def load_env() -> Tuple[str, str]:
    base_url = os.environ.get("ANCHOR_BASE_URL", "")
    api_key = os.environ.get("ANCHOR_API_KEY", "")

    if os.path.exists(ENV_FILE):
        try:
            with open(ENV_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    k = k.strip()
                    v = v.strip().strip("'\"")
                    if k == "ANCHOR_BASE_URL" and not base_url:
                        base_url = v
                    elif k == "ANCHOR_API_KEY" and not api_key:
                        api_key = v
        except Exception:
            pass

    if not base_url:
        base_url = "https://anchor.mohandl3g.ly"

    if not api_key:
        print("Error: ANCHOR_API_KEY not found in environment or /root/.env", file=sys.stderr)
        sys.exit(1)

    return base_url.rstrip("/"), api_key


BASE_URL, API_KEY = load_env()


def api_request(
    method: str,
    path: str,
    params: Optional[Dict[str, Any]] = None,
    data: Optional[Dict[str, Any]] = None,
) -> Any:
    url = f"{BASE_URL}{path}"
    if params:
        encoded = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
        if encoded:
            url = f"{url}?{encoded}"

    body = None
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Accept": "application/json",
    }

    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status = resp.status
            resp_body = resp.read().decode("utf-8")
            if not resp_body:
                return {"status": "ok", "code": status}
            try:
                return json.loads(resp_body)
            except json.JSONDecodeError:
                return resp_body
    except urllib.error.HTTPError as e:
        err_msg = e.read().decode("utf-8", errors="replace")
        try:
            err_json = json.loads(err_msg)
            msg = err_json.get("message", err_msg)
        except Exception:
            msg = err_msg
        print(f"API Error ({e.code} {e.reason}): {msg}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Connection Error: {e.reason}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Quill Delta <-> Markdown Converters
# ---------------------------------------------------------------------------

def delta_to_markdown(raw_content: Optional[str]) -> str:
    """Convert Quill Delta JSON string into clean, readable Markdown."""
    if not raw_content:
        return ""

    try:
        data = json.loads(raw_content)
    except Exception:
        return raw_content

    if not isinstance(data, dict) or "ops" not in data:
        return raw_content

    ops = data.get("ops", [])
    output = []
    line_buffer = []

    for op in ops:
        insert = op.get("insert", "")
        attrs = op.get("attributes", {})

        if not isinstance(insert, str):
            continue

        parts = insert.split("\n")
        for idx, part in enumerate(parts):
            if part:
                # Apply inline styles
                styled_part = part
                if attrs.get("code"):
                    styled_part = f"`{styled_part}`"
                if attrs.get("bold"):
                    styled_part = f"**{styled_part}**"
                if attrs.get("italic"):
                    styled_part = f"*{styled_part}*"
                if attrs.get("strike"):
                    styled_part = f"~~{styled_part}~~"
                if attrs.get("link"):
                    styled_part = f"[{styled_part}]({attrs['link']})"
                line_buffer.append(styled_part)

            # A newline indicates end of current line with block attributes
            if idx < len(parts) - 1:
                line_str = "".join(line_buffer)
                line_buffer = []

                header = attrs.get("header")
                list_type = attrs.get("list")
                code_block = attrs.get("code-block")

                if header:
                    line_str = f"{'#' * int(header)} {line_str}"
                elif list_type == "bullet":
                    line_str = f"- {line_str}"
                elif list_type == "ordered":
                    line_str = f"1. {line_str}"
                elif list_type == "checked":
                    line_str = f"- [x] {line_str}"
                elif list_type == "unchecked":
                    line_str = f"- [ ] {line_str}"
                elif code_block:
                    line_str = f"    {line_str}"

                output.append(line_str)

    if line_buffer:
        output.append("".join(line_buffer))

    return "\n".join(output)


def markdown_to_delta(text: str) -> str:
    """Convert Markdown / plain text into Quill Delta JSON format."""
    if not text:
        return json.dumps({"ops": []})

    # If already a valid delta string, pass as-is
    try:
        val = json.loads(text)
        if isinstance(val, dict) and "ops" in val:
            return text
    except Exception:
        pass

    ops = []
    lines = text.split("\n")

    in_code_block = False

    for line in lines:
        if line.strip().startswith("```"):
            in_code_block = not in_code_block
            continue

        if in_code_block:
            ops.append({"insert": line})
            ops.append({"attributes": {"code-block": True}, "insert": "\n"})
            continue

        # Checklists
        if re.match(r"^-\s*\[x\]\s+(.*)", line, re.IGNORECASE):
            match = re.match(r"^-\s*\[x\]\s+(.*)", line, re.IGNORECASE)
            ops.append({"insert": match.group(1)})
            ops.append({"attributes": {"list": "checked"}, "insert": "\n"})
        elif re.match(r"^-\s*\[\s*\]\s+(.*)", line):
            match = re.match(r"^-\s*\[\s*\]\s+(.*)", line)
            ops.append({"insert": match.group(1)})
            ops.append({"attributes": {"list": "unchecked"}, "insert": "\n"})
        # Headers
        elif line.startswith("### "):
            ops.append({"insert": line[4:]})
            ops.append({"attributes": {"header": 3}, "insert": "\n"})
        elif line.startswith("## "):
            ops.append({"insert": line[3:]})
            ops.append({"attributes": {"header": 2}, "insert": "\n"})
        elif line.startswith("# "):
            ops.append({"insert": line[2:]})
            ops.append({"attributes": {"header": 1}, "insert": "\n"})
        # Bullet list
        elif re.match(r"^[-*]\s+(.*)", line):
            match = re.match(r"^[-*]\s+(.*)", line)
            ops.append({"insert": match.group(1)})
            ops.append({"attributes": {"list": "bullet"}, "insert": "\n"})
        # Numbered list
        elif re.match(r"^\d+\.\s+(.*)", line):
            match = re.match(r"^\d+\.\s+(.*)", line)
            ops.append({"insert": match.group(1)})
            ops.append({"attributes": {"list": "ordered"}, "insert": "\n"})
        # Regular line
        else:
            if line:
                ops.append({"insert": line})
            ops.append({"insert": "\n"})

    return json.dumps({"ops": ops})


# ---------------------------------------------------------------------------
# Tag & Note Lookup Helpers
# ---------------------------------------------------------------------------

def get_tags_map() -> Dict[str, str]:
    """Returns mapping of tag name (lowercase) -> tag ID."""
    tags = api_request("GET", "/api/tags")
    return {t["name"].lower(): t["id"] for t in tags}


def resolve_tag_ids(tag_names_or_ids: List[str]) -> List[str]:
    """Converts a list of tag names or IDs into valid tag IDs."""
    if not tag_names_or_ids:
        return []
    tags_map = get_tags_map()
    tag_id_set = set(tags_map.values())

    resolved = []
    for item in tag_names_or_ids:
        item_clean = item.strip()
        if not item_clean:
            continue
        if item_clean in tag_id_set:
            resolved.append(item_clean)
        elif item_clean.lower() in tags_map:
            resolved.append(tags_map[item_clean.lower()])
        else:
            print(f"Warning: Tag '{item_clean}' not found on server; skipping.", file=sys.stderr)
    return resolved


def find_note_by_id_or_title(identifier: str) -> Dict[str, Any]:
    """Finds a note either by exact UUID or by title query."""
    # Try as direct ID first
    is_uuid = bool(re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", identifier, re.I))
    if is_uuid:
        return api_request("GET", f"/api/notes/{identifier}")

    # Search by title
    notes = api_request("GET", "/api/notes", params={"search": identifier})
    if not notes:
        print(f"Error: No note found matching '{identifier}'", file=sys.stderr)
        sys.exit(1)

    exact_matches = [n for n in notes if n.get("title", "").strip().lower() == identifier.strip().lower()]
    if exact_matches:
        return exact_matches[0]

    return notes[0]


# ---------------------------------------------------------------------------
# CLI Commands
# ---------------------------------------------------------------------------

def cmd_tags(as_json: bool = False):
    tags = api_request("GET", "/api/tags")
    if as_json:
        print(json.dumps(tags, indent=2, ensure_ascii=False))
        return

    print(f"{'NAME':<24} {'COLOR':<10} {'NOTES':<8} ID")
    print("-" * 75)
    for t in sorted(tags, key=lambda x: x.get("name", "")):
        notes_count = t.get("_count", {}).get("notes", 0)
        color = t.get("color") or "none"
        print(f"{t['name']:<24} {color:<10} {notes_count:<8} {t['id']}")


def cmd_list(tag: Optional[str] = None, limit: int = 20, as_json: bool = False):
    tag_id = None
    if tag:
        resolved = resolve_tag_ids([tag])
        if resolved:
            tag_id = resolved[0]

    notes = api_request("GET", "/api/notes", params={"tagId": tag_id, "limit": limit})
    if as_json:
        print(json.dumps(notes, indent=2, ensure_ascii=False))
        return

    tags_map = {t["id"]: t["name"] for t in api_request("GET", "/api/tags")}

    print(f"Total Notes: {len(notes)}")
    print(f"{'TITLE':<38} {'TAGS':<20} {'PIN':<5} ID")
    print("-" * 85)
    for n in notes:
        title = (n.get("title") or "Untitled")[:36]
        tag_names = ", ".join([tags_map.get(tid, tid) for tid in n.get("tagIds", [])])[:18]
        pin = "★" if n.get("isPinned") else " "
        print(f"{title:<38} {tag_names:<20} {pin:<5} {n['id']}")


def cmd_search(query: str, as_json: bool = False):
    notes = api_request("GET", "/api/notes", params={"search": query})
    if as_json:
        print(json.dumps(notes, indent=2, ensure_ascii=False))
        return

    print(f"Found {len(notes)} note(s) matching '{query}':\n")
    for n in notes:
        title = n.get("title") or "Untitled"
        nid = n.get("id")
        created = (n.get("createdAt") or "")[:10]
        md_content = delta_to_markdown(n.get("content"))
        snippet = "\n".join([line for line in md_content.splitlines() if line.strip()][:3])

        print(f"## {title} (ID: {nid}) [{created}]")
        if snippet:
            print(f"   {snippet}")
        print()


def cmd_get(identifier: str, as_json: bool = False):
    note = find_note_by_id_or_title(identifier)
    if as_json:
        print(json.dumps(note, indent=2, ensure_ascii=False))
        return

    tags_map = {t["id"]: t["name"] for t in api_request("GET", "/api/tags")}
    tag_names = [tags_map.get(tid, tid) for tid in note.get("tagIds", [])]

    print(f"# {note.get('title') or 'Untitled'}")
    print(f"**ID:** {note['id']}")
    print(f"**Created:** {note.get('createdAt')}")
    print(f"**Updated:** {note.get('updatedAt')}")
    if tag_names:
        print(f"**Tags:** {', '.join(tag_names)}")
    if note.get("isPinned"):
        print("**Pinned:** Yes")
    if note.get("isArchived"):
        print("**Archived:** Yes")
    print("-" * 60)
    print(delta_to_markdown(note.get("content")))


def cmd_create(
    title: str,
    content: str = "",
    tags: Optional[List[str]] = None,
    pinned: bool = False,
    archived: bool = False,
    bg: Optional[str] = None,
    as_json: bool = False,
):
    tag_ids = resolve_tag_ids(tags) if tags else []
    delta_content = markdown_to_delta(content) if content else None

    payload: Dict[str, Any] = {
        "title": title,
    }
    if delta_content:
        payload["content"] = delta_content
    if tag_ids:
        payload["tagIds"] = tag_ids
    if pinned:
        payload["isPinned"] = True
    if archived:
        payload["isArchived"] = True
    if bg:
        payload["background"] = bg

    created = api_request("POST", "/api/notes", data=payload)
    if as_json:
        print(json.dumps(created, indent=2, ensure_ascii=False))
        return

    print(f"✓ Created note '{created.get('title')}' (ID: {created.get('id')})")


def cmd_append(identifier: str, text_to_append: str):
    note = find_note_by_id_or_title(identifier)
    note_id = note["id"]

    existing_md = delta_to_markdown(note.get("content"))
    new_md = f"{existing_md}\n\n{text_to_append}".strip()
    new_delta = markdown_to_delta(new_md)

    updated = api_request("PATCH", f"/api/notes/{note_id}", data={"content": new_delta})
    print(f"✓ Appended content to note '{updated.get('title')}' ({note_id})")


def cmd_update(
    identifier: str,
    title: Optional[str] = None,
    content: Optional[str] = None,
    tags: Optional[List[str]] = None,
    pinned: Optional[bool] = None,
    archived: Optional[bool] = None,
    bg: Optional[str] = None,
):
    note = find_note_by_id_or_title(identifier)
    note_id = note["id"]

    payload: Dict[str, Any] = {}
    if title is not None:
        payload["title"] = title
    if content is not None:
        payload["content"] = markdown_to_delta(content)
    if tags is not None:
        payload["tagIds"] = resolve_tag_ids(tags)
    if pinned is not None:
        payload["isPinned"] = pinned
    if archived is not None:
        payload["isArchived"] = archived
    if bg is not None:
        payload["background"] = bg

    if not payload:
        print("Warning: No changes specified for update.", file=sys.stderr)
        return

    updated = api_request("PATCH", f"/api/notes/{note_id}", data=payload)
    print(f"✓ Updated note '{updated.get('title')}' ({note_id})")


def cmd_delete(identifier: str, permanent: bool = False):
    note = find_note_by_id_or_title(identifier)
    note_id = note["id"]

    if permanent:
        api_request("DELETE", f"/api/notes/{note_id}/permanent")
        print(f"✓ Permanently deleted note '{note.get('title')}' ({note_id})")
    else:
        api_request("DELETE", f"/api/notes/{note_id}")
        print(f"✓ Moved note '{note.get('title')}' to trash ({note_id})")


def cmd_restore(identifier: str):
    note = find_note_by_id_or_title(identifier)
    note_id = note["id"]
    restored = api_request("PATCH", f"/api/notes/{note_id}/restore")
    print(f"✓ Restored note '{restored.get('title')}' from trash ({note_id})")


# ---------------------------------------------------------------------------
# Argument Dispatcher
# ---------------------------------------------------------------------------

def main():
    import argparse

    common_parser = argparse.ArgumentParser(add_help=False)
    common_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    parser = argparse.ArgumentParser(description="Anchor Notes CLI", parents=[common_parser])
    subparsers = parser.add_subparsers(dest="command", required=True)

    # tags
    subparsers.add_parser("tags", help="List all tags", parents=[common_parser])

    # list
    list_p = subparsers.add_parser("list", help="List notes", parents=[common_parser])
    list_p.add_argument("--tag", help="Filter by tag name or ID")
    list_p.add_argument("--limit", type=int, default=20, help="Maximum notes to return")

    # search
    search_p = subparsers.add_parser("search", help="Search notes by query", parents=[common_parser])
    search_p.add_argument("query", help="Text to search in titles and contents")

    # get
    get_p = subparsers.add_parser("get", help="Get a single note as Markdown", parents=[common_parser])
    get_p.add_argument("id_or_title", help="Note UUID or title")

    # create
    create_p = subparsers.add_parser("create", help="Create a new note", parents=[common_parser])
    create_p.add_argument("--title", required=True, help="Note title")
    create_p.add_argument("--content", default="", help="Note content (Markdown/plain text)")
    create_p.add_argument("--tag", action="append", help="Tag name or ID (can be repeated)")
    create_p.add_argument("--pin", action="store_true", help="Pin this note")
    create_p.add_argument("--archive", action="store_true", help="Archive this note")
    create_p.add_argument("--bg", help="Background color name (e.g. color_yellow, color_red)")

    # append
    append_p = subparsers.add_parser("append", help="Append content to an existing note", parents=[common_parser])
    append_p.add_argument("id_or_title", help="Note UUID or title")
    append_p.add_argument("--content", required=True, help="Text/Markdown to append")

    # update
    update_p = subparsers.add_parser("update", help="Update fields on an existing note", parents=[common_parser])
    update_p.add_argument("id_or_title", help="Note UUID or title")
    update_p.add_argument("--title", help="New title")
    update_p.add_argument("--content", help="New content")
    update_p.add_argument("--tag", action="append", help="Replace tags (can be repeated)")
    update_p.add_argument("--pin", type=lambda x: (str(x).lower() == "true"), help="Set pin (true/false)")
    update_p.add_argument("--archive", type=lambda x: (str(x).lower() == "true"), help="Set archive (true/false)")
    update_p.add_argument("--bg", help="Background color")

    # delete
    delete_p = subparsers.add_parser("delete", help="Delete a note", parents=[common_parser])
    delete_p.add_argument("id_or_title", help="Note UUID or title")
    delete_p.add_argument("--permanent", action="store_true", help="Permanently purge from database")

    # restore
    restore_p = subparsers.add_parser("restore", help="Restore a trashed note", parents=[common_parser])
    restore_p.add_argument("id_or_title", help="Note UUID or title")

    args = parser.parse_args()

    if args.command == "tags":
        cmd_tags(as_json=args.json)
    elif args.command == "list":
        cmd_list(tag=args.tag, limit=args.limit, as_json=args.json)
    elif args.command == "search":
        cmd_search(query=args.query, as_json=args.json)
    elif args.command == "get":
        cmd_get(identifier=args.id_or_title, as_json=args.json)
    elif args.command == "create":
        cmd_create(
            title=args.title,
            content=args.content,
            tags=args.tag,
            pinned=args.pin,
            archived=args.archive,
            bg=args.bg,
            as_json=args.json,
        )
    elif args.command == "append":
        cmd_append(identifier=args.id_or_title, text_to_append=args.content)
    elif args.command == "update":
        cmd_update(
            identifier=args.id_or_title,
            title=args.title,
            content=args.content,
            tags=args.tag,
            pinned=args.pin,
            archived=args.archive,
            bg=args.bg,
        )
    elif args.command == "delete":
        cmd_delete(identifier=args.id_or_title, permanent=args.permanent)
    elif args.command == "restore":
        cmd_restore(identifier=args.id_or_title)


if __name__ == "__main__":
    main()
