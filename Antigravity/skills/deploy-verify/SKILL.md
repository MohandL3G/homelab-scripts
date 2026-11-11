---
name: Deploy Verify
description: Pre-deployment, deployment, and post-deployment verification checklist for running services on the homelab (LXC apps, Docker on CT 110, configs). Use for ANY change to a live service - app updates, config replacements, code deploys.
---

# Deployment Verification

## Before deployment

- Treat production as read-only during investigation unless a production action was explicitly requested.
- Create a rollback backup of the live file(s) being replaced (temporary `.bak`, deleted after verification - the user dislikes persistent .bak clutter).
- Test fixes before deployment. For concurrency, locking, recovery, or filesystem changes, use isolated temporary directories - never production data.
- Never trigger destructive or expensive production operations just to prove a code path works.
- Never modify production user data as part of testing.

## During deployment

- Targeted replacement: change only the files required.
- Do not silently normalize line endings, permissions, ownership, or file formats.
- Compare deployed artifacts against the intended local artifacts using hashes or byte comparison. Report any line-ending difference explicitly rather than treating it as an unexplained mismatch.

## After deployment - verify ALL that apply

1. Deployed file hash matches the intended artifact
2. Syntax check passes (service-specific: config test, compile, `jq`, etc.)
3. Ownership and permissions correct
4. Service status running/healthy (`systemctl status` / `docker ps`)
5. Health endpoint or equivalent responds
6. Logs since deploy time are clean (`journalctl --since` / `docker logs --since`)
7. Scheduler/lock state where applicable
8. App-level smoke test: the actual feature works - not just "service restarted"

- Do not declare success solely because the service restarted - verify application health.
- Do not manually trigger scheduled jobs, or production "Run Now" equivalents, unless the user explicitly asks.

## Reporting (every implementation task)

1. What changed
2. Why it changed
3. Exact files changed
4. Tests performed and exact results
5. Deployment state
6. Git HEAD/status
7. Production-data impact
8. Commit/push state

Factual and concise. Never claim a test, deployment, or verification that was not actually performed. Never include credentials or tokens in reports - sanitize command output before handing it back.
