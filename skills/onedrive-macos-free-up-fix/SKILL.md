---
name: onedrive-macos-free-up-fix
description: Diagnose and fix OneDrive on macOS where "Free Up Space" does nothing, files stay downloaded, files re-download right after being freed or come back later, because macOS's File Provider has them stuck at Content Policy 3 ("keep downloaded") while not pinned. Use this whenever someone says OneDrive files under ~/Library/CloudStorage/OneDrive-* still take disk space, won't become cloud-only / online-only, keep re-downloading, download unexpectedly after "Free Up Space", or "Always Keep on This Device" is off but space isn't freed, even if they don't mention Content Policy or File Provider.
compatibility: macOS with OneDrive using Apple File Provider (~/Library/CloudStorage). Needs a terminal (or app) with Full Disk Access, sqlite3, python3, swift (Xcode Command Line Tools).
metadata:
  verified-onedrive: "26.168.0830 (build 26168.0830.0006)"
  verified-macos: "26.6.2 (25G83)"
  verified-fileprovider: "4018.160.6"
  verified-date: "2026-10-14"
---

# OneDrive on macOS: files that won't free up

## Version check first

This fix edits private macOS and OneDrive databases and depends on how OneDrive and
`fileproviderd` behave internally, so a OneDrive or macOS update can break it.

Before doing anything, compare the installed versions with `metadata` above:

```bash
defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleShortVersionString; sw_vers -buildVersion
```

If either differs, say so plainly and re-verify on **one expendable file** (the
single-file test below) before touching a whole folder. When it works on a new version,
update `metadata` here and `PROVEN_*` in `scripts/fix_folder.sh`. If a newer OneDrive no
longer has the bug, note that here too.

## Symptoms

- A folder in `~/Library/CloudStorage/OneDrive-*` keeps using disk space after
  "Free Up Space", no matter how often it's clicked.
- "Always Keep on This Device" shows as off.
- Toggling "Always Keep" re-downloads files and can temporarily double usage.
- Files that were freed come back on their own later (minutes after a run), or OneDrive's
  "Free Up Space" on a folder downloads some files instead of freeing them.

## Diagnose (read-only)

```bash
D="<folder>"; du -sh "$D"; echo "cloud-only: $(find "$D" -type f -flags dataless | wc -l)   on disk: $(find "$D" -type f ! -flags dataless | wc -l)"
fileproviderctl evaluate "<a file in it>" | grep -E "isKeepDownloaded|isUploaded =|Content Policy"
```

It's this bug when a file shows `isUploaded = 1`, `isKeepDownloaded = 0` and
`Content Policy: 3`, while `Inherited Content Policy: 1`. `fileproviderctl check` does
not catch it, because both of macOS's records agree.

## How it works (what we know)

Each OneDrive file has two sets of records:

- **macOS** (`fileproviderd`):
  - `~/Library/Application Support/FileProvider/<domain-uuid>/database/db`, table
    `FP_snapshot`, column `decoration_content_policy`.
  - `1` = download on demand (normal). `3` = download eagerly and keep downloaded
    (intentional pins, and the stuck files).
  - macOS refuses to evict policy 3 files.
- **OneDrive:**
  - `SyncEngineDatabase.db`, column `od_ClientFile_Records.lastKnownPinState`: empty/0 =
    normal (~99% of files), 1 = "Always Keep on This Device", 2 = "freed".
  - A flag in its File Provider database `OneDrive.dat`: `dbfs_files.state_flags` bit 8;
    normal files have 35, marked files 43.

Findings, from small samples on the verified versions (working knowledge, not
guarantees):

- **OneDrive pushes its "freed" state back to macOS as policy 3.** When it sees a file
  being freed while it's running, it usually sets pin state 2 and the flag. Minutes
  later it can report that to macOS as policy 3, and the file downloads again. The policy
  then drops back to 1 once the download finishes, so by the time you look the evidence
  is gone.
- **Freeing with OneDrive stopped (its app and its File Provider helper) created no
  marks** in the test.
- **Cloud-only files at macOS policy 3 are time bombs.** Nothing happens until macOS
  re-checks them (a `fileproviderd` restart, a OneDrive restart, OneDrive's own Free
  Up), then they download. Leftovers from the original stuck state are the usual source.
- **OneDrive's own "Free Up Space" sometimes downloads cloud-only files** instead of
  leaving them alone. In tests it hit files that had been downloaded and freed before;
  44 never-downloaded files were left alone. The exact rule is unknown.
- Things that were tested and **don't** explain it: OneDrive's `in_materialized_set`
  (it doesn't track what's on disk), the download history, and empty versus 0 pin
  state.

## Don't

- Don't toggle "Always Keep on This Device": it re-downloads everything.
- Don't rely on OneDrive's own "Free Up Space" on folders containing previously
  downloaded files: it can download some of them.
- Don't reset or unlink OneDrive: it drops every locally kept file, which can be
  hundreds of GB of intentionally downloaded data.
- Don't copy the folder on the web and delete the original unless the user asks for
  that specifically.
- `fileproviderctl` has no `evict` command, and `fileproviderctl repair` doesn't help.
- Don't edit OneDrive's databases while OneDrive is running. Quit OneDrive, stop the
  `OneDrive File Provider` helper and back up both databases first.
- Don't restart `fileproviderd` or OneDrive while cloud-only files are at policy 3: the
  restart sets the time bombs off. Fix them first (below).

## Working with the user

Agents usually can't do the macOS part themselves. macOS blocks sandboxed and app
processes from `~/Library/Application Support/FileProvider` and often from
`~/Library/CloudStorage` ("Operation not permitted"). Give the user commands to run in a
terminal that has Full Disk Access, and explain each step.

OneDrive's databases (in `~/Library/Containers/com.microsoft.OneDrive-mac/...` and
`~/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite/...`) are usually
readable. Work on **copies** for analysis.

This user wants the smallest intervention that works, and to be told the plan before
anything changes. Their claims and doubts have often been right, so take them seriously.

## Fix

### Single-file test (always on a new version)

Ask the user for an expendable file in the affected folder. Get its item ID with
`fileproviderctl evaluate "<file>" | grep itemIdentifier`, then run:

```bash
F="<file>"; S="<skill dir>/scripts"
fileproviderctl evaluate "$F" | grep "Content Policy:"
python3 -I "$S/fp_set_policy.py" auto <itemIdentifier>
killall fileproviderd; sleep 10
fileproviderctl evaluate "$F" | grep "Content Policy:"
swift "$S/evict.swift" "$F"; sleep 30; du -h "$F"; fileproviderctl evaluate "$F" | grep -E "isDownloaded =|Content Policy:"
```

Success looks like `evicted:`, `0B`, `isDownloaded = 0` and `Content Policy: 1`, holding
after 30 s. `auto` finds the right `fileproviderd` database by the item ID.

### Whole folder

```bash
zsh "<skill dir>/scripts/fix_folder.sh" "<folder>"
```

Run it in a terminal with Full Disk Access. It works only for
`~/Library/CloudStorage/OneDrive-Personal`, because that's the verified account layout.
It:

1. Checks the versions, collects the item IDs of **every** file in the folder (downloaded
   or cloud-only, `.DS_Store` skipped), and saves them to
   `~/onedrive-free-up-fix-ids-<timestamp>.txt`.
2. Stops OneDrive (app and helper) and backs up both of its databases to
   `~/onedrive-free-up-fix-backups/<timestamp>/` (newest 5 kept).
3. Sets macOS policy 3 → 1 for all of them, which also defuses cloud-only time bombs.
   If anything changed, it restarts `fileproviderd` and waits 30 s.
4. Evicts the downloaded files with `scripts/evict.swift`.
5. Clears OneDrive's "freed" marks for those files (pin state 2 → 0, flag bit 8 off) and
   runs integrity checks. It only does this when the helper is really stopped.
6. Starts OneDrive (always, even if a step fails), waits 60 s, and reports the size,
   cloud-only versus on-disk counts, and how many files are still at policy 3.

It quits OneDrive for a couple of minutes. Intentionally pinned files are also policy 3,
so only run it on folders the user wants freed.

## Time bombs: find and defuse

Find cloud-only files at policy 3 anywhere (read-only, Full Disk Access terminal):

```bash
DB="$HOME/Library/Application Support/FileProvider/<domain-uuid>/database/db"
sqlite3 -header "file:$DB?mode=ro" "SELECT p.decoration_content_policy AS policy, s.metadata_is_dataless AS cloud_only, count(*) FROM FP_snapshot p JOIN reconciliation_table r ON r.fp_id = p.id JOIN FS_snapshot s ON s.id = r.fs_id WHERE p.metadata_kind = 0 GROUP BY 1, 2;"
```

A `3 | 1` row means time bombs. To list them by folder, group by `p.parent_id` and
select `(SELECT filename FROM FP_snapshot WHERE id = p.parent_id)`. Defuse them by
passing their IDs (`p.id`, which is OneDrive's numeric item ID) to `fp_set_policy.py
auto <ids…>`, then `killall fileproviderd`.

If files are actively downloading after an event, the quickest containment is the same
command for every file ID in the affected folder. Only rows at 3 change. OneDrive's
`OneDrive.dat` maps folders to file IDs (`dbfs_files.itemid` and `parentid`).

## Rollback

- **macOS:**
  ```bash
  python3 -I "<skill dir>/scripts/fp_set_policy.py" --from 1 --to 3 auto <ids…>; killall fileproviderd
  ```
- **OneDrive:** quit OneDrive and stop its helper. Restore `OneDrive.dat*` and
  `SyncEngineDatabase.db*` from the backup (`fix_folder.sh` keeps them in
  `~/onedrive-free-up-fix-backups/<timestamp>/`), then start OneDrive.

## Afterwards

Free files with `scripts/fix_folder.sh` (or `scripts/evict.swift` for single files that
are already at policy 1), not OneDrive's menu item. Suggest the
user reports the bug to Microsoft (OneDrive → Help & Settings → Send Feedback), quoting
`Content Policy 3 with isKeepDownloaded = 0`.

## How the scripts work (if something breaks after an update)

- `FP_snapshot` has triggers that call `PROPAGATION_DATE_CHANGED(kind, id)`, a function
  only `fileproviderd` provides, so the `sqlite3` command line can't update it.
- `fp_set_policy.py` registers a substitute that returns `time.time_ns()`. That matches
  the nanoseconds-since-epoch values in `reconciliation_table.last_change`.
- It registers `NEXT_ANCHOR` to raise an error, so the transaction aborts if an
  unexpected trigger fires.
- It sets `metadata_is_evictable` to 4, the value normal files have; policy 3 files have
  5.
- OneDrive's databases have no custom triggers; plain `sqlite3` with
  `BEGIN IMMEDIATE … COMMIT` and `PRAGMA integrity_check` works.
- If the schema or column names change, inspect a copy of the database
  (`cp db* /tmp/x/`) before changing anything.
