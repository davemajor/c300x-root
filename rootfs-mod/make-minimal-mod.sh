#!/bin/bash
# Build a minimally modified C300X 2.0.2 rootfs image from YOUR OWN copy of the
# stock btweb_only.ext4.gz. Offline: no mounting, no root needed (uses debugfs).
#
#   make-minimal-mod.sh <btweb_only.ext4.gz> <out.ext4> [--password PW] [--json-dir DIR]
#
# Changes made (everything else stays byte-identical):
#   1. root password hash in /etc/shadow            (default password: "password")
#   2. /etc/rc5.d/S98dropbear -> ../init.d/dropbear (SSH starts in runlevel 5)
#   3. /etc/rc5.d/S99dropbear-late                  (restarts dropbear 60 s after boot,
#                                                    in case bt_daemon stopped it)
#   4. optional: --json-dir DIR copies CPython 2.7 Lib/json into /usr/lib/python2.7/json
#      (the device's python has no json module; the HA integration's installer needs it)
set -euo pipefail

IN="${1:?usage: $0 <btweb_only.ext4.gz> <out.ext4> [--password PW] [--json-dir DIR]}"
OUT="${2:?usage: $0 <btweb_only.ext4.gz> <out.ext4> [--password PW] [--json-dir DIR]}"
shift 2
PW="password"; JSON_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --password) PW="$2"; shift 2 ;;
    --json-dir) JSON_DIR="$2"; shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done

for t in debugfs e2fsck openssl gunzip python3; do
  command -v "$t" >/dev/null || { echo "missing tool: $t (macOS: brew install e2fsprogs, add its sbin to PATH)"; exit 1; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
gunzip -c "$IN" > "$OUT"
[ "$(stat -f %z "$OUT" 2>/dev/null || stat -c %s "$OUT")" = 1073741824 ] \
  || { echo "expected a 1 GiB image (the normal 'btweb_only' rootfs, NOT the recovery one)"; exit 1; }
debugfs -R "stat /home/bticino/bin/gui/BtClass" "$OUT" 2>&1 | grep -q 'Type: regular' \
  || { echo "this does not look like the normal rootfs (no /home/bticino/bin/gui/BtClass)"; exit 1; }

# 1. shadow
debugfs -R "cat /etc/shadow" "$OUT" 2>/dev/null > "$TMP/shadow.old"
HASH="$(openssl passwd -6 "$PW")"
python3 - "$TMP/shadow.old" "$TMP/shadow.new" "$HASH" <<'PY'
import sys
src, dst, h = sys.argv[1:4]
lines = open(src).read().split('\n')
assert lines[0].startswith('root:'), 'unexpected shadow format'
f = lines[0].split(':'); f[1] = h; lines[0] = ':'.join(f)
open(dst, 'w').write('\n'.join(lines))
PY

# 3. late-start hook
printf '#!/bin/sh\n( sleep 60; /etc/init.d/dropbear start ) &\n' > "$TMP/S99dropbear-late"

{
  echo "rm /etc/shadow"
  echo "write $TMP/shadow.new /etc/shadow"
  echo "sif /etc/shadow mode 0100644"
  echo "symlink /etc/rc5.d/S98dropbear ../init.d/dropbear"
  echo "write $TMP/S99dropbear-late /etc/rc5.d/S99dropbear-late"
  echo "sif /etc/rc5.d/S99dropbear-late mode 0100755"
  if [ -n "$JSON_DIR" ]; then
    echo "mkdir /usr/lib/python2.7/json"
    for f in "$JSON_DIR"/*.py; do
      echo "write $f /usr/lib/python2.7/json/$(basename "$f")"
    done
  fi
} | debugfs -w "$OUT" >/dev/null

e2fsck -fn "$OUT" >/dev/null 2>&1 || { echo "e2fsck reports problems: do not flash this image"; exit 1; }
debugfs -R "cat /etc/shadow" "$OUT" 2>/dev/null | cmp -s - "$TMP/shadow.new" || { echo "shadow read-back mismatch"; exit 1; }
echo "OK: $OUT"; shasum -a 256 "$OUT" 2>/dev/null || sha256sum "$OUT"
