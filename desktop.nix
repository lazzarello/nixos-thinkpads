{ config, pkgs, ... }:

{
  # Graphics and window management
  hardware.graphics.enable = true;
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

  # Audio and Bluetooth.
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };
  hardware.bluetooth.enable = true;

  environment.systemPackages = with pkgs; [
    alacritty
    xwayland-satellite

    # Provides the Adwaita xcursor theme under share/icons/Adwaita/cursors.
    adwaita-icon-theme

    noctalia-greeter

    # A theme actually named "default", inheriting Adwaita. This is the
    # belt-and-braces half of the fix: any client that asks for "default"
    # without XCURSOR_THEME being set now resolves to real cursor files
    # instead of finding nothing.
    (runCommand "default-cursor-theme" { } ''
      mkdir -p $out/share/icons/default
      printf '[Icon Theme]\nName=default\nComment=Default cursor theme\nInherits=Adwaita\n' \
        > $out/share/icons/default/index.theme
    '')
  ];
}
