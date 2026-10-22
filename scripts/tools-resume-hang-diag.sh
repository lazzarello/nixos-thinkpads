#!/usr/bin/env bash
# Diagnose a hung resume after a hard reset.
#
# Reads the PREVIOUS boot's journal, which survives the reset because journald
# is Storage=persistent. Writes /tmp/resume-hang.txt
#
# With suspend-debug.nix active (pm_debug_messages + no_console_suspend), the
# "last device seen" section below names the driver that wedged. Without it,
# that section will be empty and you only learn that it hung, not where.
O=/tmp/resume-hang.txt

{
echo "################ boots known to journald"
journalctl --list-boots 2>&1 | tail -6

echo
echo "################ did resume finish?"
echo "# entry count > exit count means it hung in the resume path"
printf "suspend entry: %s\n" "$(journalctl -b -1 -k --no-pager 2>&1 | grep -c 'PM: suspend entry')"
printf "suspend exit : %s\n" "$(journalctl -b -1 -k --no-pager 2>&1 | grep -c 'PM: suspend exit')"

echo
echo "################ LAST DEVICE SEEN before the hang  <-- the answer"
echo "# requires pm_debug_messages; the final device logged is the suspect"
journalctl -b -1 -k --no-pager 2>&1 \
  | grep -iE "calling |call .* returned|driver sync|PM: (dpm_run|suspend|resume)" \
  | tail -30

echo
echo "################ slowest devices (if it completed at all)"
journalctl -b -1 -k --no-pager 2>&1 | grep -iE "took [0-9.]+ (msecs|seconds)" | tail -15

echo
echo "################ pstore (panic/oops persisted by firmware)"
ls -la /sys/fs/pstore/ 2>&1
for f in /sys/fs/pstore/*; do
  [ -f "$f" ] && { echo "--- $f"; cat "$f"; }
done

echo
echo "################ suspend/resume sequence"
journalctl -b -1 -k --no-pager 2>&1 \
  | grep -iE "PM: |ACPI: PM|sleep state|freezing|thaw" | tail -40

echo
echo "################ tail of previous boot"
journalctl -b -1 --no-pager 2>&1 | tail -60

echo
echo "################ driver errors"
journalctl -b -1 -k --no-pager 2>&1 \
  | grep -iE "nouveau|i915|iwlwifi|drm|xhci|thermal|nvme" \
  | grep -iE "fail|error|timeout|hang|reset|lockup|WARN|BUG|not respond" | tail -30

echo
echo "################ freezer problems"
journalctl -b -1 -k --no-pager 2>&1 \
  | grep -iE "freezer|refusing to freeze|task .* blocked|hung_task|not freezable" | tail -20

echo
echo "################ wifi / tailscale around the failure"
journalctl -b -1 --no-pager -o short-iso 2>&1 \
  | grep -iE "wpa_supplicant|iwlwifi|NetworkManager|tailscaled|CTRL-EVENT|PMKSA" | tail -30

echo
echo "################ last timestamp written"
journalctl -b -1 --no-pager -o short-iso 2>&1 | tail -1

echo
echo "################ context"
printf "kernel=%s  mem_sleep=%s\n" "$(uname -r)" "$(cat /sys/power/mem_sleep)"
printf "pm_debug_messages=%s\n" "$(cat /sys/power/pm_debug_messages 2>&1)"
cat /proc/cmdline
sudo nix-env -p /nix/var/nix/profiles/system --list-generations 2>&1 | tail -6
echo "(end)"
} >"$O" 2>&1

echo "wrote $O"
