# Phone control

The phone is the out-of-band controller. It must keep working when T3 Code,
opencode, and the graphical session on the laptop are stopped.

Status: Phase 3 done. The phone reaches the laptop over USB and gets root there,
holds a verified copy of the bundle, and runs the runbook in tmux. opencode does
not run on this phone; see that section for the evidence.

## Device

- Pixel 8a (`akita`), Android 17 (SDK 37), `arm64-v8a`.
- `adb` comes from `nix shell --no-write-lock-file nixpkgs#android-tools`, which
  resolves to
  `/nix/store/yf3lxxaw6cfydl9gr5f2jy60l38m495p-android-tools-35.0.2/bin/adb`.
  Rebuild the shell path with `nix build --no-link --print-out-paths
  nixpkgs#android-tools` if the store path is gone.
- Completion: `adb devices -l` lists the serial `52221XEKB1A35C` as `device`,
  not `unauthorized`.

## Termux

F-Droid build 0.118.3, installed 2025-10-03. The Termux user is `u0_a197`.

Installed: `openssh`, `nano`, `rsync`, `tmux`, `fd`, `ripgrep`, `nodejs-lts`
(node 24.22.2), and `@earendil-works/pi-coding-agent`.

The mirror that `pkg update` picks by itself can be newer than the packages
already installed. That showed up twice here: node failed to link
(`cannot locate symbol _ZNSt6__ndk113__hash_memoryEPKvm`) and `proot-distro`
asked for `python3.14` while `python3.13` was installed. Both clear up with a
full upgrade:

```sh
pkg update && pkg upgrade -y
```

If it stops at a config file question, answer `N` to keep the installed file.
Leaving it half-applied is what caused the broken link above.

## Keys

The phone holds its own control key at `~/.ssh/id_ed25519_phone`. Its public
key, comment `pixel8a-control`, is in `/home/duskyelf/.ssh/authorized_keys` and
in `/root/.ssh/authorized_keys` on the laptop.

The bundle also carries the laptop's `id_ed25519`, for git and for the restore.
Keep the two roles apart: the control key is what the laptop trusts for root.

## Laptop to phone

Termux does not start sshd at boot, so run `sshd` in Termux first. The phone's
`~/.ssh/authorized_keys` holds the laptop's `id_ed25519.pub`, which is what lets
this login work.

```sh
# on the phone, once per boot
sshd

# on the laptop
ADB=/nix/store/yf3lxxaw6cfydl9gr5f2jy60l38m495p-android-tools-35.0.2/bin/adb
$ADB forward tcp:8022 tcp:8022
ssh -p 8022 -i ~/.ssh/id_ed25519 u0_a197@127.0.0.1
```

Completion: `whoami` on the phone prints `u0_a197`.

## Phone to laptop, with root

This is for the live system before disko. After the first switch the declarative
`apps/openssh.nix` takes over and this block is history.

The sshd is a transient systemd unit, so it survives a wipe night that stops T3
and opencode. It binds every interface, and the gate is one firewall rule that
admits only the USB tether link. Loopback is accepted by the first rule of
`nixos-fw` always. Nothing else can reach port 2222, so binding `0.0.0.0` does
not widen the LAN. Do not drop the `-i` from that rule.

Three things it needs that this system does not have by default:

- The privilege separation user `sshd`. The openssh module was never enabled
  here, so the account does not exist and sshd exits 255 with
  `Privilege separation user sshd does not exist`.
- A root-owned `authorized_keys`. `StrictModes` rejects a file owned by another
  user when the login user is root, so the phone's key goes in
  `/root/.ssh/authorized_keys`, not the home directory file.
- A host key. It is generated under `/run/phone-sshd` and does not persist.

The block is re-runnable: it replaces a stale host key, stops the old unit, and
starts a new one.

```sh
sudo bash -c '
install -d -m 0700 /run/phone-sshd
rm -f /run/phone-sshd/ssh_host_ed25519_key*
ssh-keygen -q -t ed25519 -N "" -C phone-sshd-temp -f /run/phone-sshd/ssh_host_ed25519_key
getent group sshd >/dev/null || groupadd --system sshd
getent passwd sshd >/dev/null || useradd --system -g sshd -d /run/phone-sshd \
  -s /run/current-system/sw/sbin/nologin sshd
install -d -m 0700 /root/.ssh
cat /home/duskyelf/.ssh/id_ed25519_phone.pub > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
cat > /etc/ssh/phone-sshd.conf <<EOF
Port 2222
ListenAddress 0.0.0.0
HostKey /run/phone-sshd/ssh_host_ed25519_key
PidFile /run/phone-sshd/sshd.pid
AuthorizedKeysFile /root/.ssh/authorized_keys
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM no
AllowUsers root
StrictModes yes
LogLevel VERBOSE
EOF
chmod 600 /etc/ssh/phone-sshd.conf
systemctl stop phone-sshd.service 2>/dev/null
systemctl reset-failed phone-sshd.service 2>/dev/null
systemd-run --unit=phone-sshd --property=Restart=no \
  /run/current-system/sw/bin/sshd -D -e -f /etc/ssh/phone-sshd.conf
ss -ltn | grep 2222
'
```

Then scope it to the tether link. The interface name comes from the laptop:

```sh
IFACE=$(ip -br a | awk '/^enp0s/ {print $1; exit}')
echo "$IFACE"
sudo iptables -C nixos-fw -i "$IFACE" -p tcp --dport 2222 -j nixos-fw-accept 2>/dev/null ||
  sudo iptables -I nixos-fw 1 -i "$IFACE" -p tcp --dport 2222 -j nixos-fw-accept
sudo iptables -S nixos-fw | head -3
```

Completion: `ss -ltn` shows `0.0.0.0:2222`, and `iptables -S nixos-fw` shows the
accept rule for `$IFACE` above the `nixos-fw-log-refuse` line.

The script reads `/home/duskyelf/.ssh/id_ed25519_phone.pub`. The bundle carries
it in `keys/`, and it is already on this laptop. On a machine that lost it:

```sh
# on the laptop
ssh -p 8022 u0_a197@127.0.0.1 cat .ssh/id_ed25519_phone.pub \
  > ~/.ssh/id_ed25519_phone.pub
```

Two ways in. With tethering on, use the tether address that
`~/find-laptop 2222` prints. With tethering off, `adb reverse` still works,
because the sshd also answers on loopback:

```sh
# on the laptop, tethering off
$ADB reverse tcp:2222 tcp:2222

# on the phone
ssh -p 2222 -i ~/.ssh/id_ed25519_phone root@127.0.0.1
```

Completion: `id` prints `uid=0(root)` and `hostname` prints `asus`.

The unit and its host key die at reboot. The `sshd` account,
`/etc/ssh/phone-sshd.conf`, `/root/.ssh/authorized_keys`, and the firewall rule
go with the disk. The firewall rule is runtime only and disappears at reboot
whether the disk does or not.

## After the wipe: how the phone reaches the laptop

Neither WiFi nor adb works without something typed at the console. The installer
is a live image: it has no `/etc/NetworkManager` credentials for this network,
and no adbd. Two paths work, and the human picks whichever suits them.

### WiFi, when the human can type at the console

The installer image sets `hardware.enableAllHardware` and runs NetworkManager,
so the AX201 firmware is present and `nmcli` and `nmtui` are the tools. From the
installer's console, as the autologin `nixos` user:

```sh
nmcli radio wifi on
nmcli device wifi list
nmcli device wifi connect "<SSID>" password "<PASSPHRASE>"
ip -br a show wlan0
ping -c1 1.1.1.1
```

`nmtui` does the same as a menu. This also gives the installer the network it
needs for the substituters in the install command below.

Then find it from the phone, using the /24 the router hands out:

```sh
SUBNETS="192.168.1" ~/find-laptop 22
```

The installer's sshd is on by default with `PermitRootLogin yes`, and both the
`nixos` and `root` accounts start with an empty password, which ssh refuses. So
one console step is still needed, either `passwd` for `root` or a public key in
`/root/.ssh/authorized_keys`. An installer started with
`live.nixos.passwd=<string>` on its kernel command line skips that: the `nixos`
account accepts that password, and it has passwordless sudo, so `nixos@<ip>`
then `sudo -i` is root.

### USB tethering, when the human would rather not type

1. Enable USB tethering on the phone, in Settings, Hotspot and tethering. The
   laptop sees a `cdc_ncm` device and takes a DHCP address from the phone.
   Nothing gets typed on the laptop.
2. Find the laptop. The phone cannot read the tether address itself, because
   Android 17 denies netlink and `/proc/net` to apps, and nmap misreports here:
   it says every port is closed while `nc` connects fine. So `~/find-laptop`
   sweeps with bash's `/dev/tcp` and prints what answers:

   ```sh
   # on the phone, in Termux
   ~/find-laptop        # port 22, the installer's sshd
   ~/find-laptop 2222   # the temporary root sshd on the live system
   ```

   The script. This block is the source of truth; the copy in the phone's home
   must match it:

   ```sh
   #!/data/data/com.termux/files/usr/bin/bash
   set -uo pipefail
   PORT=${1:-22}
   SUBNETS=${SUBNETS:-10.119.217}

   probe() {
     # /dev/tcp wants host/port, not host:port.
     timeout 1 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null
   }

   hits=$(
     for net in $SUBNETS; do
       echo "sweeping $net.0/24 for tcp/$PORT" >&2
       for i in $(seq 1 254); do
         ( probe "$net.$i" "$PORT" && echo "$net.$i:$PORT" ) &
         (( i % 32 == 0 )) && wait
       done
       wait
     done
   )

   if [ -n "$hits" ]; then
     printf '%s\n' "$hits"
     exit 0
   fi
   echo "nothing on tcp/$PORT in: $SUBNETS" >&2
   exit 1
   ```

   `SUBNETS` holds bare three-octet prefixes, space separated, and it is the
   only thing that needs maintaining:

   ```sh
   SUBNETS="10.119.217 192.168.1" ~/find-laptop 22
   ```

3. The password step is the same as the WiFi path: `passwd` at the console, a key
   in `/root/.ssh/authorized_keys`, or `live.nixos.passwd=` on the kernel command
   line. That console step is the one thing only the human can do, so ask early.

Verified 2026-11-16 on `e966850` against the live system: tethering up,
`~/find-laptop 2222` printed `10.119.217.184:2222`, and
`ssh -p 2222 root@10.119.217.184` printed `uid=0(root)`. The same address came
back after a tethering off and on cycle. A phone reboot may pick a different
/24; check after the first reboot and extend `SUBNETS` if it does.

Completion: `~/find-laptop 22` prints `<ip>:22`, and `ssh root@<ip>` with the
console password, or `ssh nixos@<ip>` with the `live.nixos.passwd` string, gets
a shell.

Two traps, both hit while testing:

- Starting tethering changes the USB function set. adbd restarts, so every
  `adb forward` and `adb reverse` is gone, and the reverse-bound loopback sshd
  path above stops working with them. Use the tether address instead.
- An sshd socket bound to the tether address specifically dies when tethering
  flaps, because the address object is recreated. Binding `0.0.0.0` with the
  scoped rule survives, which is why the block above is written that way.

This section covers the installer. After the first boot into the installed
system the path is tailscale, per `docs/migration.md` step 9, because
`apps/openssh.nix` allows 22 on the tailscale interface only.

## Bundle

`~/phone-bundle` in the Termux home, 2.3 GiB, 5551 files plus the manifest:

- `t3/` state, attachments, settings, secrets, owner identity
- `zen/` the whole profile
- `keys/` SSH keys, known_hosts, adbkey, keyring, npmrc, gh hosts
- `opencode/auth.json`
- `personal/` GnuCash and the tax PDFs
- `patches/` uncommitted patches and the media deletion manifest
- `docs/` these docs, `disk.nix`, `disko.nix`

`SHA256SUMS` was generated on the laptop before the transfer and covers every
file except itself. Verify on the phone:

```sh
cd ~/phone-bundle && sha256sum -c SHA256SUMS | grep -v ': OK$'
```

Completion: no output, or only the summary lines. The current copy verified with
zero failures.

## The agent on the phone

opencode cannot run here. Tested, in this order:

- `npm install -g opencode-ai` refuses the platform:
  `EBADPLATFORM ... wanted {"os":"darwin,linux,win32"} (current: {"os":"android"})`.
- Its postinstall tells you to install `opencode-android-arm64`, which returns
  404 on npm.
- The prebuilt `opencode-linux-arm64` package downloads and extracts, but the
  binary links against glibc, so Android cannot exec it:
  `cannot execute: required file not found`.
- `proot-distro` is no better. The device's seccomp filter blocks ptrace
  (`ptrace(TRACEME): Operation not permitted`), and with `PROOT_NO_SECCOMP=1`
  proot still fails to exec a Termux-native binary
  (`the loader was not found or doesn't work`).
- `pkg search opencode` finds nothing in the Termux repositories.

Pi works instead. It is pure JavaScript, needs only node, and OpenCode ships a
Pi harness for the Go plan, so the same subscription pays for it:

```sh
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

The API key goes in `~/.pi/env`, mode 600, so it never appears in a process
list:

```sh
export OPENCODE_API_KEY=oc_sk_...
```

`~/wipe/run-pi.sh` starts it with the model and the brief:

```sh
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
cd "$HOME/wipe"
set -a; . "$HOME/.pi/env"; set +a
exec pi --model opencode-go/deepseek-v4.1-flash \
  --append-system-prompt "$(cat "$HOME/wipe/BRIEF.md")" "$@"
```

`BRIEF.md` is the phone agent's standing instruction: it is the out-of-band
controller, root on the laptop is `ssh -p 2222 root@127.0.0.1`, nothing
destructive happens without a written go-ahead for that step, and before any
disk write it must inventory the bundle and report anything on the laptop that
the bundle is missing.

## The mailbox

The two agents talk through append-only files on the laptop, reached over the
same USB forward:

    /home/duskyelf/tmp/phone-chat/to-phone.md    laptop to phone
    /home/duskyelf/tmp/phone-chat/to-laptop.md   phone to laptop

The `talk` script in the phone's home is the whole interface:

```sh
talk read             # messages waiting for the phone
talk say "text"       # append one message for the laptop agent
talk sayfile          # append stdin, for longer replies
talk laptop '<cmd>'   # run a shell command on the laptop as root
```

## Watching the phone's session

The phone's work runs in tmux, so it can be read on the phone's own screen or
from the laptop. Two sessions exist: `pi` is the agent, `wipe` holds the
runbook.

```sh
# on the laptop, with the 8022 forward in place
ssh -p 8022 -i ~/.ssh/id_ed25519 -t u0_a197@127.0.0.1 tmux attach -t pi
```

Detach with `ctrl-b d`. The sessions survive the ssh connection, so a dropped
USB cable loses nothing. If the forward is gone, redo
`$ADB forward tcp:8022 tcp:8022` first.

## What the phone must hold

- `docs/migration.md` and this file.
- `~/.ssh/id_ed25519`, `id_ed25519_signing`, and `known_hosts`.
- Git bundles or clones of dotfiles, deploy-system, and the private repos.
- The T3, Zen, GnuCash, tax, and patch bundles.
- `sha256sum` manifest for every copied file.
