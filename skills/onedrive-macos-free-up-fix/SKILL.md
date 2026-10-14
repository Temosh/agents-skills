---
name: onedrive-macos-free-up-fix
description: Diagnose and fix OneDrive on macOS where "Free Up Space" does nothing, files stay downloaded, files re-download right after being freed or come back later, because macOS's File Provider has them stuck at Content Policy 3 ("keep downloaded") while not pinned. Root cause is a leftover OneDrive capabilities value from an old "Always Keep on This Device". Use this whenever someone says OneDrive files under ~/Library/CloudStorage/OneDrive-* still take disk space, won't become cloud-only / online-only, keep re-downloading, download unexpectedly after "Free Up Space", or "Always Keep on This Device" is off but space isn't freed, even if they don't mention Content Policy or File Provider.
compatibility: macOS with OneDrive using Apple File Provider (~/Library/CloudStorage). Needs a terminal with Full Disk Access, sqlite3, python3, swift (Xcode Command Line Tools).
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

If either differs, say so plainly. Re-verify on **one expendable file** (single-file test
below) and with the system-log check before touching a whole folder. When it works on a
new version, update `metadata` here and `PROVEN_*` in `scripts/fix_folder.sh`. If a newer
OneDrive no longer has the bug (the reproduction below frees the file normally), note that
here too.

## Symptoms

- A folder in `~/Library/CloudStorage/OneDrive-*` keeps using disk space after
  "Free Up Space", no matter how often it's clicked.
- "Always Keep on This Device" shows as off. Usually it was on at some point in the past.
- Toggling "Always Keep" re-downloads files and can temporarily double usage.
- OneDrive's "Free Up Space" on a folder downloads files instead of freeing them, a few at
  a time in the background, or freed files come back on their own later.

## Root cause (confirmed)

Each OneDrive file has records in three places:

| Where | Field | Normal | Stuck |
|---|---|---|---|
| macOS `fileproviderd`: `~/Library/Application Support/FileProvider/<domain-uuid>/database/db`, table `FP_snapshot` | `decoration_content_policy` | 1 (download on demand) | **3** (keep downloaded) |
| OneDrive `OneDrive.dat` (`~/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite/OneDrive.noindex/`), table `dbfs_files` | `capabilities` | **-1** (default) | **47** |
| OneDrive `SyncEngineDatabase.db` (`~/Library/Containers/com.microsoft.OneDrive-mac/Data/Library/Application Support/OneDrive/settings/Personal/`), table `od_ClientFile_Records` | `lastKnownPinState` | empty or 0 | 2 after a Free Up; 1 while pinned |

**What happens:**

1. "Always Keep on This Device" sets pin state 1 and `capabilities` **47**. Read as macOS
   item capabilities, that is read, write, reparent, rename and delete, without "allows
   evicting" or "trashing".
2. Unpinning, or OneDrive's "Free Up Space", sets pin state 2 but **leaves `capabilities`
   at 47**.
3. With 47, OneDrive tells macOS **`keepDownloaded`** for the file on every Free Up.
   macOS sets policy 3 and downloads it, or refuses to evict it.

**Proof:** in the macOS system log, OneDrive's item updates carry the policy it sends:
`FP snapshot mutation: update<s:<id> … cp:keepDownloaded …> diffs:…contentPolicy why:item changed`,
followed by `fetch-content(<id>) why:materialization|itemChangedRemotely|backgroundWork`.

**Evidence:**

| Case | `capabilities` | What OneDrive sent on its own Free Up |
|---|---|---|
| 229 / 243 files | 47 | `keepDownloaded` (all 47s), and downloads started |
| 58 / 44 / 11 files | -1 | `lazy` (all) |
| The same 287 files after resetting 47 → -1 | -1 | `lazy` for all 294 updates, 0 downloads |

**Single-file reproduction:**

1. "Always Keep" on one file (pin 1, caps 47, `keepDownloaded`).
2. OneDrive's Free Up Space: pin 2, caps still 47, `keepDownloaded` again. It stays on
   disk.
3. Repair: caps -1 and macOS policy 1, then evict.
4. OneDrive's Free Up Space: `lazy`, nothing downloads.

**Not the cause** (tested and ruled out):

- **Pin state:** 229 files at pin state 0 still got `keepDownloaded` while caps was 47.
  OneDrive also resets pin state to empty by itself after restarts.
- **The "freed" flag** (`state_flags` bit 8: 35 normal, 43 marked).
- `in_materialized_set`, which doesn't track what's on disk.
- **Download history:** it correlates, because only downloaded files were ever pinned,
  but it isn't the cause.

## Diagnose (read-only)

The OneDrive databases are readable without Full Disk Access. Use read-only URIs or work
on copies. Find files with leftover pin capabilities per folder: caps 47 but not
currently pinned.

```bash
OD="$HOME/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite/OneDrive.noindex/OneDrive.dat"
SE="$HOME/Library/Containers/com.microsoft.OneDrive-mac/Data/Library/Application Support/OneDrive/settings/Personal/SyncEngineDatabase.db"
sqlite3 "file:$SE?mode=ro" "ATTACH 'file:$OD?mode=ro' AS fp; SELECT p.name AS folder, count(*) FROM fp.dbfs_files x JOIN fp.dbfs_files p ON p.itemid = x.parentid LEFT JOIN od_ClientFile_Records f ON f.itemIndex = x.fsid WHERE x.filetype = 0 AND x.tombstoned = 0 AND x.capabilities = 47 AND (x.state_flags & 4) = 0 AND coalesce(f.lastKnownPinState, -1) != 1 GROUP BY x.parentid ORDER BY 2 DESC LIMIT 30;"
```

If OneDrive is stopped, its databases may have no `-shm` file and `mode=ro` fails; use
`immutable=1` instead.

Intentionally pinned files are also caps 47, and they should be left alone. Recognise them
by the **pinned bit in `dbfs_files.state_flags`** (`& 4`, e.g. 37 or 101), not by pin state.
Files pinned through a parent folder keep an **empty** pin state but still have the bit.
Leftovers have flags 35 (no pinned bit) and caps 47.

On the macOS side, from a Full Disk Access terminal:

```bash
D="<folder>"; du -sh "$D"; echo "cloud-only: $(find "$D" -type f -flags dataless | wc -l)   on disk: $(find "$D" -type f ! -flags dataless | wc -l)"
fileproviderctl evaluate "<a file in it>" | grep -E "isKeepDownloaded|isUploaded =|Content Policy|itemIdentifier"
```

It's this bug when a file shows `isUploaded = 1`, `isKeepDownloaded = 0` and
`Content Policy: 3` (with `Inherited Content Policy: 1`). `fileproviderctl check` does
not catch it.

## Ask the system log (read-only, no Full Disk Access needed)

This is the most reliable evidence: it shows exactly what OneDrive told macOS and why
macOS downloaded something. Use `/usr/bin/log`, because in zsh `log` is a built-in.

```bash
/usr/bin/log show --style compact --start "<YYYY-MM-DD HH:MM:SS>" --end "<…>" \
  --predicate 'process == "fileproviderd"' > /tmp/fp_log.txt
grep "FP snapshot mutation: update" /tmp/fp_log.txt | grep -o 'cp:[a-zA-Z]*' | sort | uniq -c   # policies OneDrive sent
grep "persist job: <FP.*fetch-content(" /tmp/fp_log.txt                                         # downloads + "why:"
```

Each `update<s:<id> p:<parent id> …>` line carries OneDrive's item ID, the same as
`dbfs_files.itemid`, so it can be matched to OneDrive's records. After a Free Up on a
healthy folder you should see only `cp:lazy` and no `fetch-content`.

## Other findings

- **Cloud-only files at macOS policy 3 are time bombs.** Nothing happens until macOS
  re-checks them (a `fileproviderd` or OneDrive restart, OneDrive's own Free Up), then
  they download. Fix the macOS policy before any restart.
- **The policy drops back to 1 after a file finishes downloading,** so by the time you look
  the evidence may be gone. Use the system log.
- **While OneDrive is running, it usually marks freed files** (pin state 2, bit 8). With
  OneDrive stopped during eviction, no marks were created. Marks are harmless once caps
  is -1: they're OneDrive's normal "freed" state.
- **Stopping OneDrive while files are downloading may fail.** `fileproviderd` relaunches
  the `OneDrive File Provider` helper to finish the queued downloads. Fixing the macOS
  policy first, then restarting `fileproviderd`, cancels the queue.
- **OneDrive's resource reports** (`/Library/Logs/DiagnosticReports/OneDrive_*.diag`)
  flagged heavy disk writes during these download bursts. Those are not crashes.

## Don't

- Don't toggle "Always Keep on This Device" on files you'll want to free later: unpinning
  leaves caps 47, and OneDrive's own Free Up Space then can't free them.
- Don't reset or unlink OneDrive: it drops every locally kept file, which can be hundreds
  of GB of intentionally downloaded data.
- Don't copy the folder on the web and delete the original unless the user asks for that
  specifically.
- `fileproviderctl` has no `evict` command, and `fileproviderctl repair` doesn't help.
- Don't edit OneDrive's databases while OneDrive is running. Quit OneDrive, stop the
  `OneDrive File Provider` helper and back up both databases first.
- Don't touch intentionally pinned files: pinned bit set in `state_flags` (`& 4`), whether
  pin state is 1 or empty (folder-level pins). They are caps 47 and policy 3 by design.

## Working with the user

Agents usually can't do the macOS part themselves. macOS blocks sandboxed and app
processes from `~/Library/Application Support/FileProvider` and often from
`~/Library/CloudStorage` ("Operation not permitted"). Give the user commands to run in a
terminal that has Full Disk Access, and explain each step.

OneDrive's databases and the system log are readable by the agent. Work on copies or
read-only URIs.

This user wants the smallest intervention that works, wants to be told the plan before
anything changes, and wants runs to log the full picture so nobody has to take snapshots
by hand. Their claims and doubts have often been right, so take them seriously. Test a
hypothesis before presenting it as fact; several plausible ones failed here.

## Fix

### Whole folder (normal path)

```bash
zsh "<skill dir>/scripts/fix_folder.sh" "<folder>"
```

Run it in a terminal with Full Disk Access. It works only for
`~/Library/CloudStorage/OneDrive-Personal`, the verified account layout. It:

1. Checks the versions, collects the item IDs of **every** file in the folder (downloaded
   or cloud-only, `.DS_Store` skipped), and records a `before` snapshot.
2. Sets intentionally pinned files aside (see below). It stops if every remaining file is
   cloud-only with clean records. Otherwise it stops OneDrive (app and helper) and backs up
   both of its databases to
   `~/onedrive-free-up-fix-backups/<timestamp>/` (newest 5 kept).
3. Sets macOS policy 3 → 1 for all of them, which defuses time bombs. If anything
   changed, it restarts `fileproviderd` and waits 30 s.
4. Evicts the downloaded files with `scripts/evict.swift`. With nothing downloaded, it
   repairs records only.
5. Repairs OneDrive's records for those files: **capabilities 47 → -1** (the fix), pin
   state 2/empty → 0, bit 8 off. Then it runs integrity checks. It only does this when the
   helper is really stopped.
6. Starts OneDrive (always, even if a step fails), waits 10 s, and records the `final`
   state.

**Intentionally pinned files are skipped.** These are files with the pinned bit in
`state_flags`, set directly or inherited from a pinned folder. They're listed as `skipped:`
in the log, and nothing about them changes. Freeing them without a real unpin would leave
OneDrive believing they're pinned, and it would push them back. To free a pinned folder,
turn off "Always Keep on This Device" in OneDrive first, then run the script.

Afterwards, OneDrive's own Free Up Space works normally on the repaired files until they're
pinned again.

Every run writes `~/onedrive-free-up-fix-logs/run-<stamp>.tsv`:

- one line per file per stage (`before`, `after-macos-fix`, `after-evict`,
  `after-onedrive-fix`, `final`) with location, bytes on disk, macOS policy, OneDrive pin
  state, flags and capabilities;
- timestamped `event` lines for every step, including the item IDs for rollback;
- a `problem:` line for each file still on disk, at policy 3, marked or at caps 47 at
  the end.

When reviewing a run, read this log first, then the system log for anything after it.

### Single-file test (always on a new version)

Ask the user for an expendable file and run `fix_folder.sh` on its folder, or do it by
hand. To do it by hand, get the item ID with
`fileproviderctl evaluate "<file>" | grep itemIdentifier`, then:

```bash
F="<file>"; S="<skill dir>/scripts"
fileproviderctl evaluate "$F" | grep "Content Policy:"
python3 -I "$S/fp_set_policy.py" auto <itemIdentifier>
killall fileproviderd; sleep 10
swift "$S/evict.swift" "$F"; sleep 30; du -h "$F"; fileproviderctl evaluate "$F" | grep -E "isDownloaded =|Content Policy:"
```

Then reset caps 47 → -1 for that item in `OneDrive.dat`, with OneDrive stopped. Use the
same SQL as the script.

Finally, verify with the reproduction: OneDrive's own Free Up Space on the file, then the
system log should show `cp:lazy` and no `fetch-content`.

### Possible improvement (not tested yet)

`fix_folder.sh` also treats OneDrive's "freed" mark (`state_flags` bit 8) and an empty or 2
pin state as needing repair. It clears the marks and sets pin state to 0. These aren't the
cause. With `capabilities` -1, OneDrive's own Free Up Space sent `lazy` whatever the pin state
or mark was. The mark is OneDrive's normal "freed" bookkeeping: after OneDrive's own Free Up
Space on a repaired folder, every file gets it again, and a rerun "repairs" all of them for
nothing.

The idea:

- count only macOS policy 3 and `capabilities` 47 as needing repair (plus downloaded files to
  free);
- leave pin state and the mark alone;
- keep logging them.

Not implemented or tested yet; propose it to the user before changing the script.

## Time bombs: find and defuse

Find cloud-only files at policy 3 anywhere (read-only, Full Disk Access terminal):

```bash
DB="$HOME/Library/Application Support/FileProvider/<domain-uuid>/database/db"
sqlite3 -header "file:$DB?mode=ro" "SELECT p.decoration_content_policy AS policy, s.metadata_is_dataless AS cloud_only, count(*) FROM FP_snapshot p JOIN reconciliation_table r ON r.fp_id = p.id JOIN FS_snapshot s ON s.id = r.fs_id WHERE p.metadata_kind = 0 GROUP BY 1, 2;"
```

A `3 | 1` row means time bombs. To list them by folder, group by `p.parent_id` and select
`(SELECT filename FROM FP_snapshot WHERE id = p.parent_id)`. Defuse them by passing
their IDs (`p.id`) to `fp_set_policy.py auto <ids…>`, then `killall fileproviderd`, and
repair caps with `fix_folder.sh` so OneDrive doesn't push them back.

If files are actively downloading, the quickest containment is `fp_set_policy.py` for every
file ID in the affected folder (only rows at 3 change), then `killall fileproviderd`.
OneDrive's `OneDrive.dat` maps folders to file IDs (`dbfs_files.itemid` and `parentid`).

## Rollback

- **macOS:**
  ```bash
  python3 -I "<skill dir>/scripts/fp_set_policy.py" --from 1 --to 3 auto <ids…>; killall fileproviderd
  ```
- **OneDrive:** quit OneDrive and stop its helper. Restore `OneDrive.dat*` and
  `SyncEngineDatabase.db*` from `~/onedrive-free-up-fix-backups/<timestamp>/`, then start
  OneDrive.

## Afterwards

Once a folder is repaired, OneDrive's own Free Up Space works there. Re-pinning files
("Always Keep") brings the trap back; run `fix_folder.sh` again after unpinning. Suggest the
user reports the bug to Microsoft (OneDrive → Help & Settings → Send Feedback): "after
unpinning, dbfs capabilities stay 47 and Free Up Space sends contentPolicy keepDownloaded".

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
