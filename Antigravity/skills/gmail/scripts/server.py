#!/usr/bin/env python3
"""
Gmail FastMCP Server for Antigravity & Homelab.

Provides Model Context Protocol (MCP) tools for Gmail integration:
- gmail_list_folders: List available IMAP mailboxes
- gmail_search: Search emails with IMAP tokens, UNSEEN, or free-form keywords
- gmail_read: Fetch and decode full message contents by UID
- gmail_create_draft: Create a draft message in [Gmail]/Drafts
- gmail_send: Send an email via SMTP (protected by confirmed=True check)
"""

import json
import os
import sys
from typing import Optional

# Support both MCP 1.x (FastMCP) and MCP 2.x (MCPServer alias)
try:
    from mcp.server.fastmcp import FastMCP
except (ImportError, ModuleNotFoundError):
    from mcp.server.mcpserver import MCPServer as FastMCP

# Ensure the package directory is in sys.path
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

try:
    from gmail import GmailClient
except ImportError:
    from client import GmailClient

# Initialize FastMCP server
mcp = FastMCP("gmail")

# Lazy-loaded client instance
_client: Optional[GmailClient] = None


def get_client() -> GmailClient:
    """Retrieve or initialize the GmailClient."""
    global _client
    if _client is None:
        _client = GmailClient(env_path="/root/.env")
    return _client


@mcp.tool()
def gmail_list_folders() -> str:
    """
    List all available IMAP mailboxes in the connected Gmail account.

    Returns:
        JSON string containing list of folders with name, flags, and delimiter.
    """
    try:
        client = get_client()
        folders = client.list_folders()
        return json.dumps(folders, indent=2, ensure_ascii=False)
    except Exception as e:
        return json.dumps({"error": str(e)}, indent=2)


@mcp.tool()
def gmail_search(
    query: str = "ALL",
    folder: str = "INBOX",
    limit: int = 10,
) -> str:
    """
    Search emails in a mailbox folder.

    Parameters:
        query: Search query. Accepts 'ALL', 'UNSEEN', IMAP criteria (e.g. 'FROM <x>', 'SUBJECT <y>'),
               or free-form terms / Gmail search operators (e.g. 'github', 'has:attachment').
        folder: Mailbox folder name (default: 'INBOX').
        limit: Maximum number of recent messages to return (default: 10).

    Returns:
        JSON string list of message summaries with UID, Subject, From, To, Date, Flags, and unread status.
    """
    try:
        client = get_client()
        results = client.search(query=query, folder=folder, limit=limit)
        return json.dumps(results, indent=2, ensure_ascii=False)
    except Exception as e:
        return json.dumps({"error": str(e)}, indent=2)


@mcp.tool()
def gmail_read(
    uid: str,
    folder: str = "INBOX",
) -> str:
    """
    Read and parse a full email message by UID.

    Parameters:
        uid: The unique identifier (UID) of the message.
        folder: Mailbox folder name where the message resides (default: 'INBOX').

    Returns:
        JSON string containing headers, decoded body, attachment list, and unread status.
    """
    try:
        client = get_client()
        message = client.get_message(uid=uid, folder=folder)
        return json.dumps(message, indent=2, ensure_ascii=False)
    except Exception as e:
        return json.dumps({"error": str(e)}, indent=2)


@mcp.tool()
def gmail_create_draft(
    to: str,
    subject: str,
    body: str,
    cc: Optional[str] = None,
) -> str:
    """
    Create a new email draft in [Gmail]/Drafts folder.

    Parameters:
        to: Recipient email address(es).
        subject: Subject line.
        body: Email body text.
        cc: Optional carbon copy recipient(s).

    Returns:
        JSON string with creation status and folder details.
    """
    try:
        client = get_client()
        res = client.create_draft(to=to, subject=subject, body=body, cc=cc)
        return json.dumps(res, indent=2, ensure_ascii=False)
    except Exception as e:
        return json.dumps({"error": str(e)}, indent=2)


@mcp.tool()
def gmail_send(
    to: str,
    subject: str,
    body: str,
    cc: Optional[str] = None,
    confirmed: bool = False,
) -> str:
    """
    Send an email immediately via SMTP.

    CRITICAL SAFETY REQUIREMENT:
    Emails will NOT be sent unless 'confirmed' is explicitly set to True.
    Always present the draft and recipient to the user and obtain explicit confirmation before calling with confirmed=True.

    Parameters:
        to: Recipient email address(es).
        subject: Subject line.
        body: Email body text.
        cc: Optional carbon copy recipient(s).
        confirmed: Explicit confirmation flag (must be True to send).

    Returns:
        JSON string with transmission status or confirmation_required prompt.
    """
    try:
        client = get_client()
        res = client.send_message(to=to, subject=subject, body=body, cc=cc, confirmed=confirmed)
        return json.dumps(res, indent=2, ensure_ascii=False)
    except Exception as e:
        return json.dumps({"error": str(e)}, indent=2)


if __name__ == "__main__":
    mcp.run()
