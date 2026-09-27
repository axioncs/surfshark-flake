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
  libx11,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,
  libxcb,
  mesa,
  expat,
  libxkbcommon,
  udev,
  alsa-lib,
  libglvnd,
  gjs,
  coreutils,
  procps,
  which,
}:

let
  info = builtins.fromJSON (builtins.readFile ./version.json);

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
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    mesa # libgbm
    expat
    libxcb
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

    chmod 750 "$out/etc/openvpn/client" || true
    chmod 4755 "$out/opt/Surfshark/chrome-sandbox" || true
    chmod 755 "$out/opt/Surfshark/resources/dist/resources/surfsharkd.js" || true
    chmod 744 "$out/opt/Surfshark/resources/dist/resources/surfsharkd2.js" || true
    chmod 755 "$out/opt/Surfshark/resources/dist/resources/update" || true
    chmod 755 "$out/opt/Surfshark/resources/dist/resources/diagnostics" || true

    mkdir -p "$out/bin"
    ln -sf "$out/opt/Surfshark/surfshark" "$out/bin/surfshark"

    mkdir -p "$out/share/surfshark-vpn-config"
    cp -r etc/openvpn "$out/share/surfshark-vpn-config/"

    runHook postInstall
  '';

  postFixup = ''
    wrapProgram "$out/bin/surfshark" \
      --prefix PATH : "${
        lib.makeBinPath [
          gjs
          coreutils
          procps
          which
        ]
      }"
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
