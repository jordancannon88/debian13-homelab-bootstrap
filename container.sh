#!/usr/bin/env bash
# ==============================================================================
#  Container runtimes for Debian — Docker and/or Podman (rootless), + Compose
#
#  Follows the official documentation:
#    - https://docs.docker.com/engine/install/debian
#    - https://docs.docker.com/engine/security/rootless/
#    - https://podman.io/  /  https://github.com/containers/podman
#
#  - Installs either or BOTH runtimes (you're asked for each):
#      Docker : Engine, CLI, containerd, Buildx and the Compose plugin from
#               Docker's official apt repository, with ROOTLESS Docker for a
#               chosen non-root user.
#      Podman : daemonless Podman from Debian's repo, run ROOTLESS for the same
#               user, plus podman-compose. Designed to COEXIST with Docker —
#               the real `docker` CLI and `podman` live side by side (the
#               `podman-docker` shim, which would hijack `docker`, is never
#               installed).
#  - Both runtimes share the rootless plumbing (uidmap, subuid/subgid and the
#    user-namespace AppArmor handling) so they can run together for one user.
#  - Colorful output, prompts, idempotent, with a final recap.
#
#  Run as root (e.g. sudo ./container.sh).
#
#  Environment overrides:
#    INSTALL_DOCKER=1|0     -> install Docker (else asks; default yes)
#    INSTALL_PODMAN=1|0     -> install Podman (else asks; default no)
#    CONTAINER_USER=<name>  -> user to configure rootless Docker/Podman for
#    DOCKER_USER=<name>     -> alias for CONTAINER_USER (back-compat)
#    ASSUME_YES=1           -> answer "yes" to all prompts (automation)
#    SETUP_ROOTLESS=1|0     -> set up rootless Docker (else asks; default yes).
#                              Podman is always rootless for CONTAINER_USER.
#    DISABLE_ROOTFUL=1|0    -> disable the system-wide root daemon (else asks)
#    USERNS_METHOD=apparmor|sysctl|none
#                           -> how to let rootless runtimes create user
#                              namespaces when Debian restricts them via
#                              AppArmor (else asks). Applies to BOTH Docker's
#                              rootlesskit and Podman:
#                              apparmor = targeted profile(s) for the rootless
#                                         binaries (RECOMMENDED — keeps the
#                                         restriction for everything else; see
#                                         https://docs.docker.com/engine/security/apparmor/)
#                              sysctl   = disable the restriction globally
#                              none     = change nothing (rootless may fail)
#    CREATE_EXAMPLE_APP=1|0  -> also drop an example app into the layout
#                               (the /opt/docker hierarchy is ALWAYS created)
#    EXAMPLE_APP=<name>      -> example app folder name (default example-app)
#    EXAMPLE_PORT=<port>     -> host port for the example app (default 8080)
#    DOCKER_JOURNALD_LOGS=1|0 -> set the log-driver to journald so container
#                               logs flow into the systemd journal (a log shipper
#                               like Grafana Alloy then picks them up with no
#                               socket access). For Docker, applies to the active
#                               daemon(s), rootful and/or rootless; for Podman it
#                               sets the user's containers.conf log_driver.
#                               Else asks; default no.
#    DOCKER_LOG_LABELS=<csv> -> container labels the journald driver attaches to
#                               each line (default the Compose project+service,
#                               which Alloy promotes to compose_project /
#                               compose_service labels). Empty = attach none.
# ==============================================================================

set -euo pipefail

# Ensure sbin paths are present (apparmor_parser, sysctl, loginctl, etc. live in
# /usr/sbin and /sbin, which some non-login shells / sudo configs drop).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# =======================
# Config (env overridable)
# =======================
# Which runtime(s) to install — at least one is required. Empty = prompt.
INSTALL_DOCKER="${INSTALL_DOCKER:-}"           # empty = prompt ; default yes
INSTALL_PODMAN="${INSTALL_PODMAN:-}"           # empty = prompt ; default no
# Rootless user for both runtimes. CONTAINER_USER is the canonical name;
# DOCKER_USER is still honoured as an alias so existing callers keep working.
CONTAINER_USER="${CONTAINER_USER:-${DOCKER_USER:-${SUDO_USER:-}}}"  # default: sudo invoker
DOCKER_USER="$CONTAINER_USER"                  # keep in sync (legacy var name)
SETUP_ROOTLESS="${SETUP_ROOTLESS:-}"           # empty = prompt (Docker only; Podman is always rootless)
DISABLE_ROOTFUL="${DISABLE_ROOTFUL:-}"         # empty = prompt
USERNS_METHOD="${USERNS_METHOD:-}"             # apparmor|sysctl|none ; empty = prompt
CREATE_EXAMPLE_APP="${CREATE_EXAMPLE_APP:-}"   # empty = prompt ; example app (layout is always created)
DOCKER_JOURNALD_LOGS="${DOCKER_JOURNALD_LOGS:-}"  # empty = prompt ; journald log-driver
# Container labels the journald driver attaches to each line (comma-separated).
# Defaults to the Compose project + service so logs group per stack/service in
# Loki; set empty to attach none. Alloy promotes these to compose_project /
# compose_service labels.
DOCKER_LOG_LABELS="${DOCKER_LOG_LABELS:-com.docker.compose.project,com.docker.compose.service}"
ASSUME_YES="${ASSUME_YES:-0}"

# /opt/docker production layout (per the "organizing Docker files" guide)
OPT_DOCKER_DIR="/opt/docker"
EXAMPLE_APP="${EXAMPLE_APP:-example-app}"      # example app folder name
EXAMPLE_PORT="${EXAMPLE_PORT:-8080}"           # host port for the example app

START_TS="$(date +%s)"

# Docker packages (per docs.docker.com/engine/install/debian)
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
# Extra package that provides dockerd-rootless-setuptool.sh
ROOTLESS_PKG="docker-ce-rootless-extras"
# Podman packages (from Debian's own repo). 'podman' pulls in crun/conmon/
# netavark/passt etc. 'podman-compose' gives a `podman compose`/compose CLI.
# NOTE: 'podman-docker' is deliberately NOT installed — it drops a `docker`
# shim at /usr/bin/docker that would shadow the real Docker CLI, breaking the
# Docker+Podman coexistence this script sets up.
PODMAN_PKGS=(podman podman-compose)
# Rootless prerequisites for Debian (uidmap = newuidmap/newgidmap). Shared by
# rootless Docker and rootless Podman.
ROOTLESS_PREREQS=(uidmap dbus-user-session slirp4netns)
# Old/conflicting packages the Docker install docs say to remove first. Only
# applied when installing Docker. 'podman-docker' is listed because it conflicts
# with the real docker CLI; plain 'podman'/'containers-common' are NOT conflicts
# and are left alone so Podman can coexist.
CONFLICT_PKGS=(docker.io docker-doc docker-compose podman-docker containerd runc)

# ==============================================================================
#  Output helpers
# ==============================================================================
if [[ -t 1 ]]; then
  BOLD=$'\033[1m';  DIM=$'\033[2m';   RESET=$'\033[0m'
  RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'
  BLU=$'\033[1;34m'; MAG=$'\033[1;35m'; CYN=$'\033[1;36m'; WHT=$'\033[1;37m'
else
  BOLD=''; DIM=''; RESET=''; RED=''; GRN=''; YEL=''; BLU=''; MAG=''; CYN=''; WHT=''
fi
S_OK="✔"; S_INFO="•"; S_WARN="!"; S_ERR="✗"; S_STEP="▸"

STEP_NO=0
TOTAL_STEPS=7
SUMMARY=()
WARNINGS=()
record()        { SUMMARY+=("$1"$'\t'"$2"); }
remember_warn() { WARNINGS+=("$1"); }

hr() { local ch="${1:-─}" w=72 l=""; printf -v l '%*s' "$w" ''; printf '%s%s%s\n' "$DIM" "${l// /$ch}" "$RESET"; }
banner() {
  STEP_NO=$((STEP_NO + 1)); printf '\n'; hr '═'
  printf '%s%s STEP %d/%d %s %s%s\n' "$BOLD$CYN" "$S_STEP" "$STEP_NO" "$TOTAL_STEPS" "│" "$*" "$RESET"; hr '═'
}
header() { printf '\n'; hr '═'; printf '%s%s %s%s\n' "$BOLD$CYN" "$S_STEP" "$*" "$RESET"; hr '═'; }
log()  { printf '%s%s%s %s\n'  "$GRN" "$S_OK"   "$RESET" "$*"; }
info() { printf '%s%s%s %s\n'  "$BLU" "$S_INFO" "$RESET" "$*"; }
warn() { printf '%s%s %s%s\n'  "$YEL" "$S_WARN" "$*" "$RESET"; remember_warn "$*"; }
err()  { printf '%s%s %s%s\n'  "$RED" "$S_ERR" "$*" "$RESET" >&2; }
note() { printf '   %s%s%s\n'  "$DIM" "$*" "$RESET"; }

# ------------------------------------------------------------------------------
#  Action wrappers
# ------------------------------------------------------------------------------
run() { "$@"; }

write_file() {
  local path="$1"
  cat > "$path"
}

# run_as_user <cmd...>  — run a command as DOCKER_USER with a working user
# systemd/D-Bus session (required by the rootless setup tool).
run_as_user() {
  local uid; uid="$(id -u "$DOCKER_USER")"
  runuser -l "$DOCKER_USER" -c \
    "export XDG_RUNTIME_DIR=/run/user/${uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus PATH=/usr/bin:/usr/sbin:/sbin:\$PATH; $*"
}

# write_journald_daemon_json <path> <owner:group> — set "log-driver":"journald"
# (and, if DOCKER_LOG_LABELS is non-empty, "log-opts":{"labels":"..."} so those
# container labels are attached to each line for grouping in Loki). Creates the
# file + parent dirs if absent; to merge into an EXISTING file (preserving other
# keys) it uses jq, installing it first if missing. Returns non-zero only if it
# couldn't apply the setting (e.g. jq unavailable and uninstallable).
write_journald_daemon_json() {
  local path="$1" owner="$2" dir; dir="$(dirname "$path")"
  local labels="$DOCKER_LOG_LABELS"
  install -d -o "${owner%:*}" -g "${owner#*:}" -m 0755 "$dir"
  if [[ -s "$path" ]]; then
    # Merging into an existing file without clobbering other keys needs jq —
    # install it if it's missing (it usually is on a fresh Debian box).
    if ! command -v jq >/dev/null 2>&1; then
      info "Installing jq (needed to merge the existing ${path})..."
      apt-get install -y jq >/dev/null 2>&1 || true
    fi
    if command -v jq >/dev/null 2>&1; then
      cp -a "$path" "${path}.bak.$(date +%F-%H%M%S)"
      local tmp; tmp="$(mktemp)"
      if jq --arg labels "$labels" '
            ."log-driver" = "journald"
            | if $labels != "" then ."log-opts" = ((."log-opts" // {}) + {"labels": $labels}) else . end
          ' "$path" > "$tmp" && mv "$tmp" "$path"; then
        chown "$owner" "$path"; chmod 0644 "$path"
        log "Merged journald log-driver into existing ${path} (backup kept)."
        return 0
      fi
      rm -f "$tmp"
    fi
    warn "${path} exists and jq couldn't be installed to merge it — set log-driver=journald${labels:+ and log-opts.labels=${labels}} in it yourself, then restart Docker."
    return 1
  fi
  if [[ -n "$labels" ]]; then
    printf '{\n  "log-driver": "journald",\n  "log-opts": {\n    "labels": "%s"\n  }\n}\n' "$labels" > "$path"
  else
    printf '{\n  "log-driver": "journald"\n}\n' > "$path"
  fi
  chown "$owner" "$path"; chmod 0644 "$path"
  log "Wrote ${path} with the journald log-driver${labels:+ (labels: ${labels})}."
  return 0
}

# install_userns_apparmor_profile <binary> <what> — grant ONLY <binary> the
# userns permission, keeping kernel.apparmor_restrict_unprivileged_userns
# enforced for everything else (the AppArmor-aligned fix per docs.docker.com).
# Used for Docker's rootlesskit and for Podman. Sets APPARMOR_PROFILE_PATH on
# success; returns 1 (and warns) if a DIFFERENT profile is already attached to
# this binary, to avoid an AppArmor conflict from two profiles on one path.
install_userns_apparmor_profile() {
  local bin="$1" what="${2:-rootless containers}" name profile abi_line=""
  name="$(printf '%s' "${bin#/}" | tr '/' '.')"     # e.g. usr.bin.rootlesskit
  profile="/etc/apparmor.d/${name}"
  # If a profile for this exact binary already exists from another source (e.g.
  # the distro package) and it isn't ours, don't fight it — warn and bail so the
  # caller can fall back to the sysctl method.
  if [[ -e "$profile" ]] && ! grep -q 'homelab-bootstrap userns profile' "$profile" 2>/dev/null; then
    warn "An AppArmor profile already exists at ${profile} — leaving it; if ${what} can't create a userns, use USERNS_METHOD=sysctl."
    return 1
  fi
  # Use the abi pin only if this AppArmor ships it (4.x); harmless to omit otherwise.
  [[ -e /etc/apparmor.d/abi/4.0 ]] && abi_line=$'abi <abi/4.0>,\n'
  printf '%s' "# homelab-bootstrap userns profile
# Allow ${what} to create user namespaces while keeping
# kernel.apparmor_restrict_unprivileged_userns enforced for all other programs.
# See https://docs.docker.com/engine/security/apparmor/
${abi_line}include <tunables/global>

\"${bin}\" flags=(unconfined) {
  userns,

  include if exists <local/${name}>
}
" | write_file "$profile"
  run apparmor_parser -r -W "$profile"
  run systemctl reload apparmor 2>/dev/null || run systemctl restart apparmor || true
  APPARMOR_PROFILE_PATH="$profile"
  return 0
}

# Back-compat thin wrapper for the Docker rootlesskit path.
install_rootlesskit_apparmor_profile() {
  local bin; bin="$(command -v rootlesskit 2>/dev/null || echo /usr/bin/rootlesskit)"
  install_userns_apparmor_profile "$bin" "rootless Docker's RootlessKit"
}

INTERACTIVE=0
if [[ "$ASSUME_YES" != "1" && -r /dev/tty ]]; then INTERACTIVE=1; fi

confirm() {
  local prompt="$1" default="${2:-N}" reply hint
  if [[ "$default" =~ ^[Yy]$ ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  if [[ "$ASSUME_YES" == "1" ]]; then info "auto-confirm: ${prompt} → yes"; return 0; fi
  if [[ "$INTERACTIVE" -eq 0 ]]; then info "non-interactive: ${prompt} → default (${default})"; [[ "$default" =~ ^[Yy] ]]; return; fi
  printf '%s%s %s %s%s ' "$YEL" "$S_WARN" "$prompt" "$hint" "$RESET" > /dev/tty
  read -r reply < /dev/tty || reply=""
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

require_root() { if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then err "Run as root (e.g. sudo $0)."; exit 1; fi; }

prompt_for_user() {
  # Choose the user that will own rootless Docker/Podman — must be an EXISTING
  # account. Loops until a valid user is picked (interactive); errors out
  # non-interactively.
  local candidates default
  mapfile -t candidates < <(awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | sort)
  # Sensible default: the sudo invoker if it exists, else the sole human user.
  default=""
  if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
    default="$SUDO_USER"
  elif (( ${#candidates[@]} == 1 )); then
    default="${candidates[0]}"
  fi

  while true; do
    # Accept a valid pre-set / previously-entered value without re-asking.
    if [[ -n "$DOCKER_USER" ]] && id "$DOCKER_USER" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "$DOCKER_USER" ]]; then
      # Provided but missing.
      if [[ "$INTERACTIVE" -ne 1 ]]; then
        err "User '$DOCKER_USER' does not exist. Set DOCKER_USER=<existing user> (run bootstrap.sh first to create one)."
        exit 1
      fi
      warn "User '$DOCKER_USER' does not exist — pick an existing user."
    fi
    if [[ "$INTERACTIVE" -ne 1 ]]; then
      err "No existing target user for rootless Docker/Podman. Set CONTAINER_USER=<existing user>."
      exit 1
    fi
    if (( ${#candidates[@]} > 0 )); then
      printf '   %sExisting users:%s %s\n' "$DIM" "$RESET" "${candidates[*]}" > /dev/tty
    else
      printf '   %sNo regular users found — run bootstrap.sh first to create one.%s\n' "$DIM" "$RESET" > /dev/tty
    fi
    printf '%s%s Which user should own rootless Docker/Podman?%s%s ' \
      "$YEL" "$S_INFO" "${default:+ [default: $default]}" "$RESET" > /dev/tty
    read -r DOCKER_USER < /dev/tty || DOCKER_USER=""
    DOCKER_USER="${DOCKER_USER:-$default}"
  done
}

# ==============================================================================
#  Splash
# ==============================================================================
# Don't wipe the terminal when run nested by init.sh — keep the previous
# script's output visible. (BOOTSTRAP_NESTED is set by init.sh.)
[[ "${BOOTSTRAP_NESTED:-0}" == "1" ]] || clear 2>/dev/null || true
printf '%s' "$BOLD$BLU"
cat <<'EOF'
   ____             _              ____             _   _
  |  _ \  ___   ___| | _____ _ __ |  _ \ ___   ___ | |_| | ___ ___ ___
  | | | |/ _ \ / __| |/ / _ \ '__|| |_) / _ \ / _ \| __| |/ _ Y __/ __|
  | |_| | (_) | (__|   <  __/ |   |  _ < (_) | (_) | |_| |  __|__ \__ \
  |____/ \___/ \___|_|\_\___|_|   |_| \_\___/ \___/ \__|_|\___|___/___/
EOF
printf '%s' "$RESET"
printf '%s     Container runtimes for Debian — Docker and/or Podman (rootless)%s\n' "$DIM" "$RESET"
hr '─'

require_root
if ! command -v apt >/dev/null 2>&1; then err "This installer targets Debian/apt systems."; exit 1; fi
if [[ ! -r /etc/os-release ]] || ! grep -qiE 'ID=debian|ID_LIKE=.*debian' /etc/os-release; then
  warn "This does not look like Debian — the apt repo path assumes Debian."
fi

prompt_for_user
CONTAINER_USER="$DOCKER_USER"   # keep canonical name in sync with the chosen user

# Which runtime(s)? At least one is required; both may be selected so they
# coexist for CONTAINER_USER.
[[ -z "$INSTALL_DOCKER" ]] && { confirm "Install Docker (Engine + Compose, rootless)?" Y && INSTALL_DOCKER=1 || INSTALL_DOCKER=0; }
[[ -z "$INSTALL_PODMAN" ]] && { confirm "Install Podman (daemonless, rootless) alongside?" N && INSTALL_PODMAN=1 || INSTALL_PODMAN=0; }
if [[ "$INSTALL_DOCKER" != "1" && "$INSTALL_PODMAN" != "1" ]]; then
  err "Nothing selected — choose Docker, Podman, or both (set INSTALL_DOCKER=1 and/or INSTALL_PODMAN=1)."
  exit 1
fi

CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"
ARCH="$(dpkg --print-architecture)"
RUNTIMES_LABEL=""
[[ "$INSTALL_DOCKER" == "1" ]] && RUNTIMES_LABEL="Docker"
[[ "$INSTALL_PODMAN" == "1" ]] && RUNTIMES_LABEL="${RUNTIMES_LABEL:+${RUNTIMES_LABEL}+}Podman"

info "Runtime(s)    : ${BOLD}${RUNTIMES_LABEL}${RESET}"
info "Target user   : ${BOLD}${CONTAINER_USER}${RESET}"
info "Debian suite  : ${BOLD}${CODENAME}${RESET}   arch: ${BOLD}${ARCH}${RESET}"
hr '─'

# ==============================================================================
#  PRE-FLIGHT
# ==============================================================================
header "Pre-flight checks"

# The target user was validated in prompt_for_user (it exists).
USER_UID="$(id -u "$DOCKER_USER")"
USER_HOME="$(getent passwd "$DOCKER_USER" | cut -d: -f6)"
log "Target user '$DOCKER_USER' exists (uid ${USER_UID}, home ${USER_HOME})."

# Detect conflicting packages (only relevant when installing Docker — these are
# the legacy/duplicate Docker packages, plus podman-docker which would hijack
# the docker CLI). When Podman is selected we keep podman-docker OUT regardless.
FOUND_CONFLICTS=()
if [[ "$INSTALL_DOCKER" == "1" ]]; then
  for p in "${CONFLICT_PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" && FOUND_CONFLICTS+=("$p")
  done
  if (( ${#FOUND_CONFLICTS[@]} > 0 )); then
    warn "Conflicting packages present (docs say remove before installing): ${FOUND_CONFLICTS[*]}"
  else
    log "No conflicting Docker packages installed."
  fi
fi

# Resolve rootless / rootful decisions. SETUP_ROOTLESS governs DOCKER only;
# Podman is always rootless for CONTAINER_USER.
if [[ "$INSTALL_DOCKER" == "1" ]]; then
  [[ -z "$SETUP_ROOTLESS" ]] && { confirm "Set up ROOTLESS Docker for '$CONTAINER_USER'?" Y && SETUP_ROOTLESS=1 || SETUP_ROOTLESS=0; }
  if [[ "$SETUP_ROOTLESS" == "1" ]]; then
    [[ -z "$DISABLE_ROOTFUL" ]] && { confirm "Also DISABLE the system-wide (root) Docker daemon? (recommended for rootless-only)" Y && DISABLE_ROOTFUL=1 || DISABLE_ROOTFUL=0; }
  fi
else
  SETUP_ROOTLESS=0   # no Docker → no Docker-rootless steps
fi
SETUP_ROOTLESS="${SETUP_ROOTLESS:-0}"
DISABLE_ROOTFUL="${DISABLE_ROOTFUL:-0}"

# Do we need unprivileged user namespaces? Both rootless Docker (RootlessKit)
# and rootless Podman require them.
ROOTLESS_NEEDED=0
[[ "$INSTALL_DOCKER" == "1" && "$SETUP_ROOTLESS" == "1" ]] && ROOTLESS_NEEDED=1
[[ "$INSTALL_PODMAN" == "1" ]] && ROOTLESS_NEEDED=1

# Debian restricts unprivileged user namespaces; rootless Docker (RootlessKit)
# and Podman need them. Two independent knobs may exist:
#   - kernel.unprivileged_userns_clone (Debian 11): 0 = userns disabled entirely
#   - kernel.apparmor_restrict_unprivileged_userns (Debian 13): 1 = AppArmor-gated
# The hardening script keeps AppArmor enabled, which is what enforces the latter.
USERNS_CLONE_OFF=0      # legacy knob set to 0 (needs flipping to 1)
APPARMOR_USERNS_ON=0    # Debian 13 AppArmor restriction active
[[ -e /proc/sys/kernel/unprivileged_userns_clone ]] && \
  [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)" == "0" ]] && USERNS_CLONE_OFF=1
[[ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]] && \
  [[ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" == "1" ]] && APPARMOR_USERNS_ON=1

if [[ "$ROOTLESS_NEEDED" == "1" && "$APPARMOR_USERNS_ON" == "1" ]]; then
  warn "AppArmor restricts unprivileged user namespaces on this kernel (Debian 13 default)."
  note "Rootless Docker (RootlessKit) and Podman need to create a userns. Choose how to allow it (per docs.docker.com/engine/security/apparmor):"
  if [[ -z "$USERNS_METHOD" ]]; then
    if [[ "$INTERACTIVE" -eq 1 ]]; then
      printf '   %s[1]%s %sTargeted AppArmor profile(s)%s — recommended; grants only the rootless binaries (rootlesskit/podman), keeps the restriction for everything else\n' "$BOLD" "$RESET" "$GRN" "$RESET" > /dev/tty
      printf '   %s[2]%s Disable the restriction globally (sysctl) — simpler, weaker\n' "$BOLD" "$RESET" > /dev/tty
      printf '   %s[3]%s Do nothing (rootless may fail to start)\n' "$BOLD" "$RESET" > /dev/tty
      printf '%s%s Choose 1/2/3 [default: 1]: %s' "$YEL" "$S_WARN" "$RESET" > /dev/tty
      read -r _m < /dev/tty || _m=""
      case "${_m:-1}" in 2) USERNS_METHOD=sysctl ;; 3) USERNS_METHOD=none ;; *) USERNS_METHOD=apparmor ;; esac
    else
      USERNS_METHOD=apparmor   # safest default for automation
    fi
  fi
  log "Userns method: ${BOLD}${USERNS_METHOD}${RESET}"
fi
USERNS_METHOD="${USERNS_METHOD:-none}"

# The /opt/docker layout is always created; only ask whether to add an example
# app — and only when Docker is being installed (the example is a docker-compose
# stack). Podman-only installs skip it.
if [[ "$INSTALL_DOCKER" == "1" ]]; then
  [[ -z "$CREATE_EXAMPLE_APP" ]] && { confirm "Also create an example app under ${OPT_DOCKER_DIR}?" Y && CREATE_EXAMPLE_APP=1 || CREATE_EXAMPLE_APP=0; }
  CREATE_EXAMPLE_APP="${CREATE_EXAMPLE_APP:-1}"
else
  CREATE_EXAMPLE_APP=0
fi

# Optionally route container logs to the journal (so a shipper like Grafana Alloy
# picks them up). Default no — it changes the log-driver and needs containers recreated.
[[ -z "$DOCKER_JOURNALD_LOGS" ]] && { confirm "Send container logs to the journal (journald log-driver, so Grafana Alloy can ship them)?" N && DOCKER_JOURNALD_LOGS=1 || DOCKER_JOURNALD_LOGS=0; }
DOCKER_JOURNALD_LOGS="${DOCKER_JOURNALD_LOGS:-0}"

# Offer to remove conflicts (Docker only).
PURGE_CONFLICTS=0
if (( ${#FOUND_CONFLICTS[@]} > 0 )); then
  confirm "Remove conflicting packages now (${FOUND_CONFLICTS[*]})?" N && PURGE_CONFLICTS=1
fi

# Compute the step total now that all decisions are made, so banners read n/N.
# Each increment matches a banner() that is actually emitted below.
TOTAL_STEPS=0
[[ "$INSTALL_DOCKER" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 3))  # conflicts, repo, engine
[[ "$INSTALL_PODMAN" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))  # podman install
[[ "$ROOTLESS_NEEDED" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1)) # rootless prerequisites
[[ "$SETUP_ROOTLESS" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))  # rootless Docker
[[ "$INSTALL_PODMAN" == "1" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))  # rootless Podman
TOTAL_STEPS=$((TOTAL_STEPS + 2))                                    # log-driver + /opt/docker

echo
confirm "Proceed installing ${RUNTIMES_LABEL}$( [[ $SETUP_ROOTLESS == 1 || $INSTALL_PODMAN == 1 ]] && echo ' (rootless)' ) for '$CONTAINER_USER'?" N \
  || { err "Aborted by user."; exit 1; }

# ==============================================================================
# DOCKER: conflicts → apt repo → engine. Skipped entirely when Docker isn't selected.
# ==============================================================================
if [[ "$INSTALL_DOCKER" == "1" ]]; then
  banner "Removing conflicting packages"
  if [[ "$PURGE_CONFLICTS" == "1" ]]; then
    run apt -y purge "${FOUND_CONFLICTS[@]}"
    run apt -y autoremove
    log "Removed: ${FOUND_CONFLICTS[*]}"
    record "Conflicts" "Removed ${FOUND_CONFLICTS[*]}"
  elif (( ${#FOUND_CONFLICTS[@]} > 0 )); then
    note "Left conflicting packages in place: ${FOUND_CONFLICTS[*]}"
    record "Conflicts" "Left in place (remove before a clean install): ${FOUND_CONFLICTS[*]}"
  else
    log "Nothing to remove."
    record "Conflicts" "none present"
  fi

  banner "Setting up Docker's apt repository"
  export DEBIAN_FRONTEND=noninteractive
  info "Installing repo prerequisites (ca-certificates, curl)..."
  run apt update
  run apt -y install ca-certificates curl
  run install -m 0755 -d /etc/apt/keyrings
  info "Adding Docker's official GPG key..."
  run curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  run chmod a+r /etc/apt/keyrings/docker.asc
  info "Writing /etc/apt/sources.list.d/docker.sources (deb822 format)..."
  write_file /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  run apt update
  log "Docker apt repository configured for '${CODENAME}' (${ARCH})."
  record "Apt repo" "Docker repo added (suite=${CODENAME}, arch=${ARCH})"

  banner "Installing Docker Engine + Compose"
  PKGS=("${DOCKER_PKGS[@]}")
  [[ "$SETUP_ROOTLESS" == "1" ]] && PKGS+=("$ROOTLESS_PKG")
  info "Installing: ${DIM}${PKGS[*]}${RESET}"
  run apt -y install "${PKGS[@]}"
  log "Docker Engine, CLI, containerd, Buildx and Compose plugin installed."
  note "Compose is available as 'docker compose' (v2 plugin)."
  record "Docker" "Engine + CLI + containerd + buildx + compose-plugin installed"
else
  export DEBIAN_FRONTEND=noninteractive
fi

# ==============================================================================
# PODMAN: install from Debian's repo (daemonless). Coexists with Docker.
# ==============================================================================
if [[ "$INSTALL_PODMAN" == "1" ]]; then
  banner "Installing Podman + compose"
  # Guard against podman-docker, which provides /usr/bin/docker and would shadow
  # the real Docker CLI when both runtimes are installed.
  if dpkg-query -W -f='${Status}' podman-docker 2>/dev/null | grep -q "install ok installed"; then
    warn "podman-docker is installed — it hijacks the 'docker' command. Removing it so Docker and Podman can coexist."
    run apt -y purge podman-docker
  fi
  info "Installing: ${DIM}${PODMAN_PKGS[*]}${RESET}"
  run apt update
  run apt -y install "${PODMAN_PKGS[@]}"
  log "Podman + podman-compose installed (daemonless; the 'docker' CLI is untouched)."
  note "Compose works via 'podman compose' or 'podman-compose'."
  record "Podman" "podman + podman-compose installed (coexists with Docker)"
fi

# ==============================================================================
# Rootless prerequisites — shared by rootless Docker AND Podman.
# ==============================================================================
if [[ "$ROOTLESS_NEEDED" == "1" ]]; then
  banner "Configuring rootless prerequisites"
  info "Installing rootless prerequisites: ${DIM}${ROOTLESS_PREREQS[*]}${RESET}"
  run apt -y install "${ROOTLESS_PREREQS[@]}"

  # Ensure subordinate UID/GID ranges exist for the user (>= 65536).
  for f in /etc/subuid /etc/subgid; do
    if ! grep -q "^${DOCKER_USER}:" "$f" 2>/dev/null; then
      printf '%s:100000:65536\n' "$DOCKER_USER" >> "$f"
      log "Added subordinate range for ${DOCKER_USER} to ${f}."
    else
      log "${f} already has a range for ${DOCKER_USER}."
    fi
  done

  # Legacy Debian 11 knob: enable unprivileged userns entirely if it is off.
  if [[ "$USERNS_CLONE_OFF" == "1" ]]; then
    printf '# Enable unprivileged user namespaces for rootless containers\nkernel.unprivileged_userns_clone = 1\n' \
      | write_file /etc/sysctl.d/99-rootless-userns.conf
    run sysctl --system >/dev/null
    log "Enabled kernel.unprivileged_userns_clone=1."
    record "userns(clone)" "enabled via /etc/sysctl.d/99-rootless-userns.conf"
  fi

  # Debian 13 AppArmor restriction: apply the chosen method. With the apparmor
  # method we add a targeted profile for EACH rootless binary in play —
  # rootlesskit (Docker) and/or podman — so both can create a userns while the
  # restriction stays enforced for everything else.
  if [[ "$APPARMOR_USERNS_ON" == "1" ]]; then
    case "$USERNS_METHOD" in
      apparmor)
        _aa_targets=()
        _aa_applied=()
        [[ "$SETUP_ROOTLESS" == "1" ]] && _aa_targets+=("$(command -v rootlesskit 2>/dev/null || echo /usr/bin/rootlesskit):rootless Docker's RootlessKit")
        [[ "$INSTALL_PODMAN" == "1" ]] && _aa_targets+=("$(command -v podman 2>/dev/null || echo /usr/bin/podman):Podman")
        for _t in "${_aa_targets[@]}"; do
          _bin="${_t%%:*}"; _what="${_t#*:}"
          info "Installing a targeted AppArmor profile so ${_what} may create user namespaces..."
          if install_userns_apparmor_profile "$_bin" "$_what"; then
            _aa_applied+=("${APPARMOR_PROFILE_PATH}")
          fi
        done
        if (( ${#_aa_applied[@]} > 0 )); then
          log "AppArmor profile(s) loaded — restriction stays ON for everything else."
          record "userns(apparmor)" "Granted 'userns' to: ${_aa_applied[*]}"
        else
          warn "No AppArmor userns profile was applied — rootless may fail; consider USERNS_METHOD=sysctl."
          record "userns(apparmor)" "no profile applied (see warnings)"
        fi
        ;;
      sysctl)
        printf '# Disable AppArmor unprivileged-userns restriction (weakens hardening)\nkernel.apparmor_restrict_unprivileged_userns = 0\n' \
          | write_file /etc/sysctl.d/99-rootless-userns.conf
        run sysctl --system >/dev/null
        warn "Disabled kernel.apparmor_restrict_unprivileged_userns globally — weaker than the AppArmor-profile method."
        record "userns(sysctl)" "Restriction disabled globally via /etc/sysctl.d/99-rootless-userns.conf"
        ;;
      *)
        note "Left the AppArmor userns restriction in place; rootless may fail until addressed."
        record "userns" "Left restricted (rootless may not start)"
        ;;
    esac
  fi
  record "Rootless prereqs" "uidmap, dbus-user-session, slirp4netns + subuid/subgid ensured"
elif [[ "$INSTALL_DOCKER" == "1" ]]; then
  note "Rootless setup skipped — Docker runs as the root daemon."
  record "Rootless prereqs" "skipped"
fi

# ==============================================================================
# Setting up rootless Docker (Docker-rootless only).
# ==============================================================================
if [[ "$SETUP_ROOTLESS" == "1" ]]; then
  banner "Setting up rootless Docker"
  # Optionally disable the system-wide root daemon (docs recommend this for rootless-only).
  if [[ "$DISABLE_ROOTFUL" == "1" ]]; then
    info "Disabling the system-wide (root) Docker daemon..."
    run systemctl disable --now docker.service docker.socket || true
    run rm -f /var/run/docker.sock
    log "Rootful daemon disabled."
    record "Rootful daemon" "disabled (rootless-only)"
  else
    note "Keeping the system-wide root daemon enabled alongside rootless."
    record "Rootful daemon" "left enabled"
  fi

  # Enable lingering so the user's services run without an active login.
  info "Enabling systemd lingering for ${DOCKER_USER}..."
  run loginctl enable-linger "$DOCKER_USER"

  # Run the official rootless setup tool AS the target user.
  info "Running dockerd-rootless-setuptool.sh as ${DOCKER_USER}..."
  # Give the user's systemd instance a moment to come up after enable-linger.
  sleep 2
  if run_as_user "dockerd-rootless-setuptool.sh install --force"; then
    run_as_user "systemctl --user enable docker" || true
    log "Rootless Docker installed for ${DOCKER_USER}."
    record "Rootless" "Installed for ${DOCKER_USER} (user service enabled)"
  else
    warn "Automated rootless setup failed (often a missing user systemd session)."
    note "Finish it by logging in as '${DOCKER_USER}' and running: dockerd-rootless-setuptool.sh install"
    record "Rootless" "Setup tool failed — finish manually as ${DOCKER_USER}"
  fi

  # Hold the daemon at boot until the host can resolve DNS. Lingering starts
  # the user's docker.service seconds into boot, and user units cannot order
  # on the system's network-online.target — so containers brought up by
  # restart policies snapshot a not-yet-ready resolv.conf and keep broken DNS
  # until manually restarted (services like NPM also bake those resolvers into
  # their own configs at entrypoint time). The pre-start poll is fail-open
  # ('-' prefix, ~2 min cap): broken DNS delays dockerd, never blocks it.
  WAIT_CONF="${USER_HOME}/.config/systemd/user/docker.service.d/wait-online.conf"
  if [[ -f "$WAIT_CONF" ]] && grep -q 'getent hosts' "$WAIT_CONF"; then
    log "DNS wait-online drop-in already present at ${WAIT_CONF}."
    record "DNS wait" "already present (${WAIT_CONF})"
  else
    runuser -u "$DOCKER_USER" -- mkdir -p "${WAIT_CONF%/*}"
    cat > "$WAIT_CONF" <<'EOF'
[Service]
ExecStartPre=-/bin/sh -c 'i=0; until getent hosts debian.org >/dev/null 2>&1 || [ $i -ge 60 ]; do i=$((i+1)); sleep 2; done'
TimeoutStartSec=300
EOF
    chown "${DOCKER_USER}:${DOCKER_USER}" "$WAIT_CONF"
    run_as_user "systemctl --user daemon-reload" || true
    log "dockerd now waits for working DNS at boot (containers no longer snapshot an empty resolv.conf)."
    record "DNS wait" "docker.service delays until DNS resolves at boot (${WAIT_CONF})"
  fi

  # Configure the user's shell environment (PATH + DOCKER_HOST).
  BASHRC="${USER_HOME}/.bashrc"
  ENV_BLOCK=$'\n# >>> rootless docker >>>\nexport PATH=/usr/bin:$PATH\nexport DOCKER_HOST=unix:///run/user/'"${USER_UID}"$'/docker.sock\n# <<< rootless docker <<<\n'
  if [[ -f "$BASHRC" ]] && grep -q 'rootless docker' "$BASHRC"; then
    log "Rootless env already present in ${BASHRC}."
  else
    printf '%s' "$ENV_BLOCK" >> "$BASHRC"
    chown "$DOCKER_USER:$DOCKER_USER" "$BASHRC" 2>/dev/null || true
    log "Added PATH + DOCKER_HOST to ${BASHRC}."
  fi
  record "User env" "DOCKER_HOST=unix:///run/user/${USER_UID}/docker.sock in ${BASHRC}"

  # Expected AppArmor limitation in rootless mode (not a failure).
  note "Rootless containers run WITHOUT the 'docker-default' AppArmor profile —"
  note "loading a profile needs root (CAP_MAC_ADMIN), so rootless relies on the user"
  note "namespace + seccomp instead. To AppArmor-confine a container, preload a profile"
  note "as root (apparmor_parser -r) and run with --security-opt apparmor=<profile>."
  record "AppArmor" "rootless: docker-default not applied (expected); userns+seccomp in effect"
elif [[ "$INSTALL_DOCKER" == "1" ]]; then
  note "Rootless Docker not configured (running the root daemon)."
fi

# ==============================================================================
# Setting up rootless Podman (Podman is always rootless for CONTAINER_USER).
# ==============================================================================
if [[ "$INSTALL_PODMAN" == "1" ]]; then
  banner "Setting up rootless Podman"

  # Lingering lets the user's Podman socket/containers run without an active
  # login — same requirement as rootless Docker, harmless if already enabled.
  info "Enabling systemd lingering for ${CONTAINER_USER}..."
  run loginctl enable-linger "$CONTAINER_USER"

  # Migrate any prior root-era / stale rootless state, then prove userns works.
  sleep 1
  run_as_user "podman system migrate" || true
  if run_as_user "podman unshare true"; then
    log "Rootless Podman works for ${CONTAINER_USER} (user namespace OK)."
    record "Podman rootless" "verified for ${CONTAINER_USER} (userns OK)"
  else
    warn "Rootless Podman could not create a user namespace for ${CONTAINER_USER}."
    note "If AppArmor restricts userns, re-run with USERNS_METHOD=sysctl, or log in as"
    note "'${CONTAINER_USER}' and check: podman unshare true"
    record "Podman rootless" "userns check failed — see warnings"
  fi

  # Optionally expose Podman's Docker-compatible API socket for the user, so
  # docker-API tools (e.g. the Zabbix Docker plugin, lazydocker) can talk to it
  # at /run/user/<uid>/podman/podman.sock. Enabling is cheap and reversible.
  info "Enabling the rootless Podman API socket for ${CONTAINER_USER}..."
  if run_as_user "systemctl --user enable --now podman.socket"; then
    log "Podman API socket active at /run/user/${USER_UID}/podman/podman.sock (Docker-API compatible)."
    record "Podman socket" "enabled at /run/user/${USER_UID}/podman/podman.sock"
  else
    note "Could not enable podman.socket now (finish as ${CONTAINER_USER}: systemctl --user enable --now podman.socket)."
    record "Podman socket" "not enabled (finish manually)"
  fi

  # When Docker isn't also installed, point the user's DOCKER_HOST at Podman's
  # socket so generic docker-API tooling 'just works'. If Docker IS installed,
  # its rootless step already set DOCKER_HOST to the Docker socket — don't fight
  # it (the user can still target Podman explicitly via `podman`/`podman compose`).
  if [[ "$INSTALL_DOCKER" != "1" ]]; then
    BASHRC="${USER_HOME}/.bashrc"
    PODMAN_ENV_BLOCK=$'\n# >>> rootless podman >>>\nexport DOCKER_HOST=unix:///run/user/'"${USER_UID}"$'/podman/podman.sock\n# <<< rootless podman <<<\n'
    if [[ -f "$BASHRC" ]] && grep -q 'rootless podman' "$BASHRC"; then
      log "Podman DOCKER_HOST already present in ${BASHRC}."
    else
      printf '%s' "$PODMAN_ENV_BLOCK" >> "$BASHRC"
      chown "$CONTAINER_USER:$CONTAINER_USER" "$BASHRC" 2>/dev/null || true
      log "Added DOCKER_HOST=unix:///run/user/${USER_UID}/podman/podman.sock to ${BASHRC}."
      record "User env" "DOCKER_HOST -> podman.sock in ${BASHRC}"
    fi
  fi
fi

# ==============================================================================
banner "Container log-driver (journald)"
# ==============================================================================
# Optional: send container stdout/stderr to the systemd journal so a log shipper
# (e.g. Grafana Alloy) picks them up with NO socket access — the clean way to
# ship rootless container logs. For Docker it applies to whichever daemon(s) are
# active: rootful (/etc/docker/daemon.json) and/or the rootless user's
# (~/.config/docker/daemon.json). For Podman it sets the user's containers.conf
# log_driver. Existing containers must be recreated to adopt it.
if [[ "$DOCKER_JOURNALD_LOGS" != "1" ]]; then
  note "Container log-driver left at each runtime's default (Docker: json-file; Podman: k8s-file)."
  record "Log driver" "default"
else
  _jrnl_done=0
  # --- Docker ---------------------------------------------------------------
  if [[ "$INSTALL_DOCKER" == "1" ]]; then
    # Rootful daemon — only if it's still active (not disabled for rootless-only).
    if [[ "$DISABLE_ROOTFUL" != "1" ]]; then
      if write_journald_daemon_json /etc/docker/daemon.json "root:root"; then
        run systemctl restart docker 2>/dev/null || true
        _jrnl_done=1
      fi
    fi
    # Rootless daemon — the user's own dockerd.
    if [[ "$SETUP_ROOTLESS" == "1" ]]; then
      if write_journald_daemon_json "${USER_HOME}/.config/docker/daemon.json" "${DOCKER_USER}:${DOCKER_USER}"; then
        run_as_user "systemctl --user restart docker" || true
        _jrnl_done=1
      fi
    fi
  fi
  # --- Podman ---------------------------------------------------------------
  # Podman is daemonless; set the rootless user's containers.conf log_driver.
  # Only created when absent (TOML can't be safely merged blind); if a file is
  # already present we leave it and tell the user what to set.
  if [[ "$INSTALL_PODMAN" == "1" ]]; then
    _pm_conf="${USER_HOME}/.config/containers/containers.conf"
    if [[ -s "$_pm_conf" ]] && grep -q '^\s*log_driver' "$_pm_conf"; then
      log "Podman log_driver already set in ${_pm_conf} — leaving it."
      _jrnl_done=1
    elif [[ -s "$_pm_conf" ]]; then
      warn "${_pm_conf} exists — add 'log_driver = \"journald\"' under its [containers] table yourself."
    else
      runuser -u "$CONTAINER_USER" -- mkdir -p "${_pm_conf%/*}"
      cat > "$_pm_conf" <<'EOF'
[containers]
log_driver = "journald"
EOF
      chown "$CONTAINER_USER:$CONTAINER_USER" "$_pm_conf"
      log "Wrote ${_pm_conf} with the journald log_driver for Podman."
      _jrnl_done=1
    fi
  fi
  if [[ "$_jrnl_done" == "1" ]]; then
    log "Container logs now go to the systemd journal (journald log-driver)."
    [[ "$INSTALL_DOCKER" == "1" && -n "$DOCKER_LOG_LABELS" ]] && note "Attached Docker container labels for grouping in Loki: ${DIM}${DOCKER_LOG_LABELS}${RESET}"
    note "Recreate existing containers to adopt it: ${DIM}docker compose up -d --force-recreate${RESET} (or ${DIM}podman ... --log-driver journald${RESET})."
    record "Log driver" "journald$( [[ $INSTALL_DOCKER == 1 ]] && echo ' (docker)' )$( [[ $INSTALL_PODMAN == 1 ]] && echo ' (podman)' )"
  else
    record "Log driver" "journald requested but not applied (see warnings)"
  fi
fi

# ==============================================================================
banner "Creating ${OPT_DOCKER_DIR} structure"
# ==============================================================================
# Layout per the "organizing Docker files for production" guide. Works for both
# Docker Compose and 'podman compose' (same compose files). The directory
# hierarchy is ALWAYS created; the example <app>/ folder is only added when the
# user asked for it (CREATE_EXAMPLE_APP=1):
#   /opt/docker/
#   ├── <app>/              (only with CREATE_EXAMPLE_APP=1)
#   │   ├── docker-compose.yml
#   │   ├── .env            (sensitive — chmod 600, keep out of VCS)
#   │   └── data/           (persistent volume)
#   └── shared/
#       └── networks/       (reusable external networks)
# Owner: if anything rootless is in play (rootless Docker or Podman) the user
# owns the tree; otherwise it's the rootful-Docker case (root + docker group).
if [[ "$ROOTLESS_NEEDED" == "1" ]]; then OPT_OWNER="$CONTAINER_USER:$CONTAINER_USER"; else OPT_OWNER="root:docker"; fi
APP_DIR="${OPT_DOCKER_DIR}/${EXAMPLE_APP}"

# --- Base hierarchy (always created) -----------------------------------------
info "Creating ${OPT_DOCKER_DIR} tree (owner ${OPT_OWNER})..."
run install -d -m 0755 "$OPT_DOCKER_DIR"
run install -d -m 0755 "${OPT_DOCKER_DIR}/shared" "${OPT_DOCKER_DIR}/shared/networks"

# shared/networks usage notes.
write_file "${OPT_DOCKER_DIR}/shared/networks/README.md" <<'EOF'
# Shared Docker networks

Create reusable external networks once, e.g.:

    docker network create proxy

Then reference them from any app's docker-compose.yml:

    networks:
      proxy:
        external: true
EOF

# --- Example app (optional — placed inside the layout under <app>/) ----------
if [[ "$CREATE_EXAMPLE_APP" == "1" ]]; then
  run install -d -m 0750 "$APP_DIR" "${APP_DIR}/data"

  # docker-compose.yml — do not clobber an existing one.
  if [[ -f "${APP_DIR}/docker-compose.yml" ]]; then
    log "Existing ${APP_DIR}/docker-compose.yml left untouched."
  else
    write_file "${APP_DIR}/docker-compose.yml" <<EOF
name: ${EXAMPLE_APP}

# Minimal example service. 'traefik/whoami' prints request info on port 80.
services:
  web:
    image: traefik/whoami
    container_name: ${EXAMPLE_APP}-whoami
    restart: unless-stopped
    env_file: .env
    ports:
      - "\${HOST_PORT:-${EXAMPLE_PORT}}:80"
    networks:
      - app_net
    volumes:
      - ./data:/data

networks:
  app_net:
    driver: bridge
EOF
  fi

  # .env — sensitive; do not clobber.
  if [[ -f "${APP_DIR}/.env" ]]; then
    log "Existing ${APP_DIR}/.env left untouched."
  else
    write_file "${APP_DIR}/.env" <<EOF
# ${EXAMPLE_APP} environment — keep this file OUT of version control.
HOST_PORT=${EXAMPLE_PORT}
EOF
  fi
fi

# --- Ownership + permissions (guide: restrict sensitive files) ---------------
chown -R "$OPT_OWNER" "$OPT_DOCKER_DIR"
if [[ "$CREATE_EXAMPLE_APP" == "1" ]]; then
  chmod 600 "${APP_DIR}/.env"
  chmod 644 "${APP_DIR}/docker-compose.yml"
fi

# Preferred compose invocation for hints: Docker if present, else Podman.
if [[ "$INSTALL_DOCKER" == "1" ]]; then COMPOSE_CMD="docker compose"; else COMPOSE_CMD="podman compose"; fi

if [[ "$CREATE_EXAMPLE_APP" == "1" ]]; then
  log "Created ${OPT_DOCKER_DIR}/{${EXAMPLE_APP},shared/networks}."
  if [[ "$ROOTLESS_NEEDED" == "1" ]]; then
    note "Start it as ${CONTAINER_USER}:  cd ${APP_DIR} && ${COMPOSE_CMD} up -d"
  else
    note "Start it:  cd ${APP_DIR} && sudo ${COMPOSE_CMD} up -d"
  fi
  note "Then browse http://<host>:${EXAMPLE_PORT} (open that port in the firewall first)."
  record "/opt/docker" "Created ${OPT_DOCKER_DIR} + shared/networks and example app ${APP_DIR} (compose+.env+data); owner ${OPT_OWNER}"
else
  log "Created ${OPT_DOCKER_DIR}/shared/networks (no example app)."
  note "Add an app as ${OPT_DOCKER_DIR}/<app>/docker-compose.yml (one folder per app)."
  record "/opt/docker" "Created ${OPT_DOCKER_DIR} + shared/networks (no example app); owner ${OPT_OWNER}"
fi

# ==============================================================================
#  Verification
# ==============================================================================
header "Verification"
if [[ "$INSTALL_DOCKER" == "1" ]]; then
  printf '\n%s%sdocker --version:%s\n' "$BOLD" "$WHT" "$RESET"; docker --version 2>/dev/null || warn "docker not found on PATH"
  printf '\n%s%sdocker compose version:%s\n' "$BOLD" "$WHT" "$RESET"; docker compose version 2>/dev/null || warn "compose plugin not found"
  if [[ "$SETUP_ROOTLESS" == "1" ]]; then
    printf '\n%s%srootless docker context (as %s):%s\n' "$BOLD" "$WHT" "$CONTAINER_USER" "$RESET"
    run_as_user "docker info --format 'Rootless: {{.SecurityOptions}}' 2>/dev/null" || \
      note "Run 'docker info' as ${CONTAINER_USER} to confirm rootless once their session is active."
  fi
fi
if [[ "$INSTALL_PODMAN" == "1" ]]; then
  printf '\n%s%spodman --version:%s\n' "$BOLD" "$WHT" "$RESET"; podman --version 2>/dev/null || warn "podman not found on PATH"
  printf '\n%s%srootless podman (as %s):%s\n' "$BOLD" "$WHT" "$CONTAINER_USER" "$RESET"
  run_as_user "podman info --format 'rootless: {{.Host.Security.Rootless}}' 2>/dev/null" || \
    note "Run 'podman info' as ${CONTAINER_USER} to confirm rootless once their session is active."
fi

# ==============================================================================
#  RECAP
# ==============================================================================
ELAPSED=$(( $(date +%s) - START_TS )); MM=$(( ELAPSED / 60 )); SS=$(( ELAPSED % 60 ))
printf '\n'; hr '═'
printf '%s%s  ✅  %s INSTALL COMPLETE — RECAP%s\n' "$BOLD" "$GRN" "${RUNTIMES_LABEL}" "$RESET"
hr '═'
printf '%s  Host: %s   |   Elapsed: %dm %ds%s\n' "$DIM" "$(hostname)" "$MM" "$SS" "$RESET"
hr '─'
printf '%s%s  WHAT %s%s\n' "$BOLD" "$CYN" "WAS DONE" "$RESET"
for entry in "${SUMMARY[@]}"; do
  key="${entry%%$'\t'*}"; val="${entry#*$'\t'}"
  printf '   %s%s%-16s%s %s\n' "$GRN" "$S_OK " "$key" "$RESET" "$val"
done

if (( ${#WARNINGS[@]} > 0 )); then
  hr '─'; printf '%s%s  ⚠ WARNINGS / NOTES%s\n' "$BOLD" "$YEL" "$RESET"
  for w in "${WARNINGS[@]}"; do printf '   %s%s%s %s\n' "$YEL" "$S_WARN" "$RESET" "$w"; done
fi

hr '─'
printf '%s%s  ⏭ NEXT STEPS%s\n' "$BOLD" "$MAG" "$RESET"
printf '   %s1.%s Log in as %s%s%s (or re-login) so its systemd user session is active.\n' "$BOLD" "$RESET" "$BOLD" "$CONTAINER_USER" "$RESET"
if [[ "$INSTALL_DOCKER" == "1" && "$SETUP_ROOTLESS" == "1" ]]; then
  printf '   %s2.%s Test rootless Docker: %sdocker run --rm hello-world%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '   %s•%s  DOCKER_HOST is set to %sunix:///run/user/%s/docker.sock%s in ~%s/.bashrc\n' \
    "$BOLD" "$RESET" "$DIM" "$USER_UID" "$RESET" "$CONTAINER_USER"
  printf '   %s•%s  Published rootless ports bind on the host — open them in the firewall as needed.\n' "$BOLD" "$RESET"
elif [[ "$INSTALL_DOCKER" == "1" ]]; then
  printf '   %s2.%s Add your user to the %sdocker%s group to use the root daemon without sudo.\n' "$BOLD" "$RESET" "$BOLD" "$RESET"
fi
if [[ "$INSTALL_PODMAN" == "1" ]]; then
  printf '   %s•%s  Test rootless Podman: %spodman run --rm hello-world%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '   %s•%s  Podman API socket: %sunix:///run/user/%s/podman/podman.sock%s (Docker-API compatible)\n' \
    "$BOLD" "$RESET" "$DIM" "$USER_UID" "$RESET"
  [[ "$INSTALL_DOCKER" == "1" ]] && printf '   %s•%s  Both runtimes coexist; %sdocker%s targets Docker, %spodman%s targets Podman.\n' "$BOLD" "$RESET" "$DIM" "$RESET" "$DIM" "$RESET"
fi
if [[ "$CREATE_EXAMPLE_APP" == "1" ]]; then
  printf '   %s3.%s Launch the example app: %scd %s/%s && %s up -d%s\n' \
    "$BOLD" "$RESET" "$DIM" "$OPT_DOCKER_DIR" "$EXAMPLE_APP" "$COMPOSE_CMD" "$RESET"
fi
printf '   %s•%s  Add more apps as %s%s/<app>/docker-compose.yml%s (one folder per app).\n' \
  "$BOLD" "$RESET" "$DIM" "$OPT_DOCKER_DIR" "$RESET"
if [[ "$DOCKER_JOURNALD_LOGS" == "1" ]]; then
  printf '   %s•%s  Container logs go to the journal — recreate running containers (%sdocker compose up -d --force-recreate%s)\n' "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '       to adopt it. With Grafana Alloy installed they show in Loki as %s{host="%s", container=~".+"}%s\n' "$DIM" "$(hostname)" "$RESET"
fi

# Troubleshooting (from README → "A container isn't reachable on the machine's IP").
printf '\n   %s%sTroubleshooting — published port not reachable from another machine:%s\n' "$BOLD" "$YEL" "$RESET"
printf '       %sCause:%s harden.sh sets the nftables input policy to %sdrop%s; a rootless\n' "$DIM" "$RESET" "$BOLD" "$RESET"
printf '       published port is a host listener subject to that filter (rootful Docker\n'
printf '       bypasses it via its own NAT rules), so packets are dropped.\n'
printf '       %sFix (persistent):%s insert the rule before the input chain'"'"'s drop, then reload:\n' "$BOLD" "$RESET"
printf '           %ssudo sed -i '"'"'s/^\\([[:space:]]*\\)drop$/\\1tcp dport 8080 ct state new accept\\n\\1drop/'"'"' /etc/nftables.conf && sudo nft -f /etc/nftables.conf%s\n' "$CYN" "$RESET"
printf '           %s(survives reloads/reboots; swap tcp->udp for UDP)%s\n' "$DIM" "$RESET"
printf '       %sFix (temporary):%s %ssudo nft insert rule inet filter input tcp dport 8080 ct state new accept%s\n' "$BOLD" "$RESET" "$CYN" "$RESET"
printf '           %s(use insert, not add — the input chain ends in an explicit drop)%s\n' "$DIM" "$RESET"
printf '       %sStill stuck?%s %sss -tlnp | grep '"'"':8080'"'"'%s — if bound to %s127.0.0.1%s, change the compose\n' "$BOLD" "$RESET" "$CYN" "$RESET" "$BOLD" "$RESET"
printf '           mapping from %s127.0.0.1:8080:80%s to %s8080:80%s and redeploy.\n' "$DIM" "$RESET" "$DIM" "$RESET"
hr '═'
printf '%s%s  Done. 🐳%s\n\n' "$BOLD" "$GRN" "$RESET"

# One-line summary for init.sh's bootstrap report.
_runtimes=""
if [[ "$INSTALL_DOCKER" == "1" ]]; then
  if [[ "$SETUP_ROOTLESS" == "1" ]]; then _runtimes="Docker (rootless for ${CONTAINER_USER})"; else _runtimes="Docker (root daemon)"; fi
fi
if [[ "$INSTALL_PODMAN" == "1" ]]; then
  [[ -n "$_runtimes" ]] && _runtimes+=" + "
  _runtimes+="Podman (rootless for ${CONTAINER_USER})"
fi
if [[ "$CREATE_EXAMPLE_APP" == "1" ]]; then _opt="${OPT_DOCKER_DIR} created (+ ${EXAMPLE_APP})"; else _opt="${OPT_DOCKER_DIR} created (no example app)"; fi
mkdir -p /var/lib/homelab-bootstrap/summaries
printf '%s installed; %s\n' "$_runtimes" "$_opt" \
  > /var/lib/homelab-bootstrap/summaries/container.sh
