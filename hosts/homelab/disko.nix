# Disk layout for the homelab box: one 500 GB HDD, so there is room for a data
# partition beside the system. The device and the labels come from
# hosts/homelab/disk.nix, the same file the NixOS fileSystems read, so a label
# cannot drift between them.
#
# ext4 rather than the laptop's f2fs: this is a spinning disk with no
# compression story, and noatime is the only tuning it needs. Reading the store
# off it is the slowest routine work this box does: a cold flake evaluation
# takes 54 s against 14 s warm, and the bay is SATA, so an SSD is the upgrade.
# A 100% partition is created last by disko, so root takes whatever the other
# two leave.
#
# Disk mode only. The disko imageSize default is unused here.
#
# nixos-anywhere formats this layout from a live ISO, kexecing into the target,
# so the ISO's kernel has to support kexec. Alpine's does not: it lacks
# kexec_file_load and its kernel.kexec_load_disabled is set, so a box booted
# from that ISO is installed the long way instead. Alpine also runs mdev, so
# /dev/disk/by-partlabel never appears and disko's formatScript cannot find the
# labels. That path is `apk add nix bash util-linux`, generate
# hosts/homelab/hardware.nix with `nixos-generate-config` from the tools
# closure, build the system on the laptop, export the closure and
# `nix-store --import` it as root (the installed daemon rejects unsigned pushes
# from an untrusted user), link the partlabels by hand after `mdev -s`, run the
# formatScript and then the mountScript, and finish with
# `nixos-install --root /mnt --system <path> --no-root-passwd`.
let
  disk = import ./disk.nix;
in
{
  disko.devices.disk.main = {
    type = "disk";
    device = disk.device;

    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1G";
          type = "EF00";
          label = disk.labels.boot;
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            extraArgs = [
              "-n"
              disk.labels.boot
            ];
            mountOptions = [
              "fmask=0077"
              "dmask=0077"
            ];
          };
        };

        storage = {
          size = "250G";
          label = disk.labels.storage;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/mnt/personal-storage";
            extraArgs = [
              "-L"
              disk.labels.storage
            ];
            mountOptions = [ "noatime" ];
          };
        };

        root = {
          size = "100%";
          label = disk.labels.root;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            extraArgs = [
              "-L"
              disk.labels.root
            ];
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };
}
