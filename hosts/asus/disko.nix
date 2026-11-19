# Disk layout for the ZenBook Pro Duo UX581GV.
#
# Not wired into the running configuration: hosts/asus/default.nix has no
# `disko` key, because this machine is already installed and nothing here should
# ever format it. Both this file and mkHost's disko seam exist for a reinstall:
# pass the key temporarily, install, then drop it again.
#
# The device and the filesystem labels come from hosts/asus/disk.nix, the same
# file the NixOS fileSystems read, so a label cannot drift between them.
#
# Everything is f2fs: p2 is 200 GiB for the store, p3 takes the rest for home.
# Compression is not a mount-wide switch on f2fs. The filesystem has to be
# created with the feature, mounted with the algorithm, and the target
# directories need the +c inode flag so new files inherit it. The installer runs
# chattr +c on /mnt and /mnt/home before nixos-install for that reason.
#
# f2fs reserves uncompressed block counts until f2fs_io release_cblocks runs, so
# df and du overstate usage on a freshly written tree. The data is compressed;
# the accounting is not.
#
# Disk mode only. The disko imageSize default is unused here.
let
  disk = import ./disk.nix;
  f2fsArgs = [
    "-O"
    "extra_attr,compression"
  ];
  f2fsMountOptions = [
    "noatime"
    "compress_algorithm=zstd:3"
    "compress_mode=fs"
  ];
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

        nixos = {
          size = "200G";
          label = disk.labels.root;
          content = {
            type = "filesystem";
            format = "f2fs";
            mountpoint = "/";
            extraArgs = f2fsArgs ++ [
              "-l"
              disk.labels.root
            ];
            mountOptions = f2fsMountOptions;
          };
        };

        home = {
          size = "100%";
          label = disk.labels.home;
          content = {
            type = "filesystem";
            format = "f2fs";
            mountpoint = "/home";
            extraArgs = f2fsArgs ++ [
              "-l"
              disk.labels.home
            ];
            mountOptions = f2fsMountOptions;
          };
        };
      };
    };
  };
}
