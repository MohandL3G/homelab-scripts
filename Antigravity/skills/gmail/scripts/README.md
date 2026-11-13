# Gmail Automation Scripts for Mohand's Homelab

This directory provides tools for interacting with Mohand's Gmail account via secure **IMAP4_SSL** (`imap.gmail.com:993`) and **SMTP STARTTLS** (`smtp.gmail.com:587`).

---

## Files

- **`gmail.py`**: Standalone Python module and command-line interface. Contains `GmailClient` and full CLI for interactive terminal usage or shell scripts.
- **`server.py`**: Model Context Protocol (FastMCP) stdio server registered with Antigravity to expose structured tools.
- **`requirements.txt`**: Minimal Python dependencies (`mcp`, `python-dotenv`, `beautifulsoup4`).

---

## Configuration & Credentials

Credentials are read automatically from `/root/.env` (mode `0600`):

```bash
GMAIL_ADDRESS="mohandl3g@gmail.com"
GMAIL_APP_PASSWORD="xxxx xxxx xxxx xxxx"
```

Never commit credentials to version control.

---

## CLI Usage

### 1. List Mailboxes
```bash
./gmail.py folders
# Output as JSON:
./gmail.py folders --json
```

### 2. Search Emails
```bash
# Search latest 5 messages in INBOX
./gmail.py search --limit 5

# Search unread messages
./gmail.py search --query "UNSEEN" --limit 10

# Search from a specific sender
./gmail.py search --query "FROM alerts@proxmox.com" --limit 5

# Search keyword across messages
./gmail.py search --query "backup" --limit 5
```

### 3. Read Full Message by UID
```bash
./gmail.py read 17837
# Output complete parsed message as JSON:
./gmail.py read 17837 --json
```

### 4. Create a Draft in `[Gmail]/Drafts`
```bash
./gmail.py draft --to "friend@example.com" --subject "Dinner plans" --body "Let's meet tomorrow at 7."
```

### 5. Send an Email (Guarded)
```bash
# Without --confirmed, sending is blocked:
./gmail.py send --to "alert@example.com" --subject "Status" --body "All systems normal"
# => ⚠ Safety check: 'confirmed' is False. Emails are NOT sent without explicit user confirmation.

# With --confirmed flag:
./gmail.py send --to "alert@example.com" --subject "Status" --body "All systems normal" --confirmed
```

### 6. Run Self-Test
```bash
./gmail.py test
```
