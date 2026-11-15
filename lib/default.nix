# The flake's internals: nixpkgs instances, the jail wrapper, the kernel
# selection, and the host builder. flake.nix imports this and wires outputs.
{ inputs }:
let
  pkgs = import ./pkgs.nix { inherit inputs; };
  jail =
    (import ./jail.nix {
      pkgs = pkgs.stable;
      jail-nix = inputs.jail-nix;
    }).jail;
  kernel = import ./kernel.nix { pkgs-fast-release = pkgs.fast-release; };
in
{
  inherit pkgs jail kernel;
  mkHost = import ./mkHost.nix {
    inherit
      inputs
      pkgs
      jail
      kernel
      ;
  };
}
