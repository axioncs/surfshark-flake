{
  stdenv,
  lib,
  fetchurl,
  autoPatchelfHook,
  dpkg,
  makeWrapper,
  wrapGAppsHook3,
  glib,
  nss,
  nspr,
  dbus,
  atk,
  at-spi2-atk,
  at-spi2-core,
  cups,
  cairo,
  gtk3,
  pango,
  xorg,
  mesa,
  expat,
  libxkbcommon,
  udev,
  alsa-lib,
  libglvnd,
  gjs,
}:

let
  info = builtins.fromJSON (builtins.readFile ./version.json);

  # Full Electron/Chromium runtime deps, read from `readelf -d` against
  # the real `surfshark` binary. This is NOT a CLI tool -- it's
  # Electron, so it needs the same library set as any Electron app
  # packaged for Nix.
  electronLibs = [
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
stdenv.mkDerivation {
  pname = "surfshark";
  inherit (info) version;

  src = fetchurl {
    inherit (info) url hash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = electronLibs ++ [ gjs ];

  # surfsharkd/surfsharkd2 are GJS scripts (#!/usr/bin/gjs), not Node --
  # autoPatchelfHook only touches ELF binaries so this doesn't affect
  # them, but gjs must be on PATH at runtime for the systemd units to
  # exec them directly.

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

    # the .deb's own postinst prints this reminder rather than doing it
    # itself -- replicate the permission fixes here.
    chmod 750 "$out/etc/openvpn/client" || true
    chmod 4755 "$out/opt/Surfshark/chrome-sandbox" || true
    chmod 755 "$out/opt/Surfshark/resources/dist/resources/surfsharkd.js" || true
    chmod 744 "$out/opt/Surfshark/resources/dist/resources/surfsharkd2.js" || true
    chmod 755 "$out/opt/Surfshark/resources/dist/resources/update" || true
    chmod 755 "$out/opt/Surfshark/resources/dist/resources/diagnostics" || true

    # /usr/bin/surfshark -> /opt/Surfshark/surfshark symlink, but
    # pointed at $out instead of the FHS /opt path
    mkdir -p "$out/bin"
    ln -sf "$out/opt/Surfshark/surfshark" "$out/bin/surfshark"

    # etc/ (openvpn client cert/key, init.d scripts) is reference
    # material only -- the NixOS module wires the real systemd units,
    # not these SysV init scripts, and the OpenVPN cert/key are
    # consumed via NetworkManager instead of copied into /etc directly
    # from here.
    mkdir -p "$out/share/surfshark-vpn-config"
    cp -r etc/openvpn "$out/share/surfshark-vpn-config/"

    runHook postInstall
  '';

  postFixup = ''
    # chrome-sandbox needs real privilege (setuid or capabilities),
    # which the Nix store cannot provide -- security.wrappers in the
    # NixOS module re-wraps it. autoPatchelfHook has already patched
    # RPATHs on all ELF binaries under $out by this point.
    wrapProgram "$out/bin/surfshark" \
      --prefix PATH : "${lib.makeBinPath [ gjs ]}"
  '';

  meta = {
    description = "Surfshark VPN official Linux client: Electron GUI + surfsharkd/surfsharkd2 daemons (repackaged from the upstream .deb)";
    homepage = "https://surfshark.com/download/linux";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = "surfshark";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
