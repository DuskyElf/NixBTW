# Picks the kernel series this machine tracks: the newest series that already
# has at least one stable patch release.
#
# kernel.org calls a freshly cut release "mainline" (7.3, no patch releases)
# and a maintained series "stable" (7.2.13 today, and 7.3.1 once gregkh cuts
# it). nixpkgs spells the mainline release with two version components and
# every stable patch with three, so that difference is the whole test. An rc of
# the mainline release (7.3-rc1) also spells two, so it is skipped for free.
#
# Deliberately neither of the obvious aliases:
#   linuxPackages_latest -> mainline (7.3), untested by anyone else yet
#   linuxPackages        -> the 6.18 LTS, an old series
# Both would be a regression from the series that has stable patches on it.
#
# Usage: (import ./stable-kernel.nix { inherit lib kernels; }) -> kernel drv
{ lib, kernels }:
let
  # Series stubs for kernels nixpkgs has dropped (linux_4_19 and friends) throw
  # as soon as their attributes are touched, so every version lookup is
  # guarded. Attr names are cheap and always safe.
  series = builtins.filter (n: builtins.match "linux_[0-9]+_[0-9]+" n != null) (
    builtins.attrNames kernels
  );

  withVersion = name: {
    inherit name;
    version =
      let probed = builtins.tryEval kernels.${name}.version;
      in
      if
        probed.success
        && builtins.length (lib.splitString "." probed.value) == 3
      then
        probed.value
      else
        null;
  };

  stable = builtins.filter (c: c.version != null) (map withVersion series);

  newest = a: b: if lib.versionOlder a.version b.version then b else a;
in
if stable == [ ] then
  throw "stable-kernel.nix: this nixpkgs has no kernel series with a stable patch release"
else
  kernels.${(builtins.foldl' newest (builtins.head stable) (builtins.tail stable)).name}
