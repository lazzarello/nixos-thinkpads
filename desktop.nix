{ config, pkgs, lib, ... }:

let
  # Toggle wrapper around wl-screenrec.
  #
  # Recording needs an explicit stop, unlike niri's one-shot screenshot action,
  # so a single key has to both start and stop. Stopping uses SIGINT so the
  # muxer writes the container trailer -- SIGKILL leaves an unplayable file.
  #
  # Set SCREENREC_AUDIO_DEVICE to also record audio; use a sink's .monitor for
  # desktop sound or an input for the mic (`pactl list short sources`).
  screenrec = pkgs.writeShellApplication {
    name = "screenrec";
    runtimeInputs = with pkgs; [
      wl-screenrec
      slurp
      coreutils # date, basename, mkdir, sort, cut, seq, sleep
      findutils # find, to locate the newest recording
      procps # pkill is not used, but kill -0 needs a real shell builtin only
    ];
    text = builtins.readFile ./screenrec.sh;
  };
in
{
  # Graphics and window management
  hardware.graphics = {
    enable = true;

    # VAAPI, for hardware video encode/decode.
    #
    # Needed by wl-screenrec, which encodes on the GPU by default. Without a
    # VAAPI driver only /run/opengl-driver/lib/dri/*_drv_video.so for other
    # vendors exist (nouveau, radeonsi, virtio) and no Intel one, so hardware
    # encoding fails and recording falls back to --no-hw or does not work.
    #
    # This GPU is Coffee Lake (UHD P630), which the iHD driver from
    # intel-media-driver supports. intel-vaapi-driver is the older i965 for
    # pre-Broadwell parts and is not used here.
    extraPackages = with pkgs; [
      intel-media-driver # iHD
      libva-vdpau-driver
      intel-compute-runtime
    ];
  };
  programs.niri.enable = true;

  # Desktop shell and automatic session startup.
  programs.dms-shell = {
    enable = true;
    systemd.enable = true;
    enableCalendarEvents = false;
    enableAudioWavelength = false;
  };

  # Graphical login screen: greetd running Noctalia Greeter.
  #
  # Replaced sddm. Under DisplayServer=wayland, sddm runs Weston as its
  # greeter compositor, and Weston reads its cursor theme only from the
  # [shell] section of weston.ini. Three successive fixes -- installing a
  # cursor theme, setting XCURSOR_THEME, and injecting [shell] into a
  # regenerated weston.ini -- all failed to produce a visible pointer at the
  # login screen, while niri itself was fine. Noctalia Greeter brings its own
  # wlroots compositor which reads XCURSOR_THEME/SIZE/PATH directly (verified
  # in the binary), so it does not depend on weston.ini at all.
  #
  # Note: nixpkgs 26.05 has the noctalia-greeter *package* but not the
  # services.displayManager.noctalia-greeter *module* (that is in unstable),
  # so greetd is configured directly here.
  services.greetd = {
    enable = true;
    settings.default_session = {
      command = "${pkgs.noctalia-greeter}/bin/noctalia-greeter-session";
      user = "greeter";
    };
  };

  # greetd's own module sets services.displayManager.enable, which generates
  # the wayland-sessions entries the greeter lists. Keep niri preselected.
  services.displayManager.defaultSession = "niri";

  # The session entries live in their own store path, not in
  # /run/current-system/sw/share/wayland-sessions (which does not exist here).
  # The greeter discovers sessions via XDG_DATA_DIRS, but NixOS only sets that
  # for user sessions -- not for the greetd service -- so without this the
  # greeter would show an empty session list.
  systemd.services.greetd.environment.XDG_DATA_DIRS =
    "${config.services.displayManager.sessionData.desktops}/share";

  # State directory for greeter.toml, per the package's tmpfiles.d drop-in.
  systemd.tmpfiles.packages = [ pkgs.noctalia-greeter ];

  # Declarative greeter configuration. The greeter reads [cursor] theme/size/
  # path, confirmed from the binary's own help string. Setting path explicitly
  # avoids depending on the greeter user's environment, which is the class of
  # problem that made the sddm/Weston pointer invisible.
  environment.etc."noctalia-greeter/greeter.toml".text = ''
    [cursor]
    theme = "Adwaita"
    size = 24
    path = "/run/current-system/sw/share/icons"

    [keyboard]
    layout = "us"
  '';

  # Cursor theme for user sessions.
  #
  # Nothing sets XCURSOR_THEME by default, so clients request the theme
  # literally named "default". That name did not exist, so niri fell back to
  # its built-in bitmap (usable but tiny) while Weston drew nothing at all.
  # Setting this explicitly makes niri load real Adwaita cursors at 24px.
  environment.sessionVariables = {
    XCURSOR_THEME = "Adwaita";
    XCURSOR_SIZE = "24";
  };

  # Alacritty must use a Nerd Font for LazyVim's file/status icons.
  environment.etc."xdg/alacritty/alacritty.toml".text = ''
    [font]
    normal = { family = "JetBrainsMono Nerd Font Mono" }
  '';

  # File sharing to phones and other machines on the LAN.
  #
  # The module installs the package and opens TCP+UDP 53317, which localsend
  # needs both for discovery and transfer. openFirewall defaults to true; it is
  # stated explicitly here so the firewall hole is visible in this file rather
  # than implied by a default.
  programs.localsend = {
    enable = true;
    openFirewall = true;
  };

  # File management and removable/network media.
  services.gvfs.enable = true;

  # Audio and Bluetooth.
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
  hardware.bluetooth.enable = true;

  # Battery and power-source reporting.
  #
  # DMS reads the battery through UPower (BatteryService.qml filters
  # UPower.devices for isLaptopBattery), not from sysfs. Without upower,
  # batteryAvailable is false, so DMS hides every battery-conditional control
  # -- including the "Power source" AC/Battery selector in Power & Sleep,
  # which makes the battery-side idle timeouts unreachable in the UI.
  #
  # The dms-shell module enables power-profiles-daemon but not upower.
  services.upower.enable = true;
  environment.systemPackages = with pkgs; [
    alacritty
    nerd-fonts.jetbrains-mono
    xwayland-satellite

    # Screenshot, annotation and screen recording. DMS exposes screenshot and
    # clipboard IPC targets and binds keys to them, but does not pull in the
    # binaries, so those actions fail silently without these.
    # Screenshots themselves are a niri built-in action (Print / Ctrl+Print /
    # Alt+Print, saved to ~/Pictures/Screenshots), so grim is not needed for
    # those. It is kept because other tools shell out to it.
    grim # capture
    slurp # select a region
    satty # annotate

    # Inspect VAAPI support: `vainfo` should list the iHD driver and its
    # supported encode entrypoints.
    libva-utils

    # pulseaudio provides pactl, for `pactl list short sources` -- the command
    # wl-screenrec's own --audio-device help text tells you to use. Only the
    # client tools are installed; the daemon is not used, pipewire-pulse is.
    pulseaudio
    wl-clipboard # wl-copy / wl-paste
    cliphist # clipboard history, used by the DMS clipboard UI
    wl-screenrec # screen recording (wlroots, hardware encoded)
    screenrec # the toggle wrapper defined above, bound to Mod+Print
    vlc

    # Lightweight file manager with UDisks2/GVfs removable and network media support.
    thunar
    thunar-volman
    gvfs
    tumbler

    # Provides the Adwaita xcursor theme under share/icons/Adwaita/cursors.
    adwaita-icon-theme
    noctalia-greeter

    # A theme actually named "default", inheriting Adwaita. This is the
    # belt-and-suspenders half of the fix: any client that asks for "default"
    # without XCURSOR_THEME being set now resolves to real cursor files
    # instead of finding nothing.
    (runCommand "default-cursor-theme" { } ''
      mkdir -p $out/share/icons/default
      printf '[Icon Theme]\nName=default\nComment=Default cursor theme\nInherits=Adwaita\n' \
        > $out/share/icons/default/index.theme
    '')

    # Software dev utilities
    # OpenAI Codex
    codex
    # Pi Coding Agent
    # Installed from `nix profile add github:NixOS/nixpkgs/nixos-unstable#pi-coding-agent`
    # devenv installed through `nix profile install nixpkgs#devenv`
    # RTK (Rust Token Killer)
    # Installed from `nix profile add github:NixOS/nixpkgs/nixos-unstable#rtk`
  ];
}
