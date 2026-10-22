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
    text = builtins.replaceStrings
      [ "@composeFile@" "@windowsVersion@" ]
      [ "${composeFile}" cfg.version ]
      (builtins.readFile ./scripts/windows-vm.sh);
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
