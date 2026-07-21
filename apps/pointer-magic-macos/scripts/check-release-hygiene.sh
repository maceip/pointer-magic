#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h:h}
cd "$ROOT"

EXCLUDE=(
  --glob '!.git/**'
  --glob '!**/.build/**'
  --glob '!**/node_modules/**'
  --glob '!**/.next/**'
  --glob '!**/out/**'
  --glob '!**/coverage/**'
  --glob '!**/.swiftpm/**'
  --glob '!**/check-release-hygiene.sh'
)

fail=0

# Build forbidden literals so this script does not match itself.
machine_home="/Users/"$'\x6d\x61\x63'
machine_slug="-Users-"$'\x6d\x61\x63'

if hits=$(rg -n "${EXCLUDE[@]}" --fixed-strings "$machine_home" . 2>/dev/null); then
  print -u2 "ERROR: machine-specific absolute path ${machine_home} found:"
  print -u2 "$hits"
  fail=1
fi

# Allow only neutral fixture homes in committed sources.
if hits=$(rg -n "${EXCLUDE[@]}" '/Users/[A-Za-z0-9._-]+' . 2>/dev/null \
  | rg -v '/Users/(example|test|runner)\b'); then
  print -u2 "ERROR: non-neutral /Users/<name> absolute paths found:"
  print -u2 "$hits"
  fail=1
fi

if hits=$(rg -n "${EXCLUDE[@]}" --fixed-strings "$machine_slug" . 2>/dev/null); then
  print -u2 "ERROR: username-shaped Claude project slug ${machine_slug} found:"
  print -u2 "$hits"
  fail=1
fi

# Product rename gate: old brand must not remain in source/docs.
# Construct literals so this file never self-matches.
old_display=$'Magic'" Pointer"
old_camel=$'Magic'"Pointer"
old_kebab=$'magic'"-pointer"
old_env=$'MAGIC'"_POINTER"
if hits=$(rg -n "${EXCLUDE[@]}" -e "$old_display" -e "$old_camel" -e "$old_kebab" -e "$old_env" . 2>/dev/null); then
  print -u2 "ERROR: old product name ${old_display} / ${old_camel} still present:"
  print -u2 "$hits"
  fail=1
fi

if (( fail )); then
  exit 1
fi

print "Release hygiene OK (no machine-specific home paths; Pointer Magic naming clean)."
