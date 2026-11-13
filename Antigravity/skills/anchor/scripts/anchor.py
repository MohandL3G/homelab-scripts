#!/usr/bin/env python3
"""
Anchor CLI Helper for Antigravity Agent
Interact with self-hosted Anchor Notes instance (https://anchor.mohandl3g.ly)

Supports multi-user switching:
- Default: Antigravity-Home agent account (ANCHOR_API_KEY)
- Optional: MohandL3G personal account (ANCHOR_MOHAND_API_KEY via --user mohand / --as-user mohand)

Includes full note lifecycle management and memory helper subcommands.
"""

import sys
import os
import json
import re
import datetime
import urllib.request
import urllib.error
import urllib.parse
import argparse
from typing import Any, Dict, List, Optional, Tuple

ENV_FILE = "/root/.env"
DEFAULT_BASE_URL = "https://anchor.mohandl3g.ly"

TAG_COLOR_PALETTE = [
    "#4DB6AC",  # Teal
    "#64B5F6",  # Blue
    "#AED581",  # Light Green
    "#FFD54F",  # Amber
    "#BA68C8",  # Purple
    "#FF8A65",  # Deep Orange
    "#4FC3F7",  # Light Blue
    "#F06292",  # Pink
]

VALID_BG_COLORS = {
    "yellow": "color_yellow",
    "orange": "color_orange",
    "brown": "color_brown",
    "red": "color_red",
    "pink": "color_pink",
    "purple": "color_purple",
    "dark_blue": "color_dark_blue",
    "indigo": "color_dark_blue",
    "blue": "color_blue",
    "teal": "color_teal",
    "green": "color_green",
}

# Runtime context holding active user configuration
CURRENT_CONTEXT: Dict[str, Any] = {
    "base_url": DEFAULT_BASE_URL,
    "api_key": "",
    "user_label": "agent",
    "account_name": "Antigravity-Home",
}


def load_raw_env() -> Dict[str, str]:
    """Reads /root/.env and merges with os.environ (os.environ takes precedence)."""
    env_vars: Dict[str, str] = {}
    if os.path.exists(ENV_FILE):
        try:
            with open(ENV_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, v = line.split("=", 1)
                    env_vars[k.strip()] = v.strip().strip("'\"")
        except Exception:
            pass

    for k, v in os.environ.items():
        env_vars[k] = v

    return env_vars


def init_context(user_flag: Optional[str] = None):
    """Initializes CURRENT_CONTEXT with resolved URL, API token, and active user."""
    env = load_raw_env()
    base_url = env.get("ANCHOR_BASE_URL", DEFAULT_BASE_URL).rstrip("/")

    target = (user_flag or env.get("ANCHOR_USER") or "agent").strip().lower()

    if target in ("mohand", "mohandl3g", "user", "personal"):
        api_key = env.get("ANCHOR_MOHAND_API_KEY") or env.get("ANCHOR_USER_API_KEY")
        if not api_key:
            print("Error: ANCHOR_MOHAND_API_KEY not found in /root/.env or environment", file=sys.stderr)
            sys.exit(1)
        CURRENT_CONTEXT["base_url"] = base_url
        CURRENT_CONTEXT["api_key"] = api_key
        CURRENT_CONTEXT["user_label"] = "mohand"
        CURRENT_CONTEXT["account_name"] = "MohandL3G"

    elif target in ("agent", "home", "antigravity", "bot", "default"):
        api_key = env.get("ANCHOR_API_KEY") or env.get("ANCHOR_AGENT_API_KEY")
        if not api_key:
            print("Error: ANCHOR_API_KEY not found in /root/.env or environment", file=sys.stderr)
            sys.exit(1)
        CURRENT_CONTEXT["base_url"] = base_url
        CURRENT_CONTEXT["api_key"] = api_key
        CURRENT_CONTEXT["user_label"] = "agent"
        CURRENT_CONTEXT["account_name"] = "Antigravity-Home"

    else:
        print(
            f"Error: Unknown user '{user_flag}'. Supported options: 'agent'/'home' (default) or 'mohand'/'user'",
            file=sys.stderr,
        )
        sys.exit(1)


def api_request(
    method: str,
    path: str,
    params: Optional[Dict[str, Any]] = None,
    data: Optional[Dict[str, Any]] = None,
) -> Any:
    base_url = CURRENT_CONTEXT.get("base_url", DEFAULT_BASE_URL)
    api_key = CURRENT_CONTEXT.get("api_key", "")

    if not api_key:
        print("Error: Anchor API key is empty.", file=sys.stderr)
        sys.exit(1)

    url = f"{base_url}{path}"
    if params:
        encoded = urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
        if encoded:
            url = f"{url}?{encoded}"

    body = None
    headers = {
        "Authorization": f"Bearer {api_key}",
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
        print(f"API Error ({e.code} {e.reason}) on {method} {path}: {msg}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Connection Error on {url}: {e.reason}", file=sys.stderr)
        sys.exit(1)


def normalize_bg_color(color: Optional[str]) -> Optional[str]:
    if not color:
        return None
    c = color.strip().lower()
    if c.startswith("color_") or c.startswith("pattern_"):
        return c
    return VALID_BG_COLORS.get(c, c)


def prepare_content(content: Optional[str] = None, file_path: Optional[str] = None) -> str:
    """Resolves content from direct string, file, or stdin. Unescapes literal \\n if needed."""
    text = ""
    if file_path:
        if not os.path.exists(file_path):
            print(f"Error: File '{file_path}' does not exist.", file=sys.stderr)
            sys.exit(1)
        with open(file_path, "r", encoding="utf-8") as f:
            text = f.read()
    elif content:
        if content == "-":
            text = sys.stdin.read()
        else:
            text = content
            # If literal \n was passed on CLI without real newlines, convert them
            if "\n" not in text and "\\n" in text:
                text = text.replace("\\n", "\n")

    return text


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
    """Returns mapping of tag name (lowercase) -> tag ID for the active user."""
    tags = api_request("GET", "/api/tags")
    return {t["name"].lower(): t["id"] for t in tags}


def resolve_tag_ids(tag_names_or_ids: List[str], create_missing: bool = True) -> List[str]:
    """Converts a list of tag names or IDs into valid tag IDs.

    If create_missing is True, any nonexistent tag is created automatically via POST /api/tags.
    """
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
        elif create_missing:
            # Auto-create the missing tag on Anchor
            palette_color = TAG_COLOR_PALETTE[len(tags_map) % len(TAG_COLOR_PALETTE)]
            try:
                new_tag = api_request("POST", "/api/tags", data={"name": item_clean, "color": palette_color})
                tag_id = new_tag.get("id")
                if tag_id:
                    tags_map[item_clean.lower()] = tag_id
                    tag_id_set.add(tag_id)
                    resolved.append(tag_id)
                    print(f"Created new tag '{item_clean}' ({tag_id}) under {CURRENT_CONTEXT['account_name']}", file=sys.stderr)
                else:
                    print(f"Warning: Could not create tag '{item_clean}'", file=sys.stderr)
            except Exception as e:
                print(f"Warning: Error creating tag '{item_clean}': {e}", file=sys.stderr)
        else:
            print(f"Warning: Tag '{item_clean}' not found on server; skipping.", file=sys.stderr)

    return resolved


def find_note_by_id_or_title(identifier: str) -> Dict[str, Any]:
    """Finds a note either by exact UUID or by title query."""
    is_uuid = bool(re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", identifier, re.I))
    if is_uuid:
        return api_request("GET", f"/api/notes/{identifier}")

    notes = api_request("GET", "/api/notes", params={"search": identifier})
    if not notes:
        print(f"Error: No note found matching '{identifier}' under {CURRENT_CONTEXT['account_name']}", file=sys.stderr)
        sys.exit(1)

    exact_matches = [n for n in notes if n.get("title", "").strip().lower() == identifier.strip().lower()]
    if exact_matches:
        return exact_matches[0]

    return notes[0]


# ---------------------------------------------------------------------------
# General CLI Commands
# ---------------------------------------------------------------------------

def cmd_tags(as_json: bool = False, create_name: Optional[str] = None, color: Optional[str] = None):
    if create_name:
        cmd_tag_create(create_name, color=color, as_json=as_json)
        return

    tags = api_request("GET", "/api/tags")
    if as_json:
        print(json.dumps(tags, indent=2, ensure_ascii=False))
        return

    print(f"User: {CURRENT_CONTEXT['account_name']} ({CURRENT_CONTEXT['user_label']})")
    print(f"{'NAME':<24} {'COLOR':<10} {'NOTES':<8} ID")
    print("-" * 75)
    for t in sorted(tags, key=lambda x: x.get("name", "")):
        notes_count = t.get("_count", {}).get("notes", 0)
        c = t.get("color") or "none"
        print(f"{t['name']:<24} {c:<10} {notes_count:<8} {t['id']}")


def cmd_tag_create(name: str, color: Optional[str] = None, as_json: bool = False):
    payload: Dict[str, Any] = {"name": name}
    if color:
        payload["color"] = color
    else:
        tags_map = get_tags_map()
        payload["color"] = TAG_COLOR_PALETTE[len(tags_map) % len(TAG_COLOR_PALETTE)]

    created = api_request("POST", "/api/tags", data=payload)
    if as_json:
        print(json.dumps(created, indent=2, ensure_ascii=False))
        return

    print(f"✓ Created tag '{created.get('name')}' (ID: {created.get('id')})")


def cmd_tag_delete(id_or_name: str):
    tags_map = get_tags_map()
    tag_id = id_or_name
    if id_or_name.lower() in tags_map:
        tag_id = tags_map[id_or_name.lower()]

    api_request("DELETE", f"/api/tags/{tag_id}")
    print(f"✓ Deleted tag '{id_or_name}' ({tag_id})")


def cmd_list(tag: Optional[str] = None, limit: int = 20, as_json: bool = False):
    tag_id = None
    if tag:
        resolved = resolve_tag_ids([tag], create_missing=False)
        if resolved:
            tag_id = resolved[0]
        else:
            print(f"Warning: Tag '{tag}' not found. Listing all notes instead.", file=sys.stderr)

    notes = api_request("GET", "/api/notes", params={"tagId": tag_id, "limit": limit})
    if as_json:
        print(json.dumps(notes, indent=2, ensure_ascii=False))
        return

    tags_map = {t["id"]: t["name"] for t in api_request("GET", "/api/tags")}

    print(f"User: {CURRENT_CONTEXT['account_name']} ({CURRENT_CONTEXT['user_label']}) | Total Notes: {len(notes)}")
    print(f"{'TITLE':<38} {'TAGS':<20} {'PIN':<5} ID")
    print("-" * 85)
    for n in notes:
        title = (n.get("title") or "Untitled")[:36]
        tag_names = ", ".join([tags_map.get(tid, tid) for tid in n.get("tagIds", [])])[:18]
        pin = "★" if n.get("isPinned") else " "
        print(f"{title:<38} {tag_names:<20} {pin:<5} {n['id']}")


def cmd_search(query: str, as_json: bool = False, tag: Optional[str] = None):
    tag_id = None
    if tag:
        resolved = resolve_tag_ids([tag], create_missing=False)
        if resolved:
            tag_id = resolved[0]

    notes = api_request("GET", "/api/notes", params={"search": query, "tagId": tag_id})
    if as_json:
        print(json.dumps(notes, indent=2, ensure_ascii=False))
        return

    print(f"User: {CURRENT_CONTEXT['account_name']} | Found {len(notes)} note(s) matching '{query}':\n")
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
    print(f"**User:** {CURRENT_CONTEXT['account_name']}")
    print(f"**Created:** {note.get('createdAt')}")
    print(f"**Updated:** {note.get('updatedAt')}")
    if tag_names:
        print(f"**Tags:** {', '.join(tag_names)}")
    if note.get("background"):
        print(f"**Background:** {note.get('background')}")
    if note.get("isPinned"):
        print("**Pinned:** Yes")
    if note.get("isArchived"):
        print("**Archived:** Yes")
    print("-" * 60)
    print(delta_to_markdown(note.get("content")))


def cmd_create(
    title: str,
    content: str = "",
    file_path: Optional[str] = None,
    tags: Optional[List[str]] = None,
    pinned: bool = False,
    archived: bool = False,
    bg: Optional[str] = None,
    as_json: bool = False,
):
    resolved_text = prepare_content(content=content, file_path=file_path)
    tag_ids = resolve_tag_ids(tags, create_missing=True) if tags else []
    delta_content = markdown_to_delta(resolved_text) if resolved_text else None
    bg_normalized = normalize_bg_color(bg)

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
    if bg_normalized:
        payload["background"] = bg_normalized

    created = api_request("POST", "/api/notes", data=payload)
    if as_json:
        print(json.dumps(created, indent=2, ensure_ascii=False))
        return

    print(f"✓ Created note '{created.get('title')}' (ID: {created.get('id')}) under {CURRENT_CONTEXT['account_name']}")


def cmd_append(
    identifier: str,
    text_to_append: str = "",
    file_path: Optional[str] = None,
    as_json: bool = False,
):
    note = find_note_by_id_or_title(identifier)
    note_id = note["id"]

    resolved_append = prepare_content(content=text_to_append, file_path=file_path)
    existing_md = delta_to_markdown(note.get("content"))
    if existing_md.strip():
        new_md = f"{existing_md.strip()}\n\n{resolved_append.strip()}"
    else:
        new_md = resolved_append.strip()

    new_delta = markdown_to_delta(new_md)
    updated = api_request("PATCH", f"/api/notes/{note_id}", data={"content": new_delta})

    if as_json:
        print(json.dumps(updated, indent=2, ensure_ascii=False))
        return

    print(f"✓ Appended content to note '{updated.get('title')}' ({note_id})")


def cmd_update(
    identifier: str,
    title: Optional[str] = None,
    content: Optional[str] = None,
    file_path: Optional[str] = None,
    tags: Optional[List[str]] = None,
    pinned: Optional[bool] = None,
    archived: Optional[bool] = None,
    bg: Optional[str] = None,
    as_json: bool = False,
):
    note = find_note_by_id_or_title(identifier)
    note_id = note["id"]

    payload: Dict[str, Any] = {}
    if title is not None:
        payload["title"] = title
    if content is not None or file_path is not None:
        resolved_text = prepare_content(content=content, file_path=file_path)
        payload["content"] = markdown_to_delta(resolved_text)
    if tags is not None:
        payload["tagIds"] = resolve_tag_ids(tags, create_missing=True)
    if pinned is not None:
        payload["isPinned"] = pinned
    if archived is not None:
        payload["isArchived"] = archived
    if bg is not None:
        payload["background"] = normalize_bg_color(bg)

    if not payload:
        print("Warning: No changes specified for update.", file=sys.stderr)
        return

    updated = api_request("PATCH", f"/api/notes/{note_id}", data=payload)
    if as_json:
        print(json.dumps(updated, indent=2, ensure_ascii=False))
        return

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
# Memory Helper Subcommands (`anchor.py memory ...`)
# ---------------------------------------------------------------------------

def cmd_memory_list(tag: Optional[str] = None, limit: int = 20, all_notes: bool = False, as_json: bool = False):
    """Lists memory notes. By default filters by 'Memory' tag unless all_notes=True."""
    target_tag = tag
    if not target_tag and not all_notes:
        target_tag = "Memory"

    tag_id = None
    if target_tag:
        tags_map = get_tags_map()
        if target_tag.lower() in tags_map:
            tag_id = tags_map[target_tag.lower()]
        elif not all_notes:
            # No Memory tag yet
            if as_json:
                print(json.dumps([], indent=2))
                return
            print(f"User: {CURRENT_CONTEXT['account_name']} ({CURRENT_CONTEXT['user_label']})")
            print(f"No notes with tag '{target_tag}' found. (Use 'memory save' to record a new memory).")
            return

    notes = api_request("GET", "/api/notes", params={"tagId": tag_id, "limit": limit})
    if as_json:
        print(json.dumps(notes, indent=2, ensure_ascii=False))
        return

    tags_map = {t["id"]: t["name"] for t in api_request("GET", "/api/tags")}

    header_tag = f" [Tag: {target_tag}]" if target_tag else ""
    print(f"Anchor Memory Store ({CURRENT_CONTEXT['account_name']}){header_tag} | Total: {len(notes)}")
    print(f"{'TITLE':<40} {'TAGS':<22} {'PIN':<5} ID")
    print("-" * 90)
    for n in notes:
        title = (n.get("title") or "Untitled")[:38]
        tag_names = ", ".join([tags_map.get(tid, tid) for tid in n.get("tagIds", [])])[:20]
        pin = "★" if n.get("isPinned") else " "
        print(f"{title:<40} {tag_names:<22} {pin:<5} {n['id']}")


def cmd_memory_search(query: str, tag: Optional[str] = None, limit: int = 20, as_json: bool = False):
    """Searches memory notes matching query."""
    tag_id = None
    if tag:
        resolved = resolve_tag_ids([tag], create_missing=False)
        if resolved:
            tag_id = resolved[0]

    notes = api_request("GET", "/api/notes", params={"search": query, "tagId": tag_id, "limit": limit})
    if as_json:
        print(json.dumps(notes, indent=2, ensure_ascii=False))
        return

    tags_map = {t["id"]: t["name"] for t in api_request("GET", "/api/tags")}

    print(f"Anchor Memory Search ({CURRENT_CONTEXT['account_name']}) | '{query}' ({len(notes)} matches):\n")
    for n in notes:
        title = n.get("title") or "Untitled"
        nid = n.get("id")
        created = (n.get("createdAt") or "")[:10]
        tag_names = ", ".join([tags_map.get(tid, tid) for tid in n.get("tagIds", [])])
        md_content = delta_to_markdown(n.get("content"))
        snippet_lines = [l for l in md_content.splitlines() if l.strip()]
        snippet = "\n".join(snippet_lines[:3]) if snippet_lines else "(empty)"

        print(f"## {title} [ID: {nid}]")
        print(f"   Date: {created} | Tags: {tag_names}")
        print(f"   {snippet}")
        print()


def cmd_memory_get(identifier: str, as_json: bool = False):
    """Retrieves a memory note by title or UUID."""
    cmd_get(identifier=identifier, as_json=as_json)


def cmd_memory_save(
    title: str,
    content: str = "",
    file_path: Optional[str] = None,
    category: Optional[str] = None,
    tags: Optional[List[str]] = None,
    pinned: bool = False,
    bg: Optional[str] = None,
    as_json: bool = False,
):
    """Saves a new memory note.

    Automatically attaches the 'Memory' tag, any specified --category, and --tag.
    Auto-creates missing tags if necessary.
    """
    combined_tags = ["Memory"]
    if category:
        combined_tags.append(category)
    if tags:
        for t in tags:
            if t not in combined_tags:
                combined_tags.append(t)

    cmd_create(
        title=title,
        content=content,
        file_path=file_path,
        tags=combined_tags,
        pinned=pinned,
        archived=False,
        bg=bg,
        as_json=as_json,
    )


def cmd_memory_append(
    identifier: str,
    text: str = "",
    file_path: Optional[str] = None,
    timestamp: bool = False,
    as_json: bool = False,
):
    """Appends content to an existing memory note, optionally timestamped."""
    resolved_text = prepare_content(content=text, file_path=file_path)
    if timestamp:
        now_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        formatted = f"### [{now_utc}]\n{resolved_text.strip()}"
    else:
        formatted = resolved_text.strip()

    cmd_append(identifier=identifier, text_to_append=formatted, as_json=as_json)


def cmd_memory_delete(identifier: str, permanent: bool = False):
    """Deletes/trashes a memory note."""
    cmd_delete(identifier=identifier, permanent=permanent)


def cmd_memory_stats(as_json: bool = False):
    """Displays summary statistics of the Anchor memory store for active user."""
    notes = api_request("GET", "/api/notes")
    tags = api_request("GET", "/api/tags")

    tags_map = {t["id"]: t["name"] for t in tags}
    pinned_count = sum(1 for n in notes if n.get("isPinned"))
    memory_tag_id = next((t["id"] for t in tags if t["name"].lower() == "memory"), None)
    memory_notes_count = sum(1 for n in notes if memory_tag_id and memory_tag_id in n.get("tagIds", []))

    stats_data = {
        "user": CURRENT_CONTEXT["account_name"],
        "user_alias": CURRENT_CONTEXT["user_label"],
        "base_url": CURRENT_CONTEXT["base_url"],
        "total_notes": len(notes),
        "pinned_notes": pinned_count,
        "memory_tagged_notes": memory_notes_count,
        "total_tags": len(tags),
        "tags": [t["name"] for t in tags],
    }

    if as_json:
        print(json.dumps(stats_data, indent=2, ensure_ascii=False))
        return

    print("=" * 60)
    print(f"Anchor Memory Store Statistics")
    print("=" * 60)
    print(f"Account:              {CURRENT_CONTEXT['account_name']} ({CURRENT_CONTEXT['user_label']})")
    print(f"Base URL:             {CURRENT_CONTEXT['base_url']}")
    print(f"Total Notes:          {len(notes)}")
    print(f"Pinned Notes:         {pinned_count}")
    print(f"Memory-Tagged Notes:  {memory_notes_count}")
    print(f"Total Tags:           {len(tags)}")
    if tags:
        print(f"Available Tags:       {', '.join(sorted([t['name'] for t in tags]))}")
    print("=" * 60)


# ---------------------------------------------------------------------------
# Argument Dispatcher
# ---------------------------------------------------------------------------

def main():
    # 1. Early extraction of user flag (supports flag placed before or after command)
    pre_parser = argparse.ArgumentParser(add_help=False)
    pre_parser.add_argument("--user", "--as-user", dest="user", default=None)
    pre_args, _ = pre_parser.parse_known_args()

    # Initialize runtime user context
    init_context(pre_args.user)

    # 2. Build full parser
    common_parser = argparse.ArgumentParser(add_help=False)
    common_parser.add_argument("--json", action="store_true", help="Output raw JSON")
    common_parser.add_argument(
        "--user",
        "--as-user",
        dest="user",
        default=pre_args.user,
        help="Target user account: 'agent'/'home' (default) or 'mohand'/'user'",
    )

    parser = argparse.ArgumentParser(
        description="Anchor Notes CLI Helper (with Antigravity-Home and MohandL3G support)",
        parents=[common_parser],
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # ------------------ tags ------------------
    tags_p = subparsers.add_parser("tags", help="List or create tags", parents=[common_parser])
    tags_p.add_argument("--create", dest="create_name", help="Name of tag to create")
    tags_p.add_argument("--color", help="Hex color for tag (e.g. #4DB6AC)")

    tag_p = subparsers.add_parser("tag", help="Tag management operations", parents=[common_parser])
    tag_sub = tag_p.add_subparsers(dest="tag_action", required=True)

    tag_list_p = tag_sub.add_parser("list", help="List tags", parents=[common_parser])
    tag_create_p = tag_sub.add_parser("create", help="Create a new tag", parents=[common_parser])
    tag_create_p.add_argument("name", help="Tag name")
    tag_create_p.add_argument("--color", help="Hex color code (e.g. #4DB6AC)")
    tag_del_p = tag_sub.add_parser("delete", help="Delete a tag", parents=[common_parser])
    tag_del_p.add_argument("id_or_name", help="Tag ID or exact tag name")

    # ------------------ list ------------------
    list_p = subparsers.add_parser("list", help="List notes", parents=[common_parser])
    list_p.add_argument("--tag", help="Filter by tag name or ID")
    list_p.add_argument("--limit", type=int, default=20, help="Maximum notes to return")

    # ------------------ search ------------------
    search_p = subparsers.add_parser("search", help="Search notes by query", parents=[common_parser])
    search_p.add_argument("query", help="Text to search in titles and contents")
    search_p.add_argument("--tag", help="Filter search within a specific tag")

    # ------------------ get ------------------
    get_p = subparsers.add_parser("get", help="Get a single note as Markdown", parents=[common_parser])
    get_p.add_argument("id_or_title", help="Note UUID or title")

    # ------------------ create ------------------
    create_p = subparsers.add_parser("create", help="Create a new note", parents=[common_parser])
    create_p.add_argument("--title", required=True, help="Note title")
    create_p.add_argument("--content", default="", help="Note content (Markdown/plain text)")
    create_p.add_argument("--file", help="Path to markdown file to read content from")
    create_p.add_argument("--tag", action="append", help="Tag name or ID (can be repeated)")
    create_p.add_argument("--pin", action="store_true", help="Pin this note")
    create_p.add_argument("--archive", action="store_true", help="Archive this note")
    create_p.add_argument("--bg", help="Background color (e.g. color_yellow, color_teal, teal, blue)")

    # ------------------ append ------------------
    append_p = subparsers.add_parser("append", help="Append content to an existing note", parents=[common_parser])
    append_p.add_argument("id_or_title", help="Note UUID or title")
    append_p.add_argument("--content", default="", help="Text/Markdown to append")
    append_p.add_argument("--file", help="Path to file to read appended content from")

    # ------------------ update ------------------
    update_p = subparsers.add_parser("update", help="Update fields on an existing note", parents=[common_parser])
    update_p.add_argument("id_or_title", help="Note UUID or title")
    update_p.add_argument("--title", help="New title")
    update_p.add_argument("--content", help="New content")
    update_p.add_argument("--file", help="Path to file to read content from")
    update_p.add_argument("--tag", action="append", help="Replace tags (can be repeated)")
    update_p.add_argument("--pin", type=lambda x: (str(x).lower() == "true"), help="Set pin (true/false)")
    update_p.add_argument("--archive", type=lambda x: (str(x).lower() == "true"), help="Set archive (true/false)")
    update_p.add_argument("--bg", help="Background color")

    # ------------------ delete ------------------
    delete_p = subparsers.add_parser("delete", help="Delete a note", parents=[common_parser])
    delete_p.add_argument("id_or_title", help="Note UUID or title")
    delete_p.add_argument("--permanent", action="store_true", help="Permanently purge from database")

    # ------------------ restore ------------------
    restore_p = subparsers.add_parser("restore", help="Restore a trashed note", parents=[common_parser])
    restore_p.add_argument("id_or_title", help="Note UUID or title")

    # ------------------ memory ------------------
    mem_p = subparsers.add_parser("memory", help="Memory store helper commands", parents=[common_parser])
    mem_sub = mem_p.add_subparsers(dest="memory_command", required=True)

    # memory list
    mem_list_p = mem_sub.add_parser("list", help="List memory notes", parents=[common_parser])
    mem_list_p.add_argument("--tag", help="Filter by specific tag")
    mem_list_p.add_argument("--limit", type=int, default=20, help="Maximum notes to return")
    mem_list_p.add_argument("--all", action="store_true", help="List all notes, not just Memory-tagged")

    # memory search
    mem_search_p = mem_sub.add_parser("search", help="Search memory notes", parents=[common_parser])
    mem_search_p.add_argument("query", help="Text to search across memories")
    mem_search_p.add_argument("--tag", help="Filter by specific tag")
    mem_search_p.add_argument("--limit", type=int, default=20, help="Maximum results to return")

    # memory get
    mem_get_p = mem_sub.add_parser("get", help="Get a memory note by title or ID", parents=[common_parser])
    mem_get_p.add_argument("id_or_title", help="Memory note UUID or title")

    # memory save / add / create
    mem_save_p = mem_sub.add_parser("save", aliases=["add", "create"], help="Save a new memory note", parents=[common_parser])
    mem_save_p.add_argument("--title", required=True, help="Memory note title")
    mem_save_p.add_argument("--content", default="", help="Memory content (Markdown)")
    mem_save_p.add_argument("--file", help="Path to markdown file to read content from")
    mem_save_p.add_argument("--category", help="Category name (e.g. Homelab, Workstation, Preferences)")
    mem_save_p.add_argument("--tag", action="append", help="Extra tag names (can be repeated)")
    mem_save_p.add_argument("--pin", action="store_true", help="Pin this memory note")
    mem_save_p.add_argument("--bg", help="Background color name")

    # memory append
    mem_append_p = mem_sub.add_parser("append", help="Append content to a memory note", parents=[common_parser])
    mem_append_p.add_argument("id_or_title", help="Memory note UUID or title")
    mem_append_p.add_argument("--content", default="", help="Text to append")
    mem_append_p.add_argument("--file", help="Path to file to read content from")
    mem_append_p.add_argument("--timestamp", action="store_true", help="Prefix appended content with UTC timestamp")

    # memory delete
    mem_del_p = mem_sub.add_parser("delete", help="Delete a memory note", parents=[common_parser])
    mem_del_p.add_argument("id_or_title", help="Memory note UUID or title")
    mem_del_p.add_argument("--permanent", action="store_true", help="Permanently purge from database")

    # memory stats / info
    mem_sub.add_parser("stats", aliases=["info"], help="Show memory store statistics", parents=[common_parser])

    args = parser.parse_args()

    # Re-evaluate user context if passed after subcommand
    if args.user and args.user != CURRENT_CONTEXT["user_label"]:
        init_context(args.user)

    # Dispatch
    if args.command == "tags":
        cmd_tags(as_json=args.json, create_name=args.create_name, color=args.color)
    elif args.command == "tag":
        if args.tag_action == "list":
            cmd_tags(as_json=args.json)
        elif args.tag_action == "create":
            cmd_tag_create(name=args.name, color=args.color, as_json=args.json)
        elif args.tag_action == "delete":
            cmd_tag_delete(id_or_name=args.id_or_name)
    elif args.command == "list":
        cmd_list(tag=args.tag, limit=args.limit, as_json=args.json)
    elif args.command == "search":
        cmd_search(query=args.query, as_json=args.json, tag=args.tag)
    elif args.command == "get":
        cmd_get(identifier=args.id_or_title, as_json=args.json)
    elif args.command == "create":
        cmd_create(
            title=args.title,
            content=args.content,
            file_path=args.file,
            tags=args.tag,
            pinned=args.pin,
            archived=args.archive,
            bg=args.bg,
            as_json=args.json,
        )
    elif args.command == "append":
        cmd_append(
            identifier=args.id_or_title,
            text_to_append=args.content,
            file_path=args.file,
            as_json=args.json,
        )
    elif args.command == "update":
        cmd_update(
            identifier=args.id_or_title,
            title=args.title,
            content=args.content,
            file_path=args.file,
            tags=args.tag,
            pinned=args.pin,
            archived=args.archive,
            bg=args.bg,
            as_json=args.json,
        )
    elif args.command == "delete":
        cmd_delete(identifier=args.id_or_title, permanent=args.permanent)
    elif args.command == "restore":
        cmd_restore(identifier=args.id_or_title)
    elif args.command == "memory":
        if args.memory_command == "list":
            cmd_memory_list(tag=args.tag, limit=args.limit, all_notes=args.all, as_json=args.json)
        elif args.memory_command == "search":
            cmd_memory_search(query=args.query, tag=args.tag, limit=args.limit, as_json=args.json)
        elif args.memory_command == "get":
            cmd_memory_get(identifier=args.id_or_title, as_json=args.json)
        elif args.memory_command in ("save", "add", "create"):
            cmd_memory_save(
                title=args.title,
                content=args.content,
                file_path=args.file,
                category=args.category,
                tags=args.tag,
                pinned=args.pin,
                bg=args.bg,
                as_json=args.json,
            )
        elif args.memory_command == "append":
            cmd_memory_append(
                identifier=args.id_or_title,
                text=args.content,
                file_path=args.file,
                timestamp=args.timestamp,
                as_json=args.json,
            )
        elif args.memory_command == "delete":
            cmd_memory_delete(identifier=args.id_or_title, permanent=args.permanent)
        elif args.memory_command in ("stats", "info"):
            cmd_memory_stats(as_json=args.json)


if __name__ == "__main__":
    main()
