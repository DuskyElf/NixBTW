# Which kernel this machine runs, decided in one place: the rule lives in
# hosts/asus/stable-kernel.nix, this is the call that feeds it the pinned
# release channel. Exposed as the `kernelVersion` flake output so CI can ask a
# candidate pin the same question; hosts/asus/system.nix gets the drv through
# specialArgs.
{ pkgs-fast-release }:
import ../hosts/asus/stable-kernel.nix {
  inherit (pkgs-fast-release) lib;
  kernels = pkgs-fast-release.linuxKernel.kernels;
}
