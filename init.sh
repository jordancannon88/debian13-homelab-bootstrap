#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — init
#  Entry point. Must run as root. It:
#    1. asks whether this host is a VM or an LXC container (autodetected) — this
#       sets sensible DEFAULTS for everything below (e.g. the QEMU guest agent
#       defaults on for a VM, off for an LXC)
#    2. opens a whiptail MENU (TUI) to review & customise every step in one
#       place — pick a step to change its options, then "Accept & install".
#       Defaults are pre-set, so you can just Accept. (No terminal → a text
#       wizard; ASSUME_YES → accept the defaults unattended. whiptail is
#       auto-installed if missing.)
#    3. on Accept, runs each chosen script NON-INTERACTIVELY (answers passed via
#       env), so nothing stops mid-run to ask you anything
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

# Short descriptions for the pickable extra packages / monitoring agents, shown
# in the wizard prompts and the review summary.
declare -A EXTRA_DESC=(
  [vim]="Vim text editor"
  [btop]="resource monitor (htop-like)"
  [duf]="disk usage/free utility (df-like, friendlier)"
  [fish]="friendly interactive shell"
  [rsync]="fast file copy / sync"
  [qemu-guest-agent]="QEMU/KVM guest integration (VMs only)"
  [zabbix-agent2]="Zabbix agent 2 monitoring (needs a Zabbix server)"
  [alloy]="Grafana Alloy log shipper (needs a Loki server)"
  [container]="Docker and/or Podman (rootless) + Compose + /opt/docker layout"
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

# Scripts offered, in order. bootstrap.sh runs FIRST (it creates the admin user
# + SSH key that harden.sh relies on); documentation.sh is last: it documents
# the host you just set up (it generates a doc, it doesn't change the system).
SCRIPTS=(bootstrap.sh harden.sh ancillary.sh monitoring.sh container.sh motd.sh documentation.sh)

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
    bootstrap.sh) printf 'create/update the admin user (sudo) + install the SSH key — runs before hardening';;
    harden.sh)    printf 'system hardening (SSH, firewall, fail2ban, sysctl, AppArmor, AIDE, Lynis)';;
    ancillary.sh) printf 'pick-and-install extra packages (+ fish as your default shell)';;
    monitoring.sh) printf 'install Zabbix agent + Grafana Alloy (monitoring & log shipping)';;
    container.sh) printf 'Docker and/or Podman (rootless) + Compose + /opt/docker layout';;
    motd.sh)      printf 'cool dynamic login banner (host, IP, uptime) + docs link';;
    documentation.sh) printf 'generate /tmp/connect.html — how to SSH into this host on its hardened port';;
    *)            printf 'bootstrap script';;
  esac
}

# ==============================================================================
#  Wizard machinery — VM/LXC-aware defaults, ask-everything, review, accept/edit
# ==============================================================================
# Best-effort VM-vs-LXC autodetect; the user confirms/overrides. The choice only
# sets default ANSWERS (e.g. the QEMU guest agent — useful on a VM, pointless in
# an LXC); everything is shown for review and is editable before anything runs.
detect_env_default() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    case "$(systemd-detect-virt 2>/dev/null || true)" in
      lxc|lxc-libvirt|systemd-nspawn|openvz) printf 'lxc'; return;;
      qemu|kvm|vmware|microsoft|oracle|xen|bochs|parallels|bhyve|amazon|none) : ;;
    esac
    case "$(systemd-detect-virt 2>/dev/null || true)" in
      qemu|kvm|vmware|microsoft|oracle|xen|bochs|parallels|bhyve|amazon) printf 'vm'; return;;
    esac
  fi
  [[ -f /run/systemd/container || -n "${container:-}" ]] && { printf 'lxc'; return; }
  printf 'vm'
}

# env-aware Y/N default: yn_def <vm-default> <lxc-default>
yn_def() { [[ "$ENV_TYPE" == "vm" ]] && printf '%s' "$1" || printf '%s' "$2"; }
# ask_yn <var> "prompt" <Y|N default> — store Y/N; on edit the current value wins.
ask_yn() { local v="$1" p="$2" d="$3" c="${!1:-}"; [[ -n "$c" ]] && d="$c"; if confirm "$p" "$d"; then printf -v "$v" 'Y'; else printf -v "$v" 'N'; fi; }
# ask_val <var> "prompt" "fallback default" — store text; on edit current wins.
ask_val() { local v="$1" p="$2" d="${3:-}" c="${!1:-}"; [[ -n "$c" ]] && d="$c"; printf -v "$v" '%s' "$(ask "$p" "$d")"; }
yesno() { [[ "$1" == "Y" ]] && printf 'yes' || printf 'no'; }

declare -A STATUS DETAIL SUMM LOGS
SELECTED=(); ANCILLARY_PICK=(); MONITORING_PICK=()
skip_script() { STATUS[$1]="skipped"; DETAIL[$1]="you chose not to run it"; }

# Answer storage (empty = unanswered; collect_answers fills these and re-uses any
# existing value as the default when the user chooses Edit).
ENV_TYPE="${ENV_TYPE:-}"
A_BOOTSTRAP=""; A_HARDEN=""; A_ANCILLARY=""; A_MONITORING=""; A_CONTAINER=""; A_MOTD=""; A_DOC=""
A_PKG_vim=""; A_PKG_btop=""; A_PKG_duf=""; A_PKG_fish=""; A_PKG_rsync=""; A_PKG_qemu=""
A_AGENT_zabbix=""; A_AGENT_alloy=""
PRIMARY_USER="${PRIMARY_USER:-}"; PUBKEY="${PUBKEY:-}"; ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SSH_PORT="${SSH_PORT:-}"; A_UPGRADE=""; A_LOCKROOT=""; A_USBBLACK=""; ALLOW_TCP_PORTS="${ALLOW_TCP_PORTS:-}"
A_FISH_DEFAULT=""
ZABBIX_SERVER_ACTIVE="${ZABBIX_SERVER_ACTIVE:-}"; A_ZBX_DOCKER=""; LOKI_URL="${LOKI_URL:-}"; A_ALLOY_DOCKERLOGS=""
A_DOCKER=""; A_PODMAN=""; A_DISABLE_ROOTFUL=""; A_EXAMPLE_APP=""; A_JOURNALD=""
DOC_URL="${DOC_URL:-}"

# --- pick the primary/admin user (needed by bootstrap/harden/container/ancillary)
_collect_user() {
  mapfile -t HUMANS < <(awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | sort)
  local default_user="${PRIMARY_USER:-${SUDO_USER:-}}"
  [[ -n "$default_user" ]] || { (( ${#HUMANS[@]} == 1 )) && default_user="${HUMANS[0]}"; }
  if [[ "$A_BOOTSTRAP" == "Y" ]]; then
    while true; do
      (( ${#HUMANS[@]} > 0 )) && note "Existing users: ${HUMANS[*]}"
      PRIMARY_USER="$(ask "Admin username (sudo + SSH key) — existing user to update, or a new name to create" "$default_user")"
      PRIMARY_USER="${PRIMARY_USER//[[:space:]]/}"
      if [[ -z "$PRIMARY_USER" ]]; then warn "A username is required."; [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "No user available."; exit 1; }; continue; fi
      valid_user "$PRIMARY_USER" || { warn "Invalid username (lowercase letters, digits, - and _)."; continue; }
      break
    done
  else
    if [[ -n "$default_user" ]] && id "$default_user" >/dev/null 2>&1; then
      PRIMARY_USER="$default_user"
    else
      while true; do
        (( ${#HUMANS[@]} > 0 )) && note "Existing users: ${HUMANS[*]}"
        PRIMARY_USER="$(ask "Existing user to configure?" "$default_user")"
        PRIMARY_USER="${PRIMARY_USER//[[:space:]]/}"
        if [[ -z "$PRIMARY_USER" ]]; then warn "A username is required."; [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "No user available."; exit 1; }; continue; fi
        valid_user "$PRIMARY_USER" || { warn "Invalid username (lowercase letters, digits, - and _)."; continue; }
        if ! id "$PRIMARY_USER" >/dev/null 2>&1; then
          warn "User '$PRIMARY_USER' does not exist — pick an existing one (or include bootstrap to create it)."
          [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "User '$PRIMARY_USER' does not exist."; exit 1; }
          continue
        fi
        break
      done
    fi
  fi
}

# --- bootstrap details: SSH public key (+ optional password for a new account)
_collect_bootstrap() {
  while true; do
    note "Paste ${PRIMARY_USER}'s PUBLIC SSH key. No key yet? On your machine run:"
    printf '        %sssh-keygen -t ed25519 -C "user@example.com"%s\n' "$CYN" "$RESET" > /dev/tty 2>/dev/null || true
    PUBKEY="$(ask "SSH public key for ${PRIMARY_USER}" "${PUBKEY:-}")"
    PUBKEY="${PUBKEY#"${PUBKEY%%[![:space:]]*}"}"; PUBKEY="${PUBKEY%"${PUBKEY##*[![:space:]]}"}"
    if [[ -z "$PUBKEY" ]]; then
      if id "$PRIMARY_USER" >/dev/null 2>&1 && [[ -s "$(getent passwd "$PRIMARY_USER" | cut -d: -f6)/.ssh/authorized_keys" ]]; then
        note "No key entered, but ${PRIMARY_USER} already has authorized_keys — continuing."; break
      fi
      if [[ "$A_HARDEN" != "Y" ]]; then
        warn "No key entered — ${PRIMARY_USER} will have no authorized_keys (add one before hardening)."; break
      fi
      warn "A key is required (hardening disables password login). Without one you'd be locked out."
      [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "No SSH key provided for ${PRIMARY_USER}."; exit 1; }
      continue
    fi
    if valid_pubkey "$PUBKEY"; then log "SSH key accepted."; break; fi
    warn "That does not look like a valid SSH public key — try again."
  done
  if ! id "$PRIMARY_USER" >/dev/null 2>&1; then
    note "User '${PRIMARY_USER}' will be created."
    if [[ -z "$ADMIN_PASSWORD" ]]; then
      ADMIN_PASSWORD="$(ask_secret "Password for new user ${PRIMARY_USER} (blank to skip = SSH-key only)")"
    fi
  fi
}

# --- harden details
_collect_harden() {
  if [[ "$A_BOOTSTRAP" != "Y" ]]; then
    if ! id "$PRIMARY_USER" >/dev/null 2>&1; then
      err "User '${PRIMARY_USER}' does not exist and bootstrap was not selected — include bootstrap to create it."; exit 1
    fi
    if [[ ! -s "$(getent passwd "$PRIMARY_USER" | cut -d: -f6)/.ssh/authorized_keys" ]]; then
      warn "${PRIMARY_USER} has NO authorized_keys and bootstrap was not selected — hardening disables password login."
      confirm "Continue anyway (HIGH lockout risk)?" N || { err "Aborting. Include bootstrap to install an SSH key first."; exit 1; }
    fi
  fi
  ask_val SSH_PORT  "SSH port" "$(( RANDOM % 22000 + 10000 ))"
  ask_yn  A_UPGRADE "Run a full system upgrade (apt full-upgrade)?" "$(yn_def Y Y)"
  ask_yn  A_LOCKROOT "Lock the root account password (sudo still works)?" "$(yn_def Y Y)"
  ask_yn  A_USBBLACK "Blacklist usb-storage module (disables USB drives)?" "$(yn_def Y Y)"
  ask_val ALLOW_TCP_PORTS "Extra TCP ports to open, space-separated (e.g. published container ports: 8080 8096 32400)" ""
}

# --- monitoring details
_collect_monitoring() {
  if [[ "$A_AGENT_zabbix" == "Y" ]]; then
    while true; do
      ask_val ZABBIX_SERVER_ACTIVE "Zabbix server/proxy for active checks (host or host:port)" "zabbix:10051"
      ZABBIX_SERVER_ACTIVE="${ZABBIX_SERVER_ACTIVE//[[:space:]]/}"
      [[ -n "$ZABBIX_SERVER_ACTIVE" ]] && break
      warn "A Zabbix server address is required for zabbix-agent2."
      [[ -r /dev/tty && "$ASSUME_YES" != 1 ]] || { err "No Zabbix server address provided (set ZABBIX_SERVER_ACTIVE)."; exit 1; }
    done
    ask_yn A_ZBX_DOCKER "Set the Zabbix agent up to monitor rootless Docker?" "$(yn_def N N)"
  fi
  if [[ "$A_AGENT_alloy" == "Y" ]]; then
    ask_val LOKI_URL "Loki base URL for Alloy to push to (host:port)" "loki:3100"
    LOKI_URL="${LOKI_URL//[[:space:]]/}"
    ask_yn A_ALLOY_DOCKERLOGS "Also capture Docker container logs? (Docker must use the journald log-driver)" "$(yn_def N N)"
  fi
}

# --- container details
_collect_container() {
  ask_yn A_DOCKER "Install Docker (Engine + Compose, rootless)?" "$(yn_def Y Y)"
  ask_yn A_PODMAN "Install Podman (daemonless, rootless) alongside?" "$(yn_def N N)"
  if [[ "$A_DOCKER" != "Y" && "$A_PODMAN" != "Y" ]]; then
    warn "Neither runtime chosen — defaulting to Docker so container.sh has something to install."; A_DOCKER="Y"
  fi
  [[ "$A_DOCKER" == "Y" ]] && ask_yn A_DISABLE_ROOTFUL "Disable the system-wide (root) Docker daemon — rootless only?" "$(yn_def Y Y)"
  ask_yn A_EXAMPLE_APP "Also create an example app under /opt/docker?" "$(yn_def Y Y)"
  if [[ "$A_ALLOY_DOCKERLOGS" == "Y" ]]; then
    A_JOURNALD="Y"   # reuse the Alloy answer; no point asking twice
  else
    ask_yn A_JOURNALD "Send container logs to the journal (journald log-driver)?" "$(yn_def N N)"
  fi
}

# select_env_type — ask whether this host is a VM or an LXC (autodetected).
# Sets ENV_TYPE; this drives all the default answers.
select_env_type() {
  local _envd="${ENV_TYPE:-}"
  [[ "$_envd" == "vm" || "$_envd" == "lxc" ]] || _envd="$(detect_env_default)"
  if [[ "$ASSUME_YES" == "1" || ! -r /dev/tty ]]; then
    ENV_TYPE="$_envd"
  else
    printf '\n%s%sIs this host a VM or an LXC container?%s  (autodetected: %s%s%s)\n' "$BOLD" "$WHT" "$RESET" "$BOLD" "$_envd" "$RESET" > /dev/tty
    printf '   %s[1]%s VM  — full virtual machine (KVM/QEMU, etc.)\n' "$BOLD" "$RESET" > /dev/tty
    printf '   %s[2]%s LXC — Proxmox/LXC system container\n' "$BOLD" "$RESET" > /dev/tty
    local _dd=1; [[ "$_envd" == "lxc" ]] && _dd=2
    printf '%s%s Choose 1 or 2 [default: %s]: %s' "$YEL" "$S_WARN" "$_dd" "$RESET" > /dev/tty
    local _ee; read -r _ee < /dev/tty || _ee=""
    case "${_ee:-$_dd}" in 2) ENV_TYPE=lxc;; *) ENV_TYPE=vm;; esac
  fi
  log "Environment: ${BOLD}$( [[ "$ENV_TYPE" == "vm" ]] && echo "Virtual Machine (VM)" || echo "LXC container" )${RESET}"
}

# compute_defaults — fill EVERY answer from the VM/LXC-aware defaults WITHOUT
# prompting, so the review screen can be shown first. Free-text inputs that have
# no safe default (SSH key, Zabbix server) are left as-is and flagged in the
# summary; accepting while one is missing routes you into the questions.
compute_defaults() {
  A_BOOTSTRAP="$(yn_def Y Y)"; A_HARDEN="$(yn_def Y Y)"; A_ANCILLARY="$(yn_def Y Y)"
  A_MONITORING="$(yn_def Y Y)"; A_CONTAINER="$(yn_def N N)"; A_MOTD="$(yn_def Y Y)"; A_DOC="$(yn_def Y Y)"
  A_PKG_vim="$(yn_def Y Y)"; A_PKG_btop="$(yn_def Y Y)"; A_PKG_duf="$(yn_def Y Y)"
  A_PKG_fish="$(yn_def Y Y)"; A_PKG_rsync="$(yn_def Y Y)"; A_PKG_qemu="$(yn_def Y N)"
  A_AGENT_zabbix="$(yn_def Y Y)"; A_AGENT_alloy="$(yn_def Y Y)"
  A_FISH_DEFAULT="$(yn_def Y Y)"
  A_UPGRADE="$(yn_def Y Y)"; A_LOCKROOT="$(yn_def Y Y)"; A_USBBLACK="$(yn_def Y Y)"
  A_ZBX_DOCKER="$(yn_def N N)"; A_ALLOY_DOCKERLOGS="$(yn_def N N)"
  A_DOCKER="$(yn_def Y Y)"; A_PODMAN="$(yn_def N N)"; A_DISABLE_ROOTFUL="$(yn_def Y Y)"
  A_EXAMPLE_APP="$(yn_def Y Y)"; A_JOURNALD="$(yn_def N N)"
  # Default SSH port: a random high port (away from 22 and the ephemeral range).
  SSH_PORT="${SSH_PORT:-$(( RANDOM % 22000 + 10000 ))}"
  LOKI_URL="${LOKI_URL:-loki:3100}"
  ZABBIX_SERVER_ACTIVE="${ZABBIX_SERVER_ACTIVE:-zabbix:10051}"
  # Default admin user: the sudo invoker, else the sole human account (if any).
  if [[ -z "$PRIMARY_USER" ]]; then
    local du="${SUDO_USER:-}" _h=()
    if [[ -z "$du" ]]; then
      mapfile -t _h < <(awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd)
      (( ${#_h[@]} == 1 )) && du="${_h[0]}"
    fi
    PRIMARY_USER="$du"
  fi
}

# validate_answers — on Accept, check that required inputs are present. Returns 0
# if good to install, 1 if the user must still supply something (→ open the
# questions). Interactive collect_answers loops enforce these, so this only
# bites when accepting bare defaults that left a required field blank.
validate_answers() {
  local rc=0 akf=""
  if [[ "$A_BOOTSTRAP" == "Y" || "$A_HARDEN" == "Y" || "$A_CONTAINER" == "Y" || "$A_ANCILLARY" == "Y" ]]; then
    if [[ -z "$PRIMARY_USER" ]] || ! valid_user "$PRIMARY_USER"; then warn "Admin/primary user is not set."; rc=1; fi
  fi
  if [[ "$A_HARDEN" == "Y" && -n "$PRIMARY_USER" ]]; then
    akf="$(getent passwd "$PRIMARY_USER" 2>/dev/null | cut -d: -f6)/.ssh/authorized_keys"
    if [[ "$A_BOOTSTRAP" == "Y" ]]; then
      if [[ -z "$PUBKEY" ]] && ! { id "$PRIMARY_USER" &>/dev/null && [[ -s "$akf" ]]; }; then
        warn "Hardening needs an SSH key for '${PRIMARY_USER}' (none entered, none on file) — you'd be locked out."; rc=1
      fi
    else
      if ! id "$PRIMARY_USER" &>/dev/null; then
        warn "Hardening is selected without bootstrap, but user '${PRIMARY_USER}' does not exist."; rc=1
      elif [[ ! -s "$akf" ]]; then
        warn "Hardening is selected without bootstrap and '${PRIMARY_USER}' has no authorized_keys."; rc=1
      fi
    fi
  fi
  if [[ "$A_MONITORING" == "Y" && "$A_AGENT_zabbix" == "Y" && -z "${ZABBIX_SERVER_ACTIVE//[[:space:]]/}" ]]; then
    warn "zabbix-agent2 needs a server/proxy address (none set)."; rc=1
  fi
  if [[ "$A_BOOTSTRAP$A_HARDEN$A_ANCILLARY$A_MONITORING$A_CONTAINER$A_MOTD$A_DOC" != *Y* ]]; then
    warn "Nothing is selected to run."; rc=1
  fi
  return $rc
}

# collect_answers — ask EVERY question (env type, which scripts, and each
# script's settings). Defaults depend on VM/LXC; current answers pre-fill so
# Enter keeps them. Conditional/validation logic is preserved.
collect_answers() {
  select_env_type

  # --- which scripts to run ---
  printf '\n'; hr '─'; printf '%s%s Which steps to run%s\n' "$BOLD$CYN" "$S_STEP" "$RESET"; hr '─'
  ask_yn A_BOOTSTRAP  "bootstrap.sh — admin user (sudo) + SSH key?" "$(yn_def Y Y)"
  ask_yn A_HARDEN     "harden.sh — system hardening (SSH/firewall/fail2ban/…)?" "$(yn_def Y Y)"
  ask_yn A_ANCILLARY  "ancillary.sh — install extra packages?" "$(yn_def Y Y)"
  if [[ "$A_ANCILLARY" == "Y" ]]; then
    ask_yn A_PKG_vim   "   • vim — ${EXTRA_DESC[vim]}?" "$(yn_def Y Y)"
    ask_yn A_PKG_btop  "   • btop — ${EXTRA_DESC[btop]}?" "$(yn_def Y Y)"
    ask_yn A_PKG_duf   "   • duf — ${EXTRA_DESC[duf]}?" "$(yn_def Y Y)"
    ask_yn A_PKG_fish  "   • fish — ${EXTRA_DESC[fish]}?" "$(yn_def Y Y)"
    ask_yn A_PKG_rsync "   • rsync — ${EXTRA_DESC[rsync]}?" "$(yn_def Y Y)"
    ask_yn A_PKG_qemu  "   • qemu-guest-agent — ${EXTRA_DESC[qemu-guest-agent]}?" "$(yn_def Y N)"
  fi
  ask_yn A_MONITORING "monitoring.sh — install monitoring agents?" "$(yn_def Y Y)"
  if [[ "$A_MONITORING" == "Y" ]]; then
    ask_yn A_AGENT_zabbix "   • zabbix-agent2 — ${EXTRA_DESC[zabbix-agent2]}?" "$(yn_def Y Y)"
    ask_yn A_AGENT_alloy  "   • alloy — ${EXTRA_DESC[alloy]}?" "$(yn_def Y Y)"
  fi
  ask_yn A_CONTAINER  "container.sh — Docker and/or Podman (rootless)?" "$(yn_def N N)"
  ask_yn A_MOTD       "motd.sh — dynamic login banner?" "$(yn_def Y Y)"
  ask_yn A_DOC        "documentation.sh — generate the connection doc?" "$(yn_def Y Y)"

  # --- primary user (needed by several scripts) ---
  if [[ "$A_BOOTSTRAP" == "Y" || "$A_HARDEN" == "Y" || "$A_CONTAINER" == "Y" || "$A_ANCILLARY" == "Y" ]]; then
    printf '\n'; hr '─'; printf '%s%s Settings%s\n' "$BOLD$CYN" "$S_STEP" "$RESET"; hr '─'
    _collect_user
    log "Primary user: ${BOLD}${PRIMARY_USER}${RESET}"
  fi

  [[ "$A_BOOTSTRAP" == "Y" ]] && _collect_bootstrap
  [[ "$A_HARDEN"    == "Y" ]] && _collect_harden
  if [[ "$A_ANCILLARY" == "Y" && "$A_PKG_fish" == "Y" ]]; then
    ask_yn A_FISH_DEFAULT "Set fish as ${PRIMARY_USER}'s default shell?" "$(yn_def Y Y)"
  fi
  [[ "$A_MONITORING" == "Y" ]] && _collect_monitoring
  [[ "$A_CONTAINER"  == "Y" ]] && _collect_container
  [[ "$A_MOTD"       == "Y" ]] && ask_val DOC_URL "Documentation URL to show in the login banner (blank to omit)" ""
}

# print_summary — show every question and the chosen answer, grouped by script.
print_summary() {
  local envlabel; envlabel="$( [[ "$ENV_TYPE" == "vm" ]] && echo "VM" || echo "LXC" )"
  printf '\n'; hr '═'
  printf '%s%s  📋 REVIEW — confirm or edit before anything runs%s   %s[environment: %s]%s\n' "$BOLD$CYN" "$S_STEP" "$RESET" "$DIM" "$envlabel" "$RESET"
  hr '═'
  local VALCOL=34 VALW=14   # label width to VALCOL; value field VALW; then the explain column
  # cval <value> — colour a value: yes→green, no→yellow, anything else→white.
  cval() { case "$1" in
    yes) printf '%syes%s' "$GRN" "$RESET";;
    no)  printf '%sno%s'  "$YEL" "$RESET";;
    *)   printf '%s%s%s'  "$WHT" "$1" "$RESET";;
  esac; }
  # _hdr/_row <label> <value> <explain> — three aligned columns: label, the
  # colour-coded value (at VALCOL), and a short dim explanation (at VALCOL+VALW).
  _hdr() { local p=$(( VALW - ${#2} )); ((p<1)) && p=1; printf '   %s%s %s%-*s%s%s%*s%s%s%s\n' "$CYN" "$S_STEP" "$BOLD" "$((VALCOL-5))" "$1" "$RESET" "$(cval "$2")" "$p" "" "$DIM" "${3:-}" "$RESET"; }
  _row() { local p=$(( VALW - ${#2} )); ((p<1)) && p=1; printf '       %s%-*s%s%s%*s%s%s%s\n' "$BOLD" "$((VALCOL-7))" "$1" "$RESET" "$(cval "$2")" "$p" "" "$DIM" "${3:-}" "$RESET"; }

  _hdr "bootstrap.sh" "$(yesno "$A_BOOTSTRAP")" "admin user + SSH key"
  if [[ "$A_BOOTSTRAP" == "Y" ]]; then
    _row "Admin user" "$PRIMARY_USER" "sudo + login account"
    _row "SSH public key" "$([[ -n "$PUBKEY" ]] && echo provided || echo none/existing)" "key for that account"
    id "$PRIMARY_USER" >/dev/null 2>&1 || _row "New-user password" "$([[ -n "$ADMIN_PASSWORD" ]] && echo set || echo key-only)" "console login pass"
  fi
  _hdr "harden.sh" "$(yesno "$A_HARDEN")" "SSH/firewall/fail2ban lockdown"
  if [[ "$A_HARDEN" == "Y" ]]; then
    _row "SSH port" "${SSH_PORT:-22}" "sshd listen port (random)"
    _row "Full system upgrade" "$(yesno "$A_UPGRADE")" "apt full-upgrade"
    _row "Lock root password" "$(yesno "$A_LOCKROOT")" "no direct root login"
    _row "Blacklist usb-storage" "$(yesno "$A_USBBLACK")" "block USB storage"
    _row "Extra TCP ports" "${ALLOW_TCP_PORTS:-(none)}" "open in firewall"
  fi
  _hdr "ancillary.sh" "$(yesno "$A_ANCILLARY")" "extra CLI packages"
  if [[ "$A_ANCILLARY" == "Y" ]]; then
    _row "vim" "$(yesno "$A_PKG_vim")" "text editor"
    _row "btop" "$(yesno "$A_PKG_btop")" "resource monitor"
    _row "duf" "$(yesno "$A_PKG_duf")" "disk usage viewer"
    _row "fish" "$(yesno "$A_PKG_fish")" "friendly shell"
    [[ "$A_PKG_fish" == "Y" ]] && _row "  default shell" "$(yesno "$A_FISH_DEFAULT")" "chsh user to fish"
    _row "rsync" "$(yesno "$A_PKG_rsync")" "file sync/copy"
    _row "qemu-guest-agent" "$(yesno "$A_PKG_qemu")" "QEMU agent (VM only)"
  fi
  _hdr "monitoring.sh" "$(yesno "$A_MONITORING")" "Zabbix + Alloy agents"
  if [[ "$A_MONITORING" == "Y" ]]; then
    _row "zabbix-agent2" "$(yesno "$A_AGENT_zabbix")" "metrics agent"
    if [[ "$A_AGENT_zabbix" == "Y" ]]; then
      _row "  Zabbix server" "${ZABBIX_SERVER_ACTIVE:-(unset)}" "server address"
      _row "  Monitor rootless Docker" "$(yesno "$A_ZBX_DOCKER")" "watch user Docker"
    fi
    _row "alloy" "$(yesno "$A_AGENT_alloy")" "log shipper"
    if [[ "$A_AGENT_alloy" == "Y" ]]; then
      _row "  Loki URL" "${LOKI_URL:-loki:3100}" "log server address"
      _row "  Capture Docker logs" "$(yesno "$A_ALLOY_DOCKERLOGS")" "ship container logs"
    fi
  fi
  _hdr "container.sh" "$(yesno "$A_CONTAINER")" "Docker/Podman runtime"
  if [[ "$A_CONTAINER" == "Y" ]]; then
    _row "Docker" "$(yesno "$A_DOCKER")" "Docker engine"
    [[ "$A_DOCKER" == "Y" ]] && _row "  Disable rootful daemon" "$(yesno "$A_DISABLE_ROOTFUL")" "rootless only"
    _row "Podman" "$(yesno "$A_PODMAN")" "Podman engine"
    _row "Example app" "$(yesno "$A_EXAMPLE_APP")" "sample compose stack"
    _row "Logs to journald" "$(yesno "$A_JOURNALD")" "journald log-driver"
  fi
  _hdr "motd.sh" "$(yesno "$A_MOTD")" "dynamic login banner"
  [[ "$A_MOTD" == "Y" ]] && _row "Doc URL" "${DOC_URL:-(none)}" "shown in the banner"
  _hdr "documentation.sh" "$(yesno "$A_DOC")" "SSH connect guide"
  hr '─'
}

# materialize_selection — turn the answers into SELECTED[] + exported env vars
# for the chosen scripts. Safe to call once after the user accepts.
materialize_selection() {
  SELECTED=(); ANCILLARY_PICK=(); MONITORING_PICK=()
  local s; for s in "${SCRIPTS[@]}"; do unset 'STATUS[$s]' 'DETAIL[$s]'; done

  [[ "$A_BOOTSTRAP" == "Y" ]] && SELECTED+=(bootstrap.sh) || skip_script bootstrap.sh
  [[ "$A_HARDEN"    == "Y" ]] && SELECTED+=(harden.sh)    || skip_script harden.sh

  [[ "$A_PKG_vim"   == "Y" ]] && ANCILLARY_PICK+=(vim)
  [[ "$A_PKG_btop"  == "Y" ]] && ANCILLARY_PICK+=(btop)
  [[ "$A_PKG_duf"   == "Y" ]] && ANCILLARY_PICK+=(duf)
  [[ "$A_PKG_fish"  == "Y" ]] && ANCILLARY_PICK+=(fish)
  [[ "$A_PKG_rsync" == "Y" ]] && ANCILLARY_PICK+=(rsync)
  [[ "$A_PKG_qemu"  == "Y" ]] && ANCILLARY_PICK+=(qemu-guest-agent)
  if [[ "$A_ANCILLARY" == "Y" && ${#ANCILLARY_PICK[@]} -gt 0 ]]; then SELECTED+=(ancillary.sh); else skip_script ancillary.sh; fi

  [[ "$A_AGENT_zabbix" == "Y" ]] && MONITORING_PICK+=(zabbix-agent2)
  [[ "$A_AGENT_alloy"  == "Y" ]] && MONITORING_PICK+=(alloy)
  if [[ "$A_MONITORING" == "Y" && ${#MONITORING_PICK[@]} -gt 0 ]]; then SELECTED+=(monitoring.sh); else skip_script monitoring.sh; fi

  [[ "$A_CONTAINER" == "Y" ]] && SELECTED+=(container.sh)     || skip_script container.sh
  [[ "$A_MOTD"      == "Y" ]] && SELECTED+=(motd.sh)          || skip_script motd.sh
  [[ "$A_DOC"       == "Y" ]] && SELECTED+=(documentation.sh) || skip_script documentation.sh

  # Exports consumed by the individual scripts (run non-interactively).
  if [[ "$A_BOOTSTRAP" == "Y" ]]; then
    export ADMIN_USERS="$PRIMARY_USER"
    [[ -n "$PUBKEY" ]] && export PUBKEY
    [[ -n "$ADMIN_PASSWORD" ]] && export ADMIN_PASSWORD
  fi
  if [[ "$A_HARDEN" == "Y" ]]; then
    export ADMIN_USERS="$PRIMARY_USER"
    export SSH_PORT="${SSH_PORT:-22}"
    [[ "$A_UPGRADE"  == "Y" ]] && export SKIP_UPGRADE=0        || export SKIP_UPGRADE=1
    [[ "$A_LOCKROOT" == "Y" ]] && export DISABLE_ROOT_LOGIN=1  || export DISABLE_ROOT_LOGIN=0
    [[ "$A_USBBLACK" == "Y" ]] && export BLACKLIST_USB_STORAGE=1 || export BLACKLIST_USB_STORAGE=0
    export ALLOW_TCP_PORTS
    export DOCKER_COMPAT=0
  fi
  if [[ "$A_ANCILLARY" == "Y" && ${#ANCILLARY_PICK[@]} -gt 0 ]]; then
    export ANCILLARY_PKGS="${ANCILLARY_PICK[*]}"
    if [[ "$A_PKG_fish" == "Y" && "$A_FISH_DEFAULT" == "Y" ]]; then export FISH_USERS="$PRIMARY_USER"; else export FISH_USERS="none"; fi
  fi
  if [[ "$A_MONITORING" == "Y" && ${#MONITORING_PICK[@]} -gt 0 ]]; then
    export MONITORING_PKGS="${MONITORING_PICK[*]}"
    if [[ "$A_AGENT_zabbix" == "Y" ]]; then
      export ZABBIX_SERVER_ACTIVE
      if [[ "$A_ZBX_DOCKER" == "Y" ]]; then export ZABBIX_MONITOR_ROOTLESS_DOCKER=1; export ZABBIX_DOCKER_USER="$PRIMARY_USER"; else export ZABBIX_MONITOR_ROOTLESS_DOCKER=0; fi
    fi
    if [[ "$A_AGENT_alloy" == "Y" ]]; then
      export LOKI_URL
      [[ "$A_ALLOY_DOCKERLOGS" == "Y" ]] && export ALLOY_DOCKER_LOGS=1 || export ALLOY_DOCKER_LOGS=0
    fi
  fi
  if [[ "$A_CONTAINER" == "Y" ]]; then
    export CONTAINER_USER="$PRIMARY_USER"
    export USERNS_METHOD=apparmor
    [[ "$A_DOCKER" == "Y" ]] && export INSTALL_DOCKER=1 || export INSTALL_DOCKER=0
    [[ "$A_PODMAN" == "Y" ]] && export INSTALL_PODMAN=1 || export INSTALL_PODMAN=0
    if [[ "$A_DOCKER" == "Y" ]]; then
      export SETUP_ROOTLESS=1
      [[ "$A_DISABLE_ROOTFUL" == "Y" ]] && export DISABLE_ROOTFUL=1 || export DISABLE_ROOTFUL=0
    fi
    [[ "$A_EXAMPLE_APP" == "Y" ]] && export CREATE_EXAMPLE_APP=1 || export CREATE_EXAMPLE_APP=0
    [[ "$A_JOURNALD"    == "Y" ]] && export DOCKER_JOURNALD_LOGS=1 || export DOCKER_JOURNALD_LOGS=0
  fi
  [[ "$A_MOTD" == "Y" ]] && export DOC_URL
  if [[ "$A_DOC" == "Y" ]]; then
    export OUT_FILE="/tmp/connect.html"
    [[ -n "${SSH_PORT:-}" ]] && export CONN_PORT="$SSH_PORT"
    [[ -n "$PRIMARY_USER" ]] && export CONN_USER="$PRIMARY_USER"
  fi
}

# ==============================================================================
#  whiptail TUI — a menu hub to review/customise everything, then install.
#  Reads/writes the same A_* answer vars; on Accept the same validate_answers /
#  materialize_selection backend runs. Falls back to the text wizard when there
#  is no terminal or whiptail can't be installed.
# ==============================================================================
BACKTITLE="Debian 13 Homelab Bootstrap"

onoff() { [[ "$1" == "Y" ]] && printf 'ON' || printf 'OFF'; }    # checklist state
pad3()  { [[ "$1" == "Y" ]] && printf 'yes' || printf 'no '; }   # aligned menu state
# Short status summaries for the hub menu lines.
anc_list() { local p=(); [[ "$A_PKG_vim" == Y ]] && p+=(vim); [[ "$A_PKG_btop" == Y ]] && p+=(btop); [[ "$A_PKG_duf" == Y ]] && p+=(duf); [[ "$A_PKG_fish" == Y ]] && p+=(fish); [[ "$A_PKG_rsync" == Y ]] && p+=(rsync); [[ "$A_PKG_qemu" == Y ]] && p+=(qemu); local IFS=,; printf '%s' "${p[*]:-none}"; }
mon_list() { local p=(); [[ "$A_AGENT_zabbix" == Y ]] && p+=(zabbix); [[ "$A_AGENT_alloy" == Y ]] && p+=(alloy); local IFS=,; printf '%s' "${p[*]:-none}"; }
ct_list()  { [[ "$A_CONTAINER" != Y ]] && { printf 'off'; return; }; local p=(); [[ "$A_DOCKER" == Y ]] && p+=(docker); [[ "$A_PODMAN" == Y ]] && p+=(podman); local IFS=,; printf '%s' "${p[*]:-none}"; }

# validate_tui — same checks as validate_answers, but collects messages and
# shows them in a whiptail msgbox. Returns 0 if ready to install.
validate_tui() {
  local m=() akf=""
  if [[ "$A_BOOTSTRAP" == Y || "$A_HARDEN" == Y || "$A_CONTAINER" == Y || "$A_ANCILLARY" == Y ]]; then
    { [[ -z "$PRIMARY_USER" ]] || ! valid_user "$PRIMARY_USER"; } && m+=("Set a valid admin username (in bootstrap.sh).")
  fi
  if [[ "$A_HARDEN" == Y && -n "$PRIMARY_USER" ]]; then
    akf="$(getent passwd "$PRIMARY_USER" 2>/dev/null | cut -d: -f6)/.ssh/authorized_keys"
    if [[ "$A_BOOTSTRAP" == Y ]]; then
      if [[ -z "$PUBKEY" ]] && ! { id "$PRIMARY_USER" &>/dev/null && [[ -s "$akf" ]]; }; then
        m+=("harden.sh needs an SSH key for ${PRIMARY_USER} (none entered, none on file).")
      fi
    else
      if ! id "$PRIMARY_USER" &>/dev/null; then m+=("harden without bootstrap: user ${PRIMARY_USER} does not exist.")
      elif [[ ! -s "$akf" ]]; then m+=("harden without bootstrap: ${PRIMARY_USER} has no authorized_keys."); fi
    fi
  fi
  [[ "$A_MONITORING" == Y && "$A_AGENT_zabbix" == Y && -z "${ZABBIX_SERVER_ACTIVE//[[:space:]]/}" ]] && m+=("zabbix-agent2 needs a server address.")
  [[ "$A_BOOTSTRAP$A_HARDEN$A_ANCILLARY$A_MONITORING$A_CONTAINER$A_MOTD$A_DOC" != *Y* ]] && m+=("Select at least one step to run.")
  if ((${#m[@]})); then
    whiptail --backtitle "$BACKTITLE" --title "Can't install yet" \
      --msgbox "$(printf 'Please fix the following:\n\n'; printf ' • %s\n' "${m[@]}")" 16 76
    return 1
  fi
  return 0
}

tui_env() {
  local def sel; def="$(detect_env_default)"
  sel=$(whiptail --backtitle "$BACKTITLE" --title "Environment" --default-item "$def" \
    --menu "Is this host a VM or an LXC container?\n(sets sensible defaults — you can change anything next)" 13 66 2 \
    "vm"  "Virtual machine (KVM/QEMU, etc.)" \
    "lxc" "Proxmox / LXC system container" \
    3>&1 1>&2 2>&3) || { clear; info "Cancelled — nothing was changed."; exit 0; }
  ENV_TYPE="$sel"
}

tui_bootstrap() {
  if whiptail --backtitle "$BACKTITLE" --title "bootstrap.sh" \
      --yesno "Create/update the admin user (sudo) and install its SSH key?" 9 64; then A_BOOTSTRAP=Y; else A_BOOTSTRAP=N; return; fi
  local v
  if v=$(whiptail --backtitle "$BACKTITLE" --title "Admin user" \
      --inputbox "Admin username (sudo + SSH login):" 9 60 "$PRIMARY_USER" 3>&1 1>&2 2>&3); then PRIMARY_USER="${v//[[:space:]]/}"; fi
  if v=$(whiptail --backtitle "$BACKTITLE" --title "SSH public key" \
      --inputbox "Paste ${PRIMARY_USER}'s PUBLIC SSH key.\nLeave blank to use an existing authorized_keys file." 12 78 "$PUBKEY" 3>&1 1>&2 2>&3); then
    PUBKEY="${v#"${v%%[![:space:]]*}"}"; PUBKEY="${PUBKEY%"${PUBKEY##*[![:space:]]}"}"
  fi
  if ! id "$PRIMARY_USER" >/dev/null 2>&1; then
    if v=$(whiptail --backtitle "$BACKTITLE" --title "New user password" \
        --passwordbox "Password for new user ${PRIMARY_USER}\n(blank = SSH-key only):" 11 64 3>&1 1>&2 2>&3); then ADMIN_PASSWORD="$v"; fi
  fi
}

tui_harden() {
  if whiptail --backtitle "$BACKTITLE" --title "harden.sh" \
      --yesno "Harden the system?\n\nSSH lockdown, nftables firewall, fail2ban, sysctl,\nAppArmor, AIDE, Lynis." 12 66; then A_HARDEN=Y; else A_HARDEN=N; return; fi
  local v sel t
  if v=$(whiptail --backtitle "$BACKTITLE" --title "SSH port" \
      --inputbox "SSH port (a random high port is suggested):" 9 60 "${SSH_PORT:-22}" 3>&1 1>&2 2>&3); then SSH_PORT="${v//[[:space:]]/}"; fi
  if sel=$(whiptail --backtitle "$BACKTITLE" --title "Hardening options" \
      --checklist "Space to toggle, Enter to confirm:" 13 76 3 \
      "upgrade"  "Run apt full-upgrade"                        "$(onoff "$A_UPGRADE")" \
      "lockroot" "Lock the root password (sudo still works)"   "$(onoff "$A_LOCKROOT")" \
      "usbblock" "Blacklist usb-storage (disables USB drives)" "$(onoff "$A_USBBLACK")" \
      3>&1 1>&2 2>&3); then
    A_UPGRADE=N; A_LOCKROOT=N; A_USBBLACK=N
    for t in $sel; do t="${t//\"/}"; case "$t" in upgrade) A_UPGRADE=Y;; lockroot) A_LOCKROOT=Y;; usbblock) A_USBBLACK=Y;; esac; done
  fi
  if v=$(whiptail --backtitle "$BACKTITLE" --title "Firewall ports" \
      --inputbox "Extra TCP ports to open (space-separated, blank for none):" 9 76 "$ALLOW_TCP_PORTS" 3>&1 1>&2 2>&3); then ALLOW_TCP_PORTS="$v"; fi
}

tui_ancillary() {
  local sel t
  if sel=$(whiptail --backtitle "$BACKTITLE" --title "ancillary.sh — extra packages" \
      --checklist "Packages to install (Space to toggle):" 16 72 6 \
      "vim"   "Vim text editor"              "$(onoff "$A_PKG_vim")" \
      "btop"  "Resource monitor (htop-like)" "$(onoff "$A_PKG_btop")" \
      "duf"   "Disk usage viewer"            "$(onoff "$A_PKG_duf")" \
      "fish"  "Friendly interactive shell"   "$(onoff "$A_PKG_fish")" \
      "rsync" "Fast file copy / sync"        "$(onoff "$A_PKG_rsync")" \
      "qemu"  "QEMU guest agent (VM only)"   "$(onoff "$A_PKG_qemu")" \
      3>&1 1>&2 2>&3); then
    A_PKG_vim=N; A_PKG_btop=N; A_PKG_duf=N; A_PKG_fish=N; A_PKG_rsync=N; A_PKG_qemu=N
    for t in $sel; do t="${t//\"/}"; case "$t" in vim) A_PKG_vim=Y;; btop) A_PKG_btop=Y;; duf) A_PKG_duf=Y;; fish) A_PKG_fish=Y;; rsync) A_PKG_rsync=Y;; qemu) A_PKG_qemu=Y;; esac; done
    [[ "$A_PKG_vim$A_PKG_btop$A_PKG_duf$A_PKG_fish$A_PKG_rsync$A_PKG_qemu" == *Y* ]] && A_ANCILLARY=Y || A_ANCILLARY=N
    if [[ "$A_PKG_fish" == Y ]]; then
      if whiptail --backtitle "$BACKTITLE" --title "fish" --yesno "Set fish as ${PRIMARY_USER}'s default shell?" 8 60; then A_FISH_DEFAULT=Y; else A_FISH_DEFAULT=N; fi
    fi
  fi
}

tui_monitoring() {
  local sel t v
  if sel=$(whiptail --backtitle "$BACKTITLE" --title "monitoring.sh — agents" \
      --checklist "Monitoring agents (Space to toggle):" 11 72 2 \
      "zabbix" "Zabbix agent 2 (needs a Zabbix server)" "$(onoff "$A_AGENT_zabbix")" \
      "alloy"  "Grafana Alloy log shipper (needs Loki)" "$(onoff "$A_AGENT_alloy")" \
      3>&1 1>&2 2>&3); then
    A_AGENT_zabbix=N; A_AGENT_alloy=N
    for t in $sel; do t="${t//\"/}"; case "$t" in zabbix) A_AGENT_zabbix=Y;; alloy) A_AGENT_alloy=Y;; esac; done
    [[ "$A_AGENT_zabbix" == Y || "$A_AGENT_alloy" == Y ]] && A_MONITORING=Y || A_MONITORING=N
  fi
  if [[ "$A_AGENT_zabbix" == Y ]]; then
    if v=$(whiptail --backtitle "$BACKTITLE" --title "Zabbix server" \
        --inputbox "Zabbix server/proxy for active checks (host or host:port):" 9 72 "${ZABBIX_SERVER_ACTIVE:-zabbix:10051}" 3>&1 1>&2 2>&3); then ZABBIX_SERVER_ACTIVE="${v//[[:space:]]/}"; fi
    if whiptail --backtitle "$BACKTITLE" --title "Zabbix" --defaultno --yesno "Set the agent up to monitor rootless Docker?" 8 64; then A_ZBX_DOCKER=Y; else A_ZBX_DOCKER=N; fi
  fi
  if [[ "$A_AGENT_alloy" == Y ]]; then
    if v=$(whiptail --backtitle "$BACKTITLE" --title "Loki URL" \
        --inputbox "Loki base URL for Alloy (host:port):" 9 64 "${LOKI_URL:-loki:3100}" 3>&1 1>&2 2>&3); then LOKI_URL="${v//[[:space:]]/}"; fi
    if whiptail --backtitle "$BACKTITLE" --title "Alloy" --defaultno --yesno "Also capture Docker container logs (journald log-driver)?" 9 68; then A_ALLOY_DOCKERLOGS=Y; else A_ALLOY_DOCKERLOGS=N; fi
  fi
}

tui_container() {
  if whiptail --backtitle "$BACKTITLE" --title "container.sh" --defaultno \
      --yesno "Install a container runtime (Docker and/or Podman, rootless)?\n\n(Off by default — Docker/Podman inside an LXC is advanced.)" 11 70; then A_CONTAINER=Y; else A_CONTAINER=N; return; fi
  local sel t
  if sel=$(whiptail --backtitle "$BACKTITLE" --title "Container runtimes" \
      --checklist "Choose runtime(s) — at least one (Space to toggle):" 11 66 2 \
      "docker" "Docker Engine + Compose (rootless)" "$(onoff "$A_DOCKER")" \
      "podman" "Podman (daemonless, rootless)"      "$(onoff "$A_PODMAN")" \
      3>&1 1>&2 2>&3); then
    A_DOCKER=N; A_PODMAN=N
    for t in $sel; do t="${t//\"/}"; case "$t" in docker) A_DOCKER=Y;; podman) A_PODMAN=Y;; esac; done
    [[ "$A_DOCKER" == N && "$A_PODMAN" == N ]] && A_DOCKER=Y
  fi
  if [[ "$A_DOCKER" == Y ]]; then
    if whiptail --backtitle "$BACKTITLE" --title "Docker" --yesno "Disable the system-wide (root) Docker daemon — rootless only?" 9 68; then A_DISABLE_ROOTFUL=Y; else A_DISABLE_ROOTFUL=N; fi
  fi
  if whiptail --backtitle "$BACKTITLE" --title "Example app" --yesno "Create an example app under /opt/docker?" 8 60; then A_EXAMPLE_APP=Y; else A_EXAMPLE_APP=N; fi
  if whiptail --backtitle "$BACKTITLE" --title "Logging" --defaultno --yesno "Send container logs to the journal (journald log-driver)?" 9 68; then A_JOURNALD=Y; else A_JOURNALD=N; fi
}

tui_motd() {
  if whiptail --backtitle "$BACKTITLE" --title "motd.sh" --yesno "Generate a dynamic login banner (MOTD)?" 8 56; then A_MOTD=Y; else A_MOTD=N; return; fi
  local v
  if v=$(whiptail --backtitle "$BACKTITLE" --title "MOTD" \
      --inputbox "Documentation URL to show in the banner (blank to omit):" 9 70 "$DOC_URL" 3>&1 1>&2 2>&3); then DOC_URL="$v"; fi
}

tui_docs() {
  if whiptail --backtitle "$BACKTITLE" --title "documentation.sh" --yesno "Create docs (generate the SSH connection doc)?" 8 62; then A_DOC=Y; else A_DOC=N; fi
}

# tui_main — the hub: a menu of every step + its state; Accept installs.
tui_main() {
  local sel
  while true; do
    sel=$(whiptail --backtitle "$BACKTITLE" --title "Review & customise  —  [${ENV_TYPE^^}]" \
      --ok-button "Open" --cancel-button "Quit" \
      --menu "Select a step to change its options, then choose Accept.\nThe defaults are already set — just Accept to use them as-is." 21 78 11 \
      "bootstrap"  "[$(pad3 "$A_BOOTSTRAP")]  admin user + SSH key" \
      "harden"     "[$(pad3 "$A_HARDEN")]  hardening — SSH port ${SSH_PORT:-22}" \
      "ancillary"  "[$(pad3 "$A_ANCILLARY")]  packages: $(anc_list)" \
      "monitoring" "[$(pad3 "$A_MONITORING")]  agents: $(mon_list)" \
      "container"  "[$(pad3 "$A_CONTAINER")]  runtime: $(ct_list)" \
      "motd"       "[$(pad3 "$A_MOTD")]  dynamic login banner" \
      "docs"       "[$(pad3 "$A_DOC")]  SSH connection doc" \
      "sep"        "────────────────────────────────────" \
      "ACCEPT"     "✓  Accept these settings and install" \
      3>&1 1>&2 2>&3) || { if whiptail --backtitle "$BACKTITLE" --yesno "Quit without installing?" 8 50; then clear; info "Cancelled — nothing was changed."; exit 0; fi; continue; }
    case "$sel" in
      bootstrap)  tui_bootstrap ;;
      harden)     tui_harden ;;
      ancillary)  tui_ancillary ;;
      monitoring) tui_monitoring ;;
      container)  tui_container ;;
      motd)       tui_motd ;;
      docs)       tui_docs ;;
      sep)        : ;;
      ACCEPT)     if validate_tui; then break; fi ;;
    esac
  done
}

tui_wizard() { tui_env; compute_defaults; tui_main; }

# text_wizard — the no-whiptail fallback: defaults-first review + accept/edit.
text_wizard() {
  select_env_type
  compute_defaults
  ask_yn A_DOC "Create docs (run documentation.sh)?" "$A_DOC"
  step "Review settings (accept the defaults, or edit)"
  while true; do
    print_summary
    if confirm "Accept these settings and begin install?" Y; then
      validate_answers && break
      warn "Some required answers are missing — opening the questions so you can complete them."
      collect_answers
    else
      info "Editing — re-answer each question (press Enter to keep the shown value)."
      collect_answers
    fi
  done
}

# run_wizard — choose the front-end: whiptail TUI (interactive), or the text
# wizard (no whiptail), or accept env-driven defaults (unattended).
run_wizard() {
  if [[ "$ASSUME_YES" == "1" || ! -r /dev/tty ]]; then
    select_env_type; compute_defaults
    print_summary
    if ! validate_answers; then
      err "Unattended run is missing a required value (e.g. an SSH key). Provide it via env (PUBKEY=…, ZABBIX_SERVER_ACTIVE=…) and re-run."
      exit 1
    fi
    return
  fi
  if ! command -v whiptail >/dev/null 2>&1; then
    info "Installing 'whiptail' for the setup menu…"
    DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail >/dev/null 2>&1 || true
  fi
  if command -v whiptail >/dev/null 2>&1; then
    tui_wizard
    clear 2>/dev/null || true
  else
    warn "whiptail unavailable — using the text wizard instead."
    text_wizard
  fi
}

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
printf '%s        Debian 13 Homelab Bootstrap  —  review, customise, install%s\n' "$DIM" "$RESET"
hr '─'

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then err "This script must be run as root (try: sudo $0)."; exit 1; fi
command -v apt-get >/dev/null 2>&1 || { err "apt-get not found — this targets Debian/apt systems."; exit 1; }
log "Running as root."
command -v curl >/dev/null 2>&1 || warn "curl not found — the download fallback for remote scripts won't work (local copies still will)."

# ==============================================================================
step "Step 1 — Configure (menu-driven; falls back to a text wizard)"
# ==============================================================================
# whiptail menu hub when interactive: pick VM/LXC, then review & customise every
# step in one place, Accept to install. No terminal → text wizard / defaults.
run_wizard

materialize_selection
if (( ${#SELECTED[@]} == 0 )); then warn "No scripts selected — nothing to do."; exit 0; fi
log "Settings accepted — running the selected scripts now."

# ==============================================================================
step "Step 2 — Running scripts (no further prompts)"
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
