{
  config,
  pkgs,
  voxtype,
  ...
}:

let
  osdPackage = voxtype.packages.${pkgs.system}.osd-gtk4;
in
{
  # Voxtype push-to-talk voice-to-text.
  #
  # Installed from upstream's own flake (see flake.nix), not from nixpkgs --
  # voxtype is not in nixpkgs. Upstream ships prebuilt binaries that are
  # dynamically linked against /lib64/ld-linux-x86-64.so.2, so the raw release
  # tarball cannot run on NixOS; their flake wraps them correctly and puts the
  # typing backends (wtype, dotool, ydotool) on the wrapped PATH.
  #
  # Variant choice: `vulkan`. Mesa ships both intel_icd and nouveau_icd here, so
  # Whisper inference can use the Intel iGPU without waking the Quadro. The
  # `cuda` variant would pull in the proprietary NVIDIA stack, which this
  # machine deliberately avoids (nouveau handles display and suspends when idle).
  programs.voxtype = {
    enable = true;
    package = voxtype.packages.${pkgs.system}.vulkan;
  };

  # On-screen display.
  #
  # The main voxtype packages ship only the `voxtype-osd` launcher, which execs
  # into a separate frontend package. None is included, so the launcher fell
  # back to the quickshell frontend, could not find its shell.qml, and exited 3
  # times in 5 seconds before the daemon gave up on it.
  #
  # gtk4 is voxtype's default and preferred frontend, and the one the daemon
  # looks for first. Installing it avoids the quickshell path entirely -- which
  # also avoids its palette option, whose default reads colors from
  # ~/.config/omarchy/current/theme/colors.toml. That Omarchy coupling is
  # exactly what this migration is removing.
  #
  # Note this builds from source with Rust rather than using a prebuilt binary.
  # It is listed in environment.systemPackages below.

  # The upstream NixOS module only installs the package; the systemd user
  # service lives in their Home Manager module, which this machine does not use
  # yet. Define the equivalent unit directly, mirroring their HM module:
  # PartOf/WantedBy graphical-session.target, restart on failure, and ordered
  # after pipewire so audio capture is ready.
  systemd.user.services.voxtype = {
    description = "Voxtype push-to-talk voice-to-text daemon";
    documentation = [ "https://voxtype.io" ];
    partOf = [ "graphical-session.target" ];
    after = [
      "graphical-session.target"
      "pipewire.service"
      "pipewire-pulse.service"
    ];
    wantedBy = [ "graphical-session.target" ];

    # The daemon spawns `voxtype-osd`, which in turn execs a frontend binary it
    # looks up on PATH. Upstream's wrapper only --prefix'es its own runtime deps
    # (wtype, dotool, ...) onto PATH, and a systemd user unit otherwise gets a
    # minimal PATH that excludes /run/current-system/sw/bin. So the OSD frontend
    # was installed and on the interactive PATH, yet invisible to the daemon,
    # which reported "voxtype-osd-gtk4 not installed" and crash-looped on the
    # quickshell fallback.
    path = [
      osdPackage

      # Voxtype probes every output backend with `which <binary>` -- see
      # src/output/{wtype,clipboard,ydotool,eitype,xclip,paste}.rs. `which` is
      # not a shell builtin and systemd user units get a minimal PATH, so
      # without it every probe fails and voxtype reports
      # "All output methods failed. Ensure wtype, dotool, ydotool, wl-copy, or
      # xclip is available" -- even though all of them are installed and work.
      # The error names the wrong missing program.
      pkgs.which
    ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${config.programs.voxtype.package}/bin/voxtype daemon";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Voxtype needs to read evdev directly to detect hotkeys outside the
  # compositor. `lee` is already in the input group for DankMaterialShell
  # (see configuration.nix), which satisfies this too.

  environment.systemPackages = [
    # The GTK4 OSD frontend, per the comment above.
    osdPackage

    # Typing backend. Voxtype's wrapper already carries this, but having it on
    # the system PATH makes `voxtype doctor` and manual testing behave.
    pkgs.wtype

    # So we can verify which Vulkan device is actually selected rather than
    # assuming: `vulkaninfo --summary`.
    pkgs.vulkan-tools
  ];
}
