set -uo pipefail

STORAGE="$HOME/.windows"
SHARED="$HOME/Windows"
CREDS="$HOME/.config/windows/credentials"

export WIN_STORAGE="$STORAGE" WIN_SHARED="$SHARED"
COMPOSE=(docker-compose --env-file "$CREDS" -f @composeFile@ -p windows-vm)

# Arch ships FreeRDP 3 as xfreerdp3; nixpkgs may install it as xfreerdp.
# Resolve at runtime rather than betting on either name.
rdp_bin() {
  if   command -v xfreerdp3 >/dev/null; then echo xfreerdp3
  elif command -v xfreerdp  >/dev/null; then echo xfreerdp
  else echo "No xfreerdp binary found in PATH." >&2; exit 1
  fi
}

die() { echo "error: $*" >&2; exit 1; }

require_creds() {
  if [[ ! -f "$CREDS" ]]; then
    cat >&2 <<EOF
Missing $CREDS

Credentials stay out of Nix on purpose: anything in a .nix file lands in
the world-readable /nix/store. Create the file with mode 600:

  mkdir -p ~/.config/windows
  printf 'WIN_USERNAME=lee\nWIN_PASSWORD=yourpassword\n' > $CREDS
  chmod 600 $CREDS
EOF
    exit 1
  fi
  [[ $(stat -c %a "$CREDS") == 600 ]] || echo "warning: $CREDS is not mode 600" >&2
}

require_kvm() {
  [[ -e /dev/kvm ]] || die "No /dev/kvm. Enable VT-x in firmware and check kvm-intel is loaded."
  [[ -w /dev/kvm ]] || die "/dev/kvm not writable by $USER. Is 'kvm' in users.users.lee.extraGroups?"
  [[ -e /dev/net/tun ]] || die "No /dev/net/tun. The 'tun' module is required."
}

# The container warns when /storage is btrfs, and it is right: a raw image
# opened cache=none,aio=native on a CoW filesystem fragments badly.
# chattr +C only takes effect on an EMPTY file, so it must be set on the
# directory BEFORE the image is created. It cannot convert data.img later.
guard_cow() {
  mkdir -p "$STORAGE" "$SHARED"
  local fs
  fs=$(findmnt -no FSTYPE --target "$STORAGE" 2>/dev/null || true)
  [[ $fs == btrfs ]] || return 0
  if [[ -f "$STORAGE/data.img" ]]; then
    lsattr "$STORAGE/data.img" 2>/dev/null | grep -q C \
      || echo "warning: $STORAGE is btrfs and data.img lacks NoCOW (+C). Expect fragmentation; fix by recreating the image on a +C directory." >&2
  else
    chattr +C "$STORAGE" 2>/dev/null \
      && echo "Set NoCOW (+C) on $STORAGE before image creation (btrfs detected)."
  fi
}

# Docker's published port accepts TCP before the guest RDP service is
# ready, so a bare /dev/tcp connect is a false-positive. Send the small
# X.224 connection request and require an RDP negotiation response.
rdp_open() {
  local response
  exec 3<>/dev/tcp/127.0.0.1/3389 2>/dev/null || return 1
  printf '\x03\x00\x00\x13\x0e\xe0\x00\x00\x00\x00\x00\x01\x00\x08\x00\x03\x00\x00\x00' >&3
  response=$(timeout 3 head -c 4 <&3 2>/dev/null | od -An -tx1)
  exec 3<&- 3>&-
  [[ $response == *'03 00'* ]]
}

wait_for_rdp() {
  local i
  for ((i = 0; i < 90; i++)); do
    rdp_open && return 0
    sleep 2
  done
  return 1
}

# Niri equivalent of Omarchy's `hyprctl monitors -j | jq .scale` probe.
# Sets RDP_ARGS as an array so the empty (100%) case adds no argument at
# all, rather than an empty string that FreeRDP would reject.
RDP_ARGS=()
rdp_scale() {
  local scale pct
  scale=$(niri msg --json focused-output 2>/dev/null | jq -r '.logical.scale // 1' 2>/dev/null) || scale=1
  [[ -z $scale || $scale == null ]] && scale=1
  pct=$(awk -v s="$scale" 'BEGIN { printf "%d", s * 100 }')
  if   (( pct >= 170 )); then RDP_ARGS+=(/scale:180)
  elif (( pct >= 130 )); then RDP_ARGS+=(/scale:140)
  fi
}

case "${1-}" in
  launch)
    require_kvm; require_creds; guard_cow
    keep_alive=false
    [[ ${2-} == --keep-alive || ${2-} == -k ]] && keep_alive=true

    # data.img is created before unattended Setup finishes. On a truly
    # fresh install, hand the user noVNC immediately; otherwise use the
    # RDP handshake below as the authoritative readiness check. Do not
    # infer installation state from a Dockur marker: older/completed
    # guests can retain setup media and have no such marker.
    if [[ ! -f "$STORAGE/data.img" ]]; then
      echo "No Windows image yet -- starting a fresh Windows @windowsVersion@ install."
      echo "Downloading the ISO and running Setup: expect 15-30 minutes."
      notify-send "Installing Windows" "First boot: downloading ISO and running Setup" -t 20000
      "${COMPOSE[@]}" up -d || die "Failed to start the installer. Logs: windows-vm logs"
      sleep 3
      xdg-open http://127.0.0.1:8006 >/dev/null 2>&1 || true
      echo
      echo "Watch progress:  http://127.0.0.1:8006"
      echo "When Setup finishes, run 'windows-vm launch' again to connect over RDP."
      exit 0
    fi

    if [[ $(docker inspect -f '{{.State.Status}}' windows-vm 2>/dev/null) != running ]]; then
      notify-send "Starting Windows VM" "This can take 15-30 seconds" -t 15000
      "${COMPOSE[@]}" up -d || { notify-send -u critical "Windows VM" "Failed to start"; exit 1; }
    fi

    # The container's published port can be open before Windows RDP is
    # ready, and this also handles an already-running guest.
    echo "Waiting for RDP on 127.0.0.1:3389 ..."
    wait_for_rdp || {
      notify-send -u critical "Windows VM" "RDP never came up"
      xdg-open http://127.0.0.1:8006 >/dev/null 2>&1 || true
      die "RDP is not ready; VM left running. Inspect: windows-vm console"
    }

    # Export WIN_USERNAME/WIN_PASSWORD for the RDP client below.
    # The directive must sit immediately before `source` and that command
    # must be alone on its line, or shellcheck attaches it to `set -a`.
    set -a
    # shellcheck source=/dev/null
    source "$CREDS"
    set +a

    # -grab-keyboard matters under a tiling WM: without it the compositor
    # keeps consuming Super/Alt chords instead of passing them to Windows.
    rdp_scale
    "$(rdp_bin)" \
      /u:"$WIN_USERNAME" /p:"$WIN_PASSWORD" /v:127.0.0.1:3389 \
      -grab-keyboard /sound /microphone /clipboard /cert:ignore \
      /title:"Windows VM" /dynamic-resolution /gfx:AVC444 \
      /floatbar:sticky:off,default:visible,show:fullscreen \
      /drive:home,"$HOME" \
      "${RDP_ARGS[@]}" || true

    if [[ $keep_alive == false ]]; then
      echo "RDP closed. Stopping VM ..."
      "${COMPOSE[@]}" down
    else
      echo "RDP closed. VM still running. Stop it with: windows-vm stop"
    fi
    ;;

  reinstall)
    # Destructive: throws away the guest and starts Setup from scratch.
    # 'launch' already installs on first run, so this exists only to redo it.
    require_kvm; require_creds
    [[ -f "$STORAGE/data.img" ]] || die "No image to reinstall. Just run: windows-vm launch"
    echo "This DELETES the Windows guest at $STORAGE (disk, UEFI vars, MAC)."
    echo "Files in $SHARED are untouched."
    read -r -p "Type DELETE to confirm: " reply
    [[ $reply == DELETE ]] || die "Cancelled."
    "${COMPOSE[@]}" down 2>/dev/null || true
    rm -rf -- "$STORAGE"
    echo "Removed. Run 'windows-vm launch' to install Windows again."
    ;;

  console)
    # QEMU's own display. Use this when RDP is dead or Windows is mid-boot.
    xdg-open http://127.0.0.1:8006 >/dev/null 2>&1 \
      || echo "Open http://127.0.0.1:8006"
    ;;

  stop)    require_creds; "${COMPOSE[@]}" down ;;
  logs)    docker logs -f windows-vm ;;
  status)
    docker ps -a --filter name=windows-vm \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    echo
    printf 'storage : %s' "$STORAGE"
    [[ -f "$STORAGE/data.img" ]] \
      && printf ' (data.img %s on disk, %s apparent)\n' \
           "$(du -h  "$STORAGE/data.img" | cut -f1)" \
           "$(du -h --apparent-size "$STORAGE/data.img" | cut -f1)" \
      || printf ' (no image yet -- run: windows-vm launch to install)\n'
    printf 'share   : %s  -> \\\\host.lan\\Data in the guest\n' "$SHARED"
    if rdp_open; then echo 'rdp     : 127.0.0.1:3389 open'
    else echo 'rdp     : closed'
    fi
    ;;

  *)
    cat <<EOF
usage: windows-vm <command>

  launch [-k|--keep-alive]  connect over RDP; installs Windows on first run
  console                   open the noVNC/QEMU console on :8006
  stop                      stop the VM
  status                    container, image size, share, RDP state
  logs                      follow container logs
  reinstall                 delete the guest and install Windows again
EOF
    exit 1
    ;;
esac
