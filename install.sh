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

# Refuse a documentation domain. RFC 2606 reserves example.com/.org/.net and .example precisely so they
# cannot resolve — so one here came from copying an instruction verbatim, and it does not fail loudly:
# nginx has a single server block, which makes it the default for the port, so every request still
# matches and the mistake hides. What it breaks is later and worse — `audiotams cert` asks a public CA
# for a certificate for somebody else's name, and `upgrade` reads the domain back out of the site file
# and re-applies it forever. Better to stop now and be told.
case "$DOMAIN" in
  *.example.com|example.com|*.example.org|example.org|*.example.net|example.net|*.example|*.invalid|*.test|localhost)
    die ""$DOMAIN" is a documentation domain, not a hostname.

  Pass the name people will actually type:
      --domain audiotams.yourdomain.ie

  If this is an upgrade, the placeholder is already in /etc/nginx/sites-available/audiotams and every
  upgrade re-applies it — pass --domain once and it is corrected." ;;
esac

say "AudioTAMS installer — linux/$ARCH, serving as ${DOMAIN}"

WORK_APT="$(mktemp)"
WORK="$(mktemp -d)"
# One trap: a second `trap ... EXIT` silently replaces the first, so both temporaries go here.
trap 'rm -rf "$WORK"; rm -f "$WORK_APT"' EXIT

# --- 1. packages -----------------------------------------------------------------------------------
say "Installing what it needs"
PKGS="ca-certificates curl ffmpeg"
[ "$WANT_NGINX" = 1 ] && PKGS="$PKGS nginx"
[ "$WANT_FIREWALL" = 1 ] && PKGS="$PKGS ufw"
export DEBIAN_FRONTEND=noninteractive

# Ubuntu's mirrors publish AAAA records, so apt tries IPv6 first. On a host with no IPv6 route — an EC2
# instance in a subnet without it, which is the common case — every index fails with "Network is
# unreachable" and the output is a wall of warnings that hides whatever else went wrong. Ask for IPv4
# only when there is no IPv6 route to use.
APT_OPTS=""
if [ -z "$(ip -6 route show default 2>/dev/null)" ]; then
  APT_OPTS="-o Acquire::ForceIPv4=true"
  NO_IPV6=1
fi
# shellcheck disable=SC2086
apt-get $APT_OPTS update -qq 2>"$WORK_APT" || true
grep -q "Failed to fetch\|Unable to connect" "$WORK_APT" 2>/dev/null && ARCHIVE_UNREACHABLE=1
# Ubuntu's mirrors are configured over plain HTTP, and a security group that allows 443 out and not 80
# — a reasonable thing to build — blocks apt entirely while everything else works. The mirrors serve
# the same content over HTTPS, so try that before giving up.
#
# Only when apt has ALREADY failed, only Ubuntu's own URIs (a third-party repository may not offer
# HTTPS), with a backup and a rollback if it does not help. An installer should not rewrite a machine's
# package sources as a matter of course; fixing the failure in front of it is a different thing.
if [ "${ARCHIVE_UNREACHABLE:-0}" = 1 ]; then
  SRCS=$(grep -rlE '^(URIs:|deb )\s*http://[^ ]*ubuntu\.com' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true)
  if [ -n "$SRCS" ]; then
    say "The archive is unreachable over HTTP — trying HTTPS"
    # The rollback copy is per-run and lives in the scratch directory. It was a persistent .bak with
    # `cp -n`, which meant a second run found the first run's backup, refused to overwrite it, and then
    # "restored" content from a different day. A rollback that restores the wrong thing is worse than
    # no rollback: it is a silent edit dressed as a safety net.
    ROLLBACK="$WORK/apt-sources"; mkdir -p "$ROLLBACK"
    i=0
    for f in $SRCS; do i=$((i+1)); cp "$f" "$ROLLBACK/$i"; printf '%s\n' "$f" >> "$ROLLBACK/paths"; done
    # shellcheck disable=SC2086
    sed -i -E 's|http://([a-z0-9.-]*ubuntu\.com)|https://\1|g' $SRCS
    : > "$WORK_APT"
    # shellcheck disable=SC2086
    apt-get $APT_OPTS update -qq 2>"$WORK_APT" || true
    if grep -q "Failed to fetch\|Unable to connect" "$WORK_APT" 2>/dev/null; then
      i=0
      while IFS= read -r f; do i=$((i+1)); cp "$ROLLBACK/$i" "$f"; done < "$ROLLBACK/paths"
      warn "HTTPS did not help either — the sources are exactly as they were"
    else
      ARCHIVE_UNREACHABLE=0
      SWITCHED_HTTPS=1
      # Only now, having established the switch works, leave the operator a copy of the original.
      i=0
      while IFS= read -r f; do i=$((i+1)); cp "$ROLLBACK/$i" "$f.audiotams-http.bak"; done < "$ROLLBACK/paths"
      ok "switched Ubuntu's sources to HTTPS (originals kept as *.audiotams-http.bak)"
    fi
  fi
fi

# shellcheck disable=SC2086
apt-get $APT_OPTS install -y -qq --no-install-recommends $PKGS >/dev/null 2>&1 || true

# Whether apt worked matters less than whether the things it was for are present. A restricted network
# — no NAT, an egress policy, a proxy — makes apt fail noisily while the machine already has everything
# needed, and burying that in forty lines of warnings helps nobody. So check for the tools themselves,
# and only then decide whether this is a problem.
MISSING=""
command -v ffmpeg >/dev/null 2>&1 || MISSING="$MISSING ffmpeg"
command -v ffprobe >/dev/null 2>&1 || MISSING="$MISSING ffprobe"
[ "$WANT_NGINX" = 1 ] && { command -v nginx >/dev/null 2>&1 || MISSING="$MISSING nginx"; }
if [ -n "$MISSING" ]; then
  if [ "${ARCHIVE_UNREACHABLE:-0}" = 1 ]; then
    die "cannot reach the Ubuntu archive, and this machine is missing:$MISSING

  Nothing is installed. The release itself downloaded fine, so the network reaches GitHub but not
  archive.ubuntu.com — usually an egress policy, a missing NAT route, or a proxy this shell does not
  know about. Install those packages by whatever route this machine has, then run this again."
  fi
  die "these packages did not install:$MISSING"
fi
if [ "${ARCHIVE_UNREACHABLE:-0}" = 1 ]; then
  warn "could not reach the Ubuntu archive — carrying on, because everything needed is already here"
fi
ok "ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}')${WANT_NGINX:+, nginx}"

# --- 2. the release --------------------------------------------------------------------------------
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
# The Rotter ingest connector's volumes. Created whether or not ingest is enabled, so turning it on
# later is a config edit and a systemctl enable, not a hunt for why it cannot write.
# quarantine/ is separate from media/ deliberately: a recording preserved there must never be seen by
# the retention sweep, and must never be mistaken for one still being replicated.
install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "$LIB_DIR/media" "$LIB_DIR/quarantine"
install -m 0755 "$WORK/audiotams" "$OPT_DIR/audiotams"
# Both executables, from the same bundle, at the same version. The process that writes the media
# volume and the one that reads it are two halves of one agreement about where recordings live.
[ -f "$WORK/audiotams-ingest" ] && install -m 0755 "$WORK/audiotams-ingest" "$OPT_DIR/audiotams-ingest"
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
# ...and the ingest connector's, which is the one an operator reads at 3am when the archive has
# stopped growing. Same reason: a local file, not a repository they may not be able to reach.
[ -f "$WORK/deploy/INGEST.md" ] && install -m 0644 "$WORK/deploy/INGEST.md" "$OPT_DIR/docs/INGEST.md"
ok "$OPT_DIR (code) · $ETC_DIR (config) · $LIB_DIR (data) · $LOG_DIR (logs)"
ok "service account $APP_USER — system, no login, owns only its data and logs"

# Was this machine already running AudioTAMS before this run? The answer decides what the
# authentication file below is allowed to say, so it has to be taken before the config is written.
UPGRADE=no
[ -f "$ETC_DIR/audiotams.yaml" ] && UPGRADE=yes

# Config is written once. An upgrade must never edit what an operator has tuned.
if [ ! -f "$ETC_DIR/audiotams.yaml" ]; then
  sed "s/__PORT__/$PORT/" "$WORK/deploy/audiotams.yaml.template" > "$ETC_DIR/audiotams.yaml"
  chown root:"$APP_USER" "$ETC_DIR/audiotams.yaml"; chmod 0640 "$ETC_DIR/audiotams.yaml"
  ok "wrote $ETC_DIR/audiotams.yaml"
else
  ok "kept your existing $ETC_DIR/audiotams.yaml"
fi
# The environment file: where the authentication decision is written down, and later where the Entra
# client secret goes. Written ONCE, like the config, and never edited by an upgrade.
#
# What it says depends on whether this machine was ALREADY RUNNING, and the difference matters:
#
#   an UPGRADE inherits "run open", because that is what the box was doing five minutes ago. Turning a
#   running service into a stopped one is an outage, not a security improvement, and the operator gets
#   the same behaviour they had plus a file that now says so out loud.
#
#   a FRESH INSTALL inherits nothing, so it gets nothing. There is no running service to protect and
#   no behaviour to preserve — writing "let everybody in as an Administrator" as the factory setting
#   would hand every new machine an open archive and say so only in a log line. The server refuses to
#   start until somebody chooses, which is a loud, visible failure on a box nobody is using yet.
if [ ! -f "$ETC_DIR/audiotams.env" ]; then
  # Created with its permissions ALREADY on, then filled: a file that will hold a client secret must
  # never exist, even for an instant, at whatever the umask happened to be.
  install -m 0600 -o root -g root /dev/null "$ETC_DIR/audiotams.env"
  cat > "$ETC_DIR/audiotams.env" <<'ENVFILE'
# AudioTAMS environment. 0600, root-owned: this is where secrets go.
#
# YOU SHOULD NOT NEED TO EDIT THIS FILE. There is a command for each job, and each one asks you for
# what it needs — which is the difference between a change somebody makes correctly at 3am and one
# they make from memory:
#
#   sudo audiotams entra setup       first time: tenant, application, secret, redirect URI
#   sudo audiotams entra secret      a new client secret — the job that recurs
#   sudo audiotams entra redirect    change the address Entra returns to
#   sudo audiotams entra off         stop requiring sign-in (and: on)
#   audiotams entra                  what is configured, and when the secret runs out
#
# The login banner says which of those is outstanding, every time anybody logs in.
#
# Sign-in with Microsoft Entra ID. Set all four and sign-in becomes REQUIRED — there is no way to
# have a tenant configured here and authentication quietly switched off. See docs/entra-setup.md.
#
#ENTRA_TENANT_ID=
#ENTRA_CLIENT_ID=
#ENTRA_CLIENT_SECRET=
#ENTRA_REDIRECT_URI=https://your.domain/auth/callback
#ENTRA_POST_LOGOUT_URI=https://your.domain/

# Until then, this server signs nobody in: every visitor is treated as one anonymous user, and the
# network around it is the only thing deciding who that can be. Comment this out once the four
# settings above are filled in.
__ANON__AUDIOTAMS_ALLOW_ANONYMOUS=1

# What that anonymous visitor may do. Administrator by default, because this is also the switch an
# administrator throws when Entra is unavailable and the work has to continue — a break-glass that
# leaves half the job impossible gets worked around instead of used.
#
# The permission table still applies either way, and everything done is still written to the audit
# trail, as anonymous. Narrow it if the network in front of this server is broader than the set of
# people who should be able to delete things:
#
#   Viewer       browse and listen
#   Editor       ...and cut
#   Publisher    ...and export and publish
#   Administrator  ...and delete, and change the configuration
#
__ANON__AUDIOTAMS_ANONYMOUS_ROLE=Administrator
ENVFILE
  # Written out rather than left to the default, so what an anonymous visitor may do is a line
  # somebody can read rather than a fact about the binary.
  if [ "$UPGRADE" = yes ]; then
    sed -i 's/^__ANON__//' "$ETC_DIR/audiotams.env"
    warn "this machine had no sign-in, so it still has none — see $ETC_DIR/audiotams.env"
  else
    sed -i 's/^__ANON__/#/' "$ETC_DIR/audiotams.env"
  fi
  ok "wrote $ETC_DIR/audiotams.env — no sign-in yet; see it to add Entra"
else
  ok "kept your existing $ETC_DIR/audiotams.env"
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
# Installed, deliberately NOT enabled: ingest.enabled is false in a fresh config, and a service that
# starts and exits every ten seconds is worse than one an operator turns on when they mean to.
[ -f "$WORK/deploy/audiotams-ingest.service" ] && \
  install -m 0644 "$WORK/deploy/audiotams-ingest.service" /etc/systemd/system/audiotams-ingest.service
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable audiotams >/dev/null 2>&1 || true
  if [ "$WANT_START" = 1 ]; then
    systemctl restart audiotams
    sleep 2
    if systemctl is-active --quiet audiotams; then ok "running on 127.0.0.1:$PORT"
    else warn "the service did not come up — sudo audiotams logs"; fi
    # The ingest connector is only ever restarted if the operator had already enabled it. An upgrade
    # that left the OLD binary running would be worse than one that did nothing: it would go on
    # writing the media volume while its replacement sat unused beside it, and the version the banner
    # reports would not be the version doing the work.
    if systemctl is-enabled --quiet audiotams-ingest 2>/dev/null; then
      systemctl restart audiotams-ingest
      sleep 1
      if systemctl is-active --quiet audiotams-ingest; then ok "ingest connector restarted on the new build"
      else warn "the ingest connector did not come back — sudo audiotams ingest logs"; fi
    elif [ -x "$OPT_DIR/audiotams-ingest" ]; then
      ok "ingest connector installed, not enabled — sudo audiotams ingest enable"
    fi
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
    Secrets       $ETC_DIR/audiotams.env          ← sign-in goes here; open until it does
    Logs          sudo audiotams logs

SUMMARY
if [ -x "$OPT_DIR/audiotams-ingest" ] && ! systemctl is-enabled --quiet audiotams-ingest 2>/dev/null; then
  cat <<INGEST
  The Rotter ingest connector is installed and switched off. It copies the hourly radio recordings
  onto this machine so they play from here rather than from the Rotters, keeps seven days, and
  archives each completed hour to object storage. To turn it on:

    sudo audiotams config                add your rotters under \`ingest:\`, set enabled: true
    sudo audiotams ingest enable
    audiotams ingest status

  How it works, and what to do when it stops:  $OPT_DIR/docs/INGEST.md

INGEST
fi
if [ "${NO_IPV6:-0}" = 1 ]; then
  cat <<'IPV6'
  This machine has no IPv6 route, so apt was told to use IPv4 for this run. To spare yourself the
  same wall of warnings on every future apt command:

    echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4

IPV6
fi
if [ "${SWITCHED_HTTPS:-0}" = 1 ]; then
  cat <<'HTTPS'
  Ubuntu's package sources were switched from HTTP to HTTPS, because port 80 outbound is closed on
  this machine and apt could not reach the archive. Without it this box would take no security
  updates at all, silently. The originals are beside them as *.audiotams-http.bak.

HTTPS
fi
