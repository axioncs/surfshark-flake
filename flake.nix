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
          default = surfshark-unwrapped;
          surfshark-unwrapped = pkgs.callPackage ./package.nix { };
          # fhs.nix is kept in the repo but not used by default --
          # it fixed a real but secondary issue (the GUI's own
          # execSync('ps 1 -o comm=', {env:{PATH:'/usr/bin:/bin'}})
          # startup check), not the actual crash loop, which was
          # surfsharkd's missing GI_TYPELIB_PATH for libnm (see the
          # NixOS module below). Reintroducing /usr/bin, /bin-style
          # paths is undesirable on NixOS unless proven necessary --
          # testing without it first now that the daemon is healthy.
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
          # Reverted from fhs.nix back to the plain unwrapped package
          # for testing -- see packages.default's comment above. The
          # GUI still gets a normal wrapProgram PATH (coreutils/procps/
          # which/gjs) from package.nix's own postFixup, which covers
          # any call that DOES respect inherited PATH; only the one
          # hardcoded execSync call is unaffected by that, and it's
          # unclear whether it's fatal to the GUI actually opening a
          # window or just a background capability check.
          pkg = surfshark-unwrapped;
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

            # The daemons (surfsharkd/surfsharkd2) spawn `ps` via
            # GLib.spawn with what looks like the same
            # explicit-environment pattern as the GUI's hardcoded
            # execSync(..., {env: {PATH: '/usr/bin:/bin'}}) call --
            # confirmed by "GLib.SpawnError: Failed to execute child
            # process 'ps' (No such file or directory)" in the
            # journal even with `path = [ ... procps ... ]` set on
            # the systemd unit. Non-fatal (daemon keeps running), but
            # The daemons (surfsharkd/surfsharkd2) spawn `ps` via
            # GLib.spawn with what looks like the same
            # explicit-environment pattern as the GUI's hardcoded
            # execSync(..., {env: {PATH: '/usr/bin:/bin'}}) call --
            # confirmed by "GLib.SpawnError: Failed to execute child
            # process 'ps' (No such file or directory)" in the
            # journal even with `path = [ ... procps ... ]` set on
            # the systemd unit. This is NON-FATAL: the daemon logs it
            # and keeps running (confirmed in testing), so we are
            # deliberately NOT creating /usr/bin or /bin system-wide
            # to chase it -- that would change filesystem layout for
            # the whole machine over one handled, non-blocking error.
            # If this later turns out to matter (e.g. a feature that
            # depends on this ps call silently not working), the fix
            # is the same class as fhs.nix: wrap the daemon's ExecStart
            # in a small script that runs it inside a scoped
            # buildFHSEnv, not a system-wide /usr/bin.

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
