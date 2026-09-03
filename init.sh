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
  [buzz]="buzz relay alerting over forced-command ssh (needs the dev box)"
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
    documentation.sh) printf 'generate the SSH connection guide (how to reach this host on its hardened port)';;
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
  # A Proxmox VE host is Debian underneath, so detect it FIRST — pveversion (or
  # a mounted /etc/pve) means this is the hypervisor itself, not a guest.
  if command -v pveversion >/dev/null 2>&1 || [[ -d /etc/pve/local ]]; then
    printf 'pve'; return
  fi
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

# env-aware Y/N default: yn_def <vm-default> <lxc-default> [<pve-default>]
# (the pve default falls back to the vm one when a call doesn't care)
yn_def() {
  case "$ENV_TYPE" in
    vm)  printf '%s' "$1";;
    pve) printf '%s' "${3:-$1}";;
    *)   printf '%s' "$2";;
  esac
}

declare -A STATUS DETAIL SUMM LOGS
SELECTED=(); ANCILLARY_PICK=(); MONITORING_PICK=()
skip_script() { STATUS[$1]="skipped"; DETAIL[$1]="you chose not to run it"; }

# Answer storage. compute_defaults seeds these from the VM/LXC defaults; the
# whiptail menu (tui_*) reads and updates them as the user customises.
ENV_TYPE="${ENV_TYPE:-}"
A_BOOTSTRAP=""; A_HARDEN=""; A_ANCILLARY=""; A_MONITORING=""; A_CONTAINER=""; A_MOTD=""; A_DOC=""
A_PKG_vim=""; A_PKG_btop=""; A_PKG_duf=""; A_PKG_fish=""; A_PKG_rsync=""; A_PKG_qemu=""
A_AGENT_zabbix=""; A_AGENT_alloy=""; A_AGENT_buzz=""
A_BUZZ_disk=""; A_BUZZ_repl=""; A_BUZZ_ha=""; A_BUZZ_tbmesh=""
BUZZ_TARGET="${BUZZ_TARGET:-}"; BUZZ_PORT="${BUZZ_PORT:-}"
PRIMARY_USER="${PRIMARY_USER:-}"; PUBKEY="${PUBKEY:-}"; ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SSH_PORT="${SSH_PORT:-}"; A_UPGRADE=""; A_LOCKROOT=""; A_USBBLACK=""; ALLOW_TCP_PORTS="${ALLOW_TCP_PORTS:-}"
A_SSH2FA=""; A_COMPILERS=""; A_HTTP=""; A_HTTPS=""
A_HC_unattended=""; A_HC_journald=""; A_HC_ssh=""; A_HC_firewall=""; A_HC_fail2ban=""
A_HC_apparmor=""; A_HC_aide=""; A_HC_sysctl=""; A_HC_extra=""; A_HC_lynis=""
ALLOW_UDP_PORTS="${ALLOW_UDP_PORTS:-}"; ALLOW_SSH_CIDRS="${ALLOW_SSH_CIDRS:-}"
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
  A_PKG_fish="$(yn_def Y Y)"; A_PKG_rsync="$(yn_def Y Y)"; A_PKG_qemu="$(yn_def Y N N)"
  A_AGENT_zabbix="$(yn_def Y Y)"; A_AGENT_alloy="$(yn_def Y Y)"
  # buzz is off by default: it needs a dev box running the forced-command
  # dispatcher, and its key must be registered there before alerts flow.
  A_AGENT_buzz="$(yn_def N N)"
  # On a PVE host the Proxmox watches are worth having by default (their
  # tooling exists there); tbmesh stays opt-in (Thunderbolt-mesh nodes only).
  A_BUZZ_disk=Y; A_BUZZ_repl="$(yn_def N N Y)"; A_BUZZ_ha="$(yn_def N N Y)"; A_BUZZ_tbmesh=N
  BUZZ_PORT="${BUZZ_PORT:-6523}"
  A_FISH_DEFAULT="$(yn_def Y Y)"
  # PVE host: root@pam web-UI login needs the root password UNLOCKED, and
  # hypervisors routinely need USB (passthrough, installer media) — so both
  # hardening extras default OFF there.
  A_UPGRADE="$(yn_def Y Y)"; A_LOCKROOT="$(yn_def Y Y N)"; A_USBBLACK="$(yn_def Y Y N)"
  A_SSH2FA=N; A_COMPILERS=Y; A_HTTP=N; A_HTTPS=N
  A_HC_unattended=Y; A_HC_journald=Y; A_HC_ssh=Y; A_HC_firewall=Y; A_HC_fail2ban=Y
  A_HC_apparmor=Y; A_HC_aide=Y; A_HC_sysctl=Y; A_HC_extra=Y; A_HC_lynis=Y
  A_ZBX_DOCKER="$(yn_def N N)"; A_ALLOY_DOCKERLOGS="$(yn_def N N)"
  # Neither runtime is pre-selected: enabling the container step then opens the
  # runtime picker where you explicitly choose Docker and/or Podman. (Pre-ticking
  # Docker meant it — and its rootless setup — installed even when you only wanted
  # Podman.) DISABLE_ROOTFUL only applies if Docker is later chosen.
  A_DOCKER="N"; A_PODMAN="N"; A_DISABLE_ROOTFUL="$(yn_def Y Y)"
  A_EXAMPLE_APP="$(yn_def Y Y)"; A_JOURNALD="$(yn_def N N)"
  # Default SSH port: a random high port (away from 22 and the ephemeral range).
  # On a PVE host, default to 22 instead: inter-node ssh (migration,
  # replication, cluster join) assumes it — change it only fleet-wide.
  if [[ "$ENV_TYPE" == "pve" ]]; then
    SSH_PORT="${SSH_PORT:-22}"
    # 8006/3128 are NOT pre-seeded here: harden.sh's own PVE pre-flight
    # force-allows them, so the web UI stays reachable automatically.
  else
    SSH_PORT="${SSH_PORT:-$(( RANDOM % 22000 + 10000 ))}"
  fi
  LOKI_URL="${LOKI_URL:-loki:3100}"
  ZABBIX_SERVER_ACTIVE="${ZABBIX_SERVER_ACTIVE:-zabbix:10051}"
  # The admin username is deliberately NOT defaulted (no SUDO_USER guessing):
  # the operator must enter it, and the hub shows "needs admin user" until they
  # do. An explicit PRIMARY_USER=<name> environment override still works.
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
  [[ "$A_AGENT_buzz"   == "Y" ]] && MONITORING_PICK+=(buzz)
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
    [[ "$A_SSH2FA"   == "Y" ]] && export ENABLE_SSH_2FA=1      || export ENABLE_SSH_2FA=0
    [[ "$A_COMPILERS" == "Y" ]] && export HARDEN_COMPILERS=1   || export HARDEN_COMPILERS=0
    [[ "$A_HTTP"     == "Y" ]] && export ALLOW_HTTP=1          || export ALLOW_HTTP=0
    [[ "$A_HTTPS"    == "Y" ]] && export ALLOW_HTTPS=1         || export ALLOW_HTTPS=0
    export ALLOW_TCP_PORTS ALLOW_UDP_PORTS ALLOW_SSH_CIDRS
    # Docker needs the compat firewall (forward accepted, scoped flush,
    # ip_forward on) only when a ROOTFUL daemon will exist on this host;
    # rootless Docker/Podman work under the strict firewall.
    if [[ "$A_CONTAINER" == "Y" && "$A_DOCKER" == "Y" && "$A_DISABLE_ROOTFUL" != "Y" ]]; then
      export DOCKER_COMPAT=1
    else
      export DOCKER_COMPAT=0
    fi
    [[ "$A_HC_unattended" == "Y" ]] && export HARDEN_UNATTENDED=1 || export HARDEN_UNATTENDED=0
    [[ "$A_HC_journald"   == "Y" ]] && export HARDEN_JOURNALD=1   || export HARDEN_JOURNALD=0
    [[ "$A_HC_ssh"        == "Y" ]] && export HARDEN_SSH=1        || export HARDEN_SSH=0
    [[ "$A_HC_firewall"   == "Y" ]] && export HARDEN_FIREWALL=1   || export HARDEN_FIREWALL=0
    [[ "$A_HC_fail2ban"   == "Y" ]] && export HARDEN_FAIL2BAN=1   || export HARDEN_FAIL2BAN=0
    [[ "$A_HC_apparmor"   == "Y" ]] && export HARDEN_APPARMOR=1   || export HARDEN_APPARMOR=0
    [[ "$A_HC_aide"       == "Y" ]] && export HARDEN_AIDE=1       || export HARDEN_AIDE=0
    [[ "$A_HC_sysctl"     == "Y" ]] && export HARDEN_SYSCTL=1     || export HARDEN_SYSCTL=0
    [[ "$A_HC_extra"      == "Y" ]] && export HARDEN_EXTRA=1      || export HARDEN_EXTRA=0
    [[ "$A_HC_lynis"      == "Y" ]] && export HARDEN_LYNIS=1      || export HARDEN_LYNIS=0
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
    if [[ "$A_AGENT_buzz" == "Y" ]]; then
      export BUZZ_TARGET
      export BUZZ_PORT="${BUZZ_PORT:-6523}"
      export BUZZ_ALERTS="$(buzz_alert_list)"
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
    # (The example app's port is opened by container.sh itself — every step
    # that installs a listener opens its own firewall port.)
    [[ "$A_JOURNALD"    == "Y" ]] && export DOCKER_JOURNALD_LOGS=1 || export DOCKER_JOURNALD_LOGS=0
  fi
  [[ "$A_MOTD" == "Y" ]] && export DOC_URL
  if [[ "$A_DOC" == "Y" ]]; then
    # Not /tmp: a predictable root-written path in a world-writable dir is a
    # symlink-attack target. /var/lib/homelab-bootstrap is root-owned.
    export OUT_FILE="/var/lib/homelab-bootstrap/connect.html"
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
buzz_alert_list() { local p=(); [[ "$A_BUZZ_disk" == Y ]] && p+=(disk); [[ "$A_BUZZ_repl" == Y ]] && p+=(repl); [[ "$A_BUZZ_ha" == Y ]] && p+=(ha); [[ "$A_BUZZ_tbmesh" == Y ]] && p+=(tbmesh); printf '%s' "${p[*]:-none}"; }

# need_* — what a step still needs before Accept will pass (empty = ready).
# These feed the ⚠ indicators on the hub menu so required configuration is
# visible at a glance instead of only at Accept time. KEEP IN SYNC with
# validate_tui: same conditions, attributed to the step whose dialog fixes them.
need_bootstrap() {
  local n=() akf
  if [[ "$A_BOOTSTRAP" == Y || "$A_HARDEN" == Y || "$A_CONTAINER" == Y || "$A_ANCILLARY" == Y ]]; then
    { [[ -z "$PRIMARY_USER" ]] || ! valid_user "$PRIMARY_USER"; } && n+=("admin user")
  fi
  if [[ "$A_BOOTSTRAP" == Y && "$A_HARDEN" == Y && "$A_HC_ssh" == Y && -n "$PRIMARY_USER" ]] && valid_user "$PRIMARY_USER"; then
    akf="$(getent passwd "$PRIMARY_USER" 2>/dev/null | cut -d: -f6)/.ssh/authorized_keys"
    if [[ -z "$PUBKEY" ]] && ! { id "$PRIMARY_USER" &>/dev/null && [[ -s "$akf" ]]; }; then
      n+=("SSH key")
    fi
  fi
  local IFS='+'; printf '%s' "${n[*]:-}"
}
need_harden() {
  local akf
  [[ "$A_HARDEN" == Y && "$A_HC_ssh" == Y && "$A_BOOTSTRAP" != Y && -n "$PRIMARY_USER" ]] || return 0
  if ! id "$PRIMARY_USER" &>/dev/null; then
    printf 'existing user'
  else
    akf="$(getent passwd "$PRIMARY_USER" 2>/dev/null | cut -d: -f6)/.ssh/authorized_keys"
    [[ -s "$akf" ]] || printf 'SSH key on file'
  fi
}
need_zabbix() {
  [[ "$A_AGENT_zabbix" == Y && -z "${ZABBIX_SERVER_ACTIVE//[[:space:]]/}" ]] && printf 'server'
  return 0
}
need_buzz() {
  [[ "$A_AGENT_buzz" == Y ]] || return 0
  local n=()
  [[ -z "${BUZZ_TARGET//[[:space:]]/}" ]] && n+=("relay")
  [[ "$(buzz_alert_list)" == "none" ]] && n+=("alerts")
  local IFS='+'; printf '%s' "${n[*]:-}"
}
need_monitoring() {
  [[ "$A_MONITORING" == Y ]] || return 0
  local n=() z b
  z="$(need_zabbix)"; b="$(need_buzz)"
  [[ -n "$z" ]] && n+=("$z")
  [[ -n "$b" ]] && n+=("$b")
  local IFS='+'; printf '%s' "${n[*]:-}"
}
need_ancillary() {
  [[ "$A_ANCILLARY" == Y && "$(anc_list)" == "none" ]] && printf 'packages'
  return 0
}
need_container() {
  [[ "$A_CONTAINER" == Y && "$A_DOCKER" != Y && "$A_PODMAN" != Y ]] && printf 'runtime'
  return 0
}
# stat3 <Y/N> <needs> — the hub status icon: ✗ off, ⚠ on but still needs
# configuration, ✔ on and ready. The bracket IS the indicator; open the step
# to see and fill in what's missing.
stat3() {
  if [[ "$1" != "Y" ]]; then printf ' ✗ '
  elif [[ -n "$2" ]]; then printf ' ⚠ '
  else printf ' ✔ '
  fi
}

# validate_tui — check required inputs are present; collect any problems and
# show them in a whiptail msgbox. Returns 0 if ready to install.
validate_tui() {
  local m=() akf=""
  if [[ "$A_BOOTSTRAP" == Y || "$A_HARDEN" == Y || "$A_CONTAINER" == Y || "$A_ANCILLARY" == Y ]]; then
    { [[ -z "$PRIMARY_USER" ]] || ! valid_user "$PRIMARY_USER"; } && m+=("Set a valid admin username (in bootstrap.sh).")
  fi
  if [[ "$A_HARDEN" == Y && "$A_HC_ssh" == Y && -n "$PRIMARY_USER" ]]; then
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
  [[ "$A_MONITORING" == Y && "$A_AGENT_buzz" == Y && -z "${BUZZ_TARGET//[[:space:]]/}" ]] && m+=("buzz alerting needs the dev box target (user@host).")
  [[ "$A_MONITORING" == Y && "$A_AGENT_buzz" == Y && "$(buzz_alert_list)" == "none" ]] && m+=("buzz alerting: pick at least one alert type (disk/repl/ha/tbmesh).")
  [[ "$A_ANCILLARY" == Y && "$(anc_list)" == "none" ]] && m+=("extra packages is enabled but no packages are picked.")
  [[ "$A_CONTAINER" == Y && "$A_DOCKER" != Y && "$A_PODMAN" != Y ]] && m+=("container runtime is enabled but no runtime (Docker/Podman) is picked.")
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
  [[ "$def" == "vm" || "$def" == "lxc" || "$def" == "pve" ]] || def="$(detect_env_default)"
  sel=$(whiptail --backtitle "$BACKTITLE" --title "Environment" --default-item "$def" \
    --menu "What is this host?\n(sets sensible defaults — you can change anything next)" 14 72 3 \
    "vm"  "Virtual machine (KVM/QEMU, etc.)" \
    "lxc" "Proxmox / LXC system container" \
    "pve" "Proxmox VE host (the hypervisor itself)" \
    3>&1 1>&2 2>&3) || { clear; info "Cancelled — nothing was changed."; exit 0; }
  ENV_TYPE="$sel"
}

# ------------------------------------------------------------------------------
#  Uniform TUI building blocks. ONE pattern at every depth:
#    hub  ->  sub-hub  ->  input screen
#  Every menu: breadcrumb title, Open/Back buttons, the same hint header.
#  Every line: [icon]  label: current value   (✔ on/set · ✗ off · ⚠ needs input)
#  Toggle lines flip in place; value lines open an input screen.
# ------------------------------------------------------------------------------
MENU_HINT=$'Enter = open/toggle · Back = return · current values shown inline\n✔ on/set · ✗ off · ⚠ needs input'

onoff3() { [[ "$1" == "Y" ]] && printf ' ✔ ' || printf ' ✗ '; }         # toggle item icon
valic()  { if [[ -n "$1" ]]; then printf ' ✔ '; elif [[ "${2:-N}" == "Y" ]]; then printf ' ⚠ '; else printf ' ✗ '; fi; }
valp()   { [[ -n "$1" ]] && printf '%s' "$1" || printf '(not set)'; }
tgl()    { if [[ "${!1}" == "Y" ]]; then eval "$1=N"; else eval "$1=Y"; fi; }

# hubmenu <breadcrumb> <list-height> <tag> <desc> ... -> echoes selected tag
hubmenu() {
  local title="$1" lh="$2"; shift 2
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --ok-button "Open" --cancel-button "Back" \
    --menu "$MENU_HINT" $(( lh + 10 )) 78 "$lh" "$@" 3>&1 1>&2 2>&3
}

# ask <breadcrumb> <prompt> <current> <varname> [raw] — uniform input screen.
# Whitespace is stripped unless mode "raw" (port lists need their spaces).
ask() {
  local v
  if v=$(whiptail --backtitle "$BACKTITLE" --title "$1" \
      --inputbox "$2\n\n(Cancel keeps the current value.)" 13 72 "$3" 3>&1 1>&2 2>&3); then
    [[ "${5:-strip}" == "raw" ]] || v="${v//[[:space:]]/}"
    eval "$4=\$v"
  fi
}

# show_help <breadcrumb> <text> — uniform info screen; every menu carries a
# help line so what a setting does is always one Enter away.
show_help() {
  whiptail --backtitle "$BACKTITLE" --title "$1" --scrolltext --msgbox "$2" 20 74
}

# --- bootstrap ----------------------------------------------------------------
bs_key_state() {
  local akf
  if [[ -n "$PUBKEY" ]]; then printf 'entered'
  elif [[ -n "$PRIMARY_USER" ]] && id "$PRIMARY_USER" &>/dev/null; then
    akf="$(getent passwd "$PRIMARY_USER" 2>/dev/null | cut -d: -f6)/.ssh/authorized_keys"
    if [[ -s "$akf" ]]; then printf 'on file (existing authorized_keys)'; else printf '(not set)'; fi
  else printf '(not set)'; fi
}
bs_key_icon() {
  local st; st="$(bs_key_state)"
  if [[ "$st" != "(not set)" ]]; then printf ' ✔ '
  elif [[ "$A_HARDEN" == Y && "$A_HC_ssh" == Y ]]; then printf ' ⚠ '
  else printf ' ✗ '; fi
}
tui_bootstrap() {
  local sel v
  while true; do
    local items=("enabled" "[$(onoff3 "$A_BOOTSTRAP")]  run this step$([[ "$A_BOOTSTRAP" == Y ]] || echo ' — enable to configure')")
    if [[ "$A_BOOTSTRAP" == Y ]]; then
      items+=("user"     "[$(valic "$PRIMARY_USER" Y)]  admin username: $(valp "$PRIMARY_USER")")
      items+=("sshkey"   "[$(bs_key_icon)]  SSH public key: $(bs_key_state)")
      items+=("password" "[$(onoff3 "$([[ -n "$ADMIN_PASSWORD" ]] && echo Y || echo N)")]  password: $([[ -n "$ADMIN_PASSWORD" ]] && echo set || echo 'SSH-key only')")
    fi
    items+=(" " "────────────────────────────────────")
    items+=("help" "[ ? ]  what does each setting do?")
    sel=$(hubmenu "Setup › user (admin user + SSH key)" $(( ${#items[@]} / 2 )) "${items[@]}") || break
    case "$sel" in
      enabled)  tgl A_BOOTSTRAP ;;
      user)     ask "Setup › user › admin username" "Admin username (sudo + SSH login):" "$PRIMARY_USER" PRIMARY_USER ;;
      sshkey)
        if v=$(whiptail --backtitle "$BACKTITLE" --title "Setup › user › SSH public key" \
            --inputbox "Paste the admin user's PUBLIC SSH key.\nLeave blank to use an existing authorized_keys file.\n\n(Cancel keeps the current value.)" 13 78 "$PUBKEY" 3>&1 1>&2 2>&3); then
          PUBKEY="${v#"${v%%[![:space:]]*}"}"; PUBKEY="${PUBKEY%"${PUBKEY##*[![:space:]]}"}"
        fi ;;
      help) show_help "Setup › user › help" "enabled: whether this step runs at install time.

user: the admin account to create or update. It gets sudo and is the account you log in with after hardening.

SSH public key: pasted into the user's authorized_keys. Required when the harden step's SSH lockdown runs, because that disables password login — without a working key you would be locked out. If the user already exists with keys on file, this can stay blank.

password: optional login password for a NEWLY created account. Blank means SSH-key only (recommended). Existing accounts are never changed." ;;
      password) tui_get_password "${PRIMARY_USER:-admin}" ;;
    esac
  done
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

# --- harden -------------------------------------------------------------------
hc_count() {
  local n=0 f
  for f in A_HC_ssh A_HC_firewall A_HC_fail2ban A_HC_unattended A_HC_journald A_HC_apparmor A_HC_aide A_HC_sysctl A_HC_extra A_HC_lynis; do
    [[ "${!f}" == Y ]] && n=$((n+1))
  done
  printf '%s' "$n"
}
opt_list() {
  local p=()
  [[ "$A_UPGRADE" == Y ]] && p+=(upgrade); [[ "$A_LOCKROOT" == Y ]] && p+=(lockroot)
  [[ "$A_USBBLACK" == Y ]] && p+=(usbblock); [[ "$A_SSH2FA" == Y ]] && p+=(2fa)
  [[ "$A_COMPILERS" == Y ]] && p+=(compilers); [[ "$A_HTTP" == Y ]] && p+=(http); [[ "$A_HTTPS" == Y ]] && p+=(https)
  local IFS=,; printf '%s' "${p[*]:-none}"
}
tui_harden_components() {
  local sel t
  if sel=$(whiptail --backtitle "$BACKTITLE" --title "Setup › harden › components" \
      --checklist "Which hardening components should run? (Space to toggle)\nAll are on by default; skip only what you have a reason to skip." 20 76 10 \
      "ssh"        "SSH lockdown (port, key-only, root off)"       "$(onoff "$A_HC_ssh")" \
      "firewall"   "nftables firewall (deny-by-default input)"     "$(onoff "$A_HC_firewall")" \
      "fail2ban"   "fail2ban (bans repeated failed SSH logins)"    "$(onoff "$A_HC_fail2ban")" \
      "unattended" "Automatic security updates"                    "$(onoff "$A_HC_unattended")" \
      "journald"   "Persistent journald logs"                      "$(onoff "$A_HC_journald")" \
      "apparmor"   "AppArmor mandatory access control"             "$(onoff "$A_HC_apparmor")" \
      "aide"       "AIDE file-integrity baseline"                  "$(onoff "$A_HC_aide")" \
      "sysctl"     "Kernel/network sysctl hardening"               "$(onoff "$A_HC_sysctl")" \
      "extra"      "Extra Lynis fixes (auditd, banners, blacklists)" "$(onoff "$A_HC_extra")" \
      "lynis"      "Closing Lynis audit (report only)"             "$(onoff "$A_HC_lynis")" \
      3>&1 1>&2 2>&3); then
    A_HC_ssh=N; A_HC_firewall=N; A_HC_fail2ban=N; A_HC_unattended=N; A_HC_journald=N
    A_HC_apparmor=N; A_HC_aide=N; A_HC_sysctl=N; A_HC_extra=N; A_HC_lynis=N
    for t in $sel; do t="${t//\"/}"; case "$t" in
      ssh) A_HC_ssh=Y;; firewall) A_HC_firewall=Y;; fail2ban) A_HC_fail2ban=Y;;
      unattended) A_HC_unattended=Y;; journald) A_HC_journald=Y;; apparmor) A_HC_apparmor=Y;;
      aide) A_HC_aide=Y;; sysctl) A_HC_sysctl=Y;; extra) A_HC_extra=Y;; lynis) A_HC_lynis=Y;;
    esac; done
  fi
}
tui_harden_options() {
  local sel t
  if sel=$(whiptail --backtitle "$BACKTITLE" --title "Setup › harden › options" \
      --checklist "Pick the hardening options you want (Space to toggle):" 17 76 7 \
      "upgrade"   "Run apt full-upgrade"                          "$(onoff "$A_UPGRADE")" \
      "lockroot"  "Lock the root password (sudo still works)"     "$(onoff "$A_LOCKROOT")" \
      "usbblock"  "Blacklist usb-storage (disables USB drives)"   "$(onoff "$A_USBBLACK")" \
      "ssh2fa"    "Require TOTP 2FA for SSH logins"               "$(onoff "$A_SSH2FA")" \
      "compilers" "Restrict compilers to root"                    "$(onoff "$A_COMPILERS")" \
      "http"      "Open port 80 (HTTP)"                           "$(onoff "$A_HTTP")" \
      "https"     "Open port 443 (HTTPS)"                         "$(onoff "$A_HTTPS")" \
      3>&1 1>&2 2>&3); then
    A_UPGRADE=N; A_LOCKROOT=N; A_USBBLACK=N; A_SSH2FA=N; A_COMPILERS=N; A_HTTP=N; A_HTTPS=N
    for t in $sel; do t="${t//\"/}"; case "$t" in
      upgrade) A_UPGRADE=Y;; lockroot) A_LOCKROOT=Y;; usbblock) A_USBBLACK=Y;;
      ssh2fa) A_SSH2FA=Y;; compilers) A_COMPILERS=Y;; http) A_HTTP=Y;; https) A_HTTPS=Y;;
    esac; done
  fi
}
tui_harden() {
  local sel
  while true; do
    local items=("enabled" "[$(onoff3 "$A_HARDEN")]  run this step$([[ "$A_HARDEN" == Y ]] || echo ' — enable to configure')")
    if [[ "$A_HARDEN" == Y ]]; then
      items+=("components" "[ ✔ ]  hardening components: $(hc_count)/10 on")
      items+=("options"    "[ ✔ ]  extra options: $(opt_list)")
      items+=("sshport"    "[$(valic "$SSH_PORT" N)]  SSH port: $(valp "$SSH_PORT")")
      items+=("tcpports"   "[$(valic "$ALLOW_TCP_PORTS" N)]  extra TCP ports: $(valp "$ALLOW_TCP_PORTS")")
      items+=("udpports"   "[$(valic "$ALLOW_UDP_PORTS" N)]  extra UDP ports: $(valp "$ALLOW_UDP_PORTS")")
      items+=("cidrs"      "[ ✔ ]  SSH allowed from: ${ALLOW_SSH_CIDRS:-anywhere}")
    fi
    items+=(" " "────────────────────────────────────")
    items+=("help" "[ ? ]  what does each setting do?")
    sel=$(hubmenu "Setup › harden (security hardening)" $(( ${#items[@]} / 2 )) "${items[@]}") || break
    case "$sel" in
      enabled)    tgl A_HARDEN ;;
      components) tui_harden_components ;;
      options)    tui_harden_options ;;
      sshport)    ask "Setup › harden › SSH port" "SSH port (a random high port is suggested;\non a PVE host keep 22 for cluster ssh):" "${SSH_PORT:-22}" SSH_PORT ;;
      tcpports)   ask "Setup › harden › extra TCP ports" "Extra TCP ports to open (space-separated, blank for none):" "$ALLOW_TCP_PORTS" ALLOW_TCP_PORTS raw ;;
      udpports)   ask "Setup › harden › extra UDP ports" "Extra UDP ports to open (space-separated, blank for none):" "$ALLOW_UDP_PORTS" ALLOW_UDP_PORTS raw ;;
      help) show_help "Setup › harden › help" "components: which hardening subsystems run — SSH lockdown, nftables firewall, fail2ban, automatic security updates, persistent journald, AppArmor, AIDE, sysctl, extra Lynis fixes, closing audit. All on by default.

options: toggles within those components — apt full-upgrade, locking the root password (sudo still works), blacklisting usb-storage (disables USB drives), TOTP 2FA for SSH, restricting compilers to root, opening ports 80/443.

SSH port: where sshd listens. Keep 22 on a PVE host (cluster ssh assumes it); elsewhere a random high port cuts scan noise.

extra TCP/UDP ports: opened through the deny-by-default firewall — for YOUR OWN services and future container stacks. Ports needed by wizard-installed services (PVE web UI, Zabbix agent, the example app) are opened automatically by their own install steps.

SSH sources: limit which source networks may reach SSH at all (blank = anywhere)." ;;
      cidrs)      ask "Setup › harden › SSH sources" "Restrict SSH to these source CIDRs\n(space-separated, blank = allow from anywhere):" "$ALLOW_SSH_CIDRS" ALLOW_SSH_CIDRS raw ;;
    esac
  done
}

# --- ancillary ----------------------------------------------------------------
anc_list() {
  local p=()
  [[ "$A_PKG_vim" == Y ]] && p+=(vim); [[ "$A_PKG_btop" == Y ]] && p+=(btop)
  [[ "$A_PKG_duf" == Y ]] && p+=(duf); [[ "$A_PKG_fish" == Y ]] && p+=(fish)
  [[ "$A_PKG_rsync" == Y ]] && p+=(rsync); [[ "$A_PKG_qemu" == Y ]] && p+=(qemu)
  local IFS=,; printf '%s' "${p[*]:-none}"
}
tui_ancillary_packages() {
  local sel t
  if sel=$(whiptail --backtitle "$BACKTITLE" --title "Setup › packages › selection" \
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
  fi
}
tui_ancillary() {
  local sel
  while true; do
    local items=("enabled" "[$(onoff3 "$A_ANCILLARY")]  run this step$([[ "$A_ANCILLARY" == Y ]] || echo ' — enable to configure')")
    if [[ "$A_ANCILLARY" == Y ]]; then
      items+=("packages" "[$(valic "$( [[ "$(anc_list)" != none ]] && echo x )" "$A_ANCILLARY")]  packages: $(anc_list)")
      items+=("fish"     "[$(onoff3 "$A_FISH_DEFAULT")]  fish as the default shell (if picked)")
    fi
    items+=(" " "────────────────────────────────────")
    items+=("help" "[ ? ]  what does each setting do?")
    sel=$(hubmenu "Setup › packages (extra packages)" $(( ${#items[@]} / 2 )) "${items[@]}") || break
    case "$sel" in
      enabled)  tgl A_ANCILLARY ;;
      packages) tui_ancillary_packages ;;
      help) show_help "Setup › packages › help" "packages: quality-of-life tools — vim, btop (resource monitor), duf (disk usage), fish (shell), rsync, and the QEMU guest agent (useful only inside a VM: enables clean shutdown, IP reporting and snapshots from the host).

fish as the default shell: switches the admin user's login shell to fish once it is installed." ;;
      fish)     tgl A_FISH_DEFAULT ;;
    esac
  done
}

# --- monitoring: a hub of services, each service the same sub-hub pattern -----
tui_svc_zabbix() {
  local sel
  while true; do
    local items=("enabled" "[$(onoff3 "$A_AGENT_zabbix")]  install this service$([[ "$A_AGENT_zabbix" == Y ]] || echo ' — enable to configure')")
    if [[ "$A_AGENT_zabbix" == Y ]]; then
      items+=("server"  "[$(valic "$ZABBIX_SERVER_ACTIVE" "$A_AGENT_zabbix")]  Zabbix server: $(valp "$ZABBIX_SERVER_ACTIVE")")
      items+=("docker"  "[$(onoff3 "$A_ZBX_DOCKER")]  monitor rootless Docker")
    fi
    items+=(" " "────────────────────────────────────")
    items+=("help" "[ ? ]  what does each setting do?")
    sel=$(hubmenu "Setup › monitoring › zabbix (metrics agent)" $(( ${#items[@]} / 2 )) "${items[@]}") || break
    case "$sel" in
      enabled) tgl A_AGENT_zabbix ;;
      server)  ask "Setup › monitoring › zabbix › server" "Zabbix server/proxy for active checks (host or host:port):" "${ZABBIX_SERVER_ACTIVE:-zabbix:10051}" ZABBIX_SERVER_ACTIVE ;;
      help) show_help "Setup › monitoring › zabbix › help" "install this service: adds Zabbix's apt repo and installs zabbix-agent2.

Zabbix server: the server/proxy the agent reports to for active checks (host or host:port). The host must also be added on the Zabbix server side.

monitor rootless Docker: rootless Docker's API socket lives in the owner's runtime dir, which the agent normally cannot reach. This points the Docker plugin at that socket, enables lingering, and runs the agent as that user so container metrics work." ;;
      docker)  tgl A_ZBX_DOCKER ;;
    esac
  done
}
tui_svc_alloy() {
  local sel
  while true; do
    local items=("enabled" "[$(onoff3 "$A_AGENT_alloy")]  install this service$([[ "$A_AGENT_alloy" == Y ]] || echo ' — enable to configure')")
    if [[ "$A_AGENT_alloy" == Y ]]; then
      items+=("loki"       "[$(valic "$LOKI_URL" "$A_AGENT_alloy")]  Loki URL: $(valp "$LOKI_URL")")
      items+=("dockerlogs" "[$(onoff3 "$A_ALLOY_DOCKERLOGS")]  capture Docker container logs")
    fi
    items+=(" " "────────────────────────────────────")
    items+=("help" "[ ? ]  what does each setting do?")
    sel=$(hubmenu "Setup › monitoring › alloy (log shipper)" $(( ${#items[@]} / 2 )) "${items[@]}") || break
    case "$sel" in
      enabled)    tgl A_AGENT_alloy ;;
      loki)       ask "Setup › monitoring › alloy › Loki URL" "Loki base URL for Alloy (host:port):" "${LOKI_URL:-loki:3100}" LOKI_URL ;;
      help) show_help "Setup › monitoring › alloy › help" "install this service: adds Grafana's apt repo and installs Alloy, a journal-first log shipper.

Loki URL: the Loki server Alloy pushes logs to (host:port; the /loki/api/v1/push path is appended automatically).

capture Docker container logs: also ships container output to Loki. It works by pointing Docker at the journald log-driver, so container stdout/stderr lands in the systemd journal like any other log — no Docker socket access needed, and it works for rootful AND rootless Docker. Lines arrive tagged with container/image and Compose project/service labels, so you can query {compose_project=\"media\"} in Grafana. Running containers must be recreated once to adopt the driver." ;;
      dockerlogs) tgl A_ALLOY_DOCKERLOGS ;;
    esac
  done
}
tui_svc_buzz() {
  local sel t v cur
  while true; do
    cur="$BUZZ_TARGET"; [[ -n "$cur" && "${BUZZ_PORT:-6523}" != "6523" ]] && cur="${cur}:${BUZZ_PORT}"
    local items=("enabled" "[$(onoff3 "$A_AGENT_buzz")]  install this service$([[ "$A_AGENT_buzz" == Y ]] || echo ' — enable to configure')")
    if [[ "$A_AGENT_buzz" == Y ]]; then
      items+=("alerts"  "[$(valic "$( [[ "$(buzz_alert_list)" != none ]] && echo x )" "$A_AGENT_buzz")]  alerts: $(buzz_alert_list)")
      items+=("relay"   "[$(valic "$BUZZ_TARGET" "$A_AGENT_buzz")]  relay address: $(valp "$cur")")
    fi
    items+=(" " "────────────────────────────────────")
    items+=("help" "[ ? ]  what does each setting do?")
    sel=$(hubmenu "Setup › monitoring › buzz (alert relay)" $(( ${#items[@]} / 2 )) "${items[@]}") || break
    case "$sel" in
      enabled) tgl A_AGENT_buzz ;;
      alerts)
        if sel=$(whiptail --backtitle "$BACKTITLE" --title "Setup › monitoring › buzz › alerts" \
            --checklist "Which alerts should this node send? (Space to toggle)\nrepl/ha/tbmesh install only where their tooling exists." 14 76 4 \
            "disk"   "Disk health: SMART + zpool errors (daily)"       "$(onoff "$A_BUZZ_disk")" \
            "repl"   "Proxmox replication failures (every 30 min)"     "$(onoff "$A_BUZZ_repl")" \
            "ha"     "Proxmox HA recover/migrate events (every 5 min)" "$(onoff "$A_BUZZ_ha")" \
            "tbmesh" "Thunderbolt mesh auto-heal actions (every min)"  "$(onoff "$A_BUZZ_tbmesh")" \
            3>&1 1>&2 2>&3); then
          A_BUZZ_disk=N; A_BUZZ_repl=N; A_BUZZ_ha=N; A_BUZZ_tbmesh=N
          for t in $sel; do t="${t//\"/}"; case "$t" in disk) A_BUZZ_disk=Y;; repl) A_BUZZ_repl=Y;; ha) A_BUZZ_ha=Y;; tbmesh) A_BUZZ_tbmesh=Y;; esac; done
        fi ;;
      relay)
        if v=$(whiptail --backtitle "$BACKTITLE" --title "Setup › monitoring › buzz › relay address" \
            --inputbox "Where do the watches ssh their alerts to?\n\nuser@host, or user@host:port (port defaults to 6523).\nExample: jordan@192.168.16.100:6523\n\nA dedicated key is generated on this node; register its\npublic key on the relay afterward (shown in NEXT STEPS).\n\n(Cancel keeps the current value.)" 17 68 "$cur" 3>&1 1>&2 2>&3); then
          v="${v//[[:space:]]/}"
          if [[ "$v" =~ ^([^:]+@[^:]+):([0-9]+)$ ]]; then
            BUZZ_TARGET="${BASH_REMATCH[1]}"; BUZZ_PORT="${BASH_REMATCH[2]}"
          else
            BUZZ_TARGET="$v"; BUZZ_PORT="${BUZZ_PORT:-6523}"
          fi
        fi ;;
      help) show_help "Setup › monitoring › buzz › help" "install this service: generates a dedicated ssh key (/root/.ssh/buzz_report) and installs the selected watch scripts with their crons. Alerts only start flowing after you register the printed public key on the relay (shown in NEXT STEPS).

alerts: disk = SMART + zpool health, daily, any host. repl = Proxmox replication failures, every 30 min. ha = Proxmox HA recover/migrate events, every 5 min. tbmesh = Thunderbolt mesh auto-heal actions, every minute. The Proxmox and mesh watches install only where their tooling exists, so over-selecting is harmless.

relay address: the dev box the watches ssh their alerts to, as user@host or user@host:port (default port 6523)." ;;
    esac
  done
}
tui_monitoring() {
  local sel
  while true; do
    sel=$(hubmenu "Setup › monitoring (monitoring & alerts)" 5 \
      "zabbix" "[$(stat3 "$A_AGENT_zabbix" "$(need_zabbix)")]  metrics agent" \
      "alloy"  "[$(stat3 "$A_AGENT_alloy" "")]  log shipper" \
      "buzz"   "[$(stat3 "$A_AGENT_buzz" "$(need_buzz)")]  alert relay" \
      " "        "────────────────────────────────────" \
      "help"     "[ ? ]  what does each setting do?" \
      ) || break
    case "$sel" in
      zabbix) tui_svc_zabbix ;;
      alloy)  tui_svc_alloy ;;
      help) show_help "Setup › monitoring › help" "zabbix: installs Zabbix agent 2, which reports metrics (CPU, memory, disks, services) to a central Zabbix server for dashboards and alerting.

alloy: installs Grafana Alloy, which ships this host's logs (systemd journal first) to a Loki server so they are searchable in Grafana.

buzz: sets this host up to send alerts (disk health, Proxmox replication/HA, Thunderbolt mesh) to a buzz relay over forced-command ssh. Needs its key registered on the relay afterward." ;;
      buzz)   tui_svc_buzz ;;
    esac
  done
  [[ "$A_AGENT_zabbix" == Y || "$A_AGENT_alloy" == Y || "$A_AGENT_buzz" == Y ]] && A_MONITORING=Y || A_MONITORING=N
}

# --- container ----------------------------------------------------------------
rt_list() {
  local p=(); [[ "$A_DOCKER" == Y ]] && p+=(docker); [[ "$A_PODMAN" == Y ]] && p+=(podman)
  local IFS=,; printf '%s' "${p[*]:-none}"
}
tui_container() {
  local sel t
  while true; do
    local items=("enabled" "[$(onoff3 "$A_CONTAINER")]  run this step$([[ "$A_CONTAINER" == Y ]] || echo ' — enable to configure')")
    if [[ "$A_CONTAINER" == Y ]]; then
      items+=("runtimes" "[$(valic "$( [[ "$(rt_list)" != none ]] && echo x )" "$A_CONTAINER")]  runtimes: $(rt_list)")
      items+=("rootful"  "[$(onoff3 "$A_DISABLE_ROOTFUL")]  rootless only (no root Docker daemon)")
      items+=("example"  "[$(onoff3 "$A_EXAMPLE_APP")]  example app (traefik/whoami on :8080)")
      items+=("journald" "[$(onoff3 "$A_JOURNALD")]  container logs to the journal")
    fi
    items+=(" " "────────────────────────────────────")
    items+=("help" "[ ? ]  what does each setting do?")
    sel=$(hubmenu "Setup › container (Docker / Podman)" $(( ${#items[@]} / 2 )) "${items[@]}") || break
    case "$sel" in
      enabled)  tgl A_CONTAINER ;;
      runtimes)
        if t=$(whiptail --backtitle "$BACKTITLE" --title "Setup › container › runtimes" \
            --checklist "Choose runtime(s) (Space to toggle):" 11 66 2 \
            "docker" "Docker Engine + Compose (rootless)" "$(onoff "$A_DOCKER")" \
            "podman" "Podman (daemonless, rootless)"      "$(onoff "$A_PODMAN")" \
            3>&1 1>&2 2>&3); then
          A_DOCKER=N; A_PODMAN=N
          local x; for x in $t; do x="${x//\"/}"; case "$x" in docker) A_DOCKER=Y;; podman) A_PODMAN=Y;; esac; done
        fi ;;
      rootful)  tgl A_DISABLE_ROOTFUL ;;
      example)  tgl A_EXAMPLE_APP ;;
      help) show_help "Setup › container › help" "runtimes: Docker (Engine + Compose, rootless by default) and/or Podman (daemonless, rootless). They coexist; the podman-docker shim is never installed.

disable the rootful Docker daemon: keeps only the per-user rootless daemon running, shrinking the root attack surface.

create the example app: drops a minimal traefik/whoami stack in /opt/docker/example-app (port 8080) so the layout has a working reference.

container logs to the journal: sets the journald log-driver so container output flows into the systemd journal (and on to Loki via Alloy if configured)." ;;
      journald) tgl A_JOURNALD ;;
    esac
  done
}

# --- motd / docs --------------------------------------------------------------
tui_motd() {
  local sel
  while true; do
    local items=("enabled" "[$(onoff3 "$A_MOTD")]  run this step$([[ "$A_MOTD" == Y ]] || echo ' — enable to configure')")
    if [[ "$A_MOTD" == Y ]]; then
      items+=("docurl"  "[$(valic "$DOC_URL" N)]  wiki/docs link in the banner: $(valp "$DOC_URL")")
    fi
    items+=(" " "────────────────────────────────────")
    items+=("help" "[ ? ]  what does each setting do?")
    sel=$(hubmenu "Setup › banner (login banner)" $(( ${#items[@]} / 2 )) "${items[@]}") || break
    case "$sel" in
      enabled) tgl A_MOTD ;;
      help) show_help "Setup › banner › help" "run this step: installs a dynamic login banner showing host, IP, uptime, OS/kernel, load, memory, disk and sessions on every SSH login.

documentation URL: an optional link shown in the banner (your wiki page for this host, say). Blank omits it." ;;
      docurl)  ask "Setup › banner › docs link" "Documentation URL to show in the banner (blank to omit):" "$DOC_URL" DOC_URL ;;
    esac
  done
}
tui_docs() {
  local sel
  while true; do
    sel=$(hubmenu "Setup › docs (connection guide)" 3 \
      "enabled" "[$(onoff3 "$A_DOC")]  run this step" \
      " "        "────────────────────────────────────" \
      "help"     "[ ? ]  what does each setting do?" \
      ) || break
    case "$sel" in
      enabled) tgl A_DOC ;;
      help) show_help "Setup › docs › help" "run this step: generates an HTML connection doc (written to /var/lib/homelab-bootstrap/connect.html when run via this wizard) with the host's details and exactly how to SSH in on the hardened port — including a ready-made ~/.ssh/config entry and a fish alias. Handy to paste into your wiki after setup." ;;
    esac
  done
}

# tui_main — the hub: a menu of every step + its state; Accept installs.
tui_main() {
  local sel
  while true; do
    sel=$(whiptail --backtitle "$BACKTITLE" --title "Setup  —  [${ENV_TYPE^^}]" \
      --ok-button "Open" --cancel-button "Quit" \
      --menu "${MENU_HINT}"$'\n'"Defaults are pre-set — choose Accept to install as-is." 21 78 11 \
      "user"       "[$(stat3 "$A_BOOTSTRAP" "$(need_bootstrap)")]  admin user + SSH key" \
      "harden"     "[$(stat3 "$A_HARDEN" "$(need_harden)")]  security hardening" \
      "packages"   "[$(stat3 "$A_ANCILLARY" "$(need_ancillary)")]  extra packages" \
      "monitoring" "[$(stat3 "$A_MONITORING" "$(need_monitoring)")]  monitoring & alerts" \
      "container"  "[$(stat3 "$A_CONTAINER" "$(need_container)")]  Docker / Podman" \
      "banner"     "[$(stat3 "$A_MOTD" "")]  login banner (MOTD)" \
      "docs"       "[$(stat3 "$A_DOC" "")]  connection guide" \
      " "          "────────────────────────────────────" \
      "help"       "[ ? ]  what does each step do?" \
      "  "         "────────────────────────────────────" \
      "ACCEPT"     "✓  Accept these settings and install" \
      3>&1 1>&2 2>&3) || { if whiptail --backtitle "$BACKTITLE" --yesno "Quit without installing?" 8 50; then clear; info "Cancelled — nothing was changed."; exit 0; fi; continue; }
    case "$sel" in
      user)       tui_bootstrap ;;
      harden)     tui_harden ;;
      packages)   tui_ancillary ;;
      monitoring) tui_monitoring ;;
      container)  tui_container ;;
      banner)     tui_motd ;;
      docs)       tui_docs ;;
      help) show_help "Setup › help" "user: creates/updates the admin user and installs its SSH key — runs first; security hardening relies on it.

harden: security hardening — SSH lockdown, deny-by-default firewall, fail2ban, automatic updates, AppArmor, AIDE, sysctl, Lynis. Components and options are pickable inside.

packages: quality-of-life tools (vim, btop, duf, fish, rsync, guest agent).

monitoring: Zabbix metrics agent, Grafana Alloy log shipper, and buzz relay alerting — each configured in its own screen.

container: Docker and/or Podman, rootless, plus the /opt/docker layout.

banner: dynamic login banner (MOTD) with live host info on every login.

docs: generates an HTML connection guide for this host." ;;
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
    # The admin password is only bootstrap.sh's business — do not leave it in
    # the environment of every later script (their child processes expose
    # /proc/<pid>/environ to the users they run as).
    [[ "$s" == "bootstrap.sh" && -n "${ADMIN_PASSWORD:-}" ]] && { unset ADMIN_PASSWORD; export -n ADMIN_PASSWORD 2>/dev/null || true; }
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
