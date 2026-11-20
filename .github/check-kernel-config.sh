#!/usr/bin/env bash
# Assert that a generated kernel .config still carries the settings the host's
# kernel file asks for.
#
#   check-kernel-config.sh <configfile> <asserts>
#
# Why this exists: the kernels are built with `ignoreConfigErrors = true`, which
# silences both of generate-config.pl's failure channels, a symbol that no
# longer exists (renamed or dropped upstream) and one whose value a `select` or
# an unmet dependency rewrote. Neither prints anything, so the only way to see
# a bump that quietly reverts a tuned setting is to read the generated file
# back. Both the kernel build and the daily pin check run this before spending
# two hours or merging a PR.
#
# Each non-blank line of the asserts file is the literal text the .config must
# contain. A line that starts with "# CONFIG_" is an assertion ("is not set"),
# not a comment; any other "#" line is prose.
set -euo pipefail

config=${1:?usage: check-kernel-config.sh <configfile> <asserts>}
asserts=${2:?usage: check-kernel-config.sh <configfile> <asserts>}

[ -f "$config" ] || { echo "no .config at $config" >&2; exit 1; }
[ -f "$asserts" ] || { echo "no assertion list at $asserts" >&2; exit 1; }

if grep -q '^CONFIG_X86_NATIVE_CPU=y' "$config"; then
  echo "X86_NATIVE_CPU leaked into kernel .config" >&2
  exit 1
fi

missing=0
checked=0
while IFS= read -r expected; do
  case $expected in
    '') continue ;;
    '# CONFIG_'*) ;;
    '#'*) continue ;;
  esac
  checked=$((checked + 1))
  if ! grep -qxF "$expected" "$config"; then
    echo "kernel .config lost a tuned setting: $expected" >&2
    missing=$((missing + 1))
  fi
done <"$asserts"

if [ "$missing" -ne 0 ]; then
  echo "$missing assertion(s) failed against $config" >&2
  exit 1
fi
echo "$((checked - missing))/$checked assertion lines hold against $(basename "$config")"
