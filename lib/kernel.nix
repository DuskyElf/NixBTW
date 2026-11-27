# Which kernel the laptop runs, decided in one place: the rule lives in
# hosts/asus/stable-kernel.nix, this is the call that feeds it the pinned
# release channel. hosts/asus/system.nix gets the drv through specialArgs. The
# flake's `kernelVersions` output reports it next to the homelab's own choice
# (hosts/homelab/kernel.nix), so CI can ask one question of a candidate pin.
{ pkgs-fast-release }:
import ../hosts/asus/stable-kernel.nix {
  inherit (pkgs-fast-release) lib;
  kernels = pkgs-fast-release.linuxKernel.kernels;
}
