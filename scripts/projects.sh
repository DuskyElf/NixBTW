#!/usr/bin/env bash
# Keeps the devshell of chosen projects out of the nix store GC.
#
# A plain `nix develop` leaves no gc root behind, so the next GC deletes the
# devshell and every package it pulled in. This links each project listed in
# hot-configs/active-projects to a gc root at
# ~/.local/state/nix/gcroots/projects/<name>, so its closure survives.
#
#   projects.sh find    every flake under ~/Projects, and whether it is listed
#   projects.sh list    listed projects: rev pinned, rev the lock pins, state
#   projects.sh pin     (re)link the roots, one line per project
#
# Names are paths relative to ~/Projects, so nested projects work too
# (tangled/core). Only listed projects are pinned, and a project removed from
# the list is unpinned on the next run. A failed pin keeps the previous root,
# so a broken lock never leaves a project unprotected.
set -uo pipefail

projects_dir="$HOME/Projects"
list_file="$HOME/dotfiles/hot-configs/active-projects"
root="${XDG_STATE_HOME:-$HOME/.local/state}/nix/gcroots/projects"

# Read once. A missing list is fatal before anything is touched: treating it
# as an empty list would unpin every project on the next run.
if [ ! -f "$list_file" ]; then
  echo "no list at $list_file" >&2
  exit 1
fi
mapfile -t active < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$list_file" | grep -v '^$')

is_listed() {
  local want=$1 name
  for name in "${active[@]}"; do
    [ "$name" = "$want" ] && return 0
  done
  return 1
}

# Prints "<rev> <date>" for the nixpkgs input of a lock file, "- -" if none.
lock_nixpkgs() {
  python3 - "$1" <<'PY'
import datetime, json, sys

try:
    nodes = json.load(open(sys.argv[1]))["nodes"]
except Exception:
    print("- -")
    raise SystemExit

for node in nodes.values():
    original = node.get("original", {})
    if original.get("id") != "nixpkgs" and original.get("repo") != "nixpkgs":
        continue
    locked = node.get("locked", {})
    rev = locked.get("rev")
    if rev:
        stamp = locked.get("lastModified")
        date = datetime.date.fromtimestamp(stamp).isoformat() if stamp else "-"
        print(rev[:8], date)
        break
else:
    print("- -")
PY
}

# Prints the nixpkgs input a flake declares, without the github owner prefix.
flake_channel() {
  sed -n 's/.*nixpkgs\.url[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1" |
    head -1 | sed -E 's|^github:[^/]*/nixpkgs/||'
}

# A pin records the nixpkgs rev and a hash of flake.nix plus flake.lock, so
# `list` can tell a moved lock from an edited flake.
flake_hash() {
  cat "$1/flake.nix" "$1/flake.lock" | sha256sum | cut -c1-12
}

# Prints "-" when a flake pins no nixpkgs rev.
pinned_rev() {
  local rev
  read -r rev _rest < <(lock_nixpkgs "$1")
  printf '%s\n' "$rev"
}

# Prints every flake under the projects dir, up to three directories deep.
# Hidden directories are skipped so vendored checkouts (.repos) and
# node_modules do not show up as projects.
cmd_find() {
  printf '%-37s %-24s %-11s %s\n' project nixpkgs lock-date listed

  find "$projects_dir" -mindepth 1 -maxdepth 4 -name flake.nix \
    -not -path "*/.*" -not -path "*/node_modules/*" -print0 |
    sort -z |
    while IFS= read -r -d '' file; do
      dir=$(dirname "$file")
      name=${dir#"$projects_dir"/}
      channel=$(flake_channel "$file")
      read -r _rev date < <(lock_nixpkgs "$dir/flake.lock")
      listed="no"
      is_listed "$name" && listed="yes"
      printf '%-37s %-24s %-11s %s\n' "$name" "${channel:--}" "$date" "$listed"
    done
}

# Prints one row per listed project: name, pinned rev, lock rev, state.
cmd_list() {
  printf '%-22s %-8s %-8s %s\n' project pinned lock state

  while read -r name; do
    dir="$projects_dir/$name"
    pinned="-"
    pinned_hash=""
    [ -f "$root/$name.rev" ] && read -r pinned pinned_hash <"$root/$name.rev"

    if [ ! -d "$dir" ]; then
      printf '%-22s %-8s %-8s %s\n' "$name" "$pinned" "-" "missing directory"
      continue
    fi
    if [ ! -f "$dir/flake.nix" ]; then
      printf '%-22s %-8s %-8s %s\n' "$name" "$pinned" "-" "no flake.nix"
      continue
    fi
    if [ ! -f "$dir/flake.lock" ]; then
      printf '%-22s %-8s %-8s %s\n' "$name" "$pinned" "-" "no flake.lock"
      continue
    fi

    current=$(pinned_rev "$dir/flake.lock")
    if [ "$pinned" = "-" ]; then
      state="not pinned"
    elif [ "$pinned" != "$current" ]; then
      state="stale, lock moved"
    elif [ "$pinned_hash" != "$(flake_hash "$dir")" ]; then
      state="stale, flake edited"
    else
      state="ok"
    fi
    printf '%-22s %-8s %-8s %s\n' "$name" "$pinned" "$current" "$state"
  done < <(printf '%s\n' "${active[@]}")
}

# Records each listed devshell as a gc root by building the environment
# derivation that `nix develop` would use. Two steps, as nix-direnv does it:
# `print-dev-env` builds the env and prints shell code; we discard the code,
# so the shellHook inside it never runs. `nix build --out-link` then turns the
# env into a root.
#
# The commands run with the project as their working directory rather than as
# a `path:` flake ref. In a git repo nix copies only tracked files, so build
# output (tangled/ting/target is 12 GiB) never lands in the store; an explicit
# path: copies the whole directory, artifacts included.
cmd_pin() {
  mkdir -p "$root"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  failed=0

  while read -r name; do
    dir="$projects_dir/$name"

    if [ ! -d "$dir" ]; then
      printf '%-22s %s\n' "$name" "skipped, missing directory"
      continue
    fi
    if [ ! -f "$dir/flake.nix" ]; then
      printf '%-22s %s\n' "$name" "skipped, no flake.nix"
      continue
    fi
    # A lock-less flake would get one written into the working tree by
    # print-dev-env, so leave those alone.
    if [ ! -f "$dir/flake.lock" ]; then
      printf '%-22s %s\n' "$name" "skipped, no flake.lock"
      continue
    fi

    # `nix develop` falls back to packages.default when a flake has no
    # devShells, which would pin an unrelated package closure.
    has_shell=$(cd "$dir" && nix eval --json ".#devShells.x86_64-linux" \
      --apply 'builtins.hasAttr "default"' 2>/dev/null || echo false)
    if [ "$has_shell" != "true" ]; then
      printf '%-22s %s\n' "$name" "skipped, no devShell"
      continue
    fi

    rev=$(pinned_rev "$dir/flake.lock")
    mkdir -p "$root/$(dirname "$name")"
    if log=$(cd "$dir" && nix print-dev-env --profile "$tmp/env" 2>&1) \
      && envpath=$(readlink -f "$tmp/env") \
      && nix build --out-link "$root/$name" "$envpath" >/dev/null 2>&1; then
      printf '%s %s\n' "$rev" "$(flake_hash "$dir")" >"$root/$name.rev"
      printf '%-22s %s\n' "$name" "pinned $rev"
    else
      printf '%-22s %s\n' "$name" "FAILED, kept previous pin"
      printf '%s\n' "$log" | tail -3 | sed 's/^/    /'
      failed=$((failed + 1))
    fi
  done < <(printf '%s\n' "${active[@]}")

  # The list is authoritative: a project removed from it stops pinning, so its
  # closure is collectable again on the next run.
  while IFS= read -r -d '' link; do
    name=${link#"$root"/}
    if ! is_listed "$name"; then
      rm -f "$link" "$root/$name.rev"
      printf '%-22s %s\n' "$name" "unpinned, no longer listed"
    fi
  done < <(find "$root" -type l -print0)

  [ "$failed" -eq 0 ]
}

case "${1:-list}" in
  find) cmd_find ;;
  list) cmd_list ;;
  pin) cmd_pin ;;
  *) echo "usage: $(basename "$0") [find|list|pin]" >&2; exit 2 ;;
esac
