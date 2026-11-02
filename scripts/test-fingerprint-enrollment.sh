#!/usr/bin/env bash
# Run as your normal user while fingerprint.nix has enrollmentMode = true.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run as your normal user; this checks that non-root access is denied." >&2
  exit 1
fi

manager=(busctl --system call net.reactivated.Fprint /net/reactivated/Fprint/Manager net.reactivated.Fprint.Manager GetDevices)
if output=$("${manager[@]}" 2>&1); then
  echo "FAIL: unprivileged access to the setup backend was allowed" >&2
  exit 1
fi
[[ "$output" == *"Access denied"* ]] || { echo "$output" >&2; exit 1; }

output=$(sudo "${manager[@]}")
[[ "$output" == 'ao 1 '* ]] || { echo "FAIL: expected one reader, got: $output" >&2; exit 1; }
echo "PASS: reader detected; setup API is root-only"
