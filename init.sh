#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — init
#  Entry point. Must run as root. It:
#    1. installs curl
#    2. for each script (harden.sh, docker.sh), asks whether to run it
#    3. uses a LOCAL copy if present in the current directory; otherwise tells
#       you it is missing, shows the full GitHub URL, and asks to download it
#    4. runs each chosen script, one at a time, in order
#
#  Run as root, e.g.:  sudo ./init.sh
#  Or one-liner:       curl -fsSL <raw-url>/init.sh | sudo bash
#
#  Environment overrides:
#    REPO_RAW_BASE=<url>  -> base raw URL to fetch scripts from
#    ASSUME_YES=1         -> answer "yes" to every prompt (for automation)
# ==============================================================================

set -euo pipefail

# Ensure sbin paths are present even under non-login shells / restricted sudo.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# Where to fetch the scripts from (override with REPO_RAW_BASE=...).
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main}"
ASSUME_YES="${ASSUME_YES:-0}"

# Scripts offered, in order.
SCRIPTS=(harden.sh docker.sh)

# ==============================================================================
#  Output helpers — colors & banners
# ==============================================================================
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'
  BLU=$'\033[1;34m'; MAG=$'\033[1;35m'; CYN=$'\033[1;36m'; WHT=$'\033[1;37m'
else
  BOLD=''; DIM=''; RESET=''; RED=''; GRN=''; YEL=''; BLU=''; MAG=''; CYN=''; WHT=''
fi
S_OK="✔"; S_INFO="•"; S_WARN="!"; S_ERR="✗"; S_STEP="▸"

hr()   { local ch="${1:-─}" w=72 l=""; printf -v l '%*s' "$w" ''; printf '%s%s%s\n' "$DIM" "${l// /$ch}" "$RESET"; }
log()  { printf '%s%s%s %s\n' "$GRN" "$S_OK"   "$RESET" "$*"; }
info() { printf '%s%s%s %s\n' "$BLU" "$S_INFO" "$RESET" "$*"; }
warn() { printf '%s%s %s%s\n' "$YEL" "$S_WARN" "$*" "$RESET"; }
err()  { printf '%s%s %s%s\n' "$RED" "$S_ERR" "$*" "$RESET" >&2; }
step() { printf '\n'; hr '═'; printf '%s%s %s%s\n' "$BOLD$CYN" "$S_STEP" "$*" "$RESET"; hr '═'; }

# confirm "Question?" [default Y|N] -> 0 for yes, 1 for no (reads /dev/tty)
confirm() {
  local prompt="$1" default="${2:-Y}" reply hint
  if [[ "$default" =~ ^[Yy]$ ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  if [[ "$ASSUME_YES" == "1" ]]; then info "auto-confirm: ${prompt} → yes"; return 0; fi
  if [[ ! -r /dev/tty ]]; then
    info "non-interactive: ${prompt} → default (${default})"
    [[ "$default" =~ ^[Yy] ]]; return
  fi
  printf '%s%s %s %s%s ' "$YEL" "$S_WARN" "$prompt" "$hint" "$RESET" > /dev/tty
  read -r reply < /dev/tty || reply=""
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

describe() {
  case "$1" in
    harden.sh) printf 'system hardening (users, SSH, firewall, fail2ban, sysctl, AppArmor, AIDE)';;
    docker.sh) printf 'Docker Engine + Compose + rootless setup + /opt/docker layout';;
    *)         printf 'bootstrap script';;
  esac
}

# ==============================================================================
#  Splash
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
printf '%s        Debian 13 Homelab Bootstrap%s\n' "$DIM" "$RESET"
hr '─'
info "Source        : ${BOLD}${REPO_RAW_BASE}${RESET}"
info "Scripts offered: ${BOLD}${SCRIPTS[*]}${RESET} (each is optional, asked one at a time)"
hr '─'

# ==============================================================================
#  Step 1 — must be root
# ==============================================================================
step "Checking privileges"
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  err "This script must be run as root (try: sudo $0)."
  exit 1
fi
log "Running as root."

if ! command -v apt-get >/dev/null 2>&1; then
  err "apt-get not found — this targets Debian/apt systems."
  exit 1
fi

# ==============================================================================
#  Step 2 — install curl
# ==============================================================================
step "Installing curl"
if command -v curl >/dev/null 2>&1; then
  log "curl already installed ($(curl --version | head -n1))."
else
  info "curl not found — installing it (needed to download any missing scripts)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl
  log "curl installed ($(curl --version | head -n1))."
fi

# ==============================================================================
#  Step 3 — for each script: ask to run, locate locally or download, then run
# ==============================================================================
step "Bootstrap scripts"
WORKDIR="$(mktemp -d /tmp/homelab-bootstrap.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT
CWD="$(pwd)"

RAN=(); SKIPPED=()
idx=0
for s in "${SCRIPTS[@]}"; do
  idx=$((idx + 1))
  printf '\n'; hr '─'
  printf '%s%s Script %d/%d: %s%s%s\n' "$BOLD" "$S_STEP" "$idx" "${#SCRIPTS[@]}" "$CYN" "$s" "$RESET"
  printf '   %s%s%s\n' "$DIM" "$(describe "$s")" "$RESET"
  hr '─'

  # 1) Do they even want this one?
  if ! confirm "Run ${s}?" Y; then
    warn "Skipping ${s} (you chose not to run it)."
    SKIPPED+=("$s"); continue
  fi

  # 2) Prefer a LOCAL copy in the current directory; otherwise offer to download.
  src=""
  if [[ -f "${CWD}/${s}" ]]; then
    log "Found ${s} locally at ${BOLD}${CWD}/${s}${RESET} — using the local copy."
    src="${CWD}/${s}"
  else
    url="${REPO_RAW_BASE}/${s}"
    warn "${s} was not found in the current directory (${CWD})."
    info "It can be downloaded from:"
    printf '        %s%s%s\n' "$CYN" "$url" "$RESET"
    if ! confirm "Download ${s} from the URL above?" Y; then
      warn "Skipping ${s} (not present locally and not downloaded)."
      SKIPPED+=("$s"); continue
    fi
    info "Downloading ${s}..."
    if ! curl -fsSL "$url" -o "${WORKDIR}/${s}"; then
      err "Failed to download ${s} from ${url}"
      exit 1
    fi
    # Guard against a 404/HTML page being saved as a "script".
    if ! head -n1 "${WORKDIR}/${s}" | grep -q '^#!'; then
      err "${s} does not look like a script (no shebang) — check the URL/branch."
      exit 1
    fi
    chmod +x "${WORKDIR}/${s}"
    log "Downloaded ${s} ($(wc -l < "${WORKDIR}/${s}") lines)."
    src="${WORKDIR}/${s}"
  fi

  # 3) Run it (via bash so it works even if /tmp is noexec). Wait for it.
  info "Starting ${BOLD}${s}${RESET} — follow its prompts below."
  hr '─'
  if bash "$src"; then
    hr '─'
    log "${s} completed successfully."
    RAN+=("$s")
  else
    rc=$?
    hr '─'
    err "${s} exited with status ${rc} — stopping; later scripts were NOT run."
    exit "$rc"
  fi
done

# ==============================================================================
#  Done
# ==============================================================================
printf '\n'; hr '═'
printf '%s%s  ✅  BOOTSTRAP COMPLETE%s\n' "$BOLD" "$GRN" "$RESET"
hr '═'
printf '   %sRan%s     : %s\n' "$WHT" "$RESET" "${RAN[*]:-<none>}"
printf '   %sSkipped%s : %s\n' "$WHT" "$RESET" "${SKIPPED[*]:-<none>}"
info "Review each script's own recap above for details and next steps."
printf '%s%s  Done. 🚀%s\n\n' "$BOLD" "$GRN" "$RESET"
