---
name: anchor
description: Manage, search, read, create, tag, and organize notes and persistent memory in Mohand's self-hosted Anchor instance (https://anchor.mohandl3g.ly). Use whenever looking up homelab procedures, checklists, architecture specs, personal notes, or when storing, appending, and recalling memories and notes in Anchor.
---

# Anchor Notes & Memory Skill

Interact programmatically with Mohand's self-hosted **Anchor** note-taking application ([https://anchor.mohandl3g.ly](https://anchor.mohandl3g.ly)).

Anchor runs in Docker on CT 100 (`master`) and stores rich-text notes with tags, colors, pinned states, and checklists.

## Credentials & Multi-User Accounts

The CLI helper reads credentials automatically from `/root/.env`:
- `ANCHOR_BASE_URL`: Base URL (default `https://anchor.mohandl3g.ly`)
- `ANCHOR_API_KEY`: Default API key for the **Antigravity-Home** agent account.
- `ANCHOR_AGENT_API_KEY`: Alias / fallback for the agent account.
- `ANCHOR_MOHAND_API_KEY`: Preserved API key for Mohand's personal account (**MohandL3G**).

### Account Switching (`--user` / `--as-user`)
Every command supports selecting the target account via `--user` or `--as-user`:
- `--user agent` (or `--user home`, default): Operates on the dedicated **Antigravity-Home** agent account.
- `--user mohand` (or `--user personal`): Operates on Mohand's personal account (**MohandL3G**).

The flag can be placed before or after subcommands, for example:
```bash
# Agent account (default)
/root/home/.agents/skills/anchor/scripts/anchor.py memory stats

# Mohand's account
/root/home/.agents/skills/anchor/scripts/anchor.py --user mohand list
/root/home/.agents/skills/anchor/scripts/anchor.py list --as-user mohand
```

**Rule:** Never print, echo, or commit the API key in reports, logs, or chat.

---

## CLI Helper (`anchor.py`)

Executable path:
`/root/home/.agents/skills/anchor/scripts/anchor.py`

---

## 1. Memory Helper Subcommands (`anchor.py memory ...`)

Use the `memory` command family for agent memory and knowledge base storage. Notes saved via `memory` automatically receive the `Memory` tag.

### Save a Memory Note
Record a new memory or knowledge base document:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py memory save \
  --title "[Homelab] PVE Infrastructure & Container Map" \
  --file /path/to/document.md \
  --category "Homelab" \
  --pin \
  --bg "teal"
```
Or provide inline content:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py memory save \
  --title "Project Notes" \
  --content "## Scope\n- [ ] Deploy Docker containers\n- [x] Configure DNS" \
  --category "Projects"
```
- `--category <name>`: Automatically added as a tag (e.g. `Homelab`, `Workstation`, `Preferences`, `Network`).
- `--tag <name>`: Can be repeated for extra tags. Nonexistent tags are created automatically with distinct color styling.
- `--file <path>`: Read markdown content directly from file.
- `--pin`: Pins the memory note to the top of the collection.
- `--bg <color>`: Background color (`teal`, `blue`, `yellow`, `green`, `purple`, `red`, etc.).

### Search Memories
Search across memory notes by keyword or query:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py memory search "Proxmox"
/root/home/.agents/skills/anchor/scripts/anchor.py memory search "Docker" --tag "Homelab"
```

### Read a Memory Note
Retrieve and render a memory note in clean Markdown format:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py memory get "[Homelab] PVE Infrastructure & Container Map"
/root/home/.agents/skills/anchor/scripts/anchor.py memory get "<note_uuid>"
```

### List Memory Notes
List all notes tagged with `Memory`:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py memory list [--tag "<tag_name>"] [--limit 20]
# List all notes regardless of tag:
/root/home/.agents/skills/anchor/scripts/anchor.py memory list --all
```

### Append to a Memory Note
Append updates or facts to an existing memory note:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py memory append "<note_id_or_title>" \
  --content "New milestone reached." \
  --timestamp
```
- `--timestamp`: Automatically prefixes the appended content with UTC timestamp header `### [YYYY-MM-DD HH:MM:SS UTC]`.
- `--file <path>`: Append contents of a file.

### Delete a Memory Note
```bash
# Move to trash:
/root/home/.agents/skills/anchor/scripts/anchor.py memory delete "<note_id_or_title>"

# Purge permanently:
/root/home/.agents/skills/anchor/scripts/anchor.py memory delete "<note_id_or_title>" --permanent
```

### Memory Store Statistics
Inspect memory store health, total notes, pinned count, and tag list:
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py memory stats
```

---

## 2. General Note Operations

### List Notes
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py list [--tag "<tag_name>"] [--limit 20]
```

### Search Notes
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py search "search text" [--tag "<tag_name>"]
```

### Read Note
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py get "<id_or_title>"
```

### Create Note
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py create \
  --title "Title" \
  --content "Content in Markdown" \
  --tag "Tag1" \
  --tag "Tag2" \
  --bg "blue" \
  --pin
```
*Note:* Missing tags specified in `--tag` are automatically resolved and created on Anchor.

### Append to Note
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py append "<id_or_title>" --content "Appended text"
```

### Update Note
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py update "<id_or_title>" \
  --title "Updated Title" \
  --content "Replacement content" \
  --tag "NewTag" \
  --pin true
```

### Delete / Restore Note
```bash
/root/home/.agents/skills/anchor/scripts/anchor.py delete "<id_or_title>" [--permanent]
/root/home/.agents/skills/anchor/scripts/anchor.py restore "<id_or_title>"
```

### Tags Management
Inspect, create, or delete tags:
```bash
# List all tags:
/root/home/.agents/skills/anchor/scripts/anchor.py tags

# Create a tag:
/root/home/.agents/skills/anchor/scripts/anchor.py tag create "Homelab" --color "#4DB6AC"

# Delete a tag:
/root/home/.agents/skills/anchor/scripts/anchor.py tag delete "Homelab"
```

---

## Content Format & Quill Delta Conversion

- Anchor natively stores content as **Quill Delta JSON** (`{"ops": [...]}`).
- `anchor.py` automatically converts standard Markdown into Quill Delta on `create`, `update`, `save`, and `append`.
- It converts Quill Delta back to clean Markdown on `get`, `search`, and `list`.
- Supported Markdown features:
  - Headers (`# `, `## `, `### `)
  - Checklists (`- [ ] `, `- [x] `)
  - Bulleted lists (`- `, `* `)
  - Numbered lists (`1. `)
  - Code blocks (` ``` `)
  - Inline formatting (`**bold**`, `*italic*`, `~~strikethrough~~`, `` `code` ``, `[link](url)`)
