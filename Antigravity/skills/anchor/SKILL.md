---
name: anchor
description: Manage, search, read, create, tag, and organize notes in Mohand's self-hosted Anchor instance (https://anchor.mohandl3g.ly). Use whenever looking up existing notes, homelab procedures, checklists, personal notes, or when asked to save, append, or organize notes in Anchor.
---

# Anchor Notes Skill

Interact programmatically with Mohand's self-hosted **Anchor** note-taking application ([https://anchor.mohandl3g.ly](https://anchor.mohandl3g.ly)).

Anchor runs in Docker on CT 100 (`master`) and stores rich-text notes with tags, colors, pinned states, and checklists.

## Credentials & Configuration

The CLI helper reads credentials automatically from `/root/.env`:
- `ANCHOR_BASE_URL`: Base URL (default `https://anchor.mohandl3g.ly`)
- `ANCHOR_API_KEY`: User API Bearer token

**Rule:** Never print, echo, or commit the API key in reports, logs, or chat.

---

## CLI Helper (`anchor.py`)

Executable location:
`/root/home/.agents/skills/anchor/scripts/anchor.py`

### 1. Search Notes
Search across note titles and content:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py search "query"
```
Use `--json` to output raw JSON objects.

### 2. Read Note (as Markdown)
Fetch and format a note by its UUID or exact title:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py get "<note_id_or_title>"
```
*Note:* The helper automatically converts Quill Delta ops to readable Markdown (headers, checklists, code blocks, bold/italics).

### 3. List Notes
List recent notes (optionally filtered by tag name or ID):
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py list [--tag "<tag_name>"] [--limit 20]
```

### 4. Create a Note
Create a note with Markdown formatting and tags:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py create \
  --title "My Note Title" \
  --content "# Header\n- [ ] Task 1\n- [x] Task 2\n\nNotes go here." \
  --tag "Tech" \
  --tag "Linux Journey" \
  --pin
```
*Optional flags:*
- `--tag "<name>"`: Can be repeated for multiple tags (resolved automatically by name).
- `--pin`: Pins the note to the top.
- `--archive`: Archives the note immediately.
- `--bg "<color>"`: Note background color (`color_yellow`, `color_red`, `color_purple`, etc.).

### 5. Append to an Existing Note
Append text or checklist items to an existing note:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py append "<id_or_title>" --content "- [ ] New todo item"
```

### 6. Update a Note
Update specific fields of an existing note:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py update "<id_or_title>" \
  --title "New Title" \
  --content "Replaced content" \
  --pin true
```

### 7. Delete / Restore a Note
Move note to trash:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py delete "<id_or_title>"
```
Permanently purge from database:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py delete "<id_or_title>" --permanent
```
Restore from trash:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py restore "<id_or_title>"
```

### 8. List Available Tags
Inspect all tags with colors and note counts:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py tags
```

---

## Content Format Guidelines

- Anchor natively stores content as **Quill Delta JSON** (`{"ops": [...]}`).
- `anchor.py` automatically translates standard Markdown into Quill Delta on `create`/`update`/`append` and translates Quill Delta into clean Markdown on `get`/`search`.
- Supported Markdown conversions:
  - Headers (`# `, `## `, `### `)
  - Checklists (`- [ ] `, `- [x] `)
  - Bulleted lists (`- `, `* `)
  - Numbered lists (`1. `)
  - Code blocks (` ``` `)
  - Inline formatting (`**bold**`, `*italic*`, `` `code` ``)
