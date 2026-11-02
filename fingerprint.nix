{
  config,
  pkgs,
  lib,
  fingerprint-sensor,
  ...
}:

let
  # Switch to false only after enrolling with python-validity (README).
  enrollmentMode = false;
  localPackages.python-validity = pkgs.callPackage "${fingerprint-sensor}/pkgs/python-validity" {
    # The upstream package predates nixpkgs' explicit Python build-system API.
    python3Packages = pkgs.python3Packages // {
      buildPythonPackage =
        args:
        pkgs.python3Packages.buildPythonPackage (
          args
          // {
            pyproject = true;
            build-system = [ pkgs.python3Packages.setuptools ];
            postPatch = args.postPatch + ''
              substituteInPlace debian/python3-validity.udev \
                --replace-fail /bin/systemctl ${pkgs.systemd}/bin/systemctl
            '';
          }
        );
    };
  };
  sensorLib = import "${fingerprint-sensor}/lib" { inherit pkgs localPackages; };

  # open-fprintd has no authorization checks: expose the setup APIs only to root.
  rootOnly =
    package: busName:
    package.overrideAttrs (old: {
      postInstall = (old.postInstall or "") + ''
        cp ${pkgs.writeText "${busName}.conf" ''
          <busconfig>
            <policy context="default">
              <deny own="${busName}"/>
              <deny send_destination="${busName}"/>
              <deny send_interface="${busName}.Device"/>
            </policy>
            <policy user="root">
              <allow own="${busName}"/>
              <allow send_destination="${busName}"/>
              <allow send_interface="${busName}.Device"/>
            </policy>
          </busconfig>
        ''} $out/share/dbus-1/system.d/${busName}.conf
      '';
    });
  validity = rootOnly localPackages.python-validity "io.github.uunicorn.Fprint";
  openFprintd = rootOnly pkgs.open-fprintd "net.reactivated.Fprint";
in
if enrollmentMode then
  {
    # Only the clients: the full fprintd package would also install its more
    # permissive D-Bus policy through the system profile, undoing rootOnly.
    environment.systemPackages = [
      validity
      (pkgs.runCommand "fprintd-clients" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.fprintd}/bin/fprintd-* $out/bin/
      '')
    ];
    services.dbus.packages = [
      validity
      openFprintd
    ];
    systemd.packages = [
      validity
      openFprintd
    ];
    systemd.services.python3-validity.wantedBy = [ "multi-user.target" ];
    services.fprintd.enable = false;
    services.udev.packages = [ validity ];
  }
else
  {
    services.fprintd = {
      enable = true;
      tod = {
        enable = true;
        driver =
          (sensorLib.libfprint-2-tod1-vfs0090-bingch {
            calib-data-file = ./fingerprint-calib-data.bin;
          }).overrideAttrs
            (old: {
              # The wiki's stock vfs0090 is broken; this fork supports 06cb:009a.
              # Current libfprint-tod no longer needs the old API compatibility patches.
              patches = builtins.filter (p: !(lib.hasInfix "adapt-to-old-libfprint" (toString p))) old.patches;
              postInstall = (old.postInstall or "") + ''
                substituteInPlace $out/lib/udev/rules.d/60-libfprint-2-tod-vfs0090.rules \
                  --replace-fail 'GROUP="plugdev"' 'GROUP="root"'
              '';
            });
      };
    };
    services.udev.packages = [
      pkgs.libfprint-tod
      config.services.fprintd.tod.driver
    ];

    security.pam.services = {
      # Noctalia Greeter is password-only; DMS has its own fingerprint stack.
      greetd.fprintAuth = false;
      # Keep TTY/password login immediate.
      login.fprintAuth = false;
      dankshell.fprintAuth = false;
      sshd.fprintAuth = false;
    };
  }
