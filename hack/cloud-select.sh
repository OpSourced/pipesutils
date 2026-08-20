#!/usr/bin/env bash
# Decides what a build contains, from the CLOUDS build arg.
#
#   cloud-select.sh validate            reject unknown cloud names
#   cloud-select.sh selected <cloud>    is <cloud> in CLOUDS?
#   cloud-select.sh want <cloud> <override>
#                                       should the vendor CLI be installed?
#                                       override: auto | true | false
#
# `want` exits 0 for yes, 1 for no, so it reads naturally in an if.
set -euo pipefail

SUPPORTED="aws azure gcp"
clouds="${CLOUDS:-aws}"

selected() {
  case " ${clouds} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

case "${1:?mode required}" in
validate)
  for c in ${clouds}; do
    case " ${SUPPORTED} " in
      *" ${c} "*) ;;
      *)
        echo "unsupported cloud '${c}' in CLOUDS='${clouds}' (supported: ${SUPPORTED})" >&2
        exit 1
        ;;
    esac
  done
  echo "clouds: ${clouds}"
  ;;

selected)
  selected "${2:?cloud required}"
  ;;

want)
  cloud="${2:?cloud required}"
  case "${3:-auto}" in
    true) exit 0 ;;
    false) exit 1 ;;
    *) selected "$cloud" ;;
  esac
  ;;

*)
  echo "unknown mode $1" >&2
  exit 1
  ;;
esac
