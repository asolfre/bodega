#!/bin/sh
# Stand-in brew for confirmation tests: run Bodega with BODEGA_BREW=<path to this file>.
# Everything goes to real brew except a real `cleanup` and a real `upgrade` (logged, not run).
# Copy it to $TMPDIR first: macOS may not let a GUI app run a script from a cloud-synced folder.
LOG="${TMPDIR:-/tmp}/bodega/fake-actions.log"
case "$1" in
  cleanup)
    if [ "$2" = "-n" ]; then
      sleep "${FAKE_DRYRUN_SECS:-0}"; echo "Would remove: /fake/old-keg/1.0 (1 files, 1KB)"
      echo "==> This operation would free approximately 1KB of disk space."
    else
      echo "$(date +%T) FAKE brew $*" >> "$LOG"; echo "fake cleanup done"
    fi ;;
  upgrade)
    case " $* " in
      *" --dry-run "*|*" -n "*) exec /opt/homebrew/bin/brew "$@" ;;
      *) echo "$(date +%T) FAKE brew $*" >> "$LOG"; i=0; while [ $i -lt 3000 ]; do i=$((i+1)); echo "fake upgrade output line $i: ==> Pouring something--1.2.3.arm64_sonoma.bottle.tar.gz into /opt/homebrew/Cellar"; done ;;
    esac ;;
  *) exec /opt/homebrew/bin/brew "$@" ;;
esac
