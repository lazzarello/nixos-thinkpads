{ lib, pkgs, ... }:

{
  boot = {
    loader.timeout = 3;
    loader.systemd-boot.enable = true;
    loader.systemd-boot.configurationLimit = 10;
    loader.systemd-boot.consoleMode = "auto";
    loader.efi.canTouchEfiVariables = true;

    initrd.luks.devices."luks-f7fadf6a-afee-403c-9ded-a455529cadd2".device = "/dev/disk/by-uuid/f7fadf6a-afee-403c-9ded-a455529cadd2";

    # Let suspend-debug.nix raise console verbosity while diagnostics are enabled.
    consoleLogLevel = lib.mkDefault 3;
    initrd.verbose = false;
    initrd.systemd.enable = true;
    kernelParams = [
      "quiet"
      "splash"
      "intremap=on"
      "boot.shell_on_fail"
      "udev.log_priority=3"
      "rd.systemd.show_status=auto"
    ];

    plymouth = {
      enable = true;
      theme = "rings";
      themePackages = with pkgs; [
          (adi1090x-plymouth-themes.override {
          selected_themes = [ "rings" ];
        })
      ];
    }; 
    plymouth.font = "${pkgs.hack-font}/share/fonts/truetype/Hack-Regular.ttf";
    plymouth.logo = "${pkgs.nixos-icons}/share/icons/hicolor/128x128/apps/nix-snowflake.png";
  };
}
