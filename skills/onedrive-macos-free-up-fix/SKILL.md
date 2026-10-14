---
name: onedrive-macos-free-up-fix
description: Diagnose and fix OneDrive on macOS where "Free Up Space" does nothing, files stay downloaded, or files re-download right after being freed, because they are stuck at File Provider Content Policy 3 ("keep downloaded") while not pinned. Use this whenever someone says OneDrive files under ~/Library/CloudStorage/OneDrive-* still take disk space, won't become cloud-only / online-only, keep re-downloading, or "Always Keep on This Device" is off but space isn't freed, even if they don't mention Content Policy or File Provider.
compatibility: macOS with OneDrive using Apple File Provider (~/Library/CloudStorage). Needs a terminal with Full Disk Access, sqlite3, python3, swift (Xcode Command Line Tools).
metadata:
  verified-onedrive: "26.168.0830 (build 26168.0830.0006)"
  verified-macos: "26.6.2 (25G83)"
  verified-fileprovider: "4018.160.6"
  verified-date: "2026-10-14"
---

# OneDrive on macOS: files that won't free up

## Version check first

This fix edits a private macOS database and depends on how OneDrive and
`fileproviderd` behave internally, so a OneDrive or macOS update can break it.

Before doing anything, compare the installed versions with `metadata` above:

```bash
defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleShortVersionString; sw_vers -buildVersion
```

If either differs, say so plainly and re-verify on **one expendable file**
(the single-file test below) before touching a whole folder. When it works on a
new version, update `metadata` here and `PROVEN_*` in `scripts/fix_folder.sh`.
If a newer OneDrive no longer has the bug (Free Up Space just works), note
that here too.

## Symptoms

- A folder in `~/Library/CloudStorage/OneDrive-*` keeps using disk space after
  "Free Up Space", no matter how often it's clicked.
- "Always Keep on This Device" shows as off.
- Toggling "Always Keep" re-downloads files and can temporarily double usage.
- After this fix, using OneDrive's "Free Up Space" again evicts the file and then
  re-downloads it straight away.

## Diagnose (read-only)

```bash
D="<folder>"; du -sh "$D"; echo "cloud-only: $(find "$D" -type f -flags dataless | wc -l)   on disk: $(find "$D" -type f ! -flags dataless | wc -l)"
fileproviderctl evaluate "<a file in it>" | grep -E "isKeepDownloaded|isUploaded =|Content Policy"
```

It's this bug when a file shows `isUploaded = 1`, `isKeepDownloaded = 0` and
`Content Policy: 3`, while `Inherited Content Policy: 1`.
`fileproviderctl check` does not catch it, because both records agree.

## Root cause

- macOS's `fileproviderd` keeps its own per-item `decoration_content_policy` in
  `~/Library/Application Support/FileProvider/<domain-uuid>/database/db`,
  table `FP_snapshot`. A value of `3` means download eagerly and keep downloaded,
  and macOS refuses to evict those files. Normal files have `1`, intentionally
  pinned ones have `3`.
- OneDrive mirrors that value into `SyncEngineDatabase.db`
  (`od_ClientFile_Records.lastKnownPinState`: 0 normal, 1 pinned, 2 stuck).
  Editing OneDrive's side alone gets overwritten from macOS's value on the next
  change to the file.
- OneDrive's own "Free Up Space" sets pin state 2, which it reports to macOS as
  policy 3. That's why it re-pins and re-downloads.

## Don't

- Don't toggle "Always Keep on This Device": it re-downloads everything.
- Don't use OneDrive's "Free Up Space" on fixed files: it re-pins them.
- Don't reset or unlink OneDrive: it drops every locally kept file, which can be
  hundreds of GB of intentionally downloaded data.
- Don't copy the folder on the web and delete the original unless the user asks
  for that specifically.
- `fileproviderctl` has no `evict` command, and `fileproviderctl repair` doesn't help.
- Don't edit OneDrive's databases. They aren't needed: the minimal fix below
  was verified without them.

## Fix

The fix changes only macOS's record, from 3 to 1, then evicts the files with
the macOS API. OneDrive keeps running.

Agents usually can't do this themselves: macOS blocks sandboxed and app
processes from `~/Library/Application Support/FileProvider` and often from
`~/Library/CloudStorage` ("Operation not permitted"). Give the user commands
to run in a terminal that has Full Disk Access, and explain each step.
Prefer the smallest intervention that works.

### 1. Single-file test (always on a new version, otherwise optional)

Ask the user for an expendable file in the affected folder. Get its item ID
with `fileproviderctl evaluate "<file>" | grep itemIdentifier`, then run:

```bash
F="<file>"; FPDB="$HOME/Library/Application Support/FileProvider/<domain-uuid>/database/db"; S="<skill dir>/scripts"
fileproviderctl evaluate "$F" | grep "Content Policy:"
python3 -I "$S/fp_set_policy.py" "$FPDB" <itemIdentifier>
killall fileproviderd; sleep 10
fileproviderctl evaluate "$F" | grep "Content Policy:"
swift "$S/evict.swift" "$F"; sleep 30; du -h "$F"; fileproviderctl evaluate "$F" | grep -E "isDownloaded =|Content Policy:"
```

Success looks like `evicted:`, `0B`, `isDownloaded = 0` and `Content Policy: 1`,
and it should hold after 30 s. To find `<domain-uuid>`, look for the folder
under `~/Library/Application Support/FileProvider/` whose `database/db` has a
row in `FP_snapshot` with `id = CAST('<itemIdentifier>' AS BLOB)`.
`fix_folder.sh` does this lookup automatically.

### 2. Whole folder

```bash
zsh "<skill dir>/scripts/fix_folder.sh" "<folder>"
```

It runs the version check, finds the downloaded files at policy 3 (and only
those), saves their IDs to `~/onedrive-free-up-fix-ids-*.txt`, sets them to 1,
restarts `fileproviderd`, evicts the files, waits 60 s, and reports the size
and cloud-only vs on-disk counts.

Intentionally pinned files are also policy 3. Only run it on folders the user
wants freed.

## Rollback

```bash
python3 -I "<skill dir>/scripts/fp_set_policy.py" --from 1 --to 3 "$FPDB" $(cat ~/onedrive-free-up-fix-ids-<timestamp>.txt); killall fileproviderd
```

## Afterwards

To free files later, use `swift scripts/evict.swift <files>`, not OneDrive's
menu item. Suggest the user reports the bug to Microsoft (OneDrive → Help &
Settings → Send Feedback), quoting `Content Policy 3 with isKeepDownloaded = 0`.

## How the scripts work (if something breaks after an update)

- `FP_snapshot` has triggers that call `PROPAGATION_DATE_CHANGED(kind, id)`, a
  function only `fileproviderd` provides, so the `sqlite3` command line can't
  update it.
- `fp_set_policy.py` registers a substitute that returns `time.time_ns()`.
  That matches the nanoseconds-since-epoch values in
  `reconciliation_table.last_change`.
- It also registers `NEXT_ANCHOR` to raise an error, so the transaction aborts
  if an unexpected trigger fires.
- It sets `metadata_is_evictable` to 4, the value normal files have; policy 3
  files have 5.
- If the schema or column names change, inspect a copy of the database
  (`cp db* /tmp/x/`) before changing anything.
