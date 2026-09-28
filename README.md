# surfshark-flake

A Nix flake packaging Surfshark's official Linux VPN client (Electron GUI + `surfsharkd` daemons) from its official `.deb` release.

## Usage

Add the input and import the module:

```nix
{
  inputs.surfshark = {
    url = "github:axioncs/surfshark-flake";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

```nix
{ inputs, ... }:
{
  imports = [ inputs.surfshark.nixosModules.default ];

  nixpkgs.config.allowUnfree = true; #only if you don't have it configured already
  services.surfshark-vpn.enable = true;
}
```

The module installs the client, runs both daemons, and enables NetworkManager with OpenVPN support. Launch with `surfshark`.

## Known caveats

- Only `x86_64-linux` is packaged.
- The app logs errors about `ps` at startup (it uses hardcoded FHS paths that don't exist on NixOS). This is harmless and doesn't affect functionality.
- Surfshark is proprietary (`unfree`), so `allowUnfree` must be enabled.

## License

Packaging code in this repo is MIT — see `LICENSE`. Surfshark itself is proprietary.
