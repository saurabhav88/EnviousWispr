#!/usr/bin/env bash
# scripts/lib/l10n-build-with-receipt.sh: run a Dev build and leave a String Catalog receipt
# only when that build succeeded on inputs that did not move (#3524 PR 3).
#
# One owner of the ORDER, shared by scripts/build-dev-app.sh (sourced) and the build-only
# command in code-tooling.md (run directly). scripts/lib/l10n-build-receipt.py owns the
# fingerprints, the receipt schema and publication; nothing here decides what is certified.
#
#   1. remove <derived-data>/ew-l10n-receipt.json, so a failed or interrupted build leaves none
#      (when the removal itself fails, see below)
#   2. read the input digest of this checkout's working bytes, just before compiling
#   3. run the build command IN this checkout (a subshell cd), keeping its exit status
#   4. on success, publish: the helper re-reads the inputs, refuses if they moved, and certifies
#      the extraction bytes the build left
#
# The build's own exit status is always the result. Each receipt problem is reported on stderr
# as "catalog receipt unavailable" and never changes that status. If step 1 fails, this build
# publishes nothing and the OLDER receipt stays on disk; it is not evidence about this build
# attempt, and the pre-push check uses it only if verification still proves it matches the pushed
# code and the extraction now on disk (otherwise COULD NOT RUN, and CI checks the catalogs). The
# receipt certifies the compile's string extraction only; it says nothing about signing,
# deploying or launching the app, which build-dev-app.sh does afterwards.
#
# Sourced:  ew_l10n_build_with_receipt <project-root> <derived-data> <build command...>
# Run:      l10n-build-with-receipt.sh <derived-data> -- <build command...>
#           (the project root is this script's checkout)

ew_l10n_build_with_receipt() {
  local root="$1" derived="$2" helper receipt digest="" rc=0 publish=1
  shift 2
  case "$derived" in
    /*) ;;
    *) derived="$root/$derived" ;;
  esac
  helper="$root/scripts/lib/l10n-build-receipt.py"
  receipt="$derived/ew-l10n-receipt.json"
  if python3 "$helper" invalidate --receipt "$receipt" && [ ! -e "$receipt" ]; then :; else
    echo "==> catalog receipt unavailable: could not remove $receipt; this build will not write a new one," \
      "and the older one is usable only if verification still matches it." >&2
    publish=0
  fi
  if [ "$publish" -eq 1 ]; then
    if digest="$(python3 "$helper" input-digest --repo "$root" --configuration Dev \
        | python3 -c 'import json, sys; print(json.load(sys.stdin)["input_digest"])')" && [ -n "$digest" ]; then :; else
      echo "==> catalog receipt unavailable: could not read the input digest before building." >&2
      publish=0
    fi
  fi
  if (cd "$root" && "$@"); then rc=0; else rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  if [ "$publish" -eq 1 ]; then
    if python3 "$helper" publish --repo "$root" --derived-data "$derived" --configuration Dev \
        --before "$digest" --build-exit 0 --receipt "$receipt"; then :; else
      echo "==> catalog receipt unavailable: the build succeeded, but its receipt was not written (see above)." >&2
    fi
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  if [ $# -lt 3 ] || [ "$2" != "--" ]; then
    echo "usage: $0 <derived-data> -- <build command...>" >&2
    exit 2
  fi
  _derived="$1"
  shift 2
  ew_l10n_build_with_receipt "$(cd "$(dirname "$0")/../.." && pwd)" "$_derived" "$@"
fi
