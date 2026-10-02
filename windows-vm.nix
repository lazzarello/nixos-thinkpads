{ config, pkgs, ... }:

# Windows VM, ported from Omarchy's `omarchy-windows-vm`.
#
# WHAT THIS ACTUALLY IS (verified against the live container on the Arch laptop):
# `dockurr/windows` is NOT a containerised Windows -- containers share the host
# kernel and Windows cannot. It is a Debian container that runs QEMU/KVM *inside
# itself*. Docker is packaging and lifecycle only. The real process is:
#
#   qemu-system-x86_64 -cpu host,kvm=on -smp 4,cores=4 -m 4G
#     -machine q35,accel=kvm -enable-kvm -vga virtio
#     -display vnc=:0,websocket=5700
#     -drive file=/storage/data.img,format=raw,cache=none,aio=native
#     -drive file=/storage/windows.rom,if=pflash      # UEFI firmware
#     -netdev tap,ifname=qemu
#
# Alongside QEMU the container also runs nginx (noVNC on 8006), websocketd
# (install progress on 8004), dnsmasq (pins the guest to 172.30.0.2), smbd
# (exports /shared) and wsddn (makes that share discoverable in Explorer).
#
# THERE ARE TWO UIs, and they are not interchangeable:
#   1. noVNC  http://127.0.0.1:8006  -- QEMU's own display. Firmware, Windows
#      Setup, boot failures. Works even when Windows is not running.
#   2. RDP    127.0.0.1:3389         -- Windows' own RDP server. The daily UI.
#
# How 3389 reaches the guest: there is no port-forward. The container DNATs
# every port except its own (5700/5900/8006/8004) to 172.30.0.2, so Docker
# publishes 3389 to the container and iptables hands it to Windows. This is
# also why every published port MUST stay bound to 127.0.0.1 -- see below.

let
  # Sizing is declarative: edit, rebuild, and the next VM creation uses it.
  # (Omarchy asked these via a one-shot `gum` wizard and froze the answers into
  # a mutable compose file. DISK_SIZE only takes effect at image creation.)
  cfg = {
    ram = "4G";
    cores = "4";
    disk = "64G";
    version = "11";     # dockur downloads this Windows ISO on first boot
    timezone = config.time.timeZone or "America/Los_Angeles";
  };

  # Compose file lives in the Nix store: declarative, read-only, no drift.
  # Credentials are deliberately absent -- see the credentials note below.
  composeFile = pkgs.writeText "windows-vm-compose.yml" ''
    services:
      windows:
        image: dockurr/windows
        container_name: windows-vm
        environment:
          VERSION: "${cfg.version}"
          RAM_SIZE: "${cfg.ram}"
          CPU_CORES: "${cfg.cores}"
          DISK_SIZE: "${cfg.disk}"
          USERNAME: "''${WIN_USERNAME:?set WIN_USERNAME in credentials}"
          PASSWORD: "''${WIN_PASSWORD:?set WIN_PASSWORD in credentials}"
          TZ: "${cfg.timezone}"
          ARGUMENTS: "-rtc base=localtime,clock=host,driftfix=slew"
        devices:
          - /dev/kvm
          - /dev/net/tun
        cap_add:
          - NET_ADMIN
        # SECURITY: keep the 127.0.0.1 prefixes. The container DNATs all
        # non-internal ports straight into Windows, so a 0.0.0.0 bind would
        # expose the guest's RDP (and everything else) to the LAN.
        ports:
          - 127.0.0.1:8006:8006
          - 127.0.0.1:3389:3389/tcp
          - 127.0.0.1:3389:3389/udp
        volumes:
          - ''${WIN_STORAGE}:/storage
          - ''${WIN_SHARED}:/shared
        # Omarchy used `unless-stopped`, which silently resumes a 4 GB VM on
        # every boot. On a laptop that is a battery and RAM tax. The launcher
        # owns the lifecycle explicitly instead.
        restart: "no"
        stop_grace_period: 2m
  '';

  windows-vm = pkgs.writeShellApplication {
    name = "windows-vm";
    runtimeInputs = with pkgs; [
      docker
      docker-compose
      freerdp
      jq
      gawk
      gnugrep
      coreutils
      e2fsprogs      # chattr, for the btrfs NoCOW guard
      util-linux     # findmnt
      libnotify
      xdg-utils
    ];
    text = ''
      set -uo pipefail

      STORAGE="$HOME/.windows"
      SHARED="$HOME/Windows"
      CREDS="$HOME/.config/windows/credentials"

      export WIN_STORAGE="$STORAGE" WIN_SHARED="$SHARED"
      COMPOSE=(docker-compose --env-file "$CREDS" -f ${composeFile} -p windows-vm)

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

      case "''${1-}" in
        launch)
          require_kvm; require_creds; guard_cow
          keep_alive=false
          [[ ''${2-} == --keep-alive || ''${2-} == -k ]] && keep_alive=true

          # data.img is created before unattended Setup finishes. On a truly
          # fresh install, hand the user noVNC immediately; otherwise use the
          # RDP handshake below as the authoritative readiness check. Do not
          # infer installation state from a Dockur marker: older/completed
          # guests can retain setup media and have no such marker.
          if [[ ! -f "$STORAGE/data.img" ]]; then
            echo "No Windows image yet -- starting a fresh Windows ${cfg.version} install."
            echo "Downloading the ISO and running Setup: expect 15-30 minutes."
            notify-send "Installing Windows" "First boot: downloading ISO and running Setup" -t 20000
            "''${COMPOSE[@]}" up -d || die "Failed to start the installer. Logs: windows-vm logs"
            sleep 3
            xdg-open http://127.0.0.1:8006 >/dev/null 2>&1 || true
            echo
            echo "Watch progress:  http://127.0.0.1:8006"
            echo "When Setup finishes, run 'windows-vm launch' again to connect over RDP."
            exit 0
          fi

          if [[ $(docker inspect -f '{{.State.Status}}' windows-vm 2>/dev/null) != running ]]; then
            notify-send "Starting Windows VM" "This can take 15-30 seconds" -t 15000
            "''${COMPOSE[@]}" up -d || { notify-send -u critical "Windows VM" "Failed to start"; exit 1; }
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
            "''${RDP_ARGS[@]}" || true

          if [[ $keep_alive == false ]]; then
            echo "RDP closed. Stopping VM ..."
            "''${COMPOSE[@]}" down
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
          "''${COMPOSE[@]}" down 2>/dev/null || true
          rm -rf -- "$STORAGE"
          echo "Removed. Run 'windows-vm launch' to install Windows again."
          ;;

        console)
          # QEMU's own display. Use this when RDP is dead or Windows is mid-boot.
          xdg-open http://127.0.0.1:8006 >/dev/null 2>&1 \
            || echo "Open http://127.0.0.1:8006"
          ;;

        stop)    require_creds; "''${COMPOSE[@]}" down ;;
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
    '';
  };

in
{
  # dockur/windows runs QEMU inside the container, so the host only needs a
  # container runtime plus the KVM and TUN devices. No libvirt, no host QEMU.
  virtualisation.docker.enable = true;
  boot.kernelModules = [ "kvm-intel" "tun" ];

  # docker: talk to the daemon. kvm: open /dev/kvm.
  # This MERGES with the extraGroups list in configuration.nix rather than
  # replacing it -- NixOS concatenates list options across modules.
  users.users."lee".extraGroups = [ "docker" "kvm" ];

  environment.systemPackages = [
    windows-vm
    pkgs.freerdp
    (pkgs.makeDesktopItem {
      name = "windows-vm";
      desktopName = "Windows";
      comment = "Start the Windows VM and connect over RDP";
      exec = "windows-vm launch";
      terminal = false;
      categories = [ "System" ];
      keywords = [ "windows" "vm" "rdp" ];
    })
  ];

  # NOTE ON THE NIRI WINDOW RULE
  #
  # There is deliberately no `programs.niri.settings` here. The nixpkgs niri
  # module exposes only `programs.niri.enable` / `.package`; `settings` comes
  # from the third-party niri-flake and would fail to evaluate on this system.
  # ~/.config/niri/config.kdl is hand-managed, so add this rule there yourself:
  #
  #   // Windows VM over RDP. Verify the app-id with `niri msg windows`;
  #   // it is "xfreerdp" even though the binary is xfreerdp3.
  #   window-rule {
  #       match app-id=r#"^xfreerdp$"#
  #       open-fullscreen true
  #   }
}
