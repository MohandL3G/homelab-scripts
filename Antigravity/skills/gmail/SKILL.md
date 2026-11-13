---
name: gmail
description: Manage, search, read, draft, and send emails using Gmail via IMAP and SMTP MCP tools. Use whenever the user asks to check their inbox, search emails, read messages or threads, draft replies or compose new emails, or send communications via their personal Gmail account.
---

# Gmail Management Skill

Interact programmatically with Mohand's Gmail account using the local **Gmail MCP Server** and standalone Python CLI running in CT 103 (`antigravity`).

The integration connects directly to Gmail via standard encrypted protocols:
- **IMAP**: `imap.gmail.com:993` (SSL/TLS) for listing folders, searching, reading messages, and creating drafts.
- **SMTP**: `smtp.gmail.com:587` (STARTTLS) for outgoing emails.

---

## 1. Credentials & Configuration

Credentials are encrypted and stored in the central secrets environment file:
- **Path**: `/root/.env` (permissions strictly `0600`)
- **Variables**:
  - `GMAIL_ADDRESS`: Email address (`mohandl3g@gmail.com`)
  - `GMAIL_APP_PASSWORD`: Google App Password (16 characters)

> [!CAUTION]
> **Credential Protection**:
> Never print, echo, or write the values of `GMAIL_ADDRESS` or `GMAIL_APP_PASSWORD` to logs, console output, chat responses, or files. Keep `/root/.env` set to mode `0600`.

---

## 2. Standalone CLI Usage

The script at `scripts/gmail.py` provides a direct terminal interface:

```bash
# List folders
python3 /root/home/homelab-scripts/Antigravity/skills/gmail/scripts/gmail.py folders

# Search emails (latest 5)
python3 /root/home/homelab-scripts/Antigravity/skills/gmail/scripts/gmail.py search --limit 5

# Search unread emails
python3 /root/home/homelab-scripts/Antigravity/skills/gmail/scripts/gmail.py search --query "UNSEEN"

# Read message by UID
python3 /root/home/homelab-scripts/Antigravity/skills/gmail/scripts/gmail.py read <UID>

# Create draft in [Gmail]/Drafts
python3 /root/home/homelab-scripts/Antigravity/skills/gmail/scripts/gmail.py draft --to "user@example.com" --subject "Hello" --body "Draft text"

# Send email (requires explicit --confirmed flag)
python3 /root/home/homelab-scripts/Antigravity/skills/gmail/scripts/gmail.py send --to "user@example.com" --subject "Hello" --body "Message text" --confirmed
```

---

## 3. MCP Tools Reference

The Gmail FastMCP server (`scripts/server.py`) exposes five primary tools:

### `gmail_list_folders()`
List all available IMAP mailboxes in the account.
- **Arguments**: None.
- **Returns**: JSON array of folder objects with `name`, `flags`, and `delimiter`.
- **Key Mailboxes**:
  - `"INBOX"`: Primary incoming mail.
  - `"[Gmail]/Drafts"`: Stored drafts.
  - `"[Gmail]/Sent Mail"`: Outgoing sent messages.
  - `"[Gmail]/Starred"`: Flagged / starred items.
  - `"[Gmail]/Spam"`: Junk email.
  - `"[Gmail]/Trash"`: Deleted messages.

### `gmail_search(query='ALL', folder='INBOX', limit=10)`
Search for messages matching criteria.
- **Arguments**:
  - `query` (str): Search filter. Defaults to `'ALL'`.
    - Standard keywords: `'ALL'`, `'UNSEEN'`, `'SEEN'`, `'FLAGGED'`.
    - Criteria queries: `'FROM user@example.com'`, `'SUBJECT invoice'`, `'SINCE 01-Jan-2026'`.
    - Gmail search syntax: supports terms like `'has:attachment'`, `'is:unread'`, `'label:important'`, or free-form keywords.
  - `folder` (str): Target folder (default: `'INBOX'`).
  - `limit` (int): Number of most recent messages to retrieve (default: `10`).
- **Returns**: JSON array of message summaries containing `uid`, `subject`, `from`, `to`, `date`, `flags`, and `unread` boolean.

### `gmail_read(uid, folder='INBOX')`
Fetch and decode the full content of an email.
- **Arguments**:
  - `uid` (str): The unique identifier (UID) obtained from `gmail_search`.
  - `folder` (str): Mailbox containing the message (default: `'INBOX'`).
- **Returns**: JSON object with:
  - `uid`, `folder`, `subject`, `from`, `to`, `cc`, `date`
  - `body`: Decoded message body. If plain text is available, it is returned; if only HTML is present, it is automatically converted into clean readable text using BeautifulSoup.
  - `attachments`: List of attachment objects (`filename`, `content_type`, `size_bytes`).
  - `unread`: Boolean indicating if `\Seen` flag is absent.

### `gmail_create_draft(to, subject, body, cc=None)`
Create a new draft in `[Gmail]/Drafts`.
- **Arguments**:
  - `to` (str): Recipient email address or comma-separated addresses.
  - `subject` (str): Subject line.
  - `body` (str): Email body text.
  - `cc` (str, optional): Carbon copy address(es).
- **Returns**: JSON confirmation with status and draft metadata.
- **Usage**: Recommended workflow when composing emails. Allows the user to inspect and polish the draft before sending.

### `gmail_send(to, subject, body, cc=None, confirmed=False)`
Send an email immediately via SMTP.
- **Arguments**:
  - `to` (str): Recipient email address(es).
  - `subject` (str): Subject line.
  - `body` (str): Email body text.
  - `cc` (str, optional): Carbon copy address(es).
  - `confirmed` (bool): Explicit user confirmation flag (**must be `True`**).
- **Safety Guard**:
  If `confirmed` is `False` (the default), `gmail_send` **will not send** the email. Instead, it returns a `confirmation_required` response instructing the caller to verify details with the user.

---

## 4. Recommended Operational Workflows

### Triage Unread Messages
1. Search for unread emails:
   ```json
   gmail_search(query="UNSEEN", folder="INBOX", limit=5)
   ```
2. Read specific messages using the returned `uid`:
   ```json
   gmail_read(uid="17837", folder="INBOX")
   ```

### Search with Keywords
- Find emails from GitHub:
   ```json
   gmail_search(query="FROM notifications@github.com", folder="INBOX", limit=5)
   ```
- Find emails with attachments:
   ```json
   gmail_search(query="has:attachment", folder="INBOX", limit=5)
   ```

### Drafting and Sending Emails Safely
> [!IMPORTANT]
> **Safety First Protocol**:
> Always prefer creating a draft over sending directly. If the user asks to "send an email", first draft it and show the user what will be sent:
> 1. Call `gmail_create_draft(...)`.
> 2. Present the drafted message, recipient, and subject to the user.
> 3. Only call `gmail_send(..., confirmed=True)` after the user has explicitly reviewed and approved sending.
