#!/usr/bin/env python3
"""
Gmail Automation Client & CLI for Antigravity & Homelab.

Provides secure IMAP4_SSL and SMTP access to Gmail for:
- Listing mailboxes/folders
- Searching messages with IMAP tokens, flags, or free-form keywords
- Fetching and parsing RFC822 messages (headers, decoded text/HTML body, attachment metadata)
- Creating drafts directly in [Gmail]/Drafts with \\Draft flag
- Sending messages via SMTP with strict confirmation protection
"""

import argparse
import email
from email.header import decode_header
from email.message import EmailMessage
import email.utils
import imaplib
import json
import os
import re
import smtplib
import sys
import time
from typing import Any, Dict, List, Optional
from bs4 import BeautifulSoup
from dotenv import load_dotenv


def _decode_mime_str(header_val: Optional[str]) -> str:
    """Safely decode MIME-encoded header strings to Unicode."""
    if not header_val:
        return ""
    try:
        decoded_fragments = decode_header(header_val)
        parts = []
        for content, charset in decoded_fragments:
            if isinstance(content, bytes):
                parts.append(content.decode(charset or "utf-8", errors="replace"))
            else:
                parts.append(str(content))
        return "".join(parts)
    except Exception:
        return str(header_val)


class GmailClient:
    """Client for interacting with Gmail over IMAP and SMTP."""

    IMAP_HOST = "imap.gmail.com"
    IMAP_PORT = 993
    SMTP_HOST = "smtp.gmail.com"
    SMTP_PORT = 587
    DRAFTS_FOLDER = "[Gmail]/Drafts"

    def __init__(
        self,
        email_address: Optional[str] = None,
        app_password: Optional[str] = None,
        env_path: str = "/root/.env",
    ):
        if not email_address or not app_password:
            if os.path.exists(env_path):
                load_dotenv(env_path)
            else:
                load_dotenv()
            email_address = email_address or os.getenv("GMAIL_ADDRESS")
            app_password = app_password or os.getenv("GMAIL_APP_PASSWORD")

        if not email_address or not app_password:
            raise ValueError(
                "Missing Gmail credentials. Set GMAIL_ADDRESS and GMAIL_APP_PASSWORD in /root/.env"
            )

        self.email_address = email_address.strip()
        self._app_password = app_password.strip()

    def _get_imap(self) -> imaplib.IMAP4_SSL:
        """Create and authenticate a new IMAP4_SSL session."""
        try:
            imap = imaplib.IMAP4_SSL(self.IMAP_HOST, self.IMAP_PORT)
            imap.login(self.email_address, self._app_password)
            return imap
        except Exception as e:
            msg = str(e).replace(self._app_password, "[REDACTED]")
            raise RuntimeError(f"Failed to connect to Gmail IMAP: {msg}") from None

    def _get_smtp(self) -> smtplib.SMTP:
        """Create and authenticate a new SMTP session with STARTTLS."""
        try:
            smtp = smtplib.SMTP(self.SMTP_HOST, self.SMTP_PORT, timeout=30)
            smtp.starttls()
            smtp.login(self.email_address, self._app_password)
            return smtp
        except Exception as e:
            msg = str(e).replace(self._app_password, "[REDACTED]")
            raise RuntimeError(f"Failed to connect to Gmail SMTP: {msg}") from None

    @staticmethod
    def _quote_folder(folder: str) -> str:
        """Ensure folder name is properly quoted for IMAP commands."""
        f = folder.strip()
        if not (f.startswith('"') and f.endswith('"')):
            return f'"{f}"'
        return f

    def list_folders(self) -> List[Dict[str, Any]]:
        """List all available IMAP mailboxes."""
        imap = self._get_imap()
        try:
            status, folder_list = imap.list()
            if status != "OK" or not folder_list:
                return []

            result = []
            pattern = re.compile(r'\((?P<flags>[^)]*)\)\s+"(?P<delim>[^"]+)"\s+(?P<name>.+)')

            for item in folder_list:
                if not item:
                    continue
                line = item.decode("utf-8", errors="replace") if isinstance(item, bytes) else str(item)
                match = pattern.search(line)
                if match:
                    flags = match.group("flags").strip()
                    delim = match.group("delim").strip()
                    raw_name = match.group("name").strip()
                    if raw_name.startswith('"') and raw_name.endswith('"'):
                        name = raw_name[1:-1]
                    else:
                        name = raw_name
                    result.append({"name": name, "flags": flags, "delimiter": delim})
                else:
                    parts = line.split(maxsplit=2)
                    name = parts[-1].strip(' "') if len(parts) >= 3 else line
                    result.append({"name": name, "flags": "", "delimiter": "/"})

            return result
        finally:
            try:
                imap.logout()
            except Exception:
                pass

    def search(
        self,
        query: str = "ALL",
        folder: str = "INBOX",
        limit: int = 10,
    ) -> List[Dict[str, Any]]:
        """Search emails matching query criteria in specified folder."""
        imap = self._get_imap()
        try:
            quoted_folder = self._quote_folder(folder)
            status, _ = imap.select(quoted_folder, readonly=True)
            if status != "OK":
                raise ValueError(f"Failed to select folder: {folder}")

            q = (query or "ALL").strip()
            upper_q = q.upper()

            # Handle IMAP search criteria directly
            if upper_q in ("ALL", "UNSEEN", "SEEN", "FLAGGED", "ANSWERED", "DELETED"):
                criteria = upper_q
            elif any(
                upper_q.startswith(prefix)
                for prefix in ("FROM ", "TO ", "SUBJECT ", "BODY ", "TEXT ", "SINCE ", "BEFORE ", "OR ")
            ):
                criteria = q
            else:
                # Format as TEXT search
                cleaned = q.replace('"', '\\"')
                criteria = f'TEXT "{cleaned}"'

            status, msg_nums = imap.search(None, criteria)
            if status != "OK" or not msg_nums or not msg_nums[0]:
                return []

            uids = msg_nums[0].split()
            # Sort newest first and limit
            uids = uids[::-1][:limit]

            results = []
            for num in uids:
                status, data = imap.fetch(num, "(UID BODY.PEEK[HEADER.FIELDS (SUBJECT FROM TO DATE)] FLAGS)")
                if status != "OK" or not data:
                    continue

                headers_raw = b""
                flags_raw = b""
                uid_str = num.decode("utf-8", errors="replace")

                for part in data:
                    if isinstance(part, tuple) and len(part) >= 2:
                        headers_raw = part[1]
                        meta = part[0].decode("utf-8", errors="replace")
                        uid_match = re.search(r"UID\s+(\d+)", meta)
                        if uid_match:
                            uid_str = uid_match.group(1)
                    elif isinstance(part, bytes):
                        flags_raw = part

                parsed_msg = email.message_from_bytes(headers_raw)
                flags_str = flags_raw.decode("utf-8", errors="replace")
                is_unread = "\\Seen" not in flags_str

                results.append(
                    {
                        "uid": uid_str,
                        "subject": _decode_mime_str(parsed_msg.get("Subject", "(no subject)")),
                        "from": _decode_mime_str(parsed_msg.get("From", "")),
                        "to": _decode_mime_str(parsed_msg.get("To", "")),
                        "date": parsed_msg.get("Date", ""),
                        "unread": is_unread,
                        "folder": folder,
                    }
                )

            return results
        finally:
            try:
                imap.close()
            except Exception:
                pass
            try:
                imap.logout()
            except Exception:
                pass

    def get_message(self, uid: str, folder: str = "INBOX") -> Dict[str, Any]:
        """Fetch and decode complete RFC822 email message by UID."""
        imap = self._get_imap()
        try:
            quoted_folder = self._quote_folder(folder)
            status, _ = imap.select(quoted_folder, readonly=True)
            if status != "OK":
                raise ValueError(f"Failed to select folder: {folder}")

            status, data = imap.uid("fetch", uid, "(RFC822 FLAGS)")
            if status != "OK" or not data or not data[0]:
                raise ValueError(f"Message UID {uid} not found in {folder}")

            raw_email = None
            flags_str = ""
            for item in data:
                if isinstance(item, tuple) and len(item) >= 2:
                    raw_email = item[1]
                    meta = item[0].decode("utf-8", errors="replace")
                    flags_str = meta
                elif isinstance(item, bytes):
                    flags_str += " " + item.decode("utf-8", errors="replace")

            if not raw_email:
                raise ValueError(f"Failed to extract RFC822 payload for UID {uid}")

            msg = email.message_from_bytes(raw_email)

            subject = _decode_mime_str(msg.get("Subject", "(no subject)"))
            from_addr = _decode_mime_str(msg.get("From", ""))
            to_addr = _decode_mime_str(msg.get("To", ""))
            cc_addr = _decode_mime_str(msg.get("Cc", ""))
            date_str = msg.get("Date", "")
            message_id = msg.get("Message-ID", "")

            plain_texts = []
            html_texts = []
            attachments = []

            if msg.is_multipart():
                for part in msg.walk():
                    content_disposition = part.get("Content-Disposition", "")
                    content_type = part.get_content_type()
                    filename = part.get_filename()

                    if filename:
                        filename = _decode_mime_str(filename)
                        payload = part.get_payload(decode=True)
                        size = len(payload) if payload else 0
                        attachments.append(
                            {"filename": filename, "content_type": content_type, "size_bytes": size}
                        )
                        continue

                    if "attachment" in content_disposition.lower():
                        continue

                    payload = part.get_payload(decode=True)
                    if not payload:
                        continue

                    charset = part.get_content_charset() or "utf-8"
                    try:
                        text_content = payload.decode(charset, errors="replace")
                    except Exception:
                        text_content = payload.decode("latin1", errors="replace")

                    if content_type == "text/plain":
                        plain_texts.append(text_content)
                    elif content_type == "text/html":
                        html_texts.append(text_content)
            else:
                content_type = msg.get_content_type()
                payload = msg.get_payload(decode=True)
                if payload:
                    charset = msg.get_content_charset() or "utf-8"
                    try:
                        text_content = payload.decode(charset, errors="replace")
                    except Exception:
                        text_content = payload.decode("latin1", errors="replace")

                    if content_type == "text/plain":
                        plain_texts.append(text_content)
                    elif content_type == "text/html":
                        html_texts.append(text_content)

            if plain_texts:
                body = "\n\n".join(plain_texts).strip()
            elif html_texts:
                soup = BeautifulSoup("\n".join(html_texts), "html.parser")
                body = soup.get_text(separator="\n").strip()
            else:
                body = "(No readable text content)"

            return {
                "uid": str(uid),
                "folder": folder,
                "message_id": message_id,
                "subject": subject,
                "from": from_addr,
                "to": to_addr,
                "cc": cc_addr,
                "date": date_str,
                "body": body,
                "attachments": attachments,
                "unread": "\\Seen" not in flags_str,
            }
        finally:
            try:
                imap.close()
            except Exception:
                pass
            try:
                imap.logout()
            except Exception:
                pass

    def create_draft(
        self,
        to: str,
        subject: str,
        body: str,
        cc: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Construct RFC822 email and append to [Gmail]/Drafts with \\Draft flag."""
        msg = EmailMessage()
        msg["From"] = self.email_address
        msg["To"] = to
        if cc:
            msg["Cc"] = cc
        msg["Subject"] = subject
        msg["Date"] = email.utils.formatdate(localtime=True)
        msg.set_content(body)

        imap = self._get_imap()
        try:
            target_folder = self._quote_folder(self.DRAFTS_FOLDER)
            flags = "(\\Draft)"
            msg_bytes = msg.as_bytes()

            status, _ = imap.append(target_folder, flags, imaplib.Time2Internaldate(time.time()), msg_bytes)
            if status != "OK":
                # Fallback to local 'Drafts' folder if localized
                status, _ = imap.append('"Drafts"', flags, imaplib.Time2Internaldate(time.time()), msg_bytes)
                if status != "OK":
                    raise RuntimeError(f"IMAP APPEND failed to create draft in {self.DRAFTS_FOLDER}")

            return {
                "status": "success",
                "action": "draft_created",
                "folder": self.DRAFTS_FOLDER,
                "to": to,
                "cc": cc or "",
                "subject": subject,
                "message": f"Draft successfully stored in {self.DRAFTS_FOLDER}",
            }
        finally:
            try:
                imap.logout()
            except Exception:
                pass

    def send_message(
        self,
        to: str,
        subject: str,
        body: str,
        cc: Optional[str] = None,
        confirmed: bool = False,
    ) -> Dict[str, Any]:
        """Send email via SMTP with mandatory confirmed=True safety check."""
        if not confirmed:
            return {
                "status": "confirmation_required",
                "action": "none",
                "to": to,
                "cc": cc or "",
                "subject": subject,
                "message": (
                    "Safety check: 'confirmed' is False. Emails are NOT sent without "
                    "explicit user confirmation. Verify recipient and content, then call with "
                    "confirmed=True or use create_draft instead."
                ),
            }

        msg = EmailMessage()
        msg["From"] = self.email_address
        msg["To"] = to
        if cc:
            msg["Cc"] = cc
        msg["Subject"] = subject
        msg["Date"] = email.utils.formatdate(localtime=True)
        msg.set_content(body)

        recipients = [addr.strip() for addr in to.split(",") if addr.strip()]
        if cc:
            recipients.extend([addr.strip() for addr in cc.split(",") if addr.strip()])

        smtp = self._get_smtp()
        try:
            smtp.send_message(msg, from_addr=self.email_address, to_addrs=recipients)
            return {
                "status": "success",
                "action": "sent",
                "confirmed": True,
                "to": to,
                "cc": cc or "",
                "subject": subject,
                "recipients_count": len(recipients),
                "message": f"Email successfully sent to {to}",
            }
        finally:
            try:
                smtp.quit()
            except Exception:
                pass


def main() -> None:
    """CLI Entry point for Gmail automation."""
    parser = argparse.ArgumentParser(
        description="Gmail Automation CLI for Mohand's Homelab (IMAP/SMTP)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="subcommand", help="Available subcommands")

    # folders
    folders_parser = subparsers.add_parser("folders", help="List all mailbox folders")
    folders_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # search
    search_parser = subparsers.add_parser("search", help="Search emails")
    search_parser.add_argument("-q", "--query", default="ALL", help="Search criteria or keyword (default: 'ALL')")
    search_parser.add_argument("-f", "--folder", default="INBOX", help="Mailbox folder (default: 'INBOX')")
    search_parser.add_argument("-l", "--limit", type=int, default=10, help="Max results to fetch (default: 10)")
    search_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # read
    read_parser = subparsers.add_parser("read", help="Read full email by UID")
    read_parser.add_argument("uid", help="Message UID to read")
    read_parser.add_argument("-f", "--folder", default="INBOX", help="Mailbox folder (default: 'INBOX')")
    read_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # draft
    draft_parser = subparsers.add_parser("draft", help="Create a draft in [Gmail]/Drafts")
    draft_parser.add_argument("--to", required=True, help="Recipient email address")
    draft_parser.add_argument("--subject", required=True, help="Email subject line")
    draft_parser.add_argument("--body", required=True, help="Email body text")
    draft_parser.add_argument("--cc", default=None, help="Carbon copy recipient(s)")
    draft_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # send
    send_parser = subparsers.add_parser("send", help="Send email immediately (requires confirmation)")
    send_parser.add_argument("--to", required=True, help="Recipient email address")
    send_parser.add_argument("--subject", required=True, help="Email subject line")
    send_parser.add_argument("--body", required=True, help="Email body text")
    send_parser.add_argument("--cc", default=None, help="Carbon copy recipient(s)")
    send_parser.add_argument("--confirmed", action="store_true", help="Confirm email transmission")
    send_parser.add_argument("--json", action="store_true", help="Output raw JSON")

    # test
    subparsers.add_parser("test", help="Run end-to-end self-test against Gmail")

    args = parser.parse_args()
    if not args.subcommand:
        parser.print_help()
        sys.exit(1)

    try:
        client = GmailClient()
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    if args.subcommand == "folders":
        folders = client.list_folders()
        if args.json:
            print(json.dumps(folders, indent=2, ensure_ascii=False))
        else:
            print(f"Mailboxes for {client.email_address}:")
            for f in folders:
                print(f"  - {f['name']} ({f['flags'] or 'no flags'})")

    elif args.subcommand == "search":
        results = client.search(query=args.query, folder=args.folder, limit=args.limit)
        if args.json:
            print(json.dumps(results, indent=2, ensure_ascii=False))
        else:
            print(f"Search results for '{args.query}' in '{args.folder}' ({len(results)} matches):")
            for r in results:
                unread_tag = "[UNREAD] " if r.get("unread") else ""
                print(f"  UID {r['uid']}: {unread_tag}{r['subject']} | From: {r['from']} | Date: {r['date']}")

    elif args.subcommand == "read":
        msg = client.get_message(uid=args.uid, folder=args.folder)
        if args.json:
            print(json.dumps(msg, indent=2, ensure_ascii=False))
        else:
            print(f"Subject: {msg['subject']}")
            print(f"From:    {msg['from']}")
            print(f"To:      {msg['to']}")
            if msg["cc"]:
                print(f"Cc:      {msg['cc']}")
            print(f"Date:    {msg['date']}")
            if msg["attachments"]:
                print(f"Attachments: {len(msg['attachments'])} file(s)")
                for att in msg["attachments"]:
                    print(f"  - {att['filename']} ({att['content_type']}, {att['size_bytes']} bytes)")
            print("\n" + "=" * 60 + "\n")
            print(msg["body"])

    elif args.subcommand == "draft":
        res = client.create_draft(to=args.to, subject=args.subject, body=args.body, cc=args.cc)
        if args.json:
            print(json.dumps(res, indent=2, ensure_ascii=False))
        else:
            print(f"✓ {res['message']}")

    elif args.subcommand == "send":
        res = client.send_message(
            to=args.to,
            subject=args.subject,
            body=args.body,
            cc=args.cc,
            confirmed=args.confirmed,
        )
        if args.json:
            print(json.dumps(res, indent=2, ensure_ascii=False))
        else:
            if res.get("status") == "success":
                print(f"✓ {res['message']}")
            else:
                print(f"⚠ {res['message']}", file=sys.stderr)
                sys.exit(2)

    elif args.subcommand == "test":
        print(f"Running self-test for {client.email_address}...")
        folders = client.list_folders()
        print(f"✓ IMAP folders found: {len(folders)}")
        search_res = client.search(query="ALL", limit=1)
        print(f"✓ Latest message query: {len(search_res)} message(s) returned")
        safety_check = client.send_message("test@example.com", "Safety", "Check", confirmed=False)
        print(f"✓ Safety gate check: {safety_check['status']}")
        print("\nAll client self-checks passed!")


if __name__ == "__main__":
    main()
