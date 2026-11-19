#!/bin/bash
# Build a minimally-modified BTicino C300X rootfs from YOUR OWN copy of the stock
# btweb_only.ext4.gz. Runs offline on macOS/Linux (uses debugfs: no mount, no root).
# Supports firmware 2.0.2 (kernel 4.9) and 3.0.6 (kernel 5.15).
#
#   make-minimal-mod.sh <btweb_only.ext4.gz> <out.ext4> \
#       [--password PW] [--json-dir DIR] [--no-ssh] [--keep-updates]
#
# Changes (everything else stays byte-identical to stock):
#   1. root password in /etc/shadow. Default "password". The hash method is matched
#      to stock automatically ($6$/SHA-512 on 2.0.2, $5$/SHA-256 on 3.0.6).
#   2. An INDEPENDENT ssh daemon: /etc/init.d/c300x-ssh + /etc/rc5.d/S99c300x-ssh.
#      It runs dropbear with its own pidfile (/var/run/c300x-ssh.pid) plus a watchdog
#      and persistent host keys on p7. bt_daemon's hal_stopSSH() only kills the FACTORY
#      dropbear pidfile, so it can't stop this one. An ECDSA host key is generated so
#      modern OpenSSH clients connect without legacy (-o HostKeyAlgorithms=+ssh-rsa) opts.
#      (--no-ssh skips this.)
#   3. Firmware auto-updater DISABLED: WebDispatcher= blanked and autoInstall=0 in
#      /home/bticino/cfg/SmartToolHLS. SmartToolHLS then self-disables the update check
#      ("web dispatcher not set -> disable upgrade check"). (--keep-updates skips this.)
#   4. Optional --json-dir DIR: copies CPython 2.7 Lib/json into /usr/lib/python2.7/json
#      (device python lacks json; the HA integration installer needs it). 2.0.2 only.
#
# IMPORTANT: when writing files with debugfs, the `sif ... mode` value is the FULL
# st_mode incl. the type bits: 0100xxx for a regular file. A value like 010xxx is
# S_IFIFO and silently turns the file into a FIFO (corrupts the fs). Always 0100xxx.
set -euo pipefail

IN="${1:?usage: $0 <btweb_only.ext4.gz> <out.ext4> [--password PW] [--json-dir DIR] [--no-ssh] [--keep-updates]}"
OUT="${2:?usage: $0 <btweb_only.ext4.gz> <out.ext4> [--password PW] [--json-dir DIR] [--no-ssh] [--keep-updates]}"
shift 2
PW="password"; JSON_DIR=""; DO_SSH=1; DO_UPDDIS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --password)     PW="$2"; shift 2 ;;
    --json-dir)     JSON_DIR="$2"; shift 2 ;;
    --no-ssh)       DO_SSH=0; shift ;;
    --keep-updates) DO_UPDDIS=0; shift ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done

for t in debugfs e2fsck openssl gunzip python3; do
  command -v "$t" >/dev/null || { echo "missing tool: $t (macOS: brew install e2fsprogs, add its sbin to PATH)"; exit 1; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
gunzip -c "$IN" > "$OUT"

# Validate it is the NORMAL rootfs (not recovery): it must carry the GUI binary.
debugfs -R "stat /home/bticino/bin/gui/BtClass" "$OUT" 2>&1 | grep -q 'Type: regular' \
  || { echo "this does not look like the normal 'btweb_only' rootfs (no /home/bticino/bin/gui/BtClass)"; exit 1; }
SZ="$(stat -f %z "$OUT" 2>/dev/null || stat -c %s "$OUT")"
case "$SZ" in
  1073741824) echo "detected 2.0.2-era rootfs (1 GiB)";;
  1024000000) echo "detected 3.0.6-era rootfs (1000 MiB)";;
  *) echo "note: unexpected rootfs size $SZ bytes (continuing; BtClass present)";;
esac

# ---- 1. root password, hash method matched to stock ---------------------------
debugfs -R "cat /etc/shadow" "$OUT" 2>/dev/null > "$TMP/shadow.old"
case "$(head -1 "$TMP/shadow.old")" in
  root:\$6\$*) METHOD=-6 ;;   # SHA-512 (2.0.2)
  root:\$5\$*) METHOD=-5 ;;   # SHA-256 (3.0.6)
  *)           METHOD=-6 ;;   # sane default
esac
HASH="$(openssl passwd "$METHOD" "$PW")"
python3 - "$TMP/shadow.old" "$TMP/shadow.new" "$HASH" <<'PY'
import sys
src, dst, h = sys.argv[1:4]
lines = open(src).read().split('\n')
assert lines[0].startswith('root:'), 'unexpected shadow format'
f = lines[0].split(':'); f[1] = h; lines[0] = ':'.join(f)
open(dst, 'w').write('\n'.join(lines))
PY

# ---- 2. independent ssh daemon (bt_daemon can't stop it) ----------------------
if [ "$DO_SSH" = 1 ]; then
cat > "$TMP/c300x-ssh" <<'SSHEOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          c300x-ssh
# Default-Start:     5
# Short-Description: Independent dropbear instance that bt_daemon does not stop
### END INIT INFO
# bt_daemon calls hal_stopSSH()->"/etc/init.d/dropbear stop" when <abil_ssh> is
# absent/0 in /var/tmp/conf.xml (at boot and on every config resync). That stop
# targets the factory pidfile /var/run/dropbear.pid, so a dropbear started here
# with its OWN pidfile survives. A watchdog restarts it if it dies anyway. Host
# keys live on p7 (survive reboots and p6 rewrites); an ECDSA key is offered so
# modern SSH clients need no legacy options.
DAEMON=/usr/sbin/dropbear
KEYGEN=/usr/sbin/dropbearkey
KEYDIR=/home/bticino/cfg/extra/dropbear
PIDFILE=/var/run/c300x-ssh.pid
WATCHPID=/var/run/c300x-ssh-watchdog.pid
PORT=22
INTERVAL=15
gen_keys() {
    mkdir -p "$KEYDIR" && chmod 700 "$KEYDIR"
    for t in rsa ecdsa; do
        k="$KEYDIR/dropbear_${t}_host_key"
        [ -s "$k" ] || { rm -f "$k"; "$KEYGEN" -t "$t" -f "$k" >/dev/null 2>&1; }
    done
}
running() { [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
start_daemon() {
    running && return 0
    rm -f "$PIDFILE"
    "$DAEMON" -P "$PIDFILE" -p "$PORT" \
        -r "$KEYDIR/dropbear_rsa_host_key" \
        -r "$KEYDIR/dropbear_ecdsa_host_key"
}
watchdog() { while :; do sleep "$INTERVAL"; running || start_daemon; done; }
case "$1" in
  start)
    gen_keys; start_daemon
    if ! { [ -s "$WATCHPID" ] && kill -0 "$(cat "$WATCHPID")" 2>/dev/null; }; then
        watchdog </dev/null >/dev/null 2>&1 & echo $! > "$WATCHPID"
    fi ;;
  stop)
    [ -s "$WATCHPID" ] && kill "$(cat "$WATCHPID")" 2>/dev/null
    running && kill "$(cat "$PIDFILE")"; rm -f "$PIDFILE" "$WATCHPID" ;;
  status) running && echo "running (pid $(cat "$PIDFILE"))" || { echo stopped; exit 1; } ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  *) echo "Usage: $0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
exit 0
SSHEOF
fi

# ---- 3. disable the firmware auto-updater -------------------------------------
if [ "$DO_UPDDIS" = 1 ]; then
  debugfs -R "cat /home/bticino/cfg/SmartToolHLS" "$OUT" 2>/dev/null > "$TMP/smarttool" || true
  if [ -s "$TMP/smarttool" ]; then
    python3 - "$TMP/smarttool" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'(?m)^WebDispatcher=.*$', 'WebDispatcher=', s)
s = re.sub(r'(?m)^autoInstall=.*$', 'autoInstall=0', s)
open(p, 'w').write(s)
PY
  else
    DO_UPDDIS=0; echo "note: /home/bticino/cfg/SmartToolHLS not found; skipping update-disable"
  fi
fi

# ---- apply everything with debugfs -------------------------------------------
{
  echo "rm /etc/shadow"
  echo "write $TMP/shadow.new /etc/shadow"
  echo "sif /etc/shadow mode 0100640"
  if [ "$DO_SSH" = 1 ]; then
    echo "write $TMP/c300x-ssh /etc/init.d/c300x-ssh"
    echo "sif /etc/init.d/c300x-ssh mode 0100755"
    echo "symlink /etc/rc5.d/S99c300x-ssh ../init.d/c300x-ssh"
  fi
  if [ "$DO_UPDDIS" = 1 ]; then
    echo "rm /home/bticino/cfg/SmartToolHLS"
    echo "write $TMP/smarttool /home/bticino/cfg/SmartToolHLS"
    echo "sif /home/bticino/cfg/SmartToolHLS mode 0100644"
  fi
  if [ -n "$JSON_DIR" ]; then
    echo "mkdir /usr/lib/python2.7/json"
    for f in "$JSON_DIR"/*.py; do
      echo "write $f /usr/lib/python2.7/json/$(basename "$f")"
    done
  fi
} | debugfs -w "$OUT" >/dev/null

# ---- verify -------------------------------------------------------------------
e2fsck -fn "$OUT" >/dev/null 2>&1 || { echo "e2fsck reports problems: DO NOT flash this image"; exit 1; }
debugfs -R "cat /etc/shadow" "$OUT" 2>/dev/null | cmp -s - "$TMP/shadow.new" || { echo "shadow read-back mismatch"; exit 1; }
if [ "$DO_SSH" = 1 ]; then
  debugfs -R "stat /etc/rc5.d/S99c300x-ssh" "$OUT" 2>&1 | grep -q 'Fast link' || { echo "c300x-ssh link missing"; exit 1; }
fi
if [ "$DO_UPDDIS" = 1 ]; then
  debugfs -R "cat /home/bticino/cfg/SmartToolHLS" "$OUT" 2>/dev/null | grep -q '^WebDispatcher=$' || { echo "update-disable not applied"; exit 1; }
fi
echo "OK: $OUT"
echo "  password method: ${METHOD#-}  ssh: $DO_SSH  updates-disabled: $DO_UPDDIS"
shasum -a 256 "$OUT" 2>/dev/null || sha256sum "$OUT"
