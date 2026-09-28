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
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      in
      {
        packages = rec {
          surfshark-unwrapped = pkgs.callPackage ./package.nix { };
          default = surfshark-unwrapped;
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/surfshark";
        };
      }
    )
    // {
      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.surfshark-vpn;
          surfshark-unwrapped = pkgs.callPackage ./package.nix { };
          pkg = surfshark-unwrapped;
        in
        {
          options.services.surfshark-vpn = {
            enable = lib.mkEnableOption "Surfshark VPN client daemons";
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ pkg ];

            networking.networkmanager.enable = lib.mkDefault true;
            networking.networkmanager.plugins = [ pkgs.networkmanager-openvpn ];

            security.wrappers.chrome-sandbox = {
              source = "${surfshark-unwrapped}/opt/Surfshark/chrome-sandbox";
              owner = "root";
              group = "root";
              capabilities = "cap_sys_admin+ep";
            };

            systemd.services.surfsharkd2 = {
              description = "Surfshark Daemon2";
              wantedBy = [ "multi-user.target" ];

              path = with pkgs; [
                coreutils
                procps
                which
              ];
              environment = {
                GI_TYPELIB_PATH = "${pkgs.networkmanager}/lib/girepository-1.0";
                LD_LIBRARY_PATH = "${pkgs.networkmanager}/lib";
              };
              serviceConfig = {
                ExecStart = "${pkgs.gjs}/bin/gjs ${surfshark-unwrapped}/opt/Surfshark/resources/dist/resources/surfsharkd2.js";
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
              environment = {
                GI_TYPELIB_PATH = "${pkgs.networkmanager}/lib/girepository-1.0";
                LD_LIBRARY_PATH = "${pkgs.networkmanager}/lib";
              };
              serviceConfig = {
                ExecStart = "${pkgs.gjs}/bin/gjs ${surfshark-unwrapped}/opt/Surfshark/resources/dist/resources/surfsharkd.js";
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
