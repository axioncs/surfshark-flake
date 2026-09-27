{
  buildFHSEnv,
  surfshark-unwrapped,
  coreutils,
  procps,
  which,
  gjs,
  bash,
  iputils,
}:

# Surfshark's Electron app hardcodes execSync(cmd, {env: {PATH:
# '/usr/bin:/bin'}}) for at least one internal call (checking what's
# running as PID 1 via `ps`). That options object *replaces* the
# child process's environment rather than merging with it, so no
# amount of PATH-prefixing on the outer wrapper can ever reach it --
# confirmed by extracting app.asar and reading the call site
# directly (see package.nix's postFixup comment for the trail).
#
# On a normal FHS Linux distro /usr/bin and /bin are always populated
# with coreutils/procps/etc, so this assumption silently holds there
# and upstream never needed to make it configurable. NixOS has
# neither directory by default, so the hardcoded PATH points at
# nothing.
#
# buildFHSEnv solves this the way it solves it for any other FHS-
# assuming proprietary binary (Steam, standard game launchers, etc):
# run the app inside a mount namespace where /usr/bin, /bin, /lib
# etc. actually exist as real, populated directories, so the app's
# hardcoded assumptions are satisfied regardless of what environment
# variables it does or doesn't respect internally.
buildFHSEnv {
  name = "surfshark";

  targetPkgs =
    pkgs: with pkgs; [
      surfshark-unwrapped
      coreutils
      procps
      which
      gjs
      bash
      iputils
    ];

  # This is the part that actually fixes the crash: buildFHSEnv
  # populates /usr/bin (and /bin as a symlink to it) inside the
  # sandboxed environment from targetPkgs, so `ps`, `id` etc. exist
  # at the literal hardcoded path the app looks for -- independent of
  # PATH entirely.
  runScript = "${surfshark-unwrapped}/bin/surfshark";

  extraInstallCommands = ''
    mkdir -p $out/share/applications
    ln -sf ${surfshark-unwrapped}/share/applications/surfshark.desktop \
      $out/share/applications/surfshark.desktop || true
    mkdir -p $out/share/icons
    ln -sf ${surfshark-unwrapped}/share/icons/hicolor \
      $out/share/icons/hicolor || true
  '';

  meta = surfshark-unwrapped.meta // {
    mainProgram = "surfshark";
  };
}
