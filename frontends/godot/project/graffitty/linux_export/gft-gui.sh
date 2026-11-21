#!/bin/sh
set -eu
if [ "${LD_LIBRARY_PATH+x}" ]; then export GRAFFITTY_SHELL_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"; fi
if [ "${LD_PRELOAD+x}" ]; then export GRAFFITTY_SHELL_LD_PRELOAD="$LD_PRELOAD"; fi
unset LD_LIBRARY_PATH LD_PRELOAD
entry=$(readlink -f "$0")
exec "${entry%/*}/tools/gft" internal gpu-start "$@"
