# NixBTW

NixOS and home-manager config for my two machines: `asus`, a UX581GV laptop, and
`homelab`, a headless box on the LAN. Both are tuned to their hardware, kernels
included, and GitHub Actions builds those kernels into a cache both machines
substitute from. A kernel that is not in that cache is the exception: the laptop
compiles it, and the homelab skips its switch.

The laptop mixes nixpkgs channels on purpose (unstable for niri and zen,
unstable-small for the agents, fast-release for its tuned kernel). The homelab
is on stable apart from pi and its kernel. Each host pins its own inputs through
a private `deploy-system/` wrapper flake.

## Rebuild

System, through the helper the daily timer also uses:

```sh
sudo /usr/local/sbin/nixos-switch.sh
```

Home:

```sh
~/.config/scripts/hm-switch.sh
```

A host with no helper yet switches explicitly against `deploy-system`, with the
live-tree override.

## This is not a template

The asus hardware files (disk layout, BIOS offsets, undervolt values, the
screenpad quirk, and the kernel tuning) describe this one laptop. A second
machine gets its own `hosts/<name>` and a real hardware config.
