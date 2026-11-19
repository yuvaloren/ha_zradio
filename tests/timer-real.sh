#!/usr/bin/env bash
# tests/timer-real.sh — the nightly timer and a daemon-reload, with a REAL systemd. Not one of tests/run.sh's files: it
# makes two units on the machine it runs on (zradio-timer-test.timer and .service, in /run/systemd/system) and has
# systemd read its units again a few times. As root, on a throwaway Linux with systemd:
#   sudo ZRADIO_THROWAWAY=1 bash tests/timer-real.sh           # about 20 s
# Never on a Proxmox node or a radio VM (it refuses where pvecm or /etc/zradio is), and only with ZRADIO_THROWAWAY=1.
# Why it exists: on 2026-11-18 an update changed the nightly sync's time (a SYNC_TZ that had never been applied) on
# a pair in use. The installer put the new timer file in place, ran `systemctl daemon-reload`, and systemd ran the
# sync that second, on the VM that served: 12 s without radios. tests/t-install.sh could not show it — its systemctl
# is a fake, and it held the installer to "restart the timer after the change", which comes too late.
# Real: systemd, a timer of the same kind as zradio-sync.timer (OnCalendar, AccuracySec=1s, Persistent=false), its
# service, daemon-reload. Shown, in this order:
#   1. the timer runs at its time;
#   2. THE TRAP: its time changed to one whose turn has passed since that run, then daemon-reload — it runs at once;
#   3. THE INSTALLER'S WAY (guest/install.sh, step 5): stopped, the file changed the same way, daemon-reload, started
#      — it does not run, and waits for its new time.
# Not real: the installer itself. tests/t-install.sh holds it to the order of 3 (stop, the file, reload, start).
. "$(dirname "$0")/lib.sh"
U=zradio-timer-test
D=/run/systemd/system
skip() { echo "SKIP  $1: nothing was tested"; finish; exit; }
[ "${ZRADIO_THROWAWAY:-}" = 1 ] || skip "it changes this machine's systemd units: ZRADIO_THROWAWAY=1, as root, on a throwaway Linux"
[ "$(id -u)" = 0 ] || skip "not root"
! command -v pvecm >/dev/null 2>&1 && [ ! -e /etc/zradio ] || skip "this is a Proxmox node or a radio VM: never here"
case "$(systemctl is-system-running 2>/dev/null)" in running|degraded) ;; *) skip "no running systemd here";; esac
FIRED="$T/fired"; : > "$FIRED"
cleanup() { systemctl stop "$U.timer" "$U.service" >/dev/null 2>&1; rm -f "$D/$U.timer" "$D/$U.service"; systemctl daemon-reload >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
timer() { # timer <seconds from now, may be negative>: the timer's file with that time of day (this machine's zone)
  printf '%s\n' "# written $(date +%s.%N)" '[Unit]' 'Description=zradio: a test of the nightly timer (tests/timer-real.sh)' '[Timer]' \
    "OnCalendar=*-*-* $(date -d "@$(( $(date +%s) + $1 ))" +%H:%M:%S)" 'AccuracySec=1s' 'Persistent=false' > "$D/$U.timer"
}
runs() { grep -c . "$FIRED"; }
mkdir -p "$D"
printf '%s\n' '[Unit]' 'Description=zradio: what the test timer runs' '[Service]' 'Type=oneshot' "ExecStart=/bin/sh -c 'date +%%s >> $FIRED'" > "$D/$U.service"
case "$(date +%H%M)" in 2359|0000) sleep 90;; esac      # a time of day "a few seconds ago" must be today's

echo "-- 1. a timer runs at its time"
timer 3; systemctl daemon-reload; systemctl start "$U.timer"; sleep 6
check "the timer ran once, at its time" eq "$(runs)" 1

echo "-- 2. the trap: a new time whose turn has passed since the last run, and daemon-reload"
sleep 3; timer -2; systemctl daemon-reload; sleep 3
check "systemd runs it at the reload (if this fails, systemd no longer does that: the installer's stop and start are then harmless, and this file's reason is gone)" eq "$(runs)" 2
sleep 3; timer -30; systemctl daemon-reload; sleep 3
check "a new time BEFORE the last run: not run (its next turn is tomorrow)" eq "$(runs)" 2
sleep 1; sed -i '1s/.*/# a comment changed, the time not/' "$D/$U.timer"; systemctl daemon-reload; sleep 3
check "the file changed but not its time: not run" eq "$(runs)" 2

echo "-- 3. the installer's way: stop, the file, daemon-reload, start"
systemctl stop "$U.timer"; timer -2; systemctl daemon-reload; systemctl start "$U.timer"; sleep 3
check "the same change with the timer stopped across it: it does NOT run" eq "$(runs)" 2
check "…and it waits for its new time: active, the next run tomorrow" bash -c 'systemctl is-active --quiet "$1.timer" && [ "$(systemctl show "$1.timer" -p NextElapseUSecRealtime --value | cut -d" " -f2)" = "$(date -d tomorrow +%F)" ]' _ "$U"
check "…with no memory of a last run (what made the reload run it)" eq "$(systemctl show "$U.timer" -p LastTriggerUSec --value)" ""
finish
