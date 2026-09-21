#!/usr/bin/env bash
# Usage: suspend-test.sh <label>
# Snapshots state, suspends, then snapshots again after resume.
# Writes everything to /tmp/suspend-<label>.log so it survives the SSH drop.
L="${1:-test}"
O="/tmp/suspend-$L.log"
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-1
export NIRI_SOCKET=$(ls -t /run/user/1000/niri.wayland-*.sock 2>/dev/null | head -1)
Q=/nix/store/fzk0q2plg3r8c5nrvwihs96vkvwpakx6-quickshell-0.3.0/bin/quickshell
QID=r81wg2qlt

snap() {
  echo "--- $1 $(date -Iseconds) ---"
  echo "hdmi=$(cat /sys/class/drm/card0-HDMI-A-1/status) edp=$(cat /sys/class/drm/card1-eDP-1/status)"
  echo "nvidia=$(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status) intel=$(cat /sys/bus/pci/devices/0000:00:02.0/power/runtime_status)"
  echo "nv_suspended_ms=$(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_suspended_time)"
  echo "niri_pid=$(pgrep -f 'niri --session' | head -1) dms=$(systemctl --user is-active dms)"
  echo "locked=$("$Q" ipc -i "$QID" call lock isLocked 2>&1)"
  echo "outputs:"
  niri msg outputs 2>&1 | grep -E '^Output|Current mode' | sed 's/^/  /'
  echo
}

{
  echo "===== SUSPEND TEST: $L ====="
  echo "kernel=$(uname -r)  mem_sleep=$(cat /sys/power/mem_sleep)"
  snap PRE
  echo ">>> suspending now"
} >"$O" 2>&1

logger -t suspend-test "SUSPEND-TEST-$L suspending"
systemctl suspend

# Execution continues here after the machine wakes.
sleep 8

{
  echo ">>> resumed"
  snap POST
  echo "===== PM / driver log across the cycle ====="
  journalctl -k -b --no-pager --since "5 minutes ago" \
    | grep -iE "PM: |suspend|resume|nouveau|i915" | tail -40
  echo
  echo "===== errors only ====="
  journalctl -k -b --no-pager --since "5 minutes ago" \
    | grep -iE "nouveau.*(fail|error|timeout|lockup)|i915.*(fail|error|hang)|PM: .*(fail|error)" \
    | tail -20
  echo "(no matches above means no driver errors)"
  echo "(end)"
} >>"$O" 2>&1
