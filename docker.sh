#!/usr/bin/env bash
# ==============================================================================
#  Docker Engine + Compose + Rootless Docker installer for Debian
#
#  Follows the official documentation:
#    - https://docs.docker.com/engine/install/debian
#    - https://docs.docker.com/engine/security/rootless/
#
#  - Installs Docker Engine, CLI, containerd, Buildx and the Compose plugin
#    from Docker's official apt repository.
#  - Sets up ROOTLESS Docker for a chosen non-root user.
#  - Colorful output, DRY-RUN mode, prompts, idempotent, with a final recap.
#
#  Run as root (e.g. sudo ./docker.sh).
#
#  Environment overrides:
#    DOCKER_USER=<name>     -> user to configure rootless Docker for
#    DRY_RUN=1|0            -> force preview / actual (else asks)
#    ASSUME_YES=1           -> answer "yes" to all prompts (automation)
#    SETUP_ROOTLESS=1|0     -> set up rootless mode (else asks; default yes)
#    DISABLE_ROOTFUL=1|0    -> disable the system-wide root daemon (else asks)
#    USERNS_METHOD=apparmor|sysctl|none
#                           -> how to let rootless create user namespaces when
#                              Debian restricts them via AppArmor (else asks):
#                              apparmor = targeted profile for rootlesskit
#                                         (RECOMMENDED — keeps the restriction
#                                          for everything else; see
#                                          https://docs.docker.com/engine/security/apparmor/)
#                              sysctl   = disable the restriction globally
#                              none     = change nothing (rootless may fail)
#    CREATE_OPT_DOCKER=1|0   -> create the /opt/docker layout + example app
#    EXAMPLE_APP=<name>      -> example app folder name (default example-app)
#    EXAMPLE_PORT=<port>     -> host port for the example app (default 8080)
# ==============================================================================

set -euo pipefail

# Ensure sbin paths are present (apparmor_parser, sysctl, loginctl, etc. live in
# /usr/sbin and /sbin, which some non-login shells / sudo configs drop).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# =======================
# Config (env overridable)
# =======================
DOCKER_USER="${DOCKER_USER:-${SUDO_USER:-}}"   # default to the sudo invoker
SETUP_ROOTLESS="${SETUP_ROOTLESS:-}"           # empty = prompt
DISABLE_ROOTFUL="${DISABLE_ROOTFUL:-}"         # empty = prompt
USERNS_METHOD="${USERNS_METHOD:-}"             # apparmor|sysctl|none ; empty = prompt
CREATE_OPT_DOCKER="${CREATE_OPT_DOCKER:-}"     # empty = prompt ; create /opt/docker layout
ASSUME_YES="${ASSUME_YES:-0}"

# /opt/docker production layout (per the "organizing Docker files" guide)
OPT_DOCKER_DIR="/opt/docker"
EXAMPLE_APP="${EXAMPLE_APP:-example-app}"      # example app folder name
EXAMPLE_PORT="${EXAMPLE_PORT:-8080}"           # host port for the example app

if [[ -n "${DRY_RUN+x}" ]]; then DRY_RUN_EXPLICIT=1; else DRY_RUN_EXPLICIT=0; fi
DRY_RUN="${DRY_RUN:-}"

START_TS="$(date +%s)"

# Docker packages (per docs.docker.com/engine/install/debian)
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
# Extra package that provides dockerd-rootless-setuptool.sh
ROOTLESS_PKG="docker-ce-rootless-extras"
# Rootless prerequisites for Debian (uidmap = newuidmap/newgidmap)
ROOTLESS_PREREQS=(uidmap dbus-user-session slirp4netns)
# Old/conflicting packages the install docs say to remove first
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
TOTAL_STEPS=6
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
dry()  { printf '   %s[dry-run]%s %s\n' "$MAG" "$RESET" "$*"; }

# ------------------------------------------------------------------------------
#  Action wrappers (dry-run aware)
# ------------------------------------------------------------------------------
run() { if [[ "$DRY_RUN" == "1" ]]; then dry "$*"; return 0; fi; "$@"; }

write_file() {
  local path="$1"
  if [[ "$DRY_RUN" == "1" ]]; then dry "write ${BOLD}${path}${RESET}:"; sed 's/^/        │ /'; return 0; fi
  cat > "$path"
}

# run_as_user <cmd...>  — run a command as DOCKER_USER with a working user
# systemd/D-Bus session (required by the rootless setup tool).
run_as_user() {
  local uid; uid="$(id -u "$DOCKER_USER")"
  if [[ "$DRY_RUN" == "1" ]]; then dry "su - $DOCKER_USER -c '$*'"; return 0; fi
  runuser -l "$DOCKER_USER" -c \
    "export XDG_RUNTIME_DIR=/run/user/${uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus PATH=/usr/bin:/usr/sbin:/sbin:\$PATH; $*"
}

# install_rootlesskit_apparmor_profile — grant ONLY rootlesskit the userns
# permission, keeping kernel.apparmor_restrict_unprivileged_userns enforced for
# everything else (the AppArmor-aligned fix per docs.docker.com).
install_rootlesskit_apparmor_profile() {
  local bin name profile abi_line=""
  bin="$(command -v rootlesskit 2>/dev/null || echo /usr/bin/rootlesskit)"
  name="$(printf '%s' "${bin#/}" | tr '/' '.')"     # e.g. usr.bin.rootlesskit
  profile="/etc/apparmor.d/${name}"
  # Use the abi pin only if this AppArmor ships it (4.x); harmless to omit otherwise.
  [[ -e /etc/apparmor.d/abi/4.0 ]] && abi_line=$'abi <abi/4.0>,\n'
  printf '%s' "# Allow rootless Docker's RootlessKit to create user namespaces while keeping
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

choose_run_mode() {
  if [[ "$DRY_RUN_EXPLICIT" == "1" ]]; then [[ "$DRY_RUN" == "1" ]] && DRY_RUN=1 || DRY_RUN=0; return; fi
  if [[ "$INTERACTIVE" -eq 0 ]]; then [[ "$ASSUME_YES" == "1" ]] && DRY_RUN=0 || DRY_RUN=1; return; fi
  local choice=""
  printf '\n%s%sHow do you want to run the Docker installer?%s\n' "$BOLD" "$WHT" "$RESET" > /dev/tty
  printf '   %s[1]%s %sDry run%s — preview every action, change NOTHING (recommended first)\n' "$BOLD" "$RESET" "$GRN" "$RESET" > /dev/tty
  printf '   %s[2]%s %sActual run%s — install & configure Docker\n' "$BOLD" "$RESET" "$RED" "$RESET" > /dev/tty
  printf '%s%s Choose 1 or 2 [default: 1]: %s' "$YEL" "$S_WARN" "$RESET" > /dev/tty
  read -r choice < /dev/tty || choice=""
  case "${choice:-1}" in 2) DRY_RUN=0 ;; *) DRY_RUN=1 ;; esac
}

prompt_for_user() {
  # Choose the user that will own rootless Docker.
  if [[ -z "$DOCKER_USER" && "$INTERACTIVE" -eq 1 ]]; then
    printf '%s%s Which user should own rootless Docker? [default: admin]: %s' "$YEL" "$S_INFO" "$RESET" > /dev/tty
    read -r DOCKER_USER < /dev/tty || DOCKER_USER=""
  fi
  DOCKER_USER="${DOCKER_USER:-admin}"
}

# ==============================================================================
#  Splash
# ==============================================================================
clear 2>/dev/null || true
printf '%s' "$BOLD$BLU"
cat <<'EOF'
   ____             _              ____             _   _
  |  _ \  ___   ___| | _____ _ __ |  _ \ ___   ___ | |_| | ___ ___ ___
  | | | |/ _ \ / __| |/ / _ \ '__|| |_) / _ \ / _ \| __| |/ _ Y __/ __|
  | |_| | (_) | (__|   <  __/ |   |  _ < (_) | (_) | |_| |  __|__ \__ \
  |____/ \___/ \___|_|\_\___|_|   |_| \_\___/ \___/ \__|_|\___|___/___/
EOF
printf '%s' "$RESET"
printf '%s        Docker Engine + Compose + Rootless setup for Debian%s\n' "$DIM" "$RESET"
hr '─'

require_root
if ! command -v apt >/dev/null 2>&1; then err "This installer targets Debian/apt systems."; exit 1; fi
if [[ ! -r /etc/os-release ]] || ! grep -qiE 'ID=debian|ID_LIKE=.*debian' /etc/os-release; then
  warn "This does not look like Debian — the apt repo path assumes Debian."
fi

choose_run_mode
prompt_for_user

if [[ "$DRY_RUN" == "1" ]]; then MODE_LABEL="${MAG}DRY RUN (no changes)${RESET}"; else MODE_LABEL="${RED}ACTUAL RUN${RESET}"; fi
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")"
ARCH="$(dpkg --print-architecture)"

info "Mode          : ${BOLD}${MODE_LABEL}"
info "Target user   : ${BOLD}${DOCKER_USER}${RESET}"
info "Debian suite  : ${BOLD}${CODENAME}${RESET}   arch: ${BOLD}${ARCH}${RESET}"
hr '─'

# ==============================================================================
#  PRE-FLIGHT
# ==============================================================================
header "Pre-flight checks"

# Validate the target user exists (must, for rootless).
if ! id "$DOCKER_USER" >/dev/null 2>&1; then
  err "User '$DOCKER_USER' does not exist. Create it first (the hardening script makes 'admin')."
  exit 1
fi
USER_UID="$(id -u "$DOCKER_USER")"
USER_HOME="$(getent passwd "$DOCKER_USER" | cut -d: -f6)"
log "Target user '$DOCKER_USER' exists (uid ${USER_UID}, home ${USER_HOME})."

# Detect conflicting packages.
FOUND_CONFLICTS=()
for p in "${CONFLICT_PKGS[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" && FOUND_CONFLICTS+=("$p")
done
if (( ${#FOUND_CONFLICTS[@]} > 0 )); then
  warn "Conflicting packages present (docs say remove before installing): ${FOUND_CONFLICTS[*]}"
else
  log "No conflicting Docker packages installed."
fi

# Resolve rootless / rootful / userns decisions.
[[ -z "$SETUP_ROOTLESS"   ]] && { confirm "Set up ROOTLESS Docker for '$DOCKER_USER'?" Y && SETUP_ROOTLESS=1 || SETUP_ROOTLESS=0; }
if [[ "$SETUP_ROOTLESS" == "1" ]]; then
  [[ -z "$DISABLE_ROOTFUL" ]] && { confirm "Also DISABLE the system-wide (root) Docker daemon? (recommended for rootless-only)" Y && DISABLE_ROOTFUL=1 || DISABLE_ROOTFUL=0; }
fi
DISABLE_ROOTFUL="${DISABLE_ROOTFUL:-0}"

# Debian restricts unprivileged user namespaces; rootless Docker (RootlessKit)
# needs them. Two independent knobs may exist:
#   - kernel.unprivileged_userns_clone (Debian 11): 0 = userns disabled entirely
#   - kernel.apparmor_restrict_unprivileged_userns (Debian 13): 1 = AppArmor-gated
# The hardening script keeps AppArmor enabled, which is what enforces the latter.
USERNS_CLONE_OFF=0      # legacy knob set to 0 (needs flipping to 1)
APPARMOR_USERNS_ON=0    # Debian 13 AppArmor restriction active
[[ -e /proc/sys/kernel/unprivileged_userns_clone ]] && \
  [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)" == "0" ]] && USERNS_CLONE_OFF=1
[[ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]] && \
  [[ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" == "1" ]] && APPARMOR_USERNS_ON=1

if [[ "$SETUP_ROOTLESS" == "1" && "$APPARMOR_USERNS_ON" == "1" ]]; then
  warn "AppArmor restricts unprivileged user namespaces on this kernel (Debian 13 default)."
  note "Rootless RootlessKit needs to create a userns. Choose how to allow it (per docs.docker.com/engine/security/apparmor):"
  if [[ -z "$USERNS_METHOD" ]]; then
    if [[ "$INTERACTIVE" -eq 1 ]]; then
      printf '   %s[1]%s %sAppArmor profile for rootlesskit%s — recommended; keeps the restriction for everything else\n' "$BOLD" "$RESET" "$GRN" "$RESET" > /dev/tty
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

# Create the /opt/docker layout + example app?
[[ -z "$CREATE_OPT_DOCKER" ]] && { confirm "Create the ${OPT_DOCKER_DIR} structure with an example app?" Y && CREATE_OPT_DOCKER=1 || CREATE_OPT_DOCKER=0; }
CREATE_OPT_DOCKER="${CREATE_OPT_DOCKER:-1}"

# Offer to remove conflicts.
PURGE_CONFLICTS=0
if (( ${#FOUND_CONFLICTS[@]} > 0 )) && [[ "$DRY_RUN" != "1" ]]; then
  confirm "Remove conflicting packages now (${FOUND_CONFLICTS[*]})?" N && PURGE_CONFLICTS=1
fi

echo
if [[ "$DRY_RUN" != "1" ]]; then
  confirm "Proceed installing Docker (+ Compose)$( [[ $SETUP_ROOTLESS == 1 ]] && echo ' + rootless' ) for '$DOCKER_USER'?" N \
    || { err "Aborted by user."; exit 1; }
fi

# ==============================================================================
banner "Removing conflicting packages"
# ==============================================================================
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

# ==============================================================================
banner "Setting up Docker's apt repository"
# ==============================================================================
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

# ==============================================================================
banner "Installing Docker Engine + Compose"
# ==============================================================================
PKGS=("${DOCKER_PKGS[@]}")
[[ "$SETUP_ROOTLESS" == "1" ]] && PKGS+=("$ROOTLESS_PKG")
info "Installing: ${DIM}${PKGS[*]}${RESET}"
run apt -y install "${PKGS[@]}"
log "Docker Engine, CLI, containerd, Buildx and Compose plugin installed."
note "Compose is available as 'docker compose' (v2 plugin)."
record "Docker" "Engine + CLI + containerd + buildx + compose-plugin installed"

# ==============================================================================
banner "Configuring rootless prerequisites"
# ==============================================================================
if [[ "$SETUP_ROOTLESS" == "1" ]]; then
  info "Installing rootless prerequisites: ${DIM}${ROOTLESS_PREREQS[*]}${RESET}"
  run apt -y install "${ROOTLESS_PREREQS[@]}"

  # Ensure subordinate UID/GID ranges exist for the user (>= 65536).
  for f in /etc/subuid /etc/subgid; do
    if [[ "$DRY_RUN" == "1" ]]; then
      dry "ensure ${DOCKER_USER} has a >=65536 range in ${f}"
    elif ! grep -q "^${DOCKER_USER}:" "$f" 2>/dev/null; then
      printf '%s:100000:65536\n' "$DOCKER_USER" >> "$f"
      log "Added subordinate range for ${DOCKER_USER} to ${f}."
    else
      log "${f} already has a range for ${DOCKER_USER}."
    fi
  done

  # Legacy Debian 11 knob: enable unprivileged userns entirely if it is off.
  if [[ "$USERNS_CLONE_OFF" == "1" ]]; then
    printf '# Enable unprivileged user namespaces for rootless Docker\nkernel.unprivileged_userns_clone = 1\n' \
      | write_file /etc/sysctl.d/99-rootless-userns.conf
    run sysctl --system >/dev/null
    log "Enabled kernel.unprivileged_userns_clone=1."
    record "userns(clone)" "enabled via /etc/sysctl.d/99-rootless-userns.conf"
  fi

  # Debian 13 AppArmor restriction: apply the chosen method.
  if [[ "$APPARMOR_USERNS_ON" == "1" ]]; then
    case "$USERNS_METHOD" in
      apparmor)
        info "Installing a targeted AppArmor profile so rootlesskit may create user namespaces..."
        install_rootlesskit_apparmor_profile
        log "AppArmor profile loaded — restriction stays ON for everything except rootlesskit."
        record "userns(apparmor)" "Profile ${APPARMOR_PROFILE_PATH:-/etc/apparmor.d/usr.bin.rootlesskit} grants rootlesskit 'userns'"
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
else
  note "Rootless setup skipped — Docker runs as the root daemon."
  record "Rootless prereqs" "skipped"
fi

# ==============================================================================
banner "Setting up rootless Docker"
# ==============================================================================
if [[ "$SETUP_ROOTLESS" == "1" ]]; then
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
  if [[ "$DRY_RUN" == "1" ]]; then
    dry "loginctl enable-linger ${DOCKER_USER}"
    dry "su - ${DOCKER_USER} -c 'dockerd-rootless-setuptool.sh install'"
    dry "su - ${DOCKER_USER} -c 'systemctl --user enable docker'"
    record "Rootless" "[dry-run] would run setuptool + enable user service"
  else
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
  fi

  # Configure the user's shell environment (PATH + DOCKER_HOST).
  BASHRC="${USER_HOME}/.bashrc"
  ENV_BLOCK=$'\n# >>> rootless docker >>>\nexport PATH=/usr/bin:$PATH\nexport DOCKER_HOST=unix:///run/user/'"${USER_UID}"$'/docker.sock\n# <<< rootless docker <<<\n'
  if [[ "$DRY_RUN" == "1" ]]; then
    dry "append rootless env (PATH + DOCKER_HOST) to ${BASHRC}"
  elif [[ -f "$BASHRC" ]] && grep -q 'rootless docker' "$BASHRC"; then
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
else
  note "Rootless Docker not configured."
fi

# ==============================================================================
banner "Creating /opt/docker structure + example app"
# ==============================================================================
# Layout per the "organizing Docker files for production" guide:
#   /opt/docker/
#   ├── <app>/
#   │   ├── docker-compose.yml
#   │   ├── .env            (sensitive — chmod 600, keep out of VCS)
#   │   └── data/           (persistent volume)
#   └── shared/
#       └── networks/       (reusable external networks)
if [[ "$CREATE_OPT_DOCKER" == "1" ]]; then
  if [[ "$SETUP_ROOTLESS" == "1" ]]; then OPT_OWNER="$DOCKER_USER:$DOCKER_USER"; else OPT_OWNER="root:docker"; fi
  APP_DIR="${OPT_DOCKER_DIR}/${EXAMPLE_APP}"

  info "Creating ${OPT_DOCKER_DIR} tree (owner ${OPT_OWNER})..."
  run install -d -m 0755 "$OPT_DOCKER_DIR"
  run install -d -m 0755 "${OPT_DOCKER_DIR}/shared" "${OPT_DOCKER_DIR}/shared/networks"
  run install -d -m 0750 "$APP_DIR" "${APP_DIR}/data"

  # docker-compose.yml — do not clobber an existing one.
  if [[ "$DRY_RUN" != "1" && -f "${APP_DIR}/docker-compose.yml" ]]; then
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
  if [[ "$DRY_RUN" != "1" && -f "${APP_DIR}/.env" ]]; then
    log "Existing ${APP_DIR}/.env left untouched."
  else
    write_file "${APP_DIR}/.env" <<EOF
# ${EXAMPLE_APP} environment — keep this file OUT of version control.
HOST_PORT=${EXAMPLE_PORT}
EOF
  fi

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

  # Ownership + permissions (guide: restrict sensitive files, keep compose readable).
  if [[ "$DRY_RUN" == "1" ]]; then
    dry "chown -R ${OPT_OWNER} ${OPT_DOCKER_DIR}"
    dry "chmod 600 ${APP_DIR}/.env ; chmod 644 ${APP_DIR}/docker-compose.yml"
  else
    chown -R "$OPT_OWNER" "$OPT_DOCKER_DIR"
    chmod 600 "${APP_DIR}/.env"
    chmod 644 "${APP_DIR}/docker-compose.yml"
  fi
  log "Created ${OPT_DOCKER_DIR}/{${EXAMPLE_APP},shared/networks}."
  if [[ "$SETUP_ROOTLESS" == "1" ]]; then
    note "Start it as ${DOCKER_USER}:  cd ${APP_DIR} && docker compose up -d"
  else
    note "Start it:  cd ${APP_DIR} && sudo docker compose up -d"
  fi
  note "Then browse http://<host>:${EXAMPLE_PORT} (open that port in the firewall first)."
  record "/opt/docker" "Created ${APP_DIR} (compose+.env+data) + shared/networks; owner ${OPT_OWNER}"
else
  note "Skipped creating ${OPT_DOCKER_DIR}."
  record "/opt/docker" "skipped"
fi

# ==============================================================================
#  Verification (actual run only)
# ==============================================================================
header "Verification"
if [[ "$DRY_RUN" == "1" ]]; then
  note "Dry run — nothing was installed; run again and choose Actual to apply."
else
  printf '\n%s%sdocker --version:%s\n' "$BOLD" "$WHT" "$RESET"; docker --version 2>/dev/null || warn "docker not found on PATH"
  printf '\n%s%sdocker compose version:%s\n' "$BOLD" "$WHT" "$RESET"; docker compose version 2>/dev/null || warn "compose plugin not found"
  if [[ "$SETUP_ROOTLESS" == "1" ]]; then
    printf '\n%s%srootless context (as %s):%s\n' "$BOLD" "$WHT" "$DOCKER_USER" "$RESET"
    run_as_user "docker info --format 'Rootless: {{.SecurityOptions}}' 2>/dev/null" || \
      note "Run 'docker info' as ${DOCKER_USER} to confirm rootless once their session is active."
  fi
fi

# ==============================================================================
#  RECAP
# ==============================================================================
ELAPSED=$(( $(date +%s) - START_TS )); MM=$(( ELAPSED / 60 )); SS=$(( ELAPSED % 60 ))
printf '\n'; hr '═'
if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s%s  🧪  DRY RUN COMPLETE — NO CHANGES MADE — RECAP%s\n' "$BOLD" "$MAG" "$RESET"
else
  printf '%s%s  ✅  DOCKER INSTALL COMPLETE — RECAP%s\n' "$BOLD" "$GRN" "$RESET"
fi
hr '═'
printf '%s  Host: %s   |   Elapsed: %dm %ds%s\n' "$DIM" "$(hostname)" "$MM" "$SS" "$RESET"
hr '─'
printf '%s%s  WHAT %s%s\n' "$BOLD" "$CYN" "$( [[ $DRY_RUN == 1 ]] && echo 'WOULD BE DONE' || echo 'WAS DONE' )" "$RESET"
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
if [[ "$DRY_RUN" == "1" ]]; then
  printf '   %s•%s  Re-run and choose %sActual%s (or %sDRY_RUN=0 sudo ./%s%s) to install.\n' \
    "$BOLD" "$RESET" "$BOLD" "$RESET" "$DIM" "$(basename "$0")" "$RESET"
else
  printf '   %s1.%s Log in as %s%s%s (or re-login) so its systemd user session is active.\n' "$BOLD" "$RESET" "$BOLD" "$DOCKER_USER" "$RESET"
  if [[ "$SETUP_ROOTLESS" == "1" ]]; then
    printf '   %s2.%s Test rootless: %sdocker run --rm hello-world%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
    printf '   %s•%s  DOCKER_HOST is set to %sunix:///run/user/%s/docker.sock%s in ~%s/.bashrc\n' \
      "$BOLD" "$RESET" "$DIM" "$USER_UID" "$RESET" "$DOCKER_USER"
    printf '   %s•%s  Published rootless ports bind on the host — open them in the firewall as needed.\n' "$BOLD" "$RESET"
  else
    printf '   %s2.%s Add your user to the %sdocker%s group to use the root daemon without sudo.\n' "$BOLD" "$RESET" "$BOLD" "$RESET"
  fi
  if [[ "$CREATE_OPT_DOCKER" == "1" ]]; then
    printf '   %s3.%s Launch the example app: %scd %s/%s && docker compose up -d%s\n' \
      "$BOLD" "$RESET" "$DIM" "$OPT_DOCKER_DIR" "$EXAMPLE_APP" "$RESET"
    printf '   %s•%s  Add more apps as %s%s/<app>/docker-compose.yml%s (one folder per app).\n' \
      "$BOLD" "$RESET" "$DIM" "$OPT_DOCKER_DIR" "$RESET"
  fi
fi
hr '═'
printf '%s%s  Done. 🐳%s\n\n' "$BOLD" "$GRN" "$RESET"

# One-line summary for init.sh's bootstrap report (actual runs only).
if [[ "$DRY_RUN" != "1" ]]; then
  if [[ "$SETUP_ROOTLESS" == "1" ]]; then _rootless="rootless for ${DOCKER_USER}"; else _rootless="root daemon"; fi
  if [[ "$CREATE_OPT_DOCKER" == "1" ]]; then _opt="/opt/docker created (${EXAMPLE_APP})"; else _opt="/opt/docker skipped"; fi
  mkdir -p /var/lib/homelab-bootstrap/summaries
  printf 'Docker Engine + Compose installed; %s; %s\n' "$_rootless" "$_opt" \
    > /var/lib/homelab-bootstrap/summaries/docker.sh
fi
