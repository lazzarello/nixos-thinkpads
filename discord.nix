{ pkgs, ... }:

let
  # Upstream's small launcher/bootstrap, not the Electron client. The bootstrap
  # installs the current stable client into ~/.config/discord, where Discord's
  # own updater can replace it without a Nix rebuild or binary patching.
  bootstrap = pkgs.stdenvNoCC.mkDerivation {
    pname = "discord-bootstrap";
    version = "1.0.166";
    src = pkgs.fetchurl {
      url = "https://dl.discordapp.net/apps/linux/1.0.166/discord-1.0.166.tar.gz";
      hash = "sha256-7TaVvmQYLOgJERaMHD40K4DZxesMUSqNYlFsENiob/s=";
    };
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p "$out"
      cp discord updater_bootstrap discord.png "$out/"
    '';
  };

  desktopItem = pkgs.makeDesktopItem {
    name = "discord";
    desktopName = "Discord";
    genericName = "Internet Messenger";
    exec = "discord --url -- %u";
    icon = "discord";
    startupWMClass = "discord";
    categories = [ "Network" "InstantMessaging" ];
    mimeTypes = [ "x-scheme-handler/discord" ];
  };

  discord = pkgs.buildFHSEnv {
    name = "discord";
    # Give unmodified upstream binaries the conventional Linux library paths
    # they expect, including binaries downloaded by future upstream updates.
    targetPkgs = p: with p; [
      alsa-lib
      at-spi2-atk
      at-spi2-core
      atk
      cairo
      cups
      dbus
      expat
      fontconfig
      freetype
      gdk-pixbuf
      glib
      gtk3
      libcxx
      libdrm
      libgbm
      libglvnd
      libnotify
      libpulseaudio
      libuuid
      libva
      libx11
      libxcb
      libxcomposite
      libxcursor
      libxdamage
      libxext
      libxfixes
      libxi
      libxkbcommon
      libxrandr
      libxrender
      libxshmfence
      libxscrnsaver
      libxtst
      nspr
      nss
      pango
      pipewire
      systemdLibs
      wayland
      xdg-utils
      zenity
    ];
    profile = ''
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    '';
    runScript = "${bootstrap}/discord";
    extraInstallCommands = ''
      mkdir -p "$out/share/icons/hicolor/256x256/apps"
      ln -s ${bootstrap}/discord.png "$out/share/icons/hicolor/256x256/apps/discord.png"
      ln -s ${desktopItem}/share/applications "$out/share/applications"
    '';
    meta = {
      description = "Discord with its upstream updater in a Linux compatibility environment";
      homepage = "https://discord.com/";
      license = pkgs.lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
      mainProgram = "discord";
    };
  };
in
{
  environment.systemPackages = [ discord ];
}
