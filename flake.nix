{
  description = "Nix flake for Surfshark's official Linux VPN client (Electron app + surfsharkd daemons)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      systems = [ "x86_64-linux" ];
    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib;

        info = builtins.fromJSON (builtins.readFile ./version.json);

        # Full Electron/Chromium runtime deps, read from `readelf -d`
        # against the real `surfshark` binary (see update.sh's
        # verify-deps helper). This is NOT a CLI tool -- it's Electron,
        # so it needs the same library set as any Electron app packaged
        # for Nix (see e.g. nixpkgs' electron wrapper conventions).
        electronLibs =
          with pkgs;
          [
            glib
            nss
            nspr
            dbus
            atk
            at-spi2-atk
            at-spi2-core
            cups
            cairo
            gtk3
            pango
            xorg.libX11
            xorg.libXcomposite
            xorg.libXdamage
            xorg.libXext
            xorg.libXfixes
            xorg.libXrandr
            mesa # libgbm
            expat
            xorg.libxcb
            libxkbcommon
            udev
            alsa-lib
            libglvnd
            stdenv.cc.cc.lib
          ];
      in
      {
        packages = rec {
          default = surfshark;

          surfshark = pkgs.stdenv.mkDerivation {
            pname = "surfshark";
            inherit (info) version;

            src = pkgs.fetchurl {
              inherit (info) url hash;
            };

            nativeBuildInputs = with pkgs; [
              autoPatchelfHook
              dpkg
              makeWrapper
              wrapGAppsHook3
            ];

            buildInputs = electronLibs ++ [ pkgs.gjs ];

            # surfsharkd/surfsharkd2 are GJS scripts (#!/usr/bin/gjs),
            # not Node -- autoPatchelfHook only touches ELF binaries so
            # this doesn't affect them, but gjs must be on PATH at
            # runtime for the systemd units to exec them directly.

            unpackPhase = ''
              runHook preUnpack
              dpkg-deb -x "$src" .
              runHook postUnpack
            '';

            dontConfigure = true;
            dontBuild = true;

            installPhase = ''
              runHook preInstall

              mkdir -p "$out"
              cp -r usr/. "$out/"
              mkdir -p "$out/opt"
              cp -r opt/Surfshark "$out/opt/Surfshark"

              # the .deb's own postinst prints this reminder rather than
              # doing it itself -- replicate the permission fixes here.
              chmod 750 "$out/etc/openvpn/client" || true
              chmod 4755 "$out/opt/Surfshark/chrome-sandbox" || true
              chmod 755 "$out/opt/Surfshark/resources/dist/resources/surfsharkd.js" || true
              chmod 744 "$out/opt/Surfshark/resources/dist/resources/surfsharkd2.js" || true
              chmod 755 "$out/opt/Surfshark/resources/dist/resources/update" || true
              chmod 755 "$out/opt/Surfshark/resources/dist/resources/diagnostics" || true

              # /usr/bin/surfshark -> /opt/Surfshark/surfshark symlink,
              # but pointed at $out instead of the FHS /opt path
              mkdir -p "$out/bin"
              ln -sf "$out/opt/Surfshark/surfshark" "$out/bin/surfshark"

              # etc/ (openvpn client cert/key, init.d scripts) is
              # reference material only -- the NixOS module wires the
              # real systemd units, not these SysV init scripts, and
              # the OpenVPN cert/key are consumed via NetworkManager
              # instead of copied into /etc directly from here.
              mkdir -p "$out/share/surfshark-vpn-config"
              cp -r etc/openvpn "$out/share/surfshark-vpn-config/"

              runHook postInstall
            '';

            postFixup = ''
              # chrome-sandbox needs real SUID root, which the Nix
              # store cannot provide -- security.wrappers in the NixOS
              # module below re-wraps it. autoPatchelfHook has already
              # patched RPATHs on all ELF binaries under $out by this
              # point.
              wrapProgram "$out/bin/surfshark" \
                --prefix PATH : "${lib.makeBinPath [ pkgs.gjs ]}"
            '';

            meta = {
              description = "Surfshark VPN official Linux client: Electron GUI + surfsharkd/surfsharkd2 daemons (repackaged from the upstream .deb)";
              homepage = "https://surfshark.com/download/linux";
              license = lib.licenses.unfree;
              platforms = systems;
              mainProgram = "surfshark";
              sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
            };
          };
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/surfshark";
        };
      }
    )
    // {
      # NixOS module: wires up the two systemd services (surfsharkd2 as
      # a system service, surfsharkd as a user service) and provides
      # the SUID wrapper for chrome-sandbox, since the Nix store cannot
      # carry real SUID bits.
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.surfshark-vpn;
          pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        in
        {
          options.services.surfshark-vpn = {
            enable = lib.mkEnableOption "Surfshark VPN client daemons";
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ pkg ];

            # NetworkManager + its OpenVPN plugin are the real runtime
            # dependency here (per the AUR PKGBUILD's `depends=`), not
            # a bare openvpn binary -- the client drives tunnels
            # through NM, not directly.
            networking.networkmanager.enable = lib.mkDefault true;
            networking.networkmanager.plugins = [ pkgs.networkmanager-openvpn ];

            # chrome-sandbox needs real setuid-root; the Nix store
            # can't set that bit itself, so security.wrappers
            # re-exposes a setuid copy at
            # /run/wrappers/bin/chrome-sandbox. This does NOT change
            # the copy inside the store path Electron launches by
            # default (Electron looks next to its own binary) --
            # verify at runtime whether Electron needs
            # CHROME_DEVEL_SANDBOX pointed at the wrapper, or disable
            # the sandbox (--no-sandbox) as a fallback if SUID
            # plumbing doesn't line up; this module ships the wrapper
            # but you should confirm surfshark launches cleanly.
            security.wrappers.chrome-sandbox = {
              source = "${pkg}/opt/Surfshark/chrome-sandbox";
              owner = "root";
              group = "root";
              capabilities = "cap_sys_admin+ep";
            };

            systemd.services.surfsharkd2 = {
              description = "Surfshark Daemon2";
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                ExecStart = "${pkgs.gjs}/bin/gjs ${pkg}/opt/Surfshark/resources/dist/resources/surfsharkd2.js";
                Restart = "on-failure";
                RestartSec = 5;
                IPAddressDeny = "any";
                RestrictRealtime = true;
                ProtectKernelTunables = true;
                ProtectSystem = "full";
                RestrictSUIDSGID = true;
              };
            };

            systemd.user.services.surfsharkd = {
              description = "Surfshark Daemon";
              wantedBy = [ "default.target" ];
              serviceConfig = {
                ExecStart = "${pkgs.gjs}/bin/gjs ${pkg}/opt/Surfshark/resources/dist/resources/surfsharkd.js";
                Restart = "on-failure";
                RestartSec = 5;
                IPAddressDeny = "any";
                RestrictRealtime = true;
                ProtectKernelTunables = true;
                ProtectSystem = "full";
                RestrictSUIDSGID = true;
              };
            };
          };
        };
    };
}
