# Field reference

Values observed on one Mac (~187,000 OneDrive files; OneDrive 26.168.0830, macOS 26.6.2 25G83).
Microsoft and Apple don't document the databases. `capabilities` and the content policy use
Apple's public File Provider enums; everything else is inferred.

Conventions:

- **Bitmask fields:** bit position *n* is counted from 0, and its mask is 2^*n*.
- **Test one flag** with `field & mask`, e.g. `(state_flags & 4) != 0`. Never compare whole
  values: unseen combinations are valid.
- **Confidence levels:** confirmed (consistent across thousands of files), inferred (pattern,
  not proven), unknown.

## OneDrive.dat → `dbfs_files`

Path: `~/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite/OneDrive.noindex/OneDrive.dat`.

Key columns:

- `itemid`: OneDrive's item ID. It's the same as the File Provider item ID, as the decimal
  string in `FP_snapshot.id` and in the system log `update<s:<id> …>`.
- `fsid`: joins `od_ClientFile_Records.itemIndex`.
- `parentid`: the parent folder's `itemid`.
- `filetype`: 0 = file, 1 = folder.
- `tombstoned`: 1 = deleted.

### `state_flags` (bitmask, SQLite integer)

| Mask | Bit | Meaning | Confidence |
|---|---|---|---|
| 1 | 0 | set on every item except OneDrive's hidden root marker file (value 12) | confirmed (meaning unknown) |
| 2 | 1 | set on normal files; clear on pinned files and folders | inferred |
| 4 | 2 | **pinned** ("Always Keep on This Device"), on the file or inherited from a pinned folder | confirmed |
| 8 | 3 | **"freed" mark**, set by OneDrive when it frees a file; also on folders whose contents changed | confirmed (harmless once caps = -1) |
| 16 | 4 | seen on a few folders only | unknown |
| 32 | 5 | **"in sync"**; clear → Finder shows "sync pending" arrows; OneDrive restores it itself (its own Free Up Space did) | inferred |
| 64 | 6 | seen on 5 pinned files | unknown |

Values seen on files:

| Value | Bits | Meaning | Count |
|---|---|---|---|
| 35 | 5,1,0 | normal | ~169,000 |
| 37 | 5,2,0 | pinned | ~18,100 |
| 43 | 5,3,1,0 | normal + freed mark | varies |
| 3 | 1,0 | normal, not in sync (after a pin and unpin) | rare |
| 101 | 6,5,2,0 | pinned + unknown bit 6 | 5 |
| 12 | 3,2 | OneDrive's hidden marker file in its root | 1 |

Folders seen: 33 (5,0), 41 (5,3,0), 49 (5,4,0), 53 (5,4,2,0; a pinned folder).

### `capabilities` (Apple `NSFileProviderItemCapabilities` bitmask)

| Mask | Bit | Apple name |
|---|---|---|
| 1 | 0 | allowsReading |
| 2 | 1 | allowsWriting |
| 4 | 2 | allowsReparenting |
| 8 | 3 | allowsRenaming |
| 16 | 4 | allowsTrashing |
| 32 | 5 | allowsDeleting |
| 64 | 6 | allowsEvicting |
| 128 | 7 | allowsExcludingFromSync |

- **-1** (all bits set): default. Normal files (~167,000).
- **47** = 1+2+4+8+32: no trashing (16), **no evicting** (64). OneDrive sets it on pin and
  never resets it on unpin. That's the root cause. Pinned files (mask 4 set) legitimately
  have it.
- **Leftover:** caps 47 with `state_flags & 4` = 0.

## SyncEngineDatabase.db → `od_ClientFile_Records`

Path: `~/Library/Containers/com.microsoft.OneDrive-mac/Data/Library/Application Support/OneDrive/settings/Personal/SyncEngineDatabase.db`.
Join: `itemIndex` = `dbfs_files.fsid`.

### `lastKnownPinState` (plain enum, not a bitmask)

| Value | Meaning |
|---|---|
| NULL | no record. OneDrive resets values to NULL itself after restarts. |
| 0 | normal |
| 1 | pinned (folder-level pins leave the files at NULL; use `state_flags & 4`) |
| 2 | freed by OneDrive's own Free Up Space |

Not causal: files at 0 still got `keepDownloaded` while caps was 47.

Other tables: `od_HydrationData` holds the download history (first/last time, count), and
`od_ClientFolder_Records` holds folders (`resourceID`, `parentResourceID`, `folderName`).

## macOS FileProvider db → `FP_snapshot`

Path: `~/Library/Application Support/FileProvider/<domain-uuid>/database/db`. Needs Full Disk
Access. Writes go through triggers that need the substitute functions (see SKILL.md).

- `id`: the item ID as an ASCII blob (`CAST('184520' AS BLOB)`).

### `decoration_content_policy` (Apple `NSFileProviderContentPolicy`)

| Value | Apple name | System log |
|---|---|---|
| 0 | inherited | |
| 1 | downloadLazily (normal) | `cp:lazy` |
| 2 | downloadLazilyAndEvictOnRemoteUpdate | |
| 3 | downloadEagerlyAndKeepDownloaded (pinned / stuck) | `cp:keepDownloaded` |

`fileproviderctl evaluate <file>` prints `Content Policy: <n>`. A cloud-only file at 3 is a
time bomb.

### Other columns

| Column | Values |
|---|---|
| `metadata_is_evictable` | 4 at policy 1, 5 at policy 3 (keep consistent when changing the policy) |
| `decoration_is_uploaded` | 1 = the cloud copy is complete; only evict such files |
| `decoration_is_uploading` | 1 = upload in progress |

Related tables: `FS_snapshot` (disk side; `metadata_is_dataless` = 1 means cloud-only) and
`reconciliation_table` (joins `fp_id` ↔ `fs_id`; `last_change` in ns since epoch).
