#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — init
#  Entry point. Must run as root. It:
#    1. asks WHICH steps to run (harden, extra services, MOTD, connect doc) —
#       "extra services" is one prompt covering the optional packages and
#       rootless Docker
#    2. asks EVERY question up front (a single wizard)
#    3. runs each chosen script NON-INTERACTIVELY (answers passed via env), so
#       nothing stops mid-run to ask you anything
#    4. prints ONE consolidated report (review + next steps)
#
#  Run as root, e.g.:  sudo ./init.sh
#  Or one-liner:       curl -fsSL <raw-url>/init.sh | sudo bash
#
#  curl must already be present (the one-liner above uses it; download fallback
#  needs it too). Debian ships it on all but the most minimal installs.
#
#  Environment overrides:
#    REPO_RAW_BASE=<url>  -> base raw URL to fetch scripts from
#    ASSUME_YES=1         -> accept all wizard defaults (fully unattended)
# ==============================================================================

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main}"
ASSUME_YES="${ASSUME_YES:-0}"
START_TS="$(date +%s)"

# Extra services init can install, presented to the user as one "extra services"
# group. The apt packages are handled by ancillary.sh (chosen list passed via
# ANCILLARY_PKGS); "docker" runs docker.sh (rootless Docker). Order = display.
EXTRA_SERVICES=(btop fish rsync qemu-guest-agent zabbix-agent2 alloy docker)
declare -A EXTRA_DESC=(
  [btop]="resource monitor (htop-like)"
  [fish]="friendly interactive shell"
  [rsync]="fast file copy / sync"
  [qemu-guest-agent]="QEMU/KVM guest integration (VMs only)"
  [zabbix-agent2]="Zabbix agent 2 monitoring (needs a Zabbix server)"
  [alloy]="Grafana Alloy log shipper (needs a Loki server)"
  [docker]="Docker Engine + Compose + rootless setup + /opt/docker layout"
)

# Where each script drops a one-line summary of what it did (read for the recap).
SUMMARY_DIR="/var/lib/homelab-bootstrap/summaries"

# Persistent error log for this run. Created lazily (only if something goes
# wrong) so its mere existence means "an error occurred" — its location is
# printed in the final report. Lives outside the throwaway WORKDIR so it
# survives the cleanup trap.
LOG_DIR="/var/log/homelab-bootstrap"
ERROR_LOG="${LOG_DIR}/install-errors-$(date +%Y%m%d-%H%M%S).log"
ERROR_COUNT=0

# Scripts offered, in order. documentation.sh is last: it documents the host you
# just set up (it generates a doc, it doesn't change the system).
SCRIPTS=(harden.sh ancillary.sh docker.sh motd.sh documentation.sh)

# ==============================================================================
#  Output helpers
# ==============================================================================
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'
  BLU=$'\033[1;34m'; MAG=$'\033[1;35m'; CYN=$'\033[1;36m'; WHT=$'\033[1;37m'
else
  BOLD=''; DIM=''; RESET=''; RED=''; GRN=''; YEL=''; BLU=''; MAG=''; CYN=''; WHT=''
fi
S_OK="✔"; S_INFO="•"; S_WARN="!"; S_ERR="✗"; S_STEP="▸"; S_SKIP="⏭"

hr()   { local ch="${1:-─}" w=72 l=""; printf -v l '%*s' "$w" ''; printf '%s%s%s\n' "$DIM" "${l// /$ch}" "$RESET"; }
log()  { printf '%s%s%s %s\n' "$GRN" "$S_OK"   "$RESET" "$*"; }
info() { printf '%s%s%s %s\n' "$BLU" "$S_INFO" "$RESET" "$*"; }
warn() { printf '%s%s %s%s\n' "$YEL" "$S_WARN" "$*" "$RESET"; }
err()  { printf '%s%s %s%s\n' "$RED" "$S_ERR" "$*" "$RESET" >&2; }
note() { printf '   %s%s%s\n' "$DIM" "$*" "$RESET"; }
step() { printf '\n'; hr '═'; printf '%s%s %s%s\n' "$BOLD$CYN" "$S_STEP" "$*" "$RESET"; hr '═'; }

# add_error <script> <message> — record a problem to the persistent error log.
# The log + its dir are created lazily here, so the file only exists if an issue
# actually occurred (the final report keys off that).
add_error() {
  local script="$1"; shift
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$script" "$*" >> "$ERROR_LOG" 2>/dev/null || true
  ERROR_COUNT=$((ERROR_COUNT + 1))
}

# log_diagnostics <script> <logfile> — append the script's own error lines and a
# short tail of its output to the error log, for context after the run.
log_diagnostics() {
  local script="$1" logf="$2"
  [[ -n "$logf" && -f "$logf" ]] || return 0
  {
    printf '    --- error lines from %s ---\n' "$script"
    grep -F "$S_ERR" "$logf" 2>/dev/null | sed 's/^/    /' || true
    printf '    --- last 20 lines of %s output ---\n' "$script"
    tail -n 20 "$logf" 2>/dev/null | sed 's/^/    /' || true
    printf '\n'
  } >> "$ERROR_LOG" 2>/dev/null || true
}

# confirm "Q?" [default Y|N] -> 0 yes / 1 no  (reads /dev/tty)
confirm() {
  local prompt="$1" default="${2:-N}" reply hint
  if [[ "$default" =~ ^[Yy]$ ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  if [[ "$ASSUME_YES" == "1" ]]; then info "auto: ${prompt} → ${default}"; [[ "$default" =~ ^[Yy] ]]; return; fi
  if [[ ! -r /dev/tty ]]; then info "non-interactive: ${prompt} → ${default}"; [[ "$default" =~ ^[Yy] ]]; return; fi
  printf '%s%s %s %s%s ' "$YEL" "$S_WARN" "$prompt" "$hint" "$RESET" > /dev/tty
  read -r reply < /dev/tty || reply=""
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

# ask "Question" "default" -> echoes the answer (reads /dev/tty)
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ "$ASSUME_YES" == "1" || ! -r /dev/tty ]]; then printf '%s' "$default"; return; fi
  printf '%s%s %s%s%s ' "$YEL" "$S_INFO" "$prompt" "${default:+ [default: $default]}" "$RESET" > /dev/tty
  read -r reply < /dev/tty || reply=""
  printf '%s' "${reply:-$default}"
}

# ask_secret "Prompt" -> echoes a password typed twice to confirm (input hidden),
# or empty if skipped / non-interactive. Reads /dev/tty.
ask_secret() {
  local prompt="$1" p1 p2
  [[ "$ASSUME_YES" == "1" || ! -r /dev/tty ]] && return 0
  while true; do
    printf '%s%s %s %s' "$YEL" "$S_INFO" "$prompt" "$RESET" > /dev/tty
    IFS= read -rs p1 < /dev/tty || p1=""; printf '\n' > /dev/tty
    [[ -z "$p1" ]] && return 0
    printf '%s%s %s (confirm) %s' "$YEL" "$S_INFO" "$prompt" "$RESET" > /dev/tty
    IFS= read -rs p2 < /dev/tty || p2=""; printf '\n' > /dev/tty
    [[ "$p1" == "$p2" ]] && { printf '%s' "$p1"; return 0; }
    printf '%s%s Passwords do not match — try again.%s\n' "$RED" "$S_ERR" "$RESET" > /dev/tty
  done
}

valid_user()  { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; }
valid_pubkey() {
  local key="$1" tmp
  [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]] || return 1
  if command -v ssh-keygen >/dev/null 2>&1; then
    tmp="$(mktemp)"; printf '%s\n' "$key" > "$tmp"
    ssh-keygen -l -f "$tmp" >/dev/null 2>&1; local rc=$?; rm -f "$tmp"; return $rc
  fi
  return 0
}

describe() {
  case "$1" in
    harden.sh)    printf 'system hardening (users, SSH, firewall, fail2ban, sysctl, AppArmor, AIDE, Lynis)';;
    ancillary.sh) printf 'pick-and-install extra packages (+ fish as your default shell)';;
    docker.sh)    printf 'Docker Engine + Compose + rootless setup + /opt/docker layout';;
    motd.sh)      printf 'cool dynamic login banner (host, IP, uptime) + docs link';;
    documentation.sh) printf 'generate /tmp/connect.html — how to SSH into this host on its hardened port';;
    *)            printf 'bootstrap script';;
  esac
}
in_selected() { local x; for x in "${SELECTED[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
# in_selected_arr <needle> <item...> — is <needle> among the remaining args?
in_selected_arr() { local n="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }

# ==============================================================================
#  Splash + checks
# ==============================================================================
clear 2>/dev/null || true
printf '%s' "$BOLD$MAG"
cat <<'EOF'
  ██████   ██████   ██████  ████████ ███████ ████████ ██████   █████  ██████
  ██   ██ ██    ██ ██    ██    ██    ██         ██    ██   ██ ██   ██ ██   ██
  ██████  ██    ██ ██    ██    ██    ███████    ██    ██████  ███████ ██████
  ██   ██ ██    ██ ██    ██    ██         ██    ██    ██   ██ ██   ██ ██
  ██████   ██████   ██████     ██    ███████    ██    ██   ██ ██   ██ ██
EOF
printf '%s' "$RESET"
printf '%s        Debian 13 Homelab Bootstrap  —  answer everything up front%s\n' "$DIM" "$RESET"
hr '─'

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then err "This script must be run as root (try: sudo $0)."; exit 1; fi
command -v apt-get >/dev/null 2>&1 || { err "apt-get not found — this targets Debian/apt systems."; exit 1; }
log "Running as root."
command -v curl >/dev/null 2>&1 || warn "curl not found — the download fallback for remote scripts won't work (local copies still will)."

# ==============================================================================
step "Step 1 — Choose run mode & scripts"
# ==============================================================================
# Mode: dry run vs actual (passed to every script).
DRY_RUN=1
if [[ "$ASSUME_YES" == "1" ]]; then
  DRY_RUN=0
elif [[ -r /dev/tty ]]; then
  printf '%s%sRun mode?%s  %s[1]%s Dry run (preview, no changes)   %s[2]%s Actual run\n' \
    "$BOLD" "$WHT" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET" > /dev/tty
  printf '%s%s Choose 1 or 2 [default: 1]: %s' "$YEL" "$S_WARN" "$RESET" > /dev/tty
  read -r _m < /dev/tty || _m=""
  [[ "${_m:-1}" == "2" ]] && DRY_RUN=0
fi
export DRY_RUN
[[ "$DRY_RUN" == "1" ]] && info "Mode: ${MAG}DRY RUN${RESET}" || info "Mode: ${RED}ACTUAL RUN${RESET}"

# Select which scripts to run.
declare -A STATUS DETAIL SUMM LOGS
SELECTED=()
ANCILLARY_PICK=()   # apt packages chosen in the "extra services" group below

skip_script() { STATUS[$1]="skipped"; DETAIL[$1]="you chose not to run it"; }

# --- harden.sh
printf '\n%s%s %s%s%s — %s%s%s\n' "$BOLD" "$S_STEP" "$CYN" "harden.sh" "$RESET" "$DIM" "$(describe harden.sh)" "$RESET"
if confirm "Harden the system?" Y; then SELECTED+=(harden.sh); else skip_script harden.sh; fi

# --- ancillary.sh + docker.sh — combined "extra services" group.
printf '\n%s%s %sExtra services%s — %s%s%s\n' "$BOLD" "$S_STEP" "$CYN" "$RESET" "$DIM" "extra packages + optional rootless Docker" "$RESET"
if confirm "Install extra services?" Y; then
  info "Pick which services to install:"
  INSTALL_DOCKER=0
  for p in "${EXTRA_SERVICES[@]}"; do
    confirm "Install ${p} — ${EXTRA_DESC[$p]}?" Y || continue
    if [[ "$p" == "docker" ]]; then INSTALL_DOCKER=1; else ANCILLARY_PICK+=("$p"); fi
  done
  if (( ${#ANCILLARY_PICK[@]} > 0 )); then SELECTED+=(ancillary.sh); else skip_script ancillary.sh; fi
  if (( INSTALL_DOCKER == 1 )); then SELECTED+=(docker.sh); else skip_script docker.sh; fi
else
  skip_script ancillary.sh; skip_script docker.sh
fi

# --- motd.sh
printf '\n%s%s %s%s%s — %s%s%s\n' "$BOLD" "$S_STEP" "$CYN" "motd.sh" "$RESET" "$DIM" "$(describe motd.sh)" "$RESET"
if confirm "Generate a custom MOTD for this system?" Y; then SELECTED+=(motd.sh); else skip_script motd.sh; fi

# --- documentation.sh
printf '\n%s%s %s%s%s — %s%s%s\n' "$BOLD" "$S_STEP" "$CYN" "documentation.sh" "$RESET" "$DIM" "$(describe documentation.sh)" "$RESET"
if confirm "Generate documentation?" Y; then SELECTED+=(documentation.sh); else skip_script documentation.sh; fi

if (( ${#SELECTED[@]} == 0 )); then
  warn "No scripts selected — nothing to do."
  exit 0
fi

# ==============================================================================
step "Step 2 — Configuration (all questions answered now)"
# ==============================================================================
PRIMARY_USER=""

# --- A primary user is needed by harden (create), docker (owner), ancillary (fish)
if in_selected harden.sh || in_selected docker.sh || in_selected ancillary.sh; then
  mapfile -t HUMANS < <(awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | sort)
  default_user="${SUDO_USER:-}"; [[ -n "$default_user" ]] || { (( ${#HUMANS[@]} == 1 )) && default_user="${HUMANS[0]}"; }

  if in_selected harden.sh; then
    # harden can create the user, so ask which admin user to create/harden.
    while true; do
      (( ${#HUMANS[@]} > 0 )) && note "Existing users: ${HUMANS[*]}"
      PRIMARY_USER="$(ask "Admin username (sudo + SSH key) — enter an existing user to harden, or a new name to create one" "$default_user")"
      PRIMARY_USER="${PRIMARY_USER//[[:space:]]/}"
      if [[ -z "$PRIMARY_USER" ]]; then warn "A username is required."; [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "No user available."; exit 1; }; continue; fi
      if ! valid_user "$PRIMARY_USER"; then warn "Invalid username (lowercase letters, digits, - and _)."; continue; fi
      break
    done
  else
    # harden NOT selected — docker/ancillary just need an EXISTING user to own
    # things. Auto-detect it (SUDO_USER or the sole human account) and only ask
    # if it can't be resolved unambiguously, so we don't prompt unnecessarily.
    if [[ -n "$default_user" ]] && id "$default_user" >/dev/null 2>&1; then
      PRIMARY_USER="$default_user"
    else
      while true; do
        (( ${#HUMANS[@]} > 0 )) && note "Existing users: ${HUMANS[*]}"
        PRIMARY_USER="$(ask "Existing user to configure?" "$default_user")"
        PRIMARY_USER="${PRIMARY_USER//[[:space:]]/}"
        if [[ -z "$PRIMARY_USER" ]]; then warn "A username is required."; [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "No user available."; exit 1; }; continue; fi
        if ! valid_user "$PRIMARY_USER"; then warn "Invalid username (lowercase letters, digits, - and _)."; continue; fi
        if ! id "$PRIMARY_USER" >/dev/null 2>&1; then
          warn "User '$PRIMARY_USER' does not exist — pick an existing one (or include harden.sh to create it)."
          [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "User '$PRIMARY_USER' does not exist."; exit 1; }
          continue
        fi
        break
      done
    fi
  fi
  log "Primary user: ${BOLD}${PRIMARY_USER}${RESET}"
fi

# --- harden.sh questions
if in_selected harden.sh; then
  export ADMIN_USERS="$PRIMARY_USER"

  # SSH key (REQUIRED — harden disables password auth; no key = lockout).
  PUBKEY=""
  while true; do
    note "Paste ${PRIMARY_USER}'s PUBLIC SSH key. No key yet? On your machine run:"
    printf '        %sssh-keygen -t ed25519 -C "user@example.com"%s\n' "$CYN" "$RESET" > /dev/tty 2>/dev/null || true
    PUBKEY="$(ask "SSH public key for ${PRIMARY_USER}" "${PUBKEY:-}")"
    PUBKEY="${PUBKEY#"${PUBKEY%%[![:space:]]*}"}"; PUBKEY="${PUBKEY%"${PUBKEY##*[![:space:]]}"}"
    if [[ -z "$PUBKEY" ]]; then
      if id "$PRIMARY_USER" >/dev/null 2>&1 && [[ -s "$(getent passwd "$PRIMARY_USER" | cut -d: -f6)/.ssh/authorized_keys" ]]; then
        note "No key entered, but ${PRIMARY_USER} already has authorized_keys — continuing."; break
      fi
      warn "A key is required (password login is disabled). Without one you'd be locked out."
      [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "No SSH key provided for ${PRIMARY_USER}."; exit 1; }
      continue
    fi
    if valid_pubkey "$PUBKEY"; then log "SSH key accepted."; export PUBKEY; break; fi
    warn "That does not look like a valid SSH public key — try again."
  done

  # If the admin user doesn't exist yet, harden.sh will create it — collect a
  # password to set on the new account (optional; blank = SSH-key only).
  if ! id "$PRIMARY_USER" >/dev/null 2>&1; then
    note "User '${PRIMARY_USER}' will be created."
    ADMIN_PASSWORD="$(ask_secret "Password for new user ${PRIMARY_USER} (blank to skip)")"
    if [[ -n "$ADMIN_PASSWORD" ]]; then
      export ADMIN_PASSWORD; log "Password will be set for ${PRIMARY_USER}."
    else
      note "No password entered — ${PRIMARY_USER} will be SSH-key only."
    fi
  fi

  SSH_PORT="$(ask "SSH port" "${SSH_PORT:-22}")"; export SSH_PORT
  confirm "Run a full system upgrade (apt full-upgrade)?" Y && export SKIP_UPGRADE=0 || export SKIP_UPGRADE=1
  confirm "Lock the root account password (sudo still works)?" N && export DISABLE_ROOT_LOGIN=1 || export DISABLE_ROOT_LOGIN=0
  confirm "Blacklist usb-storage module (disables USB drives)?" N && export BLACKLIST_USB_STORAGE=1 || export BLACKLIST_USB_STORAGE=0
  ALLOW_TCP_PORTS="$(ask "Extra TCP ports to open in the firewall, space-separated (e.g. published container ports: 8080 8096 32400)" "")"; export ALLOW_TCP_PORTS
  export DOCKER_COMPAT=0   # rootless Docker doesn't need rootful forward/NAT tweaks
fi

# --- docker.sh questions
if in_selected docker.sh; then
  export DOCKER_USER="${PRIMARY_USER}"
  export SETUP_ROOTLESS=1
  export USERNS_METHOD=apparmor
  confirm "Disable the system-wide (root) Docker daemon — rootless only?" Y && export DISABLE_ROOTFUL=1 || export DISABLE_ROOTFUL=0
  confirm "Also create an example app under /opt/docker?" Y && export CREATE_EXAMPLE_APP=1 || export CREATE_EXAMPLE_APP=0
fi

# --- ancillary.sh questions (packages were picked in Step 1's extra-services group)
if in_selected ancillary.sh; then
  export ANCILLARY_PKGS="${ANCILLARY_PICK[*]}"
  log "Will install: ${BOLD}${ANCILLARY_PICK[*]}${RESET}"

  # Zabbix agent 2 needs the server/proxy address for active checks (no default).
  if in_selected_arr zabbix-agent2 "${ANCILLARY_PICK[@]}"; then
    ZABBIX_SERVER_ACTIVE=""
    while [[ -z "$ZABBIX_SERVER_ACTIVE" ]]; do
      ZABBIX_SERVER_ACTIVE="$(ask "Zabbix server/proxy for active checks (host or host:port, e.g. zbx.example.com:10051)" "")"
      ZABBIX_SERVER_ACTIVE="${ZABBIX_SERVER_ACTIVE//[[:space:]]/}"
      [[ -z "$ZABBIX_SERVER_ACTIVE" ]] || break
      warn "A Zabbix server address is required for zabbix-agent2."
      [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "No Zabbix server address provided (set ZABBIX_SERVER_ACTIVE)."; exit 1; }
    done
    export ZABBIX_SERVER_ACTIVE
    log "Zabbix server (active checks): ${BOLD}${ZABBIX_SERVER_ACTIVE}${RESET}"
  fi

  # Grafana Alloy needs the Loki base URL to push logs to (defaults to localhost).
  if in_selected_arr alloy "${ANCILLARY_PICK[@]}"; then
    LOKI_URL="$(ask "Loki base URL for Alloy to push to (scheme://host:port)" "http://localhost:3100")"
    LOKI_URL="${LOKI_URL//[[:space:]]/}"
    export LOKI_URL
    log "Loki endpoint (Alloy): ${BOLD}${LOKI_URL}${RESET}"
  fi

  # The fish default-shell question only matters if fish is being installed.
  if in_selected_arr fish "${ANCILLARY_PICK[@]}"; then
    if confirm "Set fish as ${PRIMARY_USER}'s default shell?" Y; then
      export FISH_USERS="$PRIMARY_USER"
    else
      export FISH_USERS="none"
    fi
  else
    export FISH_USERS="none"
  fi
fi

# --- motd.sh questions
if in_selected motd.sh; then
  DOC_URL="$(ask "Documentation URL to show in the login banner (leave blank to omit)" "${DOC_URL:-}")"
  export DOC_URL
fi

# --- documentation.sh inputs (it auto-detects everything else; reuse what we have)
if in_selected documentation.sh; then
  # Always write the doc to /tmp, regardless of who launched init.sh or from
  # where (this also avoids landing it in the throwaway download temp dir).
  export OUT_FILE="/tmp/connect.html"
  # Keep the doc consistent with the SSH port/user we just configured, rather
  # than re-detecting (in a dry run sshd_config still shows the old port).
  [[ -n "${SSH_PORT:-}" ]] && export CONN_PORT="$SSH_PORT"
  [[ -n "$PRIMARY_USER" ]] && export CONN_USER="$PRIMARY_USER"
fi

log "All questions answered — the scripts will now run unattended."

# ==============================================================================
step "Step 3 — Running scripts (no further prompts)"
# ==============================================================================
WORKDIR="$(mktemp -d /tmp/homelab-bootstrap.XXXXXX)"; trap 'rm -rf "$WORKDIR"' EXIT
CWD="$(pwd)"
idx=0
for s in "${SELECTED[@]}"; do
  idx=$((idx + 1))
  printf '\n'; hr '─'
  printf '%s%s Running %s%s%s (%d/%d)%s\n' "$BOLD" "$S_STEP" "$CYN" "$s" "$RESET" "$idx" "${#SELECTED[@]}" "$RESET"
  hr '─'

  # Locate: local copy preferred, else download (auto — already chosen to run).
  src=""
  if [[ -f "${CWD}/${s}" ]]; then
    log "Using local copy: ${CWD}/${s}"
    src="${CWD}/${s}"; srcdesc="local copy"
  else
    url="${REPO_RAW_BASE}/${s}"
    info "Downloading: ${DIM}${url}${RESET}"
    if ! curl -fsSL "$url" -o "${WORKDIR}/${s}"; then err "Failed to download ${s}."; STATUS[$s]="failed"; DETAIL[$s]="download failed"; add_error "$s" "download failed from ${url}"; break; fi
    head -n1 "${WORKDIR}/${s}" | grep -q '^#!' || { err "${s} is not a script (no shebang)."; STATUS[$s]="failed"; DETAIL[$s]="bad download"; add_error "$s" "downloaded file is not a script (no shebang) — from ${url}"; break; }
    chmod +x "${WORKDIR}/${s}"; src="${WORKDIR}/${s}"; srcdesc="downloaded"
  fi

  rm -f "${SUMMARY_DIR}/${s}" 2>/dev/null || true
  s_start="$(date +%s)"
  logf="${WORKDIR}/${s}.log"; LOGS[$s]="$logf"
  # Run NON-INTERACTIVELY (ASSUME_YES=1 + all answers exported above), teeing the
  # output to a log so we can scrape each script's NEXT STEPS for the final
  # consolidated report. pipefail makes the 'if' reflect the script's exit, not tee's.
  if ASSUME_YES=1 BOOTSTRAP_NESTED=1 bash "$src" 2>&1 | tee "$logf"; then
    STATUS[$s]="ran"; DETAIL[$s]="${srcdesc}; $(( $(date +%s) - s_start ))s"
    [[ -s "${SUMMARY_DIR}/${s}" ]] && SUMM[$s]="$(head -n1 "${SUMMARY_DIR}/${s}")"
    # Succeeded overall, but flag any error lines the script emitted along the way.
    if grep -qF "$S_ERR" "$logf" 2>/dev/null; then
      warn "${s} finished but reported error lines — see ${ERROR_LOG}"
      add_error "$s" "completed (exit 0) but emitted error lines"
      log_diagnostics "$s" "$logf"
    fi
  else
    rc="${PIPESTATUS[0]}"; err "${s} exited with status ${rc} — stopping; later scripts were NOT run."
    STATUS[$s]="failed"; DETAIL[$s]="${srcdesc}; exit ${rc}"
    add_error "$s" "exited with status ${rc} — bootstrap stopped, later scripts not run"
    log_diagnostics "$s" "$logf"
    break
  fi
done

# ==============================================================================
#  Report — ONE consolidated report: a REVIEW of what each script did, then a
#  single NEXT STEPS list merged from every script that ran. (We no longer
#  replay each script's full recap — the per-script output already scrolled by
#  above; this is the single takeaway summary.)
# ==============================================================================
ELAPSED=$(( $(date +%s) - START_TS )); MM=$(( ELAPSED / 60 )); SS=$(( ELAPSED % 60 ))
ran_count=0; fail=""
for s in "${SCRIPTS[@]}"; do
  [[ "${STATUS[$s]:-}" == "ran" ]] && ran_count=$((ran_count+1))
  case "${STATUS[$s]:-skipped}" in ran|skipped) ;; *) fail="$s" ;; esac
done

printf '\n'; hr '═'
if [[ -n "$fail" ]]; then
  printf '%s%s  ⚠  BOOTSTRAP STOPPED — %s failed%s\n' "$BOLD" "$RED" "$fail" "$RESET"
else
  printf '%s%s  ✅  BOOTSTRAP COMPLETE%s\n' "$BOLD" "$GRN" "$RESET"
fi
hr '═'
printf '%s  Host: %s   |   Ran %d/%d scripts   |   Total: %dm %ds%s\n' "$DIM" "$(hostname)" "$ran_count" "${#SCRIPTS[@]}" "$MM" "$SS" "$RESET"

# --- Review: status + one-line summary for every script -----------------------
hr '─'
printf '%s%s  📋 REVIEW%s\n' "$BOLD" "$CYN" "$RESET"
for s in "${SCRIPTS[@]}"; do
  st="${STATUS[$s]:-skipped}"
  case "$st" in
    ran)     icon="${GRN}${S_OK}${RESET}";   word="${GRN}ran${RESET}";;
    skipped) icon="${YEL}${S_SKIP}${RESET}"; word="${YEL}skipped${RESET}";;
    *)       icon="${RED}${S_ERR}${RESET}";  word="${RED}${st}${RESET}";;
  esac
  printf '   %s %s%-13s%s %s\n' "$icon" "$BOLD" "$s" "$RESET" "$word"
  if [[ -n "${SUMM[$s]:-}" ]]; then printf '       %s%s%s\n' "$WHT" "${SUMM[$s]}" "$RESET"; else printf '       %s%s%s\n' "$DIM" "$(describe "$s")" "$RESET"; fi
  [[ -n "${DETAIL[$s]:-}" ]] && printf '       %s↳ %s%s\n' "$DIM" "${DETAIL[$s]}" "$RESET"
done

# --- Next steps: one list, merged from every script that ran ------------------
# Each script prints its own "⏭ NEXT STEPS" block in its recap; we scrape those
# from the captured logs and fold them into a single list here.
NEXTSTEPS=""
for s in "${SCRIPTS[@]}"; do
  [[ -n "${LOGS[$s]:-}" && -s "${LOGS[$s]:-/nonexistent}" ]] || continue
  items="$(awk '
    /NEXT STEPS/ {cap=1; next}
    cap && (/═══/ || /Done\./) {cap=0}
    cap {print}
  ' "${LOGS[$s]}")"
  if [[ -n "${items//[[:space:]]/}" ]]; then
    NEXTSTEPS+="   ${BOLD}${CYN}${s}${RESET}"$'\n'"${items}"$'\n'
  fi
done

if [[ -n "${NEXTSTEPS//[[:space:]]/}" ]]; then
  hr '─'
  printf '%s%s  ⏭ NEXT STEPS%s\n' "$BOLD" "$MAG" "$RESET"
  printf '%s' "$NEXTSTEPS"
fi

# --- Errors: surface the log location if anything went wrong ------------------
if [[ "$ERROR_COUNT" -gt 0 && -s "$ERROR_LOG" ]]; then
  hr '─'
  printf '%s%s  ✗ ERRORS%s\n' "$BOLD" "$RED" "$RESET"
  printf '   %s%d issue(s) recorded during this run. Full details saved to:%s\n' "$DIM" "$ERROR_COUNT" "$RESET"
  printf '   %s%s%s\n' "$BOLD$WHT" "$ERROR_LOG" "$RESET"
  printf '   %sReview it with: %sless %s%s\n' "$DIM" "$CYN" "$ERROR_LOG" "$RESET"
fi

hr '═'
if [[ -n "$fail" ]]; then
  printf '%s%s  Fix the issue above, then re-run — completed scripts are idempotent. 🔧%s\n' "$BOLD" "$YEL" "$RESET"
  [[ -s "$ERROR_LOG" ]] && printf '%s%s  Error log: %s%s\n' "$BOLD" "$YEL" "$ERROR_LOG" "$RESET"
  printf '\n'
else
  printf '%s%s  Done. 🚀%s\n\n' "$BOLD" "$GRN" "$RESET"
fi
