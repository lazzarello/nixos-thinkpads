{ config, lib, pkgs, ... }:

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

  # Graphical login screen.
  services.displayManager = {
    sddm = {
      enable = true;
      wayland.enable = true;

      # NOTE: these two are inert under DisplayServer=wayland. sddm 0.21
      # applies CursorTheme only on the X11 path (the package contains no
      # reference to XCURSOR at all), so it never reaches Weston. Kept because
      # it is correct and documents intent, but the fix that actually works is
      # the "default" theme package and XCURSOR_THEME below. Merged over the
      # module defaults with recursiveUpdate, so ThemeDir/FacesDir survive.
      settings.Theme = {
        CursorTheme = "Adwaita";
        CursorSize = 24;
      };
    };
    defaultSession = "niri";
  };

  # Cursor theme for the SDDM greeter (Weston) and for niri.
  #
  # Two separate problems had to be fixed here:
  #
  # 1. XCURSOR_PATH is exported by /etc/set-environment, which only applies to
  #    login shells. The display-manager unit does not get it, so Weston fell
  #    back to libXcursor's compiled-in path, which contains no themes.
  #
  # 2. Nothing set XCURSOR_THEME, so both Weston and niri requested the theme
  #    literally named "default", which does not exist. niri has a built-in
  #    fallback bitmap and stayed usable; Weston has none and drew no pointer
  #    at all. Hence a visible cursor in niri but an invisible one at login.
  systemd.services.display-manager.environment = {
    XCURSOR_PATH = "/run/current-system/sw/share/icons";
    XCURSOR_THEME = "Adwaita";
    XCURSOR_SIZE = "24";
  };

  # Also set it for user sessions, so niri stops asking for "default".
  # This half works: niri now loads Adwaita at the requested size.
  environment.sessionVariables = {
    XCURSOR_THEME = "Adwaita";
    XCURSOR_SIZE = "24";
  };

  # The greeter needed a third fix. Weston's core reads the cursor theme only
  # from the [shell] section of weston.ini -- not from XCURSOR_THEME, and not
  # from sddm's CursorTheme. The nixpkgs sddm module generates an ini with
  # only [libinput] and [keyboard], so Weston fell back to the theme named
  # "default" and drew nothing.
  #
  # Rebuild the compositor command with the module's own ini contents plus a
  # [shell] section. Keep --shell=kiosk, matching upstream.
  services.displayManager.sddm.wayland.compositorCommand =
    let
      xcfg = config.services.xserver;
      westonIni = (pkgs.formats.ini { }).generate "weston.ini" {
        libinput = {
          enable-tap = config.services.libinput.mouse.tapping;
          left-handed = config.services.libinput.mouse.leftHanded;
        };
        keyboard = {
          keymap_model = xcfg.xkb.model;
          keymap_layout = xcfg.xkb.layout;
          keymap_variant = xcfg.xkb.variant;
          keymap_options = xcfg.xkb.options;
        };
        shell = {
          cursor-theme = "Adwaita";
          cursor-size = 24;
        };
      };
    in
    "${lib.getExe pkgs.weston} --shell=kiosk -c ${westonIni}";

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
