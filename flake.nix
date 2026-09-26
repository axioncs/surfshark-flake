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
      in
      {
        packages = rec {
          default = surfshark;
          surfshark = pkgs.callPackage ./package.nix { };
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
          pkg = pkgs.callPackage ./package.nix { };
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

            # chrome-sandbox needs elevated privilege (Linux
            # capabilities, in this case) that the Nix store cannot
            # grant directly -- security.wrappers re-exposes a
            # capability-bearing copy at
            # /run/wrappers/bin/chrome-sandbox. This does NOT change
            # the copy inside the store path Electron launches by
            # default (Electron looks next to its own binary) --
            # verify at runtime whether Electron needs
            # CHROME_DEVEL_SANDBOX pointed at the wrapper, or disable
            # the sandbox (--no-sandbox) as a fallback if this doesn't
            # line up; this module ships the wrapper but you should
            # confirm surfshark launches cleanly.
            security.wrappers.chrome-sandbox = {
              source = "${pkg}/opt/Surfshark/chrome-sandbox";
              owner = "root";
              group = "root";
              capabilities = "cap_sys_admin+ep";
            };

            systemd.services.surfsharkd2 = {
              description = "Surfshark Daemon2";
              wantedBy = [ "multi-user.target" ];
              # The daemon shells out to id/ps/which at runtime, which
              # aren't on PATH by default under systemd -- same fix as
              # the wrapped GUI binary.
              path = with pkgs; [
                coreutils
                procps
                which
              ];
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
              path = with pkgs; [
                coreutils
                procps
                which
              ];
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
