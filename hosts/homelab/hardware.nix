# A stub. nixos-anywhere runs nixos-generate-config on the target and writes the
# real file over this one before it builds the system, so nothing here reaches
# the machine; it exists only so the flake evaluates before the first install.
# Anything that must survive that rewrite belongs in system.nix instead.
{ modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "ahci"
    "sd_mod"
    "usb_storage"
    "xhci_pci"
    "ehci_pci"
    "sr_mod"
  ];
  boot.kernelModules = [ "kvm-amd" ];
}
