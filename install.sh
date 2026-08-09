#!/usr/bin/env bash
#
# AudioTAMS unattended installer.
#
#   curl -fsSL https://raw.githubusercontent.com/brianwynne/audiotams-install/main/install.sh | sudo bash
#
# Installs the binary, a hardened systemd service, nginx in front of it, a firewall, a management
# command and a login banner. Re-running it upgrades in place and never touches your config or data.
#
# No credential is needed. The source repository is private; the bundles are published to the PUBLIC
# repository above, which is what this downloads from. Nothing about the archive, the stations or the
# internal hostnames goes with them — only the built binary and the deploy assets.
#
# This file lives in the private repository at deploy/install.sh and is copied to the public one by the
# release workflow, so there is one source of truth and the two cannot drift.
#
# Options:
#   --tag vX.Y.Z      install a specific release (default: the latest)
#   --domain HOST     server_name for nginx (default: this machine's hostname)
#   --port N          loopback port for the application (default: 8090)
#   --no-nginx        do not install or touch nginx
#   --no-firewall     do not install or touch ufw
#   --no-start        install everything but do not start the service
#   --from-dir DIR    install from a local build instead of downloading (for testing the installer)
set -euo pipefail

# Bundles and this installer are published here. Public on purpose: an install should not need a
# credential, and an upgrade at 3am should not fail because a token expired.
REPO="brianwynne/audiotams-install"
TAG=""; DOMAIN=""; PORT=8090
WANT_NGINX=1; WANT_FIREWALL=1; WANT_START=1; FROM_DIR=""

APP_USER="audiotams"
OPT_DIR="/opt/audiotams"
ETC_DIR="/etc/audiotams"
LIB_DIR="/var/lib/audiotams"
LOG_DIR="/var/log/audiotams"

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:?--tag needs a version}"; shift 2 ;;
    --domain) DOMAIN="${2:?--domain needs a hostname}"; shift 2 ;;
    --port) PORT="${2:?--port needs a number}"; shift 2 ;;
    --no-nginx) WANT_NGINX=0; shift ;;
    --no-firewall) WANT_FIREWALL=0; shift ;;
    --no-start) WANT_START=0; shift ;;
    --from-dir) FROM_DIR="${2:?--from-dir needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mx\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root: pipe to 'sudo -E bash', or 'sudo -E ./install.sh'"
command -v apt-get >/dev/null 2>&1 || die "this installer supports Debian/Ubuntu (apt). Everything it does is in the file if you need another distribution."

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m). Releases are built for x86_64 and arm64." ;;
esac
[ -n "$DOMAIN" ] || DOMAIN="$(hostname -f 2>/dev/null || hostname)"

say "AudioTAMS installer — linux/$ARCH, serving as ${DOMAIN}"

# --- 1. packages -----------------------------------------------------------------------------------
say "Installing what it needs"
PKGS="ca-certificates curl ffmpeg"
[ "$WANT_NGINX" = 1 ] && PKGS="$PKGS nginx"
[ "$WANT_FIREWALL" = 1 ] && PKGS="$PKGS ufw"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# shellcheck disable=SC2086
apt-get install -y -qq --no-install-recommends $PKGS >/dev/null
ok "ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')${WANT_NGINX:+, nginx}"

# --- 2. the release --------------------------------------------------------------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if [ -n "$FROM_DIR" ]; then
  say "Installing from $FROM_DIR"
  [ -x "$FROM_DIR/audiotams" ] || die "no audiotams binary in $FROM_DIR"
  cp -r "$FROM_DIR/." "$WORK/"
  VERSION="$(cat "$FROM_DIR/VERSION" 2>/dev/null || echo local)"
else
  # A token is not required. One is used if present, purely to lift GitHub's unauthenticated rate limit
  # on a machine that installs repeatedly.
  TOKEN="${GITHUB_TOKEN:-}"
  api() {
    if [ -n "$TOKEN" ]; then curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$@"
    else curl -fsSL -H "Accept: application/vnd.github+json" "$@"; fi
  }
  dl() {
    if [ -n "$TOKEN" ]; then curl -fsSL -H "Authorization: Bearer $TOKEN" "$@"
    else curl -fsSL "$@"; fi
  }
  if [ -n "$TAG" ]; then
    REL="$(api "https://api.github.com/repos/$REPO/releases/tags/$TAG")" || die "no release tagged $TAG in $REPO"
  else
    REL="$(api "https://api.github.com/repos/$REPO/releases/latest")" || die "cannot read the latest release of $REPO"
  fi
  VERSION="$(printf '%s' "$REL" | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
  [ -n "$VERSION" ] || die "could not read a tag_name from the release"
  ASSET="audiotams_${VERSION}_linux_${ARCH}.tar.gz"
  say "Fetching $VERSION ($ASSET)"

  BASE="https://github.com/$REPO/releases/download/$VERSION"
  dl -o "$WORK/bundle.tar.gz" "$BASE/$ASSET" || die "release $VERSION has no asset named $ASSET"

  # Checksums travel with the release; a bundle that does not match is not installed.
  if dl -o "$WORK/SHA256SUMS" "$BASE/SHA256SUMS" 2>/dev/null; then
    want="$(grep " $ASSET\$" "$WORK/SHA256SUMS" | awk '{print $1}')"
    got="$(sha256sum "$WORK/bundle.tar.gz" | awk '{print $1}')"
    [ -n "$want" ] || die "SHA256SUMS has no line for $ASSET"
    [ "$want" = "$got" ] || die "checksum mismatch for $ASSET — refusing to install"
    ok "checksum verified"
  else
    warn "the release carries no SHA256SUMS; installing unverified"
  fi
  tar -xzf "$WORK/bundle.tar.gz" -C "$WORK" --strip-components=1
fi
ok "version $VERSION"

# --- 3. user, directories --------------------------------------------------------------------------
say "Laying out the filesystem"
# A system account with as little as an account can have: its own group, no password, no login shell,
# no home directory of its own beyond the data it owns, and no membership of anything else. It exists
# so the service is not root; it is not for a person, and nothing should ever su to it.
getent group "$APP_USER" >/dev/null 2>&1 || groupadd --system "$APP_USER"
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --system --gid "$APP_USER" --home-dir "$LIB_DIR" --no-create-home \
          --shell /usr/sbin/nologin --comment "AudioTAMS service account" "$APP_USER"
  passwd --lock "$APP_USER" >/dev/null 2>&1 || true
fi
install -d -m 0755 "$OPT_DIR" "$ETC_DIR"
install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "$LIB_DIR" "$LIB_DIR/data" "$LIB_DIR/tmp" "$LOG_DIR"
install -m 0755 "$WORK/audiotams" "$OPT_DIR/audiotams"
printf '%s\n' "$VERSION" > "$OPT_DIR/VERSION"
# The templates travel with the install: `audiotams cert` renders the TLS site from them later, and it
# must use the ones that shipped with THIS binary rather than whatever a newer master branch has.
install -d -m 0755 "$OPT_DIR/deploy"
install -m 0644 "$WORK/deploy/nginx-site-http.conf.template" "$WORK/deploy/nginx-site-tls.conf.template" \
        "$WORK/deploy/nginx-proxy-snippet.conf" "$WORK/deploy/audiotams.yaml.template" "$OPT_DIR/deploy/"
install -m 0755 "$WORK/deploy/nginx-render.sh" "$OPT_DIR/deploy/nginx-render.sh"
# The install/release documentation goes on the machine as well: an operator reading the banner at 2am
# should not have to find the repository to learn what `upgrade` does to their config.
install -d -m 0755 "$OPT_DIR/docs"
[ -f "$WORK/deploy/INSTALL.md" ] && install -m 0644 "$WORK/deploy/INSTALL.md" "$OPT_DIR/docs/INSTALL.md"
ok "$OPT_DIR (code) · $ETC_DIR (config) · $LIB_DIR (data) · $LOG_DIR (logs)"
ok "service account $APP_USER — system, no login, owns only its data and logs"

# Config is written once. An upgrade must never edit what an operator has tuned.
if [ ! -f "$ETC_DIR/audiotams.yaml" ]; then
  sed "s/__PORT__/$PORT/" "$WORK/deploy/audiotams.yaml.template" > "$ETC_DIR/audiotams.yaml"
  chown root:"$APP_USER" "$ETC_DIR/audiotams.yaml"; chmod 0640 "$ETC_DIR/audiotams.yaml"
  ok "wrote $ETC_DIR/audiotams.yaml"
else
  ok "kept your existing $ETC_DIR/audiotams.yaml"
fi
# Nothing to save: upgrades need no credential. An earlier version stored one here, so remove it —
# a secret left on disk that nothing reads is a secret waiting to leak.
if [ -f "$ETC_DIR/.github-token" ]; then
  rm -f "$ETC_DIR/.github-token"
  ok "removed the stored GitHub token — upgrades no longer need one"
fi

# --- 4. management command and banner ---------------------------------------------------------------
install -m 0755 "$WORK/deploy/audiotams-cli.sh" /usr/local/bin/audiotams
install -d -m 0755 /etc/update-motd.d
install -m 0755 "$WORK/deploy/motd-audiotams.sh" /etc/update-motd.d/99-audiotams
ok "audiotams command installed; login banner added"

# --- 5. service --------------------------------------------------------------------------------------
say "Installing the service"
install -m 0644 "$WORK/deploy/audiotams.service" /etc/systemd/system/audiotams.service
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable audiotams >/dev/null 2>&1 || true
  if [ "$WANT_START" = 1 ]; then
    systemctl restart audiotams
    sleep 2
    if systemctl is-active --quiet audiotams; then ok "running on 127.0.0.1:$PORT"
    else warn "the service did not come up — sudo audiotams logs"; fi
  else
    ok "installed but not started (--no-start)"
  fi
else
  warn "no systemd here; the unit is installed but nothing was started"
fi

# --- 6. nginx ------------------------------------------------------------------------------------------
if [ "$WANT_NGINX" = 1 ]; then
  say "Putting nginx in front"
  install -d -m 0755 /etc/nginx/snippets /var/www/certbot
  install -m 0644 "$WORK/deploy/nginx-proxy-snippet.conf" /etc/nginx/snippets/audiotams-proxy.conf
  # The map has to be at http level, so it goes in conf.d rather than in the site.
  install -d -m 0755 /etc/nginx/conf.d
  install -m 0644 "$WORK/deploy/nginx-forwarded-map.conf" /etc/nginx/conf.d/audiotams-forwarded.conf
  # Keep whichever variant is already in place: re-running must not undo `audiotams cert`.
  if grep -q "listen 443" /etc/nginx/sites-available/audiotams 2>/dev/null; then
    "$OPT_DIR/deploy/nginx-render.sh" "$OPT_DIR/deploy/nginx-site-tls.conf.template" \
        "$DOMAIN" "$PORT" /etc/nginx/sites-available/audiotams
    ok "kept HTTPS (certificate already issued)"
  else
    "$OPT_DIR/deploy/nginx-render.sh" "$OPT_DIR/deploy/nginx-site-http.conf.template" \
        "$DOMAIN" "$PORT" /etc/nginx/sites-available/audiotams
    ok "HTTP now — run 'sudo audiotams cert $DOMAIN' for HTTPS"
  fi
  ln -sf /etc/nginx/sites-available/audiotams /etc/nginx/sites-enabled/audiotams
  [ -e /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default && ok "removed nginx's default site"
  if nginx -t >/dev/null 2>&1; then
    if [ -d /run/systemd/system ]; then systemctl reload nginx 2>/dev/null || systemctl restart nginx || true; fi
    ok "nginx serving http://$DOMAIN/"
  else
    nginx -t || true
    die "nginx rejected the configuration; nothing was reloaded"
  fi
fi

# --- 7. firewall ---------------------------------------------------------------------------------------
if [ "$WANT_FIREWALL" = 1 ]; then
  say "Closing the box down"
  ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
  ok "22, 80, 443 only — the application is on loopback and is not reachable directly"
fi

# --- 8. what now ----------------------------------------------------------------------------------------
cat <<SUMMARY

  AudioTAMS $VERSION is installed.

    Editor        http://$DOMAIN/
    HTTPS         sudo audiotams cert $DOMAIN     ← the only step left
    Commands      audiotams help
    Config        $ETC_DIR/audiotams.yaml
    Logs          sudo audiotams logs

SUMMARY
