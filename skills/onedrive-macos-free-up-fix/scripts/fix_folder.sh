#!/bin/zsh
# Free a OneDrive folder whose files are stuck at Content Policy 3 ("keep downloaded").
# Usage: zsh fix_folder.sh "<folder inside ~/Library/CloudStorage/OneDrive-Personal>"
# Must run in a terminal that has Full Disk Access (macOS protects the FileProvider database).
#
# Flow: stop OneDrive and back up its databases -> macOS policy 3 -> 1 for every file in the
# folder (cloud-only too) -> restart fileproviderd -> evict downloaded files -> clear OneDrive's
# records (pin state 2/empty -> 0, "freed" flag bit 8 off, capabilities 47 -> -1) -> start OneDrive
# -> record the final state. Capabilities 47 is left over from "Always Keep on This Device"; with it,
# OneDrive's own Free Up Space tells macOS "keep downloaded". If nothing is downloaded but records
# need repair, the same steps run without evicting. Intentionally pinned files ("Always Keep on This
# Device", on the file or inherited from a pinned folder: OneDrive's pinned bit, state_flags & 4) are
# left alone; to free them, turn off "Always Keep" in OneDrive first.
#
# Every run writes ~/onedrive-free-up-fix-logs/run-<stamp>.tsv: one line per file per stage
# (before, after-macos-fix, after-evict, after-onedrive-fix, final) plus timestamped events and a
# "problem:" line for every file still on disk, at policy 3, marked or with capabilities 47.
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
LOG_DIR="$HOME/onedrive-free-up-fix-logs"
RUN_LOG="$LOG_DIR/run-$STAMP.tsv"

case "$DIR" in
  "$HOME/Library/CloudStorage/OneDrive-Personal/"*) ;;
  *) echo "Only verified for folders inside ~/Library/CloudStorage/OneDrive-Personal"; exit 1 ;;
esac

mkdir -p "$LOG_DIR"
print -r -- $'stage\ttime\tfile\titem_id\tlocation\tbytes_on_disk\tmacos_policy\tonedrive_pin\tonedrive_flags\tonedrive_caps' > "$RUN_LOG"

# A step of the run: printed and written to the run log.
event() {
  print -r -- "== $*"
  print -r -- "event"$'\t'"$(date +%H:%M:%S)"$'\t'"$*" >> "$RUN_LOG"
}

# Read-only query, tab-separated. A stopped OneDrive leaves its databases without a -shm
# file, which read-only WAL mode needs, so fall back to immutable mode.
q() {
  sqlite3 -separator $'\t' "file:$1?mode=ro" "$2" 2>/dev/null \
    || sqlite3 -separator $'\t' "file:$1?immutable=1" "$2" 2>/dev/null || true
}

event "run log: $RUN_LOG"
event "folder: ${DIR#$HOME/Library/CloudStorage/}"

OD_VER=$(defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleShortVersionString)
OS_BUILD=$(sw_vers -buildVersion)
event "OneDrive $OD_VER, macOS build $OS_BUILD (proven on OneDrive $PROVEN_ONEDRIVE, macOS $PROVEN_MACOS)"
if [[ "$OD_VER" != "$PROVEN_ONEDRIVE" || "$OS_BUILD" != "$PROVEN_MACOS" ]]; then
  echo "!! Versions differ from the proven ones. Re-verify on ONE expendable file first (see SKILL.md)."
  read -q "?Continue anyway? [y/N] " || { echo; event "cancelled: version mismatch"; exit 1; }
  echo
fi

echo "== collecting item IDs (every file, downloaded or cloud-only; .DS_Store skipped)"
all_files=(); all_ids=(); downloaded=()
while IFS= read -r -d '' f; do
  all_files+=("$f")
  all_ids+=("$(fileproviderctl evaluate "$f" 2>/dev/null | awk -F' = ' '/itemIdentifier =/ {gsub(/[;"]/, "", $2); print $2; exit}')")
  if [[ "$(stat -f '%Sf' "$f")" != *dataless* ]]; then downloaded+=("$f"); fi
done < <(find "$DIR" -type f ! -name .DS_Store -print0)
ids=(${(M)all_ids:#<->})  # numeric IDs only
LIST=${(j:,:)ids}
event "files: ${#all_files}   downloaded: ${#downloaded}   item ids: ${#ids}"
event "item ids in folder: ${ids[*]}"
FPDB=""
for db in "$HOME/Library/Application Support/FileProvider"/*/database/db(N); do
  if [[ -n "$LIST" && "$(q "$db" "SELECT 1 FROM FP_snapshot WHERE id = CAST('${ids[1]}' AS BLOB) LIMIT 1;")" == 1 ]]; then
    FPDB="$db"; break
  fi
done

# Intentionally pinned files: never changed (freeing them without a real unpin would leave
# OneDrive believing they're pinned).
typeset -A PINNED
if [[ -n "$LIST" ]]; then
  while IFS= read -r k; do PINNED[$k]=1; done \
    < <(q "$ONEDRIVE_DB" "SELECT itemid FROM dbfs_files WHERE itemid IN ($LIST) AND (state_flags & 4) != 0;")
fi

# Records every file's state on disk, in macOS's records and in OneDrive's records.
# Counts (and NEEDS_REPAIR) cover only files that aren't intentionally pinned.
snapshot() {
  local stage=$1 t=$(date +%H:%M:%S) k v w x i f id loc bytes st policy pin flags caps
  local -A pol fsid flg pn cap
  local ondisk=0 p3=0 marked=0 caps47=0 pinfix=0
  if [[ -n "$LIST" ]]; then
    if [[ -n "$FPDB" ]]; then
      local blobs=(); for i in $ids; do blobs+=("CAST('$i' AS BLOB)"); done
      while IFS=$'\t' read -r k v; do pol[$k]=$v; done \
        < <(q "$FPDB" "SELECT CAST(id AS TEXT), decoration_content_policy FROM FP_snapshot WHERE id IN (${(j:,:)blobs});")
    fi
    while IFS=$'\t' read -r k v w x; do fsid[$k]=$v; flg[$k]=$w; cap[$k]=$x; done \
      < <(q "$ONEDRIVE_DB" "SELECT itemid, fsid, state_flags, capabilities FROM dbfs_files WHERE itemid IN ($LIST);")
    if (( ${#fsid} )); then
      while IFS=$'\t' read -r k v; do pn[$k]=${v:-empty}; done \
        < <(q "$SYNC_ENGINE_DB" "SELECT itemIndex, coalesce(lastKnownPinState, '') FROM od_ClientFile_Records WHERE itemIndex IN (${(j:,:)${(v)fsid}});")
    fi
  fi
  for (( i = 1; i <= ${#all_files}; i++ )); do
    f=${all_files[i]}; id=${all_ids[i]}
    st=(${(s: :)$(stat -f '%Sf %b' "$f")})
    if [[ ${st[1]} == *dataless* ]]; then loc=cloud-only; else loc=on-disk; fi
    bytes=$(( ${st[-1]:-0} * 512 ))
    policy=${pol[$id]:-?}; flags=${flg[$id]:-?}; caps=${cap[$id]:-?}; pin='?'
    if [[ -n "${fsid[$id]}" ]]; then pin=${pn[${fsid[$id]}]:-?}; fi
    if [[ -z "${PINNED[$id]}" ]]; then
      if [[ $loc == on-disk ]]; then ondisk=$((ondisk + 1)); fi
      if [[ $policy == 3 ]]; then p3=$((p3 + 1)); fi
      if [[ $flags == <-> ]] && (( flags & 8 )); then marked=$((marked + 1)); fi
      if [[ $caps == 47 ]]; then caps47=$((caps47 + 1)); fi
      if [[ $pin == empty || $pin == 2 ]]; then pinfix=$((pinfix + 1)); fi
    fi
    print -r -- "$stage"$'\t'"$t"$'\t'"${f#$HOME/Library/CloudStorage/}"$'\t'"$id"$'\t'"$loc"$'\t'"$bytes"$'\t'"$policy"$'\t'"$pin"$'\t'"$flags"$'\t'"$caps" >> "$RUN_LOG"
  done
  event "$stage: $ondisk on disk, $p3 at policy 3, $marked marked by OneDrive, $caps47 with pin capabilities (of $(( ${#all_files} - ${#PINNED} )) unpinned files; ${#PINNED} pinned skipped)"
  NEEDS_REPAIR=$(( p3 + marked + caps47 + pinfix ))
}

snapshot before

# Work set: everything except intentionally pinned files.
work_ids=(); work_downloaded=()
for (( i = 1; i <= ${#all_files}; i++ )); do
  if [[ -n "${PINNED[${all_ids[i]}]}" ]]; then
    event "skipped: intentionally pinned: ${all_files[i]#$HOME/Library/CloudStorage/}"; continue
  fi
  if [[ ${all_ids[i]} == <-> ]]; then work_ids+=("${all_ids[i]}"); fi
  if [[ "$(stat -f '%Sf' "${all_files[i]}")" != *dataless* ]]; then work_downloaded+=("${all_files[i]}"); fi
done
downloaded=($work_downloaded)
WORK_LIST=${(j:,:)work_ids}
if [[ -z "$WORK_LIST" ]]; then event "nothing to do: all files are intentionally pinned"; exit 0; fi
event "item ids to change (for rollback): ${work_ids[*]}"

# Even with nothing downloaded, records may need repair: macOS policy 3 (time bombs), or OneDrive
# pin state empty/2, its mark or capabilities 47 (its own Free Up Space then pushes "keep downloaded").
if (( ${#downloaded} == 0 && NEEDS_REPAIR == 0 )); then
  event "nothing to do: all unpinned files cloud-only with clean records"; exit 0
fi
(( ${#downloaded} )) || event "nothing to free, repairing records only"

stop_onedrive() {
  osascript -e 'quit app "OneDrive"' >/dev/null 2>&1 || true
  for i in {1..15}; do pgrep -x OneDrive >/dev/null || break; sleep 1; done
  pkill -f "OneDrive File Provider" 2>/dev/null || true
  sleep 2
  ! pgrep -f "/Applications/OneDrive.app/" >/dev/null
}
ONEDRIVE_STARTED=0
start_onedrive() { open -a OneDrive; ONEDRIVE_STARTED=1; }
trap '(( ONEDRIVE_STARTED )) || { start_onedrive; event "OneDrive started (early exit)"; }' EXIT

stop_onedrive || { event "couldn't stop OneDrive, nothing changed"; exit 1; }
event "OneDrive stopped"

BACKUP="$BACKUP_ROOT/$STAMP"
mkdir -p "$BACKUP"
cp -p "$SYNC_ENGINE_DB"* "$ONEDRIVE_DB"* "$BACKUP/"
old=("$BACKUP_ROOT"/*(/On))  # newest first
if (( ${#old} > BACKUPS_TO_KEEP )); then rm -rf -- "${(@)old[BACKUPS_TO_KEEP+1,-1]}"; fi
event "OneDrive backup: $BACKUP"

out=$(python3 -I "$HERE/fp_set_policy.py" auto $work_ids)
event "fp_set_policy: ${out//$'\n'/ | }"
FPDB=$(print -r -- "$out" | sed -n 's/^database: //p')
changed=$(print -r -- "$out" | sed -n 's/^updated \([0-9]*\) of.*/\1/p')
if (( ${changed:-0} > 0 )); then
  killall fileproviderd || true
  event "fileproviderd restarted, waiting 30 s"
  sleep 30
fi
snapshot after-macos-fix

EVICT_LOG="$LOG_DIR/run-$STAMP.evict.log"
: > "$EVICT_LOG"
if (( ${#downloaded} )); then
  print -N -- $downloaded | xargs -0 swift "$HERE/evict.swift" > "$EVICT_LOG" || true
fi
grep '^FAILED' "$EVICT_LOG" | while IFS= read -r line; do event "evict ${line#FAILED: $HOME/Library/CloudStorage/}"; done || true
event "evicted $(grep -c '^evicted:' "$EVICT_LOG" || true) of ${#downloaded} downloaded files"
snapshot after-evict

if [[ -z "$WORK_LIST" ]]; then
  event "no numeric item IDs, OneDrive records left alone"
elif stop_onedrive; then
  event "OneDrive stopped again for its records"
  res=$(sqlite3 "$SYNC_ENGINE_DB" <<EOF
.bail on
ATTACH '$ONEDRIVE_DB' AS fp;
BEGIN IMMEDIATE;
UPDATE od_ClientFile_Records SET lastKnownPinState = 0
 WHERE lastKnownPinState = 2 AND itemIndex IN (SELECT fsid FROM fp.dbfs_files WHERE itemid IN ($WORK_LIST));
SELECT 'pin state 2 -> 0: ' || changes();
UPDATE od_ClientFile_Records SET lastKnownPinState = 0
 WHERE lastKnownPinState IS NULL AND itemIndex IN (SELECT fsid FROM fp.dbfs_files WHERE itemid IN ($WORK_LIST));
SELECT 'pin state empty -> 0: ' || changes();
UPDATE fp.dbfs_files SET state_flags = state_flags & ~8
 WHERE itemid IN ($WORK_LIST) AND filetype = 0 AND (state_flags & 8) != 0 AND (state_flags & 32) != 0;
SELECT 'mark cleared: ' || changes();
UPDATE fp.dbfs_files SET capabilities = -1
 WHERE itemid IN ($WORK_LIST) AND filetype = 0 AND capabilities = 47;
SELECT 'capabilities 47 -> -1: ' || changes();
COMMIT;
PRAGMA main.integrity_check;
PRAGMA fp.integrity_check;
EOF
) || true
  event "OneDrive records: ${res//$'\n'/ | }"
else
  event "OneDrive helper still running, its records NOT changed"
fi
snapshot after-onedrive-fix

start_onedrive
event "OneDrive started, waiting 10 s"  # confirms it started and kept the repaired records
sleep 10
snapshot final

# Problems: anything on disk, at policy 3 or still marked at the end.
awk -F'\t' -v pinned=",${(j:,:)${(k)PINNED}}," '$1 == "final" && index(pinned, "," $4 ",") == 0 && ($5 == "on-disk" || $7 == "3" || $10 == "47" || ($9 ~ /^[0-9]+$/ && int($9 / 8) % 2 == 1)) { print $3 }' "$RUN_LOG" \
  | while IFS= read -r path; do event "problem: $path"; done || true
event "after: $(du -sh "$DIR" | cut -f1) in folder; $(df -h /System/Volumes/Data | awk 'NR == 2 { print $4 }') free on disk"
