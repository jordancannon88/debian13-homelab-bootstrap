#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — init
#  Entry point. Must run as root. It:
#    1. asks whether this host is a VM or an LXC container (autodetected) — this
#       sets sensible DEFAULTS for everything below (e.g. the QEMU guest agent
#       defaults on for a VM, off for an LXC)
#    2. opens a whiptail MENU (TUI) to review & customise every step in one
#       place — pick a step to change its options, then "Accept & install".
#       Defaults are pre-set, so you can just Accept. This installer is
#       TUI-ONLY: it requires an interactive terminal and whiptail (which it
#       auto-installs if missing); there is no text-mode or unattended path.
#    3. on Accept, runs each chosen script NON-INTERACTIVELY (answers passed via
#       env), so nothing stops mid-run to ask you anything
#    4. prints ONE consolidated report (review + next steps)
#
#  Run as root on a terminal, e.g.:  sudo ./init.sh
#
#  curl must already be present (the download fallback for remote scripts uses
#  it). Debian ships it on all but the most minimal installs.
#
#  Environment overrides:
#    REPO_RAW_BASE=<url>  -> base raw URL to fetch scripts from
# ==============================================================================

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main}"
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

valid_user()  { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; }
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

declare -A STATUS DETAIL SUMM LOGS
SELECTED=(); ANCILLARY_PICK=(); MONITORING_PICK=()
skip_script() { STATUS[$1]="skipped"; DETAIL[$1]="you chose not to run it"; }

# Answer storage. compute_defaults seeds these from the VM/LXC defaults; the
# whiptail menu (tui_*) reads and updates them as the user customises.
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

# compute_defaults — seed EVERY answer from the VM/LXC-aware defaults so the menu
# opens pre-filled. Free-text inputs with no safe default (SSH key) stay empty
# and are flagged by validate_tui before install.
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
#  Reads/writes the A_* answer vars; on Accept, validate_tui checks required
#  inputs and materialize_selection turns the answers into the run list + env.
# ==============================================================================
BACKTITLE="Debian 13 Homelab Bootstrap"

onoff() { [[ "$1" == "Y" ]] && printf 'ON' || printf 'OFF'; }    # checklist state
pad3()  { [[ "$1" == "Y" ]] && printf 'yes' || printf 'no '; }   # aligned menu state
# Short status summaries for the hub menu lines.
anc_list() { local p=(); [[ "$A_PKG_vim" == Y ]] && p+=(vim); [[ "$A_PKG_btop" == Y ]] && p+=(btop); [[ "$A_PKG_duf" == Y ]] && p+=(duf); [[ "$A_PKG_fish" == Y ]] && p+=(fish); [[ "$A_PKG_rsync" == Y ]] && p+=(rsync); [[ "$A_PKG_qemu" == Y ]] && p+=(qemu); local IFS=,; printf '%s' "${p[*]:-none}"; }
mon_list() { local p=(); [[ "$A_AGENT_zabbix" == Y ]] && p+=(zabbix); [[ "$A_AGENT_alloy" == Y ]] && p+=(alloy); local IFS=,; printf '%s' "${p[*]:-none}"; }
ct_list()  { [[ "$A_CONTAINER" != Y ]] && { printf 'off'; return; }; local p=(); [[ "$A_DOCKER" == Y ]] && p+=(docker); [[ "$A_PODMAN" == Y ]] && p+=(podman); local IFS=,; printf '%s' "${p[*]:-none}"; }

# validate_tui — check required inputs are present; collect any problems and
# show them in a whiptail msgbox. Returns 0 if ready to install.
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
  local def sel; def="${ENV_TYPE:-}"
  [[ "$def" == "vm" || "$def" == "lxc" ]] || def="$(detect_env_default)"
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
    tui_get_password "$PRIMARY_USER"
  fi
}

# tui_get_password <user> — prompt for a NEW account's password with a "show
# password" option (visible vs masked entry) and a confirmation entry that must
# match. Sets ADMIN_PASSWORD ("" = passwordless / SSH-key only). Cancel/Esc at
# any step leaves the current value unchanged.
tui_get_password() {
  local user="$1" box p1 p2
  if whiptail --backtitle "$BACKTITLE" --title "Password — ${user}" --defaultno \
      --yesno "Show the password as you type?\n\n  Yes = visible entry (easier to verify)\n  No  = masked entry (•••)" 12 64; then
    box="--inputbox"
  else
    box="--passwordbox"
  fi
  while true; do
    p1=$(whiptail --backtitle "$BACKTITLE" --title "New password — ${user}" \
      $box "Enter a login password for ${user}.\n(Leave blank = passwordless / SSH-key only.)" 11 66 3>&1 1>&2 2>&3) || return 0
    if [[ -z "$p1" ]]; then ADMIN_PASSWORD=""; return 0; fi
    p2=$(whiptail --backtitle "$BACKTITLE" --title "Confirm password — ${user}" \
      $box "Re-enter the password to confirm:" 10 66 3>&1 1>&2 2>&3) || return 0
    if [[ "$p1" == "$p2" ]]; then
      ADMIN_PASSWORD="$p1"
      return 0
    fi
    whiptail --backtitle "$BACKTITLE" --title "Passwords don't match" \
      --msgbox "The two entries did not match — please try again." 8 58
  done
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
  # Loop the runtime checklist until at least one is chosen. Crucially we do NOT
  # silently force Docker when nothing is ticked — that caused Docker to install
  # even after the user un-ticked it. Cancel/Esc keeps the current selection.
  while sel=$(whiptail --backtitle "$BACKTITLE" --title "Container runtimes" \
      --checklist "Choose runtime(s) — at least one (Space to toggle):" 11 66 2 \
      "docker" "Docker Engine + Compose (rootless)" "$(onoff "$A_DOCKER")" \
      "podman" "Podman (daemonless, rootless)"      "$(onoff "$A_PODMAN")" \
      3>&1 1>&2 2>&3); do
    A_DOCKER=N; A_PODMAN=N
    for t in $sel; do t="${t//\"/}"; case "$t" in docker) A_DOCKER=Y;; podman) A_PODMAN=Y;; esac; done
    [[ "$A_DOCKER" == "Y" || "$A_PODMAN" == "Y" ]] && break
    whiptail --backtitle "$BACKTITLE" --title "Pick a runtime" \
      --msgbox "Select at least one runtime — Docker and/or Podman." 8 60
  done
  # If the user ended up choosing neither runtime (e.g. cancelled the picker),
  # treat that as "don't install a container runtime" rather than silently
  # defaulting to Docker.
  if [[ "$A_DOCKER" != "Y" && "$A_PODMAN" != "Y" ]]; then
    A_CONTAINER=N; A_DISABLE_ROOTFUL=N; A_EXAMPLE_APP=N; A_JOURNALD=N
    return
  fi
  if [[ "$A_DOCKER" == Y ]]; then
    if whiptail --backtitle "$BACKTITLE" --title "Docker" --yesno "Disable the system-wide (root) Docker daemon — rootless only?" 9 68; then A_DISABLE_ROOTFUL=Y; else A_DISABLE_ROOTFUL=N; fi
    # The example app is Docker-specific; only offer it when Docker is installed.
    if whiptail --backtitle "$BACKTITLE" --title "Example app" --yesno "Create an example app under /opt/docker?" 8 60; then A_EXAMPLE_APP=Y; else A_EXAMPLE_APP=N; fi
  else
    A_EXAMPLE_APP=N
  fi
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

# run_wizard — this installer is whiptail-TUI only. It needs an interactive
# terminal and whiptail (auto-installed if missing). No text fallback and no
# unattended/defaults path: if either is unavailable, we stop with a clear error.
run_wizard() {
  if [[ ! -r /dev/tty ]]; then
    err "This installer is an interactive menu (whiptail) and needs a terminal."
    err "Run it directly on the console or over SSH — not piped, detached, or in a non-interactive job."
    exit 1
  fi
  if ! command -v whiptail >/dev/null 2>&1; then
    info "Installing 'whiptail' for the setup menu…"
    DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail >/dev/null 2>&1 || true
  fi
  if ! command -v whiptail >/dev/null 2>&1; then
    err "'whiptail' is required for the setup menu and couldn't be installed."
    err "Install it manually ( apt-get install whiptail ) and re-run."
    exit 1
  fi
  tui_wizard
  clear 2>/dev/null || true
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
step "Step 1 — Configure (whiptail menu)"
# ==============================================================================
# Pick VM/LXC, then review & customise every step in one menu; Accept to install.
# TUI-only: requires a terminal + whiptail (auto-installed), else it stops.
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
