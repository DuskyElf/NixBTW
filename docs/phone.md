# Phone control

The phone is the out-of-band controller. It must keep working when T3 Code,
opencode, and the graphical session on the laptop are stopped.

Status: Phase 3 in progress. `adb` is available through
`nix shell nixpkgs#android-tools`; no device has enumerated yet.

## Human step

On the Pixel 8a:

1. Settings, About phone, tap Build number seven times.
2. Developer options, enable USB debugging.
3. Connect USB, accept the RSA prompt on the phone.

Completion: `nix shell nixpkgs#android-tools -c adb devices -l` lists the phone
as `device`, not `unauthorized`.

## Termux and sshd

Install Termux from F-Droid, not the Play Store build. Open it once and run:

```sh
pkg update
pkg install openssh nano
mkdir -p ~/.ssh
nano ~/.ssh/authorized_keys
# paste the laptop's ~/.ssh/id_ed25519.pub as one line, save, exit
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
sshd
whoami
```

`whoami` prints the Termux user, usually `u0_aNNN`. Note it.

From the laptop, with USB attached:

```sh
adb forward tcp:8022 tcp:8022
ssh -p 8022 -i ~/.ssh/id_ed25519 u0_aNNN@127.0.0.1
```

Completion: the laptop gets a shell on the phone over the USB forward.

For wireless, enable Developer options, Wireless debugging, pair, then
`adb connect <phone>:<port>`. Test both and record which one survives sleep.

## opencode on the phone

Termux is Android/bionic, not glibc. Test the linux-arm64 build directly before
assuming it runs:

```sh
pkg install nodejs-lts
npm install -g opencode-ai
opencode --version
```

If it runs, restore only the provider auth it needs and point it at the laptop
over ssh. If it does not, fall back to scripts plus ssh from Termux; the wipe
must not depend on an agent CLI that cannot start.

Completion: either `opencode` runs on the phone and can `ssh` to the laptop and
run a command, or the fallback scripts do the same. Record which path won.

## What the phone must hold

- `docs/migration.md` and this file.
- `~/.ssh/id_ed25519`, `id_ed25519_signing`, and `known_hosts`.
- Git bundles or clones of dotfiles, deploy-system, and the private repos.
- The T3, Zen, GnuCash, tax, and patch bundles.
- `sha256sum` manifest for every copied file.
