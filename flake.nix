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
          default = fhs;
          surfshark-unwrapped = pkgs.callPackage ./package.nix { };
          fhs = pkgs.callPackage ./fhs.nix { inherit (self.packages.${system}) surfshark-unwrapped; };
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
          surfshark-unwrapped = pkgs.callPackage ./package.nix { };
          pkg = pkgs.callPackage ./fhs.nix { inherit surfshark-unwrapped; };
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
              source = "${surfshark-unwrapped}/opt/Surfshark/chrome-sandbox";
              owner = "root";
              group = "root";
              capabilities = "cap_sys_admin+ep";
            };

            systemd.services.surfsharkd2 = {
              description = "Surfshark Daemon2";
              wantedBy = [ "multi-user.target" ];
              # The daemon shells out to id/ps/which at runtime.
              # UNVERIFIED: at least one call elsewhere in this
              # codebase (the GUI's PID-1 check) hardcodes
              # execSync(cmd, {env: {PATH: '/usr/bin:/bin'}}), which
              # discards inherited PATH entirely and would make this
              # `path =` addition useless for that specific call,
              # since /usr/bin and /bin don't exist on NixOS. We have
              # not traced whether surfsharkd2.js contains the same
              # pattern -- if the daemon fails the same way the GUI
              # did, it needs the same buildFHSEnv treatment as
              # fhs.nix, not more PATH entries here.
              path = with pkgs; [
                coreutils
                procps
                which
              ];
              # surfsharkd/surfsharkd2 use GJS's GObject-Introspection
              # binding to talk to libnm (NetworkManager) directly --
              # confirmed via the runtime error "Requiring NM, version
              # none: Typelib file for namespace 'NM' (any version)
              # not found" in surfsharkd's journal. GI_TYPELIB_PATH
              # and LD_LIBRARY_PATH aren't populated automatically by
              # networking.networkmanager.enable; GJS needs them set
              # explicitly per-process.
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
              # Same caveat as surfsharkd2 above -- unverified whether
              # this file has the same hardcoded-PATH execSync pattern.
              path = with pkgs; [
                coreutils
                procps
                which
              ];
              # See surfsharkd2's comment above -- this is the daemon
              # actually observed crash-looping with the NM typelib
              # error. As a user-scope service it especially can't be
              # expected to inherit GI_TYPELIB_PATH from anywhere.
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
