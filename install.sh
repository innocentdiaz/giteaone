#!/usr/bin/env bash
# Build Gitea from source and run it on Debian 12 (bookworm).
#
# Fresh VM, one line (builds, then installs and starts a systemd service):
#   curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<branch>/install.sh \
#     | sudo GITEA_REPO=https://github.com/<owner>/<repo>.git DATABASE_URL=postgres://... bash
#
# From a checkout of this repo:
#   sudo ./install.sh
#
# Commands:
#   all        (default) deps + build + runtime + configure, then a systemd service,
#              or a foreground process when systemd is not PID 1
#   deps       apt packages, Go, Node.js, pnpm at the versions the source pins
#   build      deps, then compile Gitea and install it to $GITEA_BIN
#   runtime    runtime packages, the git user, data directories
#   configure  write/update app.ini from the environment, migrate, create the admin
#   run        configure, then exec gitea in the foreground (containers, Render)
#   service    install and start the systemd unit
#
# Environment (all optional):
#   DATABASE_URL          postgres://user:pass@host[:port]/db[?sslmode=...] or mysql://...
#                         Unset means SQLite in $GITEA_WORK_DIR/data/gitea.db
#   GITEA_ADMIN_USER      admin account created on first start if missing
#   GITEA_ADMIN_PASSWORD  (with GITEA_ADMIN_EMAIL; registration is closed when these are set)
#   GITEA_ADMIN_EMAIL
#   PORT                  HTTP port (Render sets this); default 3000
#   RENDER_EXTERNAL_URL   public URL (Render sets this); becomes ROOT_URL
#   GITEA__section__KEY   any app.ini setting, applied on every configure
#   GITEA_REPO, GITEA_REF source to clone when not run from a checkout (default: upstream, latest release)
#   GITEA_WORK_DIR        data root (default /var/lib/gitea)
#   GITEA_TAGS            build tags (default "bindata timetzdata sqlite sqlite_unlock_notify")
#   NODE_MAJOR            Node.js line to install when the present one is too old (default 24)
set -Eeuo pipefail

GITEA_REPO=${GITEA_REPO:-https://github.com/go-gitea/gitea.git}
GITEA_REF=${GITEA_REF:-}
GITEA_SRC=${GITEA_SRC:-}
GITEA_USER=${GITEA_USER:-git}
GITEA_BIN=${GITEA_BIN:-/usr/local/bin/gitea}
GITEA_WORK_DIR=${GITEA_WORK_DIR:-/var/lib/gitea}
GITEA_CONFIG=${GITEA_CONFIG:-$GITEA_WORK_DIR/custom/conf/app.ini}
GITEA_TAGS=${GITEA_TAGS:-bindata timetzdata sqlite sqlite_unlock_notify}
NODE_MAJOR=${NODE_MAJOR:-24}
GITEA_HOME=/home/$GITEA_USER

export PATH=/usr/local/go/bin:/usr/local/bin:$PATH
export GOTOOLCHAIN=local CI=true DEBIAN_FRONTEND=noninteractive

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "run as root (sudo)"; }
version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }
# Exports only when the caller has not set the variable, so explicit settings win.
setdefault() { [[ -n ${!1+x} ]] || export "$1=$2"; }
urldecode() { printf '%b' "${1//%/\\x}"; }

arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

as_gitea() {
  setpriv --reuid="$GITEA_USER" --regid="$GITEA_USER" --init-groups \
    env HOME="$GITEA_HOME" USER="$GITEA_USER" GITEA_WORK_DIR="$GITEA_WORK_DIR" "$@"
}

apt_install() {
  local pkg missing=()
  for pkg; do dpkg -s "$pkg" &>/dev/null || missing+=("$pkg"); done
  ((${#missing[@]})) || return 0
  log "apt: installing ${missing[*]}"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
}

check_os() {
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  [[ ${ID:-} == debian && ${VERSION_ID:-} == 12 ]] || warn "built for Debian 12, found ${PRETTY_NAME:-unknown OS}"
}

resolve_source() {
  [[ -n $GITEA_SRC ]] && return
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]:-/nonexistent}")" 2>/dev/null && pwd) || here=
  if [[ -n $here && -f $here/go.mod ]] && grep -qE '^module (gitea\.dev|code\.gitea\.io/gitea)$' "$here/go.mod"; then
    GITEA_SRC=$here
    log "building from checkout $GITEA_SRC"
    return
  fi
  GITEA_SRC=/usr/local/src/gitea
  if [[ -d $GITEA_SRC/.git ]]; then
    git -C "$GITEA_SRC" fetch --quiet --tags origin
  else
    log "cloning $GITEA_REPO"
    git clone --quiet --filter=blob:none "$GITEA_REPO" "$GITEA_SRC"
  fi
  local ref=$GITEA_REF
  if [[ -z $ref ]]; then
    ref=$(git -C "$GITEA_SRC" tag -l 'v*' --sort=-v:refname | grep -vE -- '-(rc|dev)' | head -n1)
    [[ -n $ref ]] || die "no release tags in $GITEA_REPO; set GITEA_REF"
  fi
  log "checking out $ref"
  git -C "$GITEA_SRC" checkout --quiet --force "$ref"
}

install_go() {
  local want have
  want=$(sed -nE 's/^toolchain go([0-9.]+).*/\1/p' "$GITEA_SRC/go.mod")
  [[ -n $want ]] || want=$(sed -nE 's/^go ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' "$GITEA_SRC/go.mod")
  [[ $want == *.*.* ]] || want=$want.0
  have=$(go env GOVERSION 2>/dev/null | sed 's/^go//') || have=
  if [[ -n $have ]] && version_ge "$have" "$want"; then
    log "go $have (need $want)"
    return
  fi
  local file
  file="go${want}.linux-$(arch).tar.gz"
  log "installing go $want"
  curl -fsSL "https://dl.google.com/go/$file" -o "/tmp/$file"
  echo "$(curl -fsSL "https://dl.google.com/go/$file.sha256")  /tmp/$file" | sha256sum -c --quiet -
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "/tmp/$file"
  rm -f "/tmp/$file"
}

install_node() {
  local min have
  min=$(sed -nE 's/.*"node": *">= *([0-9.]+)".*/\1/p' "$GITEA_SRC/package.json" | head -n1)
  min=${min:-22.18.0}
  have=$(node -v 2>/dev/null | sed 's/^v//') || have=
  if [[ -n $have ]] && version_ge "$have" "$min"; then
    log "node $have (need >= $min)"
    return
  fi
  local a base sums file
  a=$(arch)
  [[ $a == amd64 ]] && a=x64
  base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"
  sums=$(curl -fsSL "$base/SHASUMS256.txt")
  file=$(awk -v suffix="-linux-$a.tar.xz" 'substr($2, length($2) - length(suffix) + 1) == suffix { print $2; exit }' <<<"$sums")
  [[ -n $file ]] || die "no Node.js $NODE_MAJOR build for linux-$a"
  log "installing ${file%-linux-*}"
  curl -fsSL "$base/$file" -o "/tmp/$file"
  (cd /tmp && grep " $file\$" <<<"$sums" | sha256sum -c --quiet -)
  tar -C /usr/local --strip-components=1 --no-same-owner -xJf "/tmp/$file" \
    --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md'
  rm -f "/tmp/$file"
  version_ge "$(node -v | sed 's/^v//')" "$min" || die "Node.js $NODE_MAJOR is older than $min; set NODE_MAJOR"
}

install_pnpm() {
  local want
  want=$(sed -nE 's/.*"packageManager": *"pnpm@([0-9][0-9.]*).*/\1/p' "$GITEA_SRC/package.json")
  [[ -n $want ]] || return 0
  if [[ "$(pnpm -v 2>/dev/null)" == "$want" ]]; then
    log "pnpm $want"
    return
  fi
  log "installing pnpm $want"
  # --force replaces a corepack shim occupying the pnpm bin name.
  npm install -g --force --silent "pnpm@$want" >/dev/null
}

cmd_deps() {
  need_root
  check_os
  apt_install ca-certificates curl git make gcc libc6-dev xz-utils
  resolve_source
  install_go
  install_node
  install_pnpm
}

cmd_build() {
  cmd_deps
  cd "$GITEA_SRC"
  # A manifest copied from another machine makes make skip the frontend build.
  rm -rf public/assets/.vite
  log "make build TAGS=\"$GITEA_TAGS\""
  make build TAGS="$GITEA_TAGS"
  install -m 0755 gitea "$GITEA_BIN"
  log "installed $("$GITEA_BIN" --version)"
}

cmd_runtime() {
  need_root
  apt_install ca-certificates git
  if ! id -u "$GITEA_USER" &>/dev/null; then
    log "creating user $GITEA_USER"
    useradd --system --user-group --create-home --home-dir "$GITEA_HOME" \
      --shell /bin/bash --comment 'Git Version Control' "$GITEA_USER"
  fi
  mkdir -p "$GITEA_WORK_DIR"
}

apply_database_url() {
  [[ -n ${DATABASE_URL:-} ]] || return 0
  local re='^([a-z0-9+]+)://([^:@/]+)(:([^@/]*))?@([^/:?]+)(:([0-9]+))?/([^?]+)(\?(.*))?$'
  [[ $DATABASE_URL =~ $re ]] || die "DATABASE_URL must look like postgres://user:password@host[:port]/dbname"
  local scheme=${BASH_REMATCH[1]} host=${BASH_REMATCH[5]} port=${BASH_REMATCH[7]} query=${BASH_REMATCH[10]}
  local user pass name type ssl
  user=$(urldecode "${BASH_REMATCH[2]}")
  pass=$(urldecode "${BASH_REMATCH[4]}")
  name=$(urldecode "${BASH_REMATCH[8]}")
  case $scheme in
    postgres | postgresql) type=postgres port=${port:-5432} ;;
    mysql | mariadb) type=mysql port=${port:-3306} ;;
    *) die "unsupported DATABASE_URL scheme: $scheme" ;;
  esac
  setdefault GITEA__database__DB_TYPE "$type"
  setdefault GITEA__database__HOST "$host:$port"
  setdefault GITEA__database__NAME "$name"
  setdefault GITEA__database__USER "$user"
  setdefault GITEA__database__PASSWD "$pass"
  if [[ $type == postgres ]]; then
    ssl=$(sed -nE 's/(^|.*&)sslmode=([^&]*).*/\2/p' <<<"$query")
    # Render's internal hostnames have no dots and no TLS; anything public gets TLS.
    [[ -n $ssl ]] || { [[ $host == *.* ]] && ssl=require || ssl=disable; }
    setdefault GITEA__database__SSL_MODE "$ssl"
  fi
  log "database: $type://$user@$host:$port/$name"
}

write_initial_config() {
  local domain root_url ssh_disabled=true registration_disabled=false
  domain=$(hostname -I 2>/dev/null | awk '{print $1}')
  domain=${domain:-localhost}
  root_url="http://$domain:3000/"
  [[ -x /usr/sbin/sshd ]] && ssh_disabled=false
  if [[ -n ${GITEA_ADMIN_USER:-} ]]; then
    registration_disabled=true
  else
    warn "GITEA_ADMIN_USER not set: registration stays open and the first account to sign up becomes admin"
  fi
  local gen=("$GITEA_BIN" generate secret)
  log "writing $GITEA_CONFIG"
  cat >"$GITEA_CONFIG" <<EOF
APP_NAME = Gitea
RUN_USER = $GITEA_USER
RUN_MODE = prod
WORK_PATH = $GITEA_WORK_DIR

[server]
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
DOMAIN = $domain
ROOT_URL = $root_url
APP_DATA_PATH = $GITEA_WORK_DIR/data
DISABLE_SSH = $ssh_disabled
SSH_DOMAIN = $domain
LFS_START_SERVER = true
LFS_JWT_SECRET = $("${gen[@]}" JWT_SECRET)
OFFLINE_MODE = true

[database]
DB_TYPE = sqlite3
PATH = $GITEA_WORK_DIR/data/gitea.db

[repository]
ROOT = $GITEA_WORK_DIR/data/gitea-repositories

[security]
INSTALL_LOCK = true
SECRET_KEY = $("${gen[@]}" SECRET_KEY)
INTERNAL_TOKEN = $("${gen[@]}" INTERNAL_TOKEN)

[oauth2]
JWT_SECRET = $("${gen[@]}" JWT_SECRET)

[service]
DISABLE_REGISTRATION = $registration_disabled

[log]
MODE = console
LEVEL = info
ROOT_PATH = $GITEA_WORK_DIR/log
EOF
}

ensure_admin() {
  [[ -n ${GITEA_ADMIN_USER:-} ]] || return 0
  [[ -n ${GITEA_ADMIN_PASSWORD:-} && -n ${GITEA_ADMIN_EMAIL:-} ]] ||
    die "GITEA_ADMIN_USER needs GITEA_ADMIN_PASSWORD and GITEA_ADMIN_EMAIL"
  if as_gitea "$GITEA_BIN" admin user list --config "$GITEA_CONFIG" | awk 'NR > 1 { print $2 }' | grep -qxF "$GITEA_ADMIN_USER"; then
    return 0
  fi
  log "creating admin $GITEA_ADMIN_USER"
  as_gitea "$GITEA_BIN" admin user create --config "$GITEA_CONFIG" --admin \
    --username "$GITEA_ADMIN_USER" --email "$GITEA_ADMIN_EMAIL" \
    --password "$GITEA_ADMIN_PASSWORD" --must-change-password=false
}

cmd_configure() {
  need_root
  [[ -x $GITEA_BIN ]] || die "$GITEA_BIN missing; run '$0 build' first"
  id -u "$GITEA_USER" &>/dev/null || cmd_runtime

  mkdir -p "$(dirname "$GITEA_CONFIG")" "$GITEA_WORK_DIR/data" "$GITEA_WORK_DIR/log"
  [[ -s $GITEA_CONFIG ]] || write_initial_config

  apply_database_url
  [[ -n ${PORT:-} ]] && setdefault GITEA__server__HTTP_PORT "$PORT"
  if [[ -n ${RENDER_EXTERNAL_URL:-} ]]; then
    local host
    host=$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"$RENDER_EXTERNAL_URL")
    setdefault GITEA__server__ROOT_URL "${RENDER_EXTERNAL_URL%/}/"
    setdefault GITEA__server__DOMAIN "$host"
    setdefault GITEA__server__SSH_DOMAIN "$host"
  fi
  "$GITEA_BIN" config edit-ini --config "$GITEA_CONFIG" --apply-env --in-place

  # A freshly mounted disk is root-owned; a recursive chown runs only then.
  [[ "$(stat -c %U "$GITEA_WORK_DIR")" == "$GITEA_USER" ]] || chown -R "$GITEA_USER:$GITEA_USER" "$GITEA_WORK_DIR"
  chown "$GITEA_USER:$GITEA_USER" "$GITEA_CONFIG"
  chmod 0640 "$GITEA_CONFIG"

  log "migrating database"
  as_gitea "$GITEA_BIN" migrate --config "$GITEA_CONFIG" >/dev/null
  ensure_admin
}

cmd_run() {
  cmd_configure
  log "starting gitea on port $(sed -nE 's/^HTTP_PORT *= *//p' "$GITEA_CONFIG" | head -n1)"
  cd "$GITEA_WORK_DIR"
  exec setpriv --reuid="$GITEA_USER" --regid="$GITEA_USER" --init-groups \
    env HOME="$GITEA_HOME" USER="$GITEA_USER" GITEA_WORK_DIR="$GITEA_WORK_DIR" \
    "$GITEA_BIN" web --config "$GITEA_CONFIG"
}

cmd_service() {
  need_root
  [[ -d /run/systemd/system ]] || die "systemd is not running; use '$0 run'"
  log "installing /etc/systemd/system/gitea.service"
  cat >/etc/systemd/system/gitea.service <<EOF
[Unit]
Description=Gitea (Git with a cup of tea)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$GITEA_USER
Group=$GITEA_USER
WorkingDirectory=$GITEA_WORK_DIR
ExecStart=$GITEA_BIN web --config $GITEA_CONFIG
Restart=always
RestartSec=2s
Environment=USER=$GITEA_USER HOME=$GITEA_HOME GITEA_WORK_DIR=$GITEA_WORK_DIR

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --quiet gitea
  systemctl restart gitea

  local port url
  port=$(sed -nE 's/^HTTP_PORT *= *//p' "$GITEA_CONFIG" | head -n1)
  url=$(sed -nE 's/^ROOT_URL *= *//p' "$GITEA_CONFIG" | head -n1)
  for _ in $(seq 60); do
    if curl -fsS "http://127.0.0.1:${port:-3000}/api/healthz" >/dev/null 2>&1; then
      log "gitea is up: $url  (logs: journalctl -u gitea -f)"
      return 0
    fi
    sleep 1
  done
  die "gitea did not become healthy; check: journalctl -u gitea -n 100"
}

cmd_all() {
  cmd_build
  cmd_runtime
  cmd_configure
  if [[ -d /run/systemd/system ]]; then
    cmd_service
  else
    log "systemd is not running; starting in the foreground"
    cmd_run
  fi
}

case "${1:-all}" in
  all | deps | build | runtime | configure | run | service) "cmd_${1:-all}" ;;
  -h | --help | help) awk 'NR > 1 && /^set -E/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
