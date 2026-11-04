#!/usr/bin/env bash
# MonoPbx one-line install (Debian package `monopbx` from the MonoPbx APT repository):
#
#   curl -fsSL https://ilinaya.github.io/monopbx-apt/install.sh | sudo bash -s -- --domain pbx.example.com --email admin@example.com
#
# 1. checks the system: Ubuntu 24.04 LTS on amd64 (anything else is refused, nothing is changed)
# 2. adds the MonoPbx APT repository and its signing key (fingerprint pinned below and verified)
# 3. apt-get install monopbx (pulls in Ubuntu's docker.io and docker-compose-v2)
# 4. runs `monopbx setup` with the options given here (see `monopbx help`): --domain, --email, --no-tls, --relay URL,
#    --no-relay, --public-ip, --turn, --yes. Without --domain the name is <public-ip>.sslip.io.
#
# Re-running is safe. MONOPBX_REPO_URL overrides the repository (https only); --no-setup stops after step 3.
# The whole script is one function called on the last line, so a truncated download runs nothing.
set -euo pipefail

REPO_URL_DEFAULT="https://ilinaya.github.io/monopbx-apt"
# The MonoPbx APT signing key (RSA 4096). The downloaded key must have exactly this fingerprint.
KEY_FPR="320DC78EFDC8439C04F5FCA63E87FE3D4C715372"
KEYRING=/etc/apt/keyrings/monopbx.gpg
SOURCES=/etc/apt/sources.list.d/monopbx.sources

say()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

monopbx_install() {
  local setup=1 args=()
  for a in "$@"; do
    case "$a" in
      --no-setup) setup=0 ;;
      *) args+=("$a") ;;
    esac
  done
  [ "$(uname -s)" = Linux ] || die "MonoPbx installs on Ubuntu 24.04 LTS servers only"
  [ "$(id -u)" -eq 0 ] || die "run as root: curl -fsSL $REPO_URL_DEFAULT/install.sh | sudo bash -s -- --domain ... --email ..."
  local id="" ver="" name=""
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && { id="$(. /etc/os-release && echo "${ID:-}")"; ver="$(. /etc/os-release && echo "${VERSION_ID:-}")"; name="$(. /etc/os-release && echo "${PRETTY_NAME:-}")"; }
  if [ "$id" != ubuntu ] || [ "$ver" != 24.04 ]; then
    die "unsupported system: ${name:-unknown}. MonoPbx supports Ubuntu 24.04 LTS only (Ubuntu 22.04 and Debian 12 are not supported yet). Nothing was changed"
  fi
  local arch; arch="$(dpkg --print-architecture)"
  [ "$arch" = amd64 ] || die "unsupported architecture $arch: the MonoPbx images are amd64 only. Nothing was changed"
  [ -d /run/systemd/system ] || die "systemd is not running as init; MonoPbx runs as a systemd service"

  local repo="${MONOPBX_REPO_URL:-$REPO_URL_DEFAULT}"
  repo="${repo%/}"
  case "$repo" in https://*) ;; *) die "MONOPBX_REPO_URL must be https://" ;; esac

  export DEBIAN_FRONTEND=noninteractive
  say "Prerequisites"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg >/dev/null

  say "MonoPbx APT repository: $repo"
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 "$repo/key.gpg" -o "$tmp/key.gpg" || die "cannot download $repo/key.gpg"
  local fprs; fprs="$(gpg --show-keys --with-colons "$tmp/key.gpg" 2>/dev/null | awk -F: '$1=="fpr" {print $10}')"
  grep -qx "$KEY_FPR" <<<"$fprs" || die "the key at $repo/key.gpg does not have the expected fingerprint $KEY_FPR; refusing to trust it"
  install -d -m 0755 /etc/apt/keyrings
  install -m 0644 "$tmp/key.gpg" "$KEYRING"
  printf '    signing key verified: %s\n' "$KEY_FPR"
  cat >"$SOURCES" <<EOF
Types: deb
URIs: $repo
Suites: stable
Components: main
Architectures: amd64
Signed-By: $KEYRING
EOF
  apt-get update -qq
  say "Installing monopbx (with Ubuntu's docker.io and docker-compose-v2 unless Docker is already installed)"
  apt-get install -y -qq monopbx >/dev/null || apt-get install -y monopbx
  systemctl enable --now docker.service >/dev/null 2>&1 || true
  printf '    %s\n' "$(monopbx version | head -n1)"

  if [ "$setup" -eq 0 ]; then
    say "Installed. Set it up with: sudo monopbx setup --domain pbx.example.com --email admin@example.com"
    return 0
  fi
  say "monopbx setup ${args[*]+"${args[*]}"}"
  monopbx setup "${args[@]+"${args[@]}"}"
}

monopbx_install "$@"
