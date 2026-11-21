#!/usr/bin/env bash
# Confine all build writes, including implicit home/cache/tmp writes, to the SSD.
set -euo pipefail
root=${1:?usage: ssd-run.sh /absolute/ssd/workspace command [args...]}
shift
[[ "$root" = /* && "$root" != *" "* ]] || exit 2
user_dir=$(getent passwd "$(id -u)" | cut -d: -f6)
[[ "$user_dir" = /home/* ]] || { echo "Expected a /home login path" >&2; exit 2; }
mkdir -p "$root/config" "$root/cache/vpython" "$root/cache/cipd" "$root/cache/xdg" "$root/tmp/runtime"
chmod 700 "$root/tmp/runtime"
exec bwrap --ro-bind / / --dev-bind /dev /dev --proc /proc \
  --bind "$root" "$root" --bind "$root/tmp" /tmp --tmpfs /home \
  --dir "$user_dir" --bind "$root/config" "$user_dir" --chdir "$root" \
  --setenv XDG_CACHE_HOME "$root/cache/xdg" --setenv XDG_CONFIG_HOME "$root/config" \
  --setenv XDG_DATA_HOME "$root/config/data" --setenv XDG_STATE_HOME "$root/config/state" \
  --setenv XDG_RUNTIME_DIR "$root/tmp/runtime" \
  --setenv VPYTHON_VIRTUALENV_ROOT "$root/cache/vpython" --setenv CIPD_CACHE_DIR "$root/cache/cipd" \
  --setenv TMPDIR "$root/tmp" --setenv DEPOT_TOOLS_UPDATE 0 \
  --setenv PATH "$root/depot_tools:/usr/local/bin:/usr/bin:/bin" "$@"
