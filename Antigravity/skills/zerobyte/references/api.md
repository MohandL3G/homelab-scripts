# Zerobyte HTTP API Reference (`/api/v1`)

Generated from live Zerobyte OpenAPI `1.0.0` (`75` endpoints).

- **Authentication:** `X-API-Key: <ZEROBYTE_API_KEY>` header
- **Default Base URL:** `http://192.168.0.100:4096` (or `https://zerobyte.mohandl3g.ly`)

## Table of Contents

- [Agents](#agents)
- [Auth](#auth)
- [Backups](#backups)
- [Desktop](#desktop)
- [Notifications](#notifications)
- [Repositories](#repositories)
- [System](#system)
- [Tasks](#tasks)
- [Volumes](#volumes)

---

## Agents

### `GET /api/v1/agents`
- **Purpose:** listAgents

### `POST /api/v1/agents`
- **Purpose:** createRemoteAgent
- **JSON Body:** `name*` (string)

### `POST /api/v1/agents/enroll`
- **Purpose:** postApiV1AgentsEnroll
- **JSON Body:** `code*` (string)

### `DELETE /api/v1/agents/{agentId}`
- **Purpose:** deleteRemoteAgent
- **Params:** `agentId` (path*)

### `DELETE /api/v1/agents/{agentId}/token`
- **Purpose:** revokeRemoteAgentToken
- **Params:** `agentId` (path*)

### `POST /api/v1/agents/{agentId}/token/rotate`
- **Purpose:** rotateRemoteAgentToken
- **Params:** `agentId` (path*)

## Auth

### `GET /api/v1/auth/admin-users`
- **Purpose:** List admin users for settings management

### `DELETE /api/v1/auth/admin-users/{userId}/accounts/{accountId}`
- **Purpose:** Delete an account linked to a user
- **Params:** `userId` (path*), `accountId` (path*)

### `GET /api/v1/auth/api-keys`
- **Purpose:** List API keys for the current user in the active organization

### `POST /api/v1/auth/api-keys`
- **Purpose:** Create an API key for the current user in the active organization
- **JSON Body:** `name*` (string), `password*` (string), `expiresIn` (integer|null)

### `DELETE /api/v1/auth/api-keys/{keyId}`
- **Purpose:** Revoke an API key for the current user in the active organization
- **Params:** `keyId` (path*)

### `GET /api/v1/auth/deletion-impact/{userId}`
- **Purpose:** Get impact of deleting a user
- **Params:** `userId` (path*)

### `GET /api/v1/auth/org-members`
- **Purpose:** Get members of the active organization

### `DELETE /api/v1/auth/org-members/{memberId}`
- **Purpose:** Remove a member from the active organization
- **Params:** `memberId` (path*)

### `PATCH /api/v1/auth/org-members/{memberId}/role`
- **Purpose:** Update a member's role in the active organization
- **Params:** `memberId` (path*)
- **JSON Body:** `role*` (enum(member,admin))

### `GET /api/v1/auth/sso-invitations`
- **Purpose:** Get pending SSO invitations for the authenticated user

### `DELETE /api/v1/auth/sso-invitations/{invitationId}`
- **Purpose:** Delete an SSO invitation
- **Params:** `invitationId` (path*)

### `POST /api/v1/auth/sso-invitations/{invitationId}/verify`
- **Purpose:** Start SSO verification for accepting an organization invitation
- **Params:** `invitationId` (path*)
- **JSON Body:** `providerId*` (string)

### `GET /api/v1/auth/sso-providers`
- **Purpose:** Get public SSO providers for the instance

### `GET /api/v1/auth/sso-providers/{providerId}`
- **Purpose:** Get editable OIDC settings and callback diagnostics for an organization provider
- **Params:** `providerId` (path*)

### `PATCH /api/v1/auth/sso-providers/{providerId}`
- **Purpose:** Update an organization's OIDC provider while preserving linked accounts
- **Params:** `providerId` (path*)
- **JSON Body:** `issuer` (string), `domain` (string), `discoveryEndpoint` (string), `clientId` (string), `clientSecret` (string)

### `DELETE /api/v1/auth/sso-providers/{providerId}`
- **Purpose:** Delete an SSO provider
- **Params:** `providerId` (path*)

### `PATCH /api/v1/auth/sso-providers/{providerId}/auto-linking`
- **Purpose:** Update whether SSO sign-in can auto-link existing accounts by email
- **Params:** `providerId` (path*)
- **JSON Body:** `enabled*` (boolean)

### `GET /api/v1/auth/sso-providers/{providerId}/discovery`
- **Purpose:** Check an organization's saved OIDC settings against its discovery document
- **Params:** `providerId` (path*)

### `GET /api/v1/auth/sso-settings`
- **Purpose:** Get SSO providers and invitations for the active organization

### `GET /api/v1/auth/status`
- **Purpose:** Get authentication system status

## Backups

### `GET /api/v1/backups`
- **Purpose:** List all backup schedules

### `POST /api/v1/backups`
- **Purpose:** Create a new backup schedule for a volume
- **JSON Body:** `name*` (string), `volumeId*` (['string', 'number']), `repositoryId*` (string), `enabled*` (boolean), `cronExpression*` (string), `retentionPolicy` (object), `excludePatterns` (array), `excludeIfPresent` (array), `includePaths` (array), `includePatterns` (array), `oneFileSystem` (boolean), `tags` (array), `customResticParams` (array), `compressionMode` (string|null), `backupWebhooks` (object|null), `maxRetries` (number), `retryDelay` (number)

### `POST /api/v1/backups/reorder`
- **Purpose:** Reorder backup schedules by providing an array of schedule short IDs in the desired order
- **JSON Body:** `scheduleShortIds*` (array)

### `GET /api/v1/backups/volume/{volumeShortId}`
- **Purpose:** Get a backup schedule for a specific volume
- **Params:** `volumeShortId` (path*)

### `GET /api/v1/backups/{shortId}`
- **Purpose:** Get a backup schedule by ID
- **Params:** `shortId` (path*)

### `PATCH /api/v1/backups/{shortId}`
- **Purpose:** Update a backup schedule
- **Params:** `shortId` (path*)
- **JSON Body:** `name` (string), `repositoryId*` (string), `enabled` (boolean), `cronExpression*` (string), `retentionPolicy` (object), `excludePatterns` (array), `excludeIfPresent` (array), `includePaths` (array), `includePatterns` (array), `oneFileSystem` (boolean), `tags` (array), `customResticParams` (array), `compressionMode` (string|null), `backupWebhooks` (object|null), `maxRetries` (number), `retryDelay` (number)

### `DELETE /api/v1/backups/{shortId}`
- **Purpose:** Delete a backup schedule
- **Params:** `shortId` (path*)

### `POST /api/v1/backups/{shortId}/forget`
- **Purpose:** Manually apply retention policy to clean up old snapshots
- **Params:** `shortId` (path*)

### `GET /api/v1/backups/{shortId}/mirrors`
- **Purpose:** Get mirror repository assignments for a backup schedule
- **Params:** `shortId` (path*)

### `PUT /api/v1/backups/{shortId}/mirrors`
- **Purpose:** Update mirror repository assignments for a backup schedule
- **Params:** `shortId` (path*)
- **JSON Body:** `mirrors*` (array)

### `GET /api/v1/backups/{shortId}/mirrors/compatibility`
- **Purpose:** Get mirror compatibility info for all repositories relative to a backup schedule's primary repository
- **Params:** `shortId` (path*)

### `POST /api/v1/backups/{shortId}/mirrors/{mirrorShortId}/status`
- **Purpose:** Start a background lookup of snapshots missing from a mirror repository
- **Params:** `shortId` (path*), `mirrorShortId` (path*)

### `POST /api/v1/backups/{shortId}/mirrors/{mirrorShortId}/sync`
- **Purpose:** Sync selected snapshots to a specific mirror repository
- **Params:** `shortId` (path*), `mirrorShortId` (path*)
- **JSON Body:** `snapshotIds` (array)

### `GET /api/v1/backups/{shortId}/notifications`
- **Purpose:** Get notification assignments for a backup schedule
- **Params:** `shortId` (path*)

### `PUT /api/v1/backups/{shortId}/notifications`
- **Purpose:** Update notification assignments for a backup schedule
- **Params:** `shortId` (path*)
- **JSON Body:** `assignments*` (array)

### `POST /api/v1/backups/{shortId}/run`
- **Purpose:** Trigger a backup immediately for a schedule
- **Params:** `shortId` (path*)

## Desktop

### `POST /api/v1/desktop/session`
- **Purpose:** Create an authenticated desktop session
- **JSON Body:** `dateFormat*` (enum(MM/DD/YYYY,DD/MM/YYYY,YYYY/MM/DD)), `timeFormat*` (enum(12h,24h))

## Notifications

### `GET /api/v1/notifications/destinations`
- **Purpose:** List all notification destinations

### `POST /api/v1/notifications/destinations`
- **Purpose:** Create a new notification destination
- **JSON Body:** `name*` (string), `config*` (oneOf)

### `GET /api/v1/notifications/destinations/{id}`
- **Purpose:** Get a notification destination by ID
- **Params:** `id` (path*)

### `PATCH /api/v1/notifications/destinations/{id}`
- **Purpose:** Update a notification destination
- **Params:** `id` (path*)
- **JSON Body:** `name` (string), `enabled` (boolean), `config` (oneOf)

### `DELETE /api/v1/notifications/destinations/{id}`
- **Purpose:** Delete a notification destination
- **Params:** `id` (path*)

### `POST /api/v1/notifications/destinations/{id}/test`
- **Purpose:** Test a notification destination by sending a test message
- **Params:** `id` (path*)

## Repositories

### `GET /api/v1/repositories`
- **Purpose:** List all repositories

### `POST /api/v1/repositories`
- **Purpose:** Create a new restic repository
- **JSON Body:** `name*` (string), `compressionMode` (enum(off,auto,max)), `autoCheckEnabled` (boolean), `config*` (oneOf)

### `GET /api/v1/repositories/rclone-remotes`
- **Purpose:** List all configured rclone remotes on the host system

### `GET /api/v1/repositories/{shortId}`
- **Purpose:** Get a single repository by ID
- **Params:** `shortId` (path*)

### `PATCH /api/v1/repositories/{shortId}`
- **Purpose:** Update a repository's name or settings
- **Params:** `shortId` (path*)
- **JSON Body:** `name` (string), `compressionMode` (enum(off,auto,max)), `autoCheckEnabled` (boolean), `config` (oneOf)

### `DELETE /api/v1/repositories/{shortId}`
- **Purpose:** Delete a repository
- **Params:** `shortId` (path*)

### `POST /api/v1/repositories/{shortId}/doctor`
- **Purpose:** Start an asynchronous doctor operation on a repository to fix common issues (unlock, check, repair index).
- **Params:** `shortId` (path*)

### `POST /api/v1/repositories/{shortId}/exec`
- **Purpose:** Execute a restic command against a repository (dev panel only)
- **Params:** `shortId` (path*)
- **JSON Body:** `command*` (string), `args` (array)

### `POST /api/v1/repositories/{shortId}/restore`
- **Purpose:** Restore a snapshot to a target path on the filesystem
- **Params:** `shortId` (path*)
- **JSON Body:** `snapshotId*` (string), `include` (array), `selectedItemKind` (enum(file,dir)), `exclude` (array), `excludeXattr` (array), `delete` (boolean), `targetPath` (string), `overwrite` (enum(always,if-changed,if-newer,never))

### `GET /api/v1/repositories/{shortId}/snapshots`
- **Purpose:** List all snapshots in a repository
- **Params:** `backupId` (query), `shortId` (path*)

### `DELETE /api/v1/repositories/{shortId}/snapshots`
- **Purpose:** Delete multiple snapshots from a repository
- **Params:** `shortId` (path*)
- **JSON Body:** `snapshotIds*` (array)

### `POST /api/v1/repositories/{shortId}/snapshots/refresh`
- **Purpose:** Clear snapshot cache and force refresh from repository
- **Params:** `shortId` (path*)

### `POST /api/v1/repositories/{shortId}/snapshots/tag`
- **Purpose:** Tag multiple snapshots in a repository
- **Params:** `shortId` (path*)
- **JSON Body:** `snapshotIds*` (array), `add` (array), `remove` (array), `set` (array)

### `GET /api/v1/repositories/{shortId}/snapshots/{snapshotId}`
- **Purpose:** Get details of a specific snapshot
- **Params:** `shortId` (path*), `snapshotId` (path*)

### `DELETE /api/v1/repositories/{shortId}/snapshots/{snapshotId}`
- **Purpose:** Delete a specific snapshot from a repository
- **Params:** `shortId` (path*), `snapshotId` (path*)

### `GET /api/v1/repositories/{shortId}/snapshots/{snapshotId}/dump`
- **Purpose:** Download a snapshot path as a tar archive (folders) or raw file stream (single files)
- **Params:** `path` (query), `kind` (query), `shortId` (path*), `snapshotId` (path*)

### `GET /api/v1/repositories/{shortId}/snapshots/{snapshotId}/files`
- **Purpose:** List files and directories in a snapshot
- **Params:** `path` (query), `offset` (query), `limit` (query), `shortId` (path*), `snapshotId` (path*)

### `GET /api/v1/repositories/{shortId}/stats`
- **Purpose:** Get repository storage and compression statistics
- **Params:** `shortId` (path*)

### `POST /api/v1/repositories/{shortId}/stats/refresh`
- **Purpose:** Refresh repository storage and compression statistics
- **Params:** `shortId` (path*)

### `POST /api/v1/repositories/{shortId}/unlock`
- **Purpose:** Unlock a repository by removing all stale locks
- **Params:** `shortId` (path*)

## System

### `POST /api/v1/system/config-export`
- **Purpose:** Export organization configuration encrypted with a dedicated export passphrase. Requires the recovery key download permission and may require password re-authentication.
- **JSON Body:** `password*` (string), `exportPassphrase*` (string)

### `POST /api/v1/system/config-import`
- **Purpose:** Import a passphrase-protected organization configuration during onboarding
- **JSON Body:** `encryptedConfig*` (string), `exportPassphrase*` (string)

### `GET /api/v1/system/dev-panel`
- **Purpose:** Get the dev panel status

### `GET /api/v1/system/info`
- **Purpose:** Get system information including available capabilities

### `GET /api/v1/system/password-login-status`
- **Purpose:** Get whether password-based login is disabled

### `PUT /api/v1/system/password-login-status`
- **Purpose:** Disable or re-enable password-based login. Requires global admin role.
- **JSON Body:** `disabled*` (boolean)

### `GET /api/v1/system/registration-status`
- **Purpose:** Get the current registration status for new users

### `PUT /api/v1/system/registration-status`
- **Purpose:** Update the registration status for new users. Requires global admin role.
- **JSON Body:** `enabled*` (boolean)

### `POST /api/v1/system/restic-password`
- **Purpose:** Download the organization's Restic password for backup recovery. Requires organization owner or admin role and may require password re-authentication.
- **JSON Body:** `password*` (string)

### `GET /api/v1/system/updates`
- **Purpose:** Check for application updates from GitHub

## Tasks

### `GET /api/v1/tasks`
- **Purpose:** List active tasks
- **Params:** `kind` (query), `resourceType` (query), `resourceId` (query), `operationKey` (query)

### `GET /api/v1/tasks/events`
- **Purpose:** Subscribe to lifecycle events for active tasks matching a filter
- **Params:** `kind` (query), `resourceType` (query), `resourceId` (query), `operationKey` (query)

### `GET /api/v1/tasks/history`
- **Purpose:** List persisted task history for the current organization
- **Params:** `kind` (query), `outcome` (query), `page` (query)

### `GET /api/v1/tasks/{taskId}`
- **Purpose:** Get a task by id
- **Params:** `taskId` (path*)

### `POST /api/v1/tasks/{taskId}/cancel`
- **Purpose:** Request cancellation of a running task
- **Params:** `taskId` (path*)

### `GET /api/v1/tasks/{taskId}/events`
- **Purpose:** Subscribe to lifecycle events for one task
- **Params:** `taskId` (path*)

## Volumes

### `GET /api/v1/volumes`
- **Purpose:** List all volumes

### `POST /api/v1/volumes`
- **Purpose:** Create a new volume
- **JSON Body:** oneOf[`sourceKind*` (string), `name*` (string), `config*` (oneOf); `sourceKind*` (string), `agentId*` (string), `trustedRootId*` (string), `relativePath` (string), `name*` (string)]

### `GET /api/v1/volumes/filesystem/browse`
- **Purpose:** Browse directories on the host filesystem
- **Params:** `agentId` (query), `rootId` (query), `path` (query)

### `GET /api/v1/volumes/source-machines`
- **Purpose:** List organization-scoped machines and trusted roots available for filesystem sources

### `POST /api/v1/volumes/test-connection`
- **Purpose:** Test connection to backend
- **JSON Body:** `config*` (oneOf), `shortId` (string)

### `GET /api/v1/volumes/{shortId}`
- **Purpose:** Get a volume by name
- **Params:** `shortId` (path*)

### `PUT /api/v1/volumes/{shortId}`
- **Purpose:** Update a volume's configuration
- **Params:** `shortId` (path*)
- **JSON Body:** `name` (string), `autoRemount` (boolean), `config` (oneOf), `agentId` (string), `trustedRootId` (string), `relativePath` (string)

### `DELETE /api/v1/volumes/{shortId}`
- **Purpose:** Delete a volume
- **Params:** `shortId` (path*)

### `GET /api/v1/volumes/{shortId}/files`
- **Purpose:** List files in a volume directory
- **Params:** `path` (query), `offset` (query), `limit` (query), `shortId` (path*)

### `POST /api/v1/volumes/{shortId}/health-check`
- **Purpose:** Perform a health check on a volume
- **Params:** `shortId` (path*)

### `POST /api/v1/volumes/{shortId}/mount`
- **Purpose:** Mount a volume
- **Params:** `shortId` (path*)

### `POST /api/v1/volumes/{shortId}/unmount`
- **Purpose:** Unmount a volume
- **Params:** `shortId` (path*)
