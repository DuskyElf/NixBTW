# What this machine needs on top of base/core.nix: one static LAN address and
# the server-side housekeeping. The fileSystems entries come from the disko
# module in hosts/homelab/disko.nix, so the mount layout has one source. A
# laptop's policy (compositor, radios, tailscale, root helpers) is
# base/workstation.nix, which this host does not list.
{
  pkgs,
  hostConfig,
  ...
}:
{
  # The install overwrites hosts/homelab/hardware.nix with nixos-generate-config
  # output, and that output does not set this option; it only defaults the AMD
  # microcode to whatever it says. Keeping it here survives the regeneration, so
  # the CPU microcode and the wired/wifi firmware are actually installed.
  hardware.enableRedistributableFirmware = true;
  hardware.cpu.amd.updateMicrocode = true;

  # The mountpoint is root-owned, and the data on it belongs to the login
  # account, so hand it over at boot rather than asking for sudo per file.
  systemd.tmpfiles.rules = [
    "d /mnt/personal-storage 0755 ${hostConfig.user.name} users -"
  ];

  # Static address, systemd-networkd instead of NetworkManager. The link is
  # matched by MAC, so udev naming cannot move the address to another
  # interface. DHCP stays on beside the static address: a box that cannot
  # reach its configured gateway is still reachable itself.
  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.networks."20-lan" = {
    matchConfig.MACAddress = "08:2e:5f:7c:97:ba";
    address = [ "192.168.1.200/24" ];
    routes = [ { Gateway = "192.168.1.1"; } ];
    dns = [
      "1.1.1.1"
      "9.9.9.9"
    ];
    networkConfig.DHCP = "yes";
  };

  # A second network file for the wired NIC that does not depend on the MAC, so
  # a wrong address above still leaves the box with a lease and the router's DNS
  # instead of no network at all. networkd uses the first matching file, so this
  # one only takes over when the MAC match fails. WiFi is not configured on this
  # host, which is why the match is `ether` and not every link type.
  systemd.network.networks."30-dhcp" = {
    matchConfig.Type = "ether";
    networkConfig.DHCP = "yes";
  };

  # The lid does nothing: the box is reached over ssh, and closing the lid is
  # how it gets put out of the way. Both the battery and AC cases, because a
  # machine left plugged in takes the external-power setting.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };

  # 15 GiB of RAM is the most this board takes, and there is no disk swap on
  # purpose: zram keeps swapped-out pages compressed in RAM and leaves the HDD
  # to the store, at the cost of the OOM killer being the ceiling.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # This machine runs no daily update timer, so the store is pruned on a clock
  # instead. Two weeks of generations is a rollback window that does not depend
  # on a user being logged in.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  environment.systemPackages = with pkgs; [
    curl
    wget
    less
    htop
  ];

  # ssh over the LAN is how the box is administered, and this is the account's
  # key. sshd itself is key-only (apps/openssh.nix), so the passwords below are
  # for the local console only. They are temporary: change both after the
  # install.
  users.users.${hostConfig.user.name} = {
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGorD4B49TQtqDXpf7vxDyFo2OCCRZ2L05b83AQdLHoX"
    ];
    initialPassword = "nixos";
  };
  users.users.root.initialPassword = "nixos";
}
