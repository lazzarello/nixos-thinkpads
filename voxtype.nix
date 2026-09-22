{
  config,
  pkgs,
  voxtype,
  ...
}:

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

  environment.systemPackages = with pkgs; [
    # Typing backend. Voxtype's wrapper already carries this, but having it on
    # the system PATH makes `voxtype doctor` and manual testing behave.
    wtype

    # So we can verify which Vulkan device is actually selected rather than
    # assuming: `vulkaninfo --summary`.
    vulkan-tools
  ];
}
