#!/usr/bin/env bash
# Build-time helper, runs in the fetch stage.
#
#   fetch-cloud-clis.sh awscli   - download, GPG-verify and install AWS CLI v2
#   fetch-cloud-clis.sh keyrings - fetch the apt signing keys for the Azure and
#                                  Google Cloud repositories
set -euo pipefail

case "${1:?mode required}" in
awscli)
  # Empty dir when AWS is not selected: the runtime stage copies this path
  # unconditionally, and an empty copy is what keeps the 249MB out of the
  # image rather than merely hidden behind a later `rm`.
  mkdir -p /usr/local/aws-cli
  if ! cloud-select.sh want aws "${INSTALL_AWS_CLI:-auto}"; then
    echo "==> skipping AWS CLI (CLOUDS='${CLOUDS:-aws}')"
    exit 0
  fi

  case "$(uname -m)" in
    x86_64) asset=awscli-exe-linux-x86_64.zip ;;
    aarch64) asset=awscli-exe-linux-aarch64.zip ;;
    *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  cd "$work"

  echo "==> fetching ${asset}"
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -O "https://awscli.amazonaws.com/${asset}"
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -O "https://awscli.amazonaws.com/${asset}.sig"

  echo "==> verifying signature"
  export GNUPGHOME="${work}/gnupg"
  mkdir -m 700 -p "$GNUPGHOME"
  gpg --batch --quiet --import /usr/local/share/aws-cli-public-key.asc
  # AWS still signs with a key that shows as expired, so gpg exits 0 with a
  # warning. Assert on the output instead of trusting the exit code alone.
  gpg --batch --status-fd 1 --verify "${asset}.sig" "$asset" > verify.out 2>/dev/null
  # An expired key reports EXPKEYSIG rather than GOODSIG; VALIDSIG with the
  # full fingerprint is the assertion that actually matters.
  grep -Eq '^\[GNUPG:\] (GOODSIG|EXPKEYSIG) A6310ACC4672475C ' verify.out
  grep -q '^\[GNUPG:\] VALIDSIG FB5DB77FD5C118B80511ADA8A6310ACC4672475C' verify.out
  echo "    good signature from FB5DB77FD5C118B80511ADA8A6310ACC4672475C"

  unzip -q "$asset"
  ./aws/install --install-dir /usr/local/aws-cli --bin-dir /usr/local/bin
  # ~40MB of `aws help examples` text nobody reads in a container
  rm -rf /usr/local/aws-cli/v2/*/dist/awscli/examples
  aws --version
  ;;

keyrings)
  mkdir -p /out/keyrings
  if cloud-select.sh want azure "${INSTALL_AZURE_CLI:-auto}"; then
    echo "==> microsoft apt key"
    curl -fsSL --retry 5 --retry-all-errors https://packages.microsoft.com/keys/microsoft.asc \
      | gpg --dearmor > /out/keyrings/microsoft.gpg
  fi
  if cloud-select.sh want gcp "${INSTALL_GCLOUD:-auto}"; then
    echo "==> google cloud apt key"
    # served ASCII-armored despite the .gpg name, so dearmor it or apt reports
    # NO_PUBKEY for a key that is right there in the file
    curl -fsSL --retry 5 --retry-all-errors https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --dearmor > /out/keyrings/google-cloud.gpg
  fi
  chmod 0644 /out/keyrings/*.gpg 2>/dev/null || true
  ;;

*)
  echo "unknown mode $1" >&2
  exit 1
  ;;
esac
