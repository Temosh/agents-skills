"""Change the content policy of File Provider items in macOS's fileproviderd database.

Usage:
  python3 -I fp_set_policy.py <db path|auto> <item id> [<item id> ...]       # 3 -> 1 (fix)
  python3 -I fp_set_policy.py --from 1 --to 3 <db path> <item id> [...]      # rollback

"auto" finds the fileproviderd database that contains the first item id.
Only rows currently at --from are changed, all in one transaction.
"""
import argparse
import glob
import os
import sqlite3
import sys
import time


def next_anchor(*_):
    # Not expected to fire for this update; abort the transaction if it does.
    raise RuntimeError("NEXT_ANCHOR called - aborting, nothing changed")


parser = argparse.ArgumentParser()
parser.add_argument("--from", dest="src", type=int, default=3)
parser.add_argument("--to", dest="dst", type=int, default=1)
parser.add_argument("db")
parser.add_argument("ids", nargs="+")
args = parser.parse_args()


def find_db(item_id):
    pattern = os.path.expanduser("~/Library/Application Support/FileProvider/*/database/db")
    for path in glob.glob(pattern):
        try:
            con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)
            found = con.execute("SELECT 1 FROM FP_snapshot WHERE id = ? LIMIT 1", (item_id.encode(),)).fetchone()
            con.close()
        except sqlite3.Error:
            continue
        if found:
            return path
    sys.exit("no FileProvider database contains these items (Full Disk Access granted?)")


if args.db == "auto":
    args.db = find_db(args.ids[0])
    print(f"database: {args.db}")

# Policy 3 items are stored with metadata_is_evictable=5, normal (policy 1) ones with 4.
evictable = {1: 4, 3: 5}[args.dst]

db = sqlite3.connect(args.db, timeout=10)
# fileproviderd's triggers stamp a change time (ns since epoch) via this function.
db.create_function("PROPAGATION_DATE_CHANGED", 2, lambda kind, item: time.time_ns())
db.create_function("NEXT_ANCHOR", 1, next_anchor)
try:
    with db:
        changed = 0
        for item_id in args.ids:
            cur = db.execute(
                "UPDATE FP_snapshot SET decoration_content_policy = ?, metadata_is_evictable = ? "
                "WHERE id = ? AND decoration_content_policy = ?",
                (args.dst, evictable, item_id.encode(), args.src),
            )
            changed += cur.rowcount
    print(f"updated {changed} of {len(args.ids)} items ({args.src} -> {args.dst})")
finally:
    db.close()
