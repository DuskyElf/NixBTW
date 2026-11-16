# Disk migration and restore

Status: Phase 2. The layout and the label-based `fileSystems` are written. The
disk is untouched. The live generation still boots from UUIDs and btrfs
`/home`. Do not switch the label-based generation before disko writes the
labels.

## Rollback before disko

A `nixos-rebuild switch` now writes a by-label, f2fs generation. The current
disk has neither the labels nor an f2fs `/home`, so that generation cannot
boot. The previous generation in the systemd-boot menu is the only rollback; it
still carries the UUID fstab and btrfs `/home`. Do not try to repair it by
setting labels: the new generation's fsType is still f2fs.

The window is short. The 04:00 `nix-gc.timer` deletes system generations older
than two days. If you need the rollback, boot it before then or stop
`nix-gc.timer` first.

## Target layout

Device: `/dev/disk/by-id/nvme-SAMSUNG_MZVLB1T0HALR-00000_S3W6NX0M825927`
Model `SAMSUNG MZVLB1T0HALR-00000`, serial `S3W6NX0M825927`.

| Partition | Size | Filesystem | Label | Mount |
|---|---|---|---|---|
| p1 | 1 GiB | vfat | `BOOT` | `/boot` |
| p2 | 115 GiB | btrfs, subvol `@` | `nixos` | `/` |
| p3 | remainder | f2fs | `home` | `/home` |

p1 is 1,073,741,824 bytes and p2 is 123,480,309,760 bytes, the same as the old
table. p3 is the remainder; the old p3 was 899,654,090,752 bytes. disko uses
`--align-end`, which can trim a partition's end by alignment. After format,
check `blockdev --getsize64` for p1 and p2 against those exact values. A
difference of 1 MiB or less is alignment; a larger difference is a real shrink,
so stop.

`/` stays btrfs. The store is about 120 GiB of logical content, about 73 GB on
disk with zstd, and `/` uses 79 G of 115 G. f2fs compression exists in the
kernel, but it is per-file or extension based, not a transparent replacement
for the store's mixed names. `/home` becomes f2fs because random 4K overwrites
amplify 11.9x on btrfs and 1.4x with nodatacow. The chattr +C activation in
`base/home.nix` is removed; f2fs has no equivalent.

Source of truth for the layout: `hosts/asus/disko.nix`. The device and labels
come from `hosts/asus/disk.nix`, which the NixOS `fileSystems` also imports.

## Layout check

Run this before any destructive step. It evaluates the layout and prints a
script; it does not touch a disk:

```sh
script=$(nix run github:nix-community/disko/1dd30c29c88d99ce295f15e27f93c49bc5fbae07 -- \
  --dry-run --mode destroy,format,mount hosts/asus/disko.nix | tail -n 1)
grep -q -- '--new=1:0:+1G' "$script" &&
grep -q -- '--new=2:0:+115G' "$script" &&
grep -q -- '--new=3:0:-0' "$script" &&
grep -A1 'mkfs.vfat' "$script" | grep -q -- '-n BOOT' &&
grep -A1 'mkfs.btrfs' "$script" | grep -q -- '-L nixos' &&
grep -A1 'mkfs.f2fs' "$script" | grep -q -- '-l home' &&
echo PASS
```

`PASS` is the only acceptable result. A missing or different value is a stop.
This is the only place the layout is evaluated; disko is not a flake input.

## Reproduce this machine

Deploy wrapper: `git@github.com:DuskyElf/NixBTW-deploy.git` (private).
Dotfiles: `https://github.com/DuskyElf/NixBTW.git`.

Clone both into a clean path, then build through the wrapper with path
overrides so the live tree cannot hide a missing file:

```sh
git clone https://github.com/DuskyElf/NixBTW.git dotfiles
git -C dotfiles submodule update --init --recursive
git clone git@github.com:DuskyElf/NixBTW-deploy.git deploy-system

cd deploy-system
nix build --print-out-paths --no-link \
  '.#nixosConfigurations.asus.config.system.build.toplevel' \
  --override-input my-dotfiles path:$PWD/../dotfiles \
  --override-input neovimBTW path:$PWD/../dotfiles/neovimBTW \
  --override-input wallpaper-guardian path:$PWD/../dotfiles/wallpaper-guardian

nix build --print-out-paths --no-link \
  '.#homeConfigurations."duskyelf@asus".activationPackage' \
  --override-input my-dotfiles path:$PWD/../dotfiles \
  --override-input neovimBTW path:$PWD/../dotfiles/neovimBTW \
  --override-input wallpaper-guardian path:$PWD/../dotfiles/wallpaper-guardian
```

Completion: both builds exit 0 and print an output path. Compare the system
path with `readlink -f /run/current-system` and the home path with
`readlink -f ~/.local/state/nix/profiles/home-manager` on the machine they
claim to reproduce.

At dotfiles `84d1789`, the clean clone built:

- system `/nix/store/lh344r5g4gb5vlvij784bd8yrn8fs9kb-nixos-system-asus-26.05.20261113.f1e5c35`
- home `/nix/store/y341jq2px52vlhspg8nvjqczgbk9dk33-home-manager-generation`

Both matched the live machine exactly.

After the label and f2fs change, the same clean-clone build produced:

- system `/nix/store/hqjqpbcbfiy17b3rmh0a75jl7f6na800-nixos-system-asus-26.05.20261113.f1e5c35`
- home `/nix/store/3y2zf5fihfxjhinrv9lcclx51vh5375s-home-manager-generation`

The system derivation `34hvx70dqjnvaj7a3wc0zdydl7vvbdfv` is the same one the
live-tree wrapper build produced.

## Restore order

1. Boot the installer and confirm Secure Boot is off: `mokutil --sb-state`.
   Completion: it reports Secure Boot disabled.
2. Verify the disk before any write:
   ```sh
   cat /sys/block/nvme0n1/device/model
   cat /sys/block/nvme0n1/device/serial
   readlink -f /dev/disk/by-id/nvme-SAMSUNG_MZVLB1T0HALR-00000_S3W6NX0M825927
   ```
   Completion: model, serial, and device match the values above, and there is
   no second NVMe.
3. If the old filesystems are intact, mount them read-only and pull anything
   not yet copied. Verify checksums on the phone.
   Completion: every file in the bundle has a matching checksum and the phone
   has a second copy of the repository bundle.
4. Run disko. This destroys the disk.
   ```sh
   sudo nix run github:nix-community/disko/1dd30c29c88d99ce295f15e27f93c49bc5fbae07 -- \
     --mode destroy,format,mount --root-mountpoint /mnt \
     /path/to/dotfiles/hosts/asus/disko.nix
   ```
   Completion: `findmnt /mnt` shows btrfs, and `/mnt/home` is f2fs with label
   `home`.
5. Restore `/home` from the phone into `/mnt/home/duskyelf`.
6. Put dotfiles and deploy-system in `/mnt/home/duskyelf/dotfiles`.
7. Make the wrapper's absolute paths resolve inside the installer:
   ```sh
   mount --bind /mnt/home /home
   ```
8. Install the system. The private cache must be trusted or the tuned kernel
   and T3 Code will compile in the RAM disk:
   ```sh
   nixos-install --flake /home/duskyelf/dotfiles/deploy-system#asus \
     --override-input my-dotfiles path:/home/duskyelf/dotfiles \
     --override-input neovimBTW path:/home/duskyelf/dotfiles/neovimBTW \
     --override-input wallpaper-guardian path:/home/duskyelf/dotfiles/wallpaper-guardian \
     --option substituters 'https://cache.nixos.org https://cache.nixos-cuda.org https://duskyelf.github.io/NixBTW' \
     --option trusted-public-keys 'cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M= i9-kernel-cache:4R0pqOZkrRj4utTbF4zP05Y58QSgShLqQ77KUPzFjwk=' \
     --cores 16
   ```
   Completion: it exits 0 without building `t3code` or the kernel. If it starts
   either, stop and install a minimal system first; see "Minimal first".

   The live `/` is 79 G used of 115 G. Do not build the new closure on the
   live root. Install into the empty `/mnt` root. If a pre-disko check needs
   space, prune old generations; the wipe removes them anyway.
9. Boot the installed system. At the console, run `passwd` for `duskyelf`: a
   freshly installed account has no password, so neither the greeter nor `sudo`
   works until you set one. Then restore T3 state, Zen, keys, and app state, and
   run `sudo tailscale up` so the machine rejoins the tailnet. `apps/openssh.nix`
   allows port 22 on the tailscale interface only, so the phone cannot reach the
   new machine over the LAN, and the new machine is a new tailscale node.
   Finally verify login, network, phone ssh, and T3 launch.

## Minimal first

If step 8 starts a long build, stop. Install only what boots and reaches the
network:

- `nixos-generate-config --root /mnt`
- Keep the generated `fileSystems` but replace devices with the labels above.
- Enable `boot.loader.systemd-boot`, `networking.hostName`, `services.openssh`,
  and the `duskyelf` user with the restored SSH key.
- `nixos-install --root /mnt`

Boot that, restore the repos, then run the wrapper switch from the machine.
This is slower in human steps and faster in failure recovery.

## Secrets

No GPG, age, sops, or password-store keys exist on this machine.

| Secret | Lives at | Restore |
|---|---|---|
| SSH login key | `~/.ssh/id_ed25519` + `.pub` | copy, mode 600/644 |
| Git signing key | `~/.ssh/id_ed25519_signing` + `.pub` | copy, mode 600/644 |
| Host fingerprints | `~/.ssh/known_hosts` | copy, mode 600 |
| T3 signing keys and cloud-link pair | `~/.t3/userdata/secrets/*` | copy, mode 600 |
| T3 owner identity | `~/.t3/userdata/server-owner.sqlite`, `server-owner.sqlite-journal`, `environment-id`, `anonymous-id`, `clerk/` | copy, mode 600 on the sqlite |
| T3 history and settings | `~/.t3/userdata/statev2.sqlite`, `attachments`, `*.json` | copy, mode 600 on the DB |
| Zen profile | `~/.config/zen` | copy encrypted; it holds logins and cookies |
| gh account | `~/.config/gh/hosts.yml` | copy, or run `gh auth login` |
| GNOME keyring, including the gh token | `~/.local/share/keyrings/login.keyring` | copy, or run `gh auth login` |
| npm token | `~/.npmrc` | copy or reissue |
| Android adb key | `~/.android/adbkey` | copy for phone control |
| Phone control public key | `~/phone-bundle/keys/id_ed25519_phone.pub` | public, no secret; needed to rebuild trust if the phone is replaced |
| Tailscale node identity | `/var/lib/tailscale` | do not copy; re-run `tailscale up` and re-auth |
| Private cache public key | `hosts/asus/system.nix` | already in the repo |
| Private cache signing key | GitHub Actions secret `NIX_SECRET_KEY` | not on this disk |

OpenCode history and its provider tokens are intentionally not restored. T3 is
the history of record.

## Phone control

The phone drives the destructive steps after T3 and opencode on the laptop are
stopped. Setup and the opencode-on-Android result are recorded in
`docs/phone.md`.
