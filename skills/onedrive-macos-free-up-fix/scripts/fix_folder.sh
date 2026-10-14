#!/bin/zsh
# Free a OneDrive folder whose files are stuck at Content Policy 3 ("keep downloaded").
# Usage: zsh fix_folder.sh "<folder inside ~/Library/CloudStorage/OneDrive-*>"
# Must run in a terminal that has Full Disk Access (macOS protects the FileProvider database).
set -e
DIR="${1:?usage: fix_folder.sh <OneDrive folder>}"
HERE="${0:A:h}"
PROVEN_ONEDRIVE="26.168.0830"
PROVEN_MACOS="25G83"

OD_VER=$(defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleShortVersionString)
OS_BUILD=$(sw_vers -buildVersion)
echo "== OneDrive $OD_VER, macOS build $OS_BUILD (proven on OneDrive $PROVEN_ONEDRIVE, macOS $PROVEN_MACOS)"
if [[ "$OD_VER" != "$PROVEN_ONEDRIVE" || "$OS_BUILD" != "$PROVEN_MACOS" ]]; then
  echo "!! Versions differ from the proven ones. Re-verify on ONE expendable file first (see SKILL.md)."
  read -q "?Continue anyway? [y/N] " || { echo; exit 1; }
  echo
fi

echo "== before"; du -sh "$DIR"

echo "== collecting downloaded files with Content Policy 3"
ids=(); files=()
while IFS= read -r -d '' f; do
  out=$(fileproviderctl evaluate "$f" 2>/dev/null)
  if print -r -- "$out" | grep -q '^Content Policy: 3$'; then
    ids+=$(print -r -- "$out" | awk -F' = ' '/itemIdentifier =/ {gsub(/[;"]/, "", $2); print $2; exit}')
    files+=("$f")
  fi
done < <(find "$DIR" -type f ! -flags dataless -print0)
echo "found ${#ids} stuck files"
(( ${#ids} )) || { echo "nothing to fix"; exit 0; }

# Locate fileproviderd's database for this OneDrive domain: the one that knows the first item.
FPDB=""
for db in "$HOME/Library/Application Support/FileProvider"/*/database/db; do
  n=$(sqlite3 "$db" "SELECT count(*) FROM FP_snapshot WHERE id = CAST('${ids[1]}' AS BLOB);" 2>/dev/null || echo 0)
  [[ "$n" == 1 ]] && { FPDB="$db"; break; }
done
[[ -n "$FPDB" ]] || { echo "could not find the FileProvider database (Full Disk Access?)"; exit 1; }
echo "== database: $FPDB"
IDS_FILE="$HOME/onedrive-free-up-fix-ids-$(date +%Y%m%d-%H%M%S).txt"
print -l -- $ids > "$IDS_FILE"
echo "== ids saved for rollback: $IDS_FILE"

echo "== macOS records: policy 3 -> 1"
python3 -I "$HERE/fp_set_policy.py" "$FPDB" $ids

echo "== restarting fileproviderd so it reloads its records"
killall fileproviderd || true; sleep 10
fileproviderctl evaluate "${files[1]}" | grep -E '^Content Policy:'

echo "== evicting with the macOS call (not OneDrive's menu)"
print -N -- $files | xargs -0 swift "$HERE/evict.swift" > "$IDS_FILE.evict.log" || true
echo "evicted: $(grep -c '^evicted:' "$IDS_FILE.evict.log")   failed: $(grep -c '^FAILED' "$IDS_FILE.evict.log")"
grep '^FAILED' "$IDS_FILE.evict.log" | head -5 || true

echo "== waiting 60s to catch re-downloads"; sleep 60
echo "== after"; du -sh "$DIR"
echo "cloud-only: $(find "$DIR" -type f -flags dataless | wc -l)   on disk: $(find "$DIR" -type f ! -flags dataless | wc -l)"
df -h /System/Volumes/Data | tail -1
