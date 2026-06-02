#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — init
#  Entry point. Must run as root. It:
#    1. installs curl
#    2. asks WHICH scripts to run
#    3. asks EVERY question up front (a single wizard)
#    4. runs each chosen script NON-INTERACTIVELY (answers passed via env), so
#       nothing stops mid-run to ask you anything
#
#  Run as root, e.g.:  sudo ./init.sh
#  Or one-liner:       curl -fsSL <raw-url>/init.sh | sudo bash
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

# Packages each script installs (shown when asking whether to run it).
PKGS_ancillary="btop, fish, rsync, qemu-guest-agent"

# Where each script drops a one-line summary of what it did (read for the recap).
SUMMARY_DIR="/var/lib/homelab-bootstrap/summaries"

# Scripts offered, in order.
SCRIPTS=(harden.sh ancillary.sh docker.sh)

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
    ancillary.sh) printf 'extra packages + fish shell for your user(s)';;
    docker.sh)    printf 'Docker Engine + Compose + rootless setup + /opt/docker layout';;
    *)            printf 'bootstrap script';;
  esac
}
details() { case "$1" in ancillary.sh) printf '   %sInstalls packages:%s %s\n' "$DIM" "$RESET" "$PKGS_ancillary";; esac; }

in_selected() { local x; for x in "${SELECTED[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }

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

# ==============================================================================
step "Step 1 — Install curl"
# ==============================================================================
if command -v curl >/dev/null 2>&1; then
  log "curl already installed."
else
  info "Installing curl (needed to download scripts)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update && apt-get install -y curl
  log "curl installed."
fi

# ==============================================================================
step "Step 2 — Choose run mode & scripts"
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
for s in "${SCRIPTS[@]}"; do
  printf '\n%s%s %s%s%s — %s%s%s\n' "$BOLD" "$S_STEP" "$CYN" "$s" "$RESET" "$DIM" "$(describe "$s")" "$RESET"
  details "$s"
  if confirm "Run ${s}?" Y; then
    SELECTED+=("$s")
  else
    STATUS[$s]="skipped"; DETAIL[$s]="you chose not to run it"
  fi
done

if (( ${#SELECTED[@]} == 0 )); then
  warn "No scripts selected — nothing to do."
  exit 0
fi

# ==============================================================================
step "Step 3 — Configuration (all questions answered now)"
# ==============================================================================
PRIMARY_USER=""

# --- A primary user is needed by harden (create), docker (owner), ancillary (fish)
if in_selected harden.sh || in_selected docker.sh || in_selected ancillary.sh; then
  mapfile -t HUMANS < <(awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | sort)
  default_user="${SUDO_USER:-}"; [[ -n "$default_user" ]] || { (( ${#HUMANS[@]} == 1 )) && default_user="${HUMANS[0]}"; }
  must_exist=1; in_selected harden.sh && must_exist=0   # harden can create a new one
  while true; do
    (( ${#HUMANS[@]} > 0 )) && note "Existing users: ${HUMANS[*]}"
    if in_selected harden.sh; then
      PRIMARY_USER="$(ask "Primary admin username to create/harden (sudo + SSH key)?" "$default_user")"
    else
      PRIMARY_USER="$(ask "Existing user to configure?" "$default_user")"
    fi
    PRIMARY_USER="${PRIMARY_USER//[[:space:]]/}"
    if [[ -z "$PRIMARY_USER" ]]; then warn "A username is required."; [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "No user available."; exit 1; }; continue; fi
    if ! valid_user "$PRIMARY_USER"; then warn "Invalid username (lowercase letters, digits, - and _)."; continue; fi
    if [[ "$must_exist" -eq 1 ]] && ! id "$PRIMARY_USER" >/dev/null 2>&1; then
      warn "User '$PRIMARY_USER' does not exist — pick an existing one (or include harden.sh to create it)."
      [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "User '$PRIMARY_USER' does not exist."; exit 1; }
      continue
    fi
    break
  done
  log "Primary user: ${BOLD}${PRIMARY_USER}${RESET}"
fi

# --- harden.sh questions
if in_selected harden.sh; then
  export ADMIN_USERS="$PRIMARY_USER"

  # SSH key (REQUIRED — harden disables password auth; no key = lockout).
  PUBKEY=""
  while true; do
    note "Paste ${PRIMARY_USER}'s PUBLIC SSH key. No key yet? On your machine run:"
    printf '        %sssh-keygen -t ed25519 -C "admin@cannon.dev"%s\n' "$CYN" "$RESET" > /dev/tty 2>/dev/null || true
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

  SSH_PORT="$(ask "SSH port" "${SSH_PORT:-22}")"; export SSH_PORT
  confirm "Run a full system upgrade (apt full-upgrade)?" Y && export SKIP_UPGRADE=0 || export SKIP_UPGRADE=1
  confirm "Lock the root account password (sudo still works)?" N && export DISABLE_ROOT_LOGIN=1 || export DISABLE_ROOT_LOGIN=0
  confirm "Blacklist usb-storage module (disables USB drives)?" N && export BLACKLIST_USB_STORAGE=1 || export BLACKLIST_USB_STORAGE=0
  ALLOW_TCP_PORTS="$(ask "Extra TCP ports to open in the firewall (e.g. published container ports)" "")"; export ALLOW_TCP_PORTS
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

# --- ancillary.sh questions
if in_selected ancillary.sh; then
  if confirm "Set fish as ${PRIMARY_USER}'s default shell?" Y; then
    export FISH_USERS="$PRIMARY_USER"
  else
    export FISH_USERS="none"
  fi
fi

log "All questions answered — the scripts will now run unattended."

# ==============================================================================
step "Step 4 — Running scripts (no further prompts)"
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
    if ! curl -fsSL "$url" -o "${WORKDIR}/${s}"; then err "Failed to download ${s}."; STATUS[$s]="failed"; DETAIL[$s]="download failed"; break; fi
    head -n1 "${WORKDIR}/${s}" | grep -q '^#!' || { err "${s} is not a script (no shebang)."; STATUS[$s]="failed"; DETAIL[$s]="bad download"; break; }
    chmod +x "${WORKDIR}/${s}"; src="${WORKDIR}/${s}"; srcdesc="downloaded"
  fi

  rm -f "${SUMMARY_DIR}/${s}" 2>/dev/null || true
  s_start="$(date +%s)"
  logf="${WORKDIR}/${s}.log"; LOGS[$s]="$logf"
  # Run NON-INTERACTIVELY (ASSUME_YES=1 + all answers exported above), teeing the
  # output to a log so we can replay each script's RECAP at the end. pipefail
  # makes the 'if' reflect the script's exit, not tee's.
  if ASSUME_YES=1 BOOTSTRAP_NESTED=1 bash "$src" 2>&1 | tee "$logf"; then
    STATUS[$s]="ran"; DETAIL[$s]="${srcdesc}; $(( $(date +%s) - s_start ))s"
    [[ -s "${SUMMARY_DIR}/${s}" ]] && SUMM[$s]="$(head -n1 "${SUMMARY_DIR}/${s}")"
  else
    rc="${PIPESTATUS[0]}"; err "${s} exited with status ${rc} — stopping; later scripts were NOT run."
    STATUS[$s]="failed"; DETAIL[$s]="${srcdesc}; exit ${rc}"; break
  fi
done

# ==============================================================================
#  Report
# ==============================================================================
ELAPSED=$(( $(date +%s) - START_TS )); MM=$(( ELAPSED / 60 )); SS=$(( ELAPSED % 60 ))
ran_count=0; for s in "${SCRIPTS[@]}"; do [[ "${STATUS[$s]:-}" == "ran" ]] && ran_count=$((ran_count+1)); done
printf '\n'; hr '═'
printf '%s%s  ✅  BOOTSTRAP COMPLETE%s\n' "$BOLD" "$GRN" "$RESET"
hr '═'
printf '%s  Host: %s   |   Ran %d/%d scripts   |   Total: %dm %ds%s\n' "$DIM" "$(hostname)" "$ran_count" "${#SCRIPTS[@]}" "$MM" "$SS" "$RESET"
hr '─'
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

# --- Full RECAP section from each script that ran -----------------------------
# Each script prints its own "⏭ NEXT STEPS" block. We strip those out of the
# per-script recaps below and collect them into ONE consolidated list at the end,
# so the user reads a single set of next steps instead of one per script.
NEXTSTEPS=""
for s in "${SCRIPTS[@]}"; do
  [[ -n "${LOGS[$s]:-}" && -s "${LOGS[$s]:-/nonexistent}" ]] || continue
  printf '\n'; hr '═'
  printf '%s%s  %s — RECAP%s\n' "$BOLD" "$CYN" "$s" "$RESET"
  hr '═'
  if grep -q 'RECAP' "${LOGS[$s]}"; then
    # Replay the recap from its header up to (but not including) NEXT STEPS.
    awk '/RECAP/{f=1} f && /NEXT STEPS/{f=0} f{print}' "${LOGS[$s]}"
    # Capture this script's NEXT STEPS items (between its header and the next
    # ═-rule / "Done." footer) for the consolidated list below.
    items="$(awk '
      /NEXT STEPS/ {cap=1; next}
      cap && (/═══/ || /Done\./) {cap=0}
      cap {print}
    ' "${LOGS[$s]}")"
    if [[ -n "${items//[[:space:]]/}" ]]; then
      NEXTSTEPS+="${BOLD}${CYN}   ${s}${RESET}"$'\n'"${items}"$'\n'
    fi
  else
    note "(no recap captured — the script stopped early; see its output above)"
  fi
done

# --- One consolidated NEXT STEPS list (merged from every script that ran) -----
if [[ -n "${NEXTSTEPS//[[:space:]]/}" ]]; then
  printf '\n'; hr '═'
  printf '%s%s  ⏭ NEXT STEPS%s\n' "$BOLD" "$MAG" "$RESET"
  hr '═'
  printf '%s' "$NEXTSTEPS"
fi
hr '═'
printf '%s%s  Done. 🚀%s\n\n' "$BOLD" "$GRN" "$RESET"
