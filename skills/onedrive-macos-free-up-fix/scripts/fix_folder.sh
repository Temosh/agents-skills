#!/bin/zsh
# Free a OneDrive folder whose files are stuck at Content Policy 3 ("keep downloaded").
# Usage: zsh fix_folder.sh "<folder inside ~/Library/CloudStorage/OneDrive-Personal>"
# Must run in a terminal that has Full Disk Access (macOS protects the FileProvider database).
#
# Flow: stop OneDrive and back up its databases -> macOS policy 3 -> 1 for every file in the
# folder (cloud-only too) -> restart fileproviderd -> evict downloaded files -> clear OneDrive's
# "freed" marks (pin state 2, flag bit 8) -> start OneDrive -> report what came back.
set -e
DIR="${1:?usage: fix_folder.sh <OneDrive folder>}"
DIR="${DIR:A}"
HERE="${0:A:h}"
PROVEN_ONEDRIVE="26.168.0830"
PROVEN_MACOS="25G83"
SYNC_ENGINE_DB="$HOME/Library/Containers/com.microsoft.OneDrive-mac/Data/Library/Application Support/OneDrive/settings/Personal/SyncEngineDatabase.db"
ONEDRIVE_DB="$HOME/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite/OneDrive.noindex/OneDrive.dat"
BACKUP_ROOT="$HOME/onedrive-free-up-fix-backups"
BACKUPS_TO_KEEP=5
STAMP=$(date +%Y%m%d-%H%M%S)
IDS_FILE="$HOME/onedrive-free-up-fix-ids-$STAMP.txt"

case "$DIR" in
  "$HOME/Library/CloudStorage/OneDrive-Personal/"*) ;;
  *) echo "Only verified for folders inside ~/Library/CloudStorage/OneDrive-Personal"; exit 1 ;;
esac

OD_VER=$(defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleShortVersionString)
OS_BUILD=$(sw_vers -buildVersion)
echo "== OneDrive $OD_VER, macOS build $OS_BUILD (proven on OneDrive $PROVEN_ONEDRIVE, macOS $PROVEN_MACOS)"
if [[ "$OD_VER" != "$PROVEN_ONEDRIVE" || "$OS_BUILD" != "$PROVEN_MACOS" ]]; then
  echo "!! Versions differ from the proven ones. Re-verify on ONE expendable file first (see SKILL.md)."
  read -q "?Continue anyway? [y/N] " || { echo; exit 1; }
  echo
fi

echo "== before"; du -sh "$DIR"

echo "== collecting item IDs (every file, downloaded or cloud-only; .DS_Store skipped)"
ids=(); downloaded=()
while IFS= read -r -d '' f; do
  id=$(fileproviderctl evaluate "$f" 2>/dev/null | awk -F' = ' '/itemIdentifier =/ {gsub(/[;"]/, "", $2); print $2; exit}')
  if [[ -n "$id" ]]; then ids+=("$id"); fi
  if [[ -z "$(find "$f" -flags dataless)" ]]; then downloaded+=("$f"); fi
done < <(find "$DIR" -type f ! -name .DS_Store -print0)
echo "files: ${#ids}   downloaded: ${#downloaded}"
(( ${#downloaded} )) || { echo "nothing to free"; exit 0; }
print -l -- $ids > "$IDS_FILE"
echo "== IDs saved for rollback: $IDS_FILE"

stop_onedrive() {
  osascript -e 'quit app "OneDrive"' >/dev/null 2>&1 || true
  for i in {1..15}; do pgrep -x OneDrive >/dev/null || break; sleep 1; done
  pkill -f "OneDrive File Provider" 2>/dev/null || true
  sleep 2
  ! pgrep -f "/Applications/OneDrive.app/" >/dev/null
}
ONEDRIVE_STARTED=0
start_onedrive() { open -a OneDrive; ONEDRIVE_STARTED=1; }
trap '(( ONEDRIVE_STARTED )) || start_onedrive' EXIT  # always bring OneDrive back

echo "== stopping OneDrive"
stop_onedrive || { echo "couldn't stop OneDrive, nothing changed"; exit 1; }

echo "== backing up OneDrive's databases"
BACKUP="$BACKUP_ROOT/$STAMP"
mkdir -p "$BACKUP"
cp -p "$SYNC_ENGINE_DB"* "$ONEDRIVE_DB"* "$BACKUP/"
old=("$BACKUP_ROOT"/*(/On))  # newest first
if (( ${#old} > BACKUPS_TO_KEEP )); then rm -rf -- "${(@)old[BACKUPS_TO_KEEP+1,-1]}"; fi
echo "backup: $BACKUP"

echo "== macOS records: policy 3 -> 1"
out=$(python3 -I "$HERE/fp_set_policy.py" auto $ids)
print -r -- "$out"
FPDB=$(print -r -- "$out" | sed -n 's/^database: //p')
changed=$(print -r -- "$out" | sed -n 's/^updated \([0-9]*\) of.*/\1/p')
if (( ${changed:-0} > 0 )); then
  echo "== restarting fileproviderd so it reloads its records, then waiting 30s"
  killall fileproviderd || true; sleep 30
fi

echo "== evicting downloaded files with the macOS call (not OneDrive's menu)"
EVICT_LOG="$IDS_FILE.evict.log"
print -N -- $downloaded | xargs -0 swift "$HERE/evict.swift" > "$EVICT_LOG" || true
echo "evicted: $(grep -c '^evicted:' "$EVICT_LOG")   failed: $(grep -c '^FAILED' "$EVICT_LOG")"

echo "== OneDrive records: clear 'freed' marks (pin state 2 -> 0, flag bit 8 off)"
LIST=${(j:,:)${(M)ids:#<->}}  # numeric IDs only
if [[ -z "$LIST" ]]; then
  echo "no numeric item IDs, OneDrive records left alone"
elif stop_onedrive; then
  sqlite3 "$SYNC_ENGINE_DB" <<EOF
.bail on
ATTACH '$ONEDRIVE_DB' AS fp;
BEGIN IMMEDIATE;
UPDATE od_ClientFile_Records SET lastKnownPinState = 0
 WHERE lastKnownPinState = 2 AND itemIndex IN (SELECT fsid FROM fp.dbfs_files WHERE itemid IN ($LIST));
SELECT 'pin state 2 -> 0: ' || changes();
UPDATE fp.dbfs_files SET state_flags = state_flags & ~8
 WHERE itemid IN ($LIST) AND filetype = 0 AND (state_flags & 8) != 0 AND (state_flags & 32) != 0;
SELECT 'mark cleared: ' || changes();
COMMIT;
PRAGMA main.integrity_check;
PRAGMA fp.integrity_check;
EOF
else
  echo "!! OneDrive's helper is still running; its records were NOT changed"
fi

echo "== starting OneDrive, waiting 60s to catch anything coming back"
start_onedrive; sleep 60

echo "== after"; du -sh "$DIR"
echo "cloud-only: $(find "$DIR" -type f ! -name .DS_Store -flags dataless | wc -l)   on disk: $(find "$DIR" -type f ! -name .DS_Store ! -flags dataless | wc -l)"
if [[ -n "$FPDB" && -n "$LIST" ]]; then
  blobs=(); for i in ${(M)ids:#<->}; do blobs+=("CAST('$i' AS BLOB)"); done
  BLOBS=${(j:,:)blobs}
  echo "still at policy 3: $(sqlite3 -readonly "$FPDB" "SELECT count(*) FROM FP_snapshot WHERE decoration_content_policy = 3 AND id IN ($BLOBS);")"
fi
df -h /System/Volumes/Data | tail -1
