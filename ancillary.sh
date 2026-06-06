#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — ancillary
#  Installs extra/quality-of-life packages and sets up the fish shell.
#
#  - Installs a selectable set of packages: btop, fish, rsync, qemu-guest-agent,
#    zabbix-agent2, alloy. By default (standalone run) it installs them all;
#    init.sh's wizard lets you pick a subset and passes it via ANCILLARY_PKGS.
#  - qemu-guest-agent (if selected) is started only when run inside a QEMU/KVM
#    guest with the guest-agent channel; otherwise it's left inactive.
#  - zabbix-agent2 (if selected) adds Zabbix's official apt repo, installs the
#    agent, and writes a custom config with this host's name and the Zabbix
#    server address (ZABBIX_SERVER_ACTIVE, or asked when run interactively).
#  - alloy (if selected) adds Grafana's official apt repo, installs Grafana
#    Alloy, and writes a journal-first log-shipping config pointing at the Loki
#    server (LOKI_URL, or asked when run interactively; defaults to localhost).
#  - fish shell (if selected): if harden.sh NEWLY created user(s) this run, fish
#    is made their default shell automatically. Otherwise it asks which current
#    users should get fish as their default shell. Affected users get it as their
#    DEFAULT login shell.
#
#  Run as root, e.g.  sudo ./ancillary.sh
#
#  Environment overrides:
#    ANCILLARY_PKGS="btop rsync ..." -> install exactly these (or "none" for
#                                       nothing); unset = the full default set
#    FISH_USERS="u1 u2 ..." -> set fish for exactly these users (skips prompts)
#    ZABBIX_SERVER_ACTIVE="host[:port]" -> Zabbix server/proxy for active checks
#                                       (required when zabbix-agent2 is selected;
#                                       asked interactively if unset)
#    LOKI_URL="scheme://host:port" -> Loki base URL for Alloy to push to
#                                       (used when alloy is selected; asked
#                                       interactively, defaults to localhost:3100)
#    DRY_RUN=1|0            -> force preview / actual (else asks)
#    ASSUME_YES=1           -> answer "yes" to every prompt (automation)
# ==============================================================================

set -euo pipefail

# Ensure sbin paths are present even under non-login shells / restricted sudo.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# Directory this script lives in — used to find bundled assets (alloy/config.alloy).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Config templates. Default to the copies alongside this script; if absent
# (e.g. this script was downloaded on its own), they're fetched from the repo.
ALLOY_CONFIG_SRC="${ALLOY_CONFIG_SRC:-${SCRIPT_DIR}/alloy/config.alloy}"
ZBX_CONFIG_SRC="${ZBX_CONFIG_SRC:-${SCRIPT_DIR}/zabbix/zabbix_agent2.conf}"
# Raw base URL used to fetch the Alloy template when it isn't present locally.
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main}"

ASSUME_YES="${ASSUME_YES:-0}"
FISH_USERS="${FISH_USERS:-}"

if [[ -n "${DRY_RUN+x}" ]]; then DRY_RUN_EXPLICIT=1; else DRY_RUN_EXPLICIT=0; fi
DRY_RUN="${DRY_RUN:-}"

START_TS="$(date +%s)"

# All packages this installer knows how to install (slug -> short description).
declare -A PKG_DESC=(
  [btop]="resource monitor (htop-like)"
  [fish]="friendly interactive shell"
  [rsync]="fast file copy / sync"
  [qemu-guest-agent]="QEMU/KVM guest integration (VMs only)"
  [zabbix-agent2]="Zabbix agent 2 monitoring (needs a Zabbix server)"
  [alloy]="Grafana Alloy log shipper (needs a Loki server)"
)
ALL_PKGS=(btop fish rsync qemu-guest-agent zabbix-agent2 alloy)

# Zabbix agent 2 specifics (its own repo + custom config; see the step below).
ZBX_VERSION="7.4"
ZBX_CONF="/etc/zabbix/zabbix_agent2.conf"
ZBX_SERVER_ACTIVE="${ZABBIX_SERVER_ACTIVE:-}"

# Grafana Alloy specifics (Grafana's apt repo + custom config; see the step below).
ALLOY_CONF="/etc/alloy/config.alloy"
# Base URL of the Loki server (scheme://host:port, no path). Required when alloy
# is selected; asked interactively if unset. The /loki/api/v1/push path is added
# automatically in the config template.
LOKI_URL="${LOKI_URL:-}"

# Which packages to install. ANCILLARY_PKGS (space-separated list, or "none")
# overrides the selection — init.sh sets it from the wizard's package picker.
# Unset = install the full default set (so a standalone run behaves as before).
if [[ "${ANCILLARY_PKGS+x}" == "x" ]]; then
  if [[ "${ANCILLARY_PKGS,,}" == "none" || -z "${ANCILLARY_PKGS// /}" ]]; then
    SELECTED_PKGS=()
  else
    read -ra SELECTED_PKGS <<< "$ANCILLARY_PKGS"
  fi
else
  SELECTED_PKGS=("${ALL_PKGS[@]}")
fi
pkg_selected() { local p; for p in "${SELECTED_PKGS[@]}"; do [[ "$p" == "$1" ]] && return 0; done; return 1; }

# State written by harden.sh: users it NEWLY created this round.
CREATED_USERS_FILE="/var/lib/homelab-bootstrap/created-users"

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
S_OK="✔"; S_INFO="•"; S_WARN="!"; S_ERR="✗"; S_STEP="▸"

STEP_NO=0
# Steps shown depend on what's selected: packages (always) + QEMU + Zabbix + fish.
TOTAL_STEPS=1
pkg_selected qemu-guest-agent && TOTAL_STEPS=$((TOTAL_STEPS + 1))
pkg_selected zabbix-agent2    && TOTAL_STEPS=$((TOTAL_STEPS + 1))
pkg_selected alloy           && TOTAL_STEPS=$((TOTAL_STEPS + 1))
pkg_selected fish            && TOTAL_STEPS=$((TOTAL_STEPS + 1))
SUMMARY=()
record() { SUMMARY+=("$1"$'\t'"$2"); }

hr()   { local ch="${1:-─}" w=72 l=""; printf -v l '%*s' "$w" ''; printf '%s%s%s\n' "$DIM" "${l// /$ch}" "$RESET"; }
banner() {
  STEP_NO=$((STEP_NO + 1)); printf '\n'; hr '═'
  printf '%s%s STEP %d/%d %s %s%s\n' "$BOLD$CYN" "$S_STEP" "$STEP_NO" "$TOTAL_STEPS" "│" "$*" "$RESET"; hr '═'
}
header() { printf '\n'; hr '═'; printf '%s%s %s%s\n' "$BOLD$CYN" "$S_STEP" "$*" "$RESET"; hr '═'; }
log()  { printf '%s%s%s %s\n' "$GRN" "$S_OK"   "$RESET" "$*"; }
info() { printf '%s%s%s %s\n' "$BLU" "$S_INFO" "$RESET" "$*"; }
warn() { printf '%s%s %s%s\n' "$YEL" "$S_WARN" "$*" "$RESET"; }
err()  { printf '%s%s %s%s\n' "$RED" "$S_ERR" "$*" "$RESET" >&2; }
note() { printf '   %s%s%s\n' "$DIM" "$*" "$RESET"; }
dry()  { printf '   %s[dry-run]%s %s\n' "$MAG" "$RESET" "$*"; }

run() { if [[ "$DRY_RUN" == "1" ]]; then dry "$*"; return 0; fi; "$@"; }

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
  printf '\n%s%sHow do you want to run the ancillary installer?%s\n' "$BOLD" "$WHT" "$RESET" > /dev/tty
  printf '   %s[1]%s %sDry run%s — preview, change NOTHING (recommended first)\n' "$BOLD" "$RESET" "$GRN" "$RESET" > /dev/tty
  printf '   %s[2]%s %sActual run%s — install & configure\n' "$BOLD" "$RESET" "$RED" "$RESET" > /dev/tty
  printf '%s%s Choose 1 or 2 [default: 1]: %s' "$YEL" "$S_WARN" "$RESET" > /dev/tty
  read -r choice < /dev/tty || choice=""
  case "${choice:-1}" in 2) DRY_RUN=0 ;; *) DRY_RUN=1 ;; esac
}

# set_fish_default <user> — ensure fish is in /etc/shells, then chsh the user.
set_fish_default() {
  local user="$1" fish_path
  fish_path="$(command -v fish 2>/dev/null || echo /usr/bin/fish)"
  if [[ "$DRY_RUN" == "1" ]]; then
    dry "ensure ${fish_path} in /etc/shells; chsh -s ${fish_path} ${user}"
    record "fish:${user}" "[dry-run] would set fish as default shell"
    return 0
  fi
  if ! grep -qxF "$fish_path" /etc/shells 2>/dev/null; then
    printf '%s\n' "$fish_path" >> /etc/shells
    log "Added ${fish_path} to /etc/shells."
  fi
  local cur; cur="$(getent passwd "$user" | cut -d: -f7)"
  if [[ "$cur" == "$fish_path" ]]; then
    log "${user}'s default shell is already fish."
    record "fish:${user}" "already default (${fish_path})"
  else
    chsh -s "$fish_path" "$user"
    log "Set ${user}'s default shell to ${fish_path}."
    record "fish:${user}" "default shell set to ${fish_path}"
  fi
}

# resolve_template <local_src> <repo_relpath> — locate a config template. Sets
# RESOLVED_TEMPLATE to a readable path: the local copy alongside this script if
# present, otherwise a freshly downloaded temp copy fetched from the repo (for
# the case where this script was downloaded on its own). RESOLVED_TEMPLATE_IS_TMP
# is 1 when it downloaded (so the caller knows to rm it). Returns non-zero if the
# template is neither local nor fetchable.
RESOLVED_TEMPLATE=""
RESOLVED_TEMPLATE_IS_TMP=0
resolve_template() {
  local src="$1" rel="$2" url tmp
  RESOLVED_TEMPLATE=""; RESOLVED_TEMPLATE_IS_TMP=0
  if [[ -r "$src" ]]; then
    RESOLVED_TEMPLATE="$src"
    return 0
  fi
  url="${REPO_RAW_BASE}/${rel}"
  tmp="$(mktemp)"
  if command -v curl >/dev/null 2>&1 && curl -fsSL "$url" -o "$tmp"; then
    RESOLVED_TEMPLATE="$tmp"; RESOLVED_TEMPLATE_IS_TMP=1; return 0
  elif command -v wget >/dev/null 2>&1 && wget -qO "$tmp" "$url"; then
    RESOLVED_TEMPLATE="$tmp"; RESOLVED_TEMPLATE_IS_TMP=1; return 0
  fi
  rm -f "$tmp"
  err "Config template not found at ${src} and could not be fetched from ${url}."
  return 1
}

# write_zabbix_conf <target> <hostname> <serveractive> <virtualized> — render the
# custom zabbix_agent2.conf to <target>, substituting this host's name and the
# Zabbix server address into the two relevant lines. The cpuTemperature
# UserParameter's key prefix is rewritten from pve2 to this host's name; on a
# VM/container it's commented out (no real CPU thermal sensors there). The
# template is zabbix/zabbix_agent2.conf alongside this script (or fetched from
# the repo); awk -v then swaps the values safely regardless of characters they
# contain. Returns non-zero if the template can't be found.
write_zabbix_conf() {
  local target="$1" hn="$2" sa="$3" virt="${4:-0}"
  resolve_template "$ZBX_CONFIG_SRC" "zabbix/zabbix_agent2.conf" || return 1
  awk -v hn="$hn" -v sa="$sa" -v virt="$virt" '
    /^Hostname=machine001$/       { print "Hostname=" hn; next }
    /^ServerActive=zabbix:10051$/ { print "ServerActive=" sa; next }
    /^UserParameter=pve2\.cpuTemperature,/ {
      sub(/^UserParameter=pve2\./, "UserParameter=" hn ".")   # key prefix -> hostname
      if (virt == "1") $0 = "#" $0                            # VM/container: no CPU sensors
      print; next
    }
    { print }
  ' "$RESOLVED_TEMPLATE" > "$target"
  [[ "$RESOLVED_TEMPLATE_IS_TMP" == "1" ]] && rm -f "$RESOLVED_TEMPLATE"
  return 0
}

# write_alloy_conf <target> <loki_base_url> — render the journal-first Alloy
# config to <target>, substituting the Loki base URL into the loki.write
# endpoint (awk swaps the @@LOKI_ENDPOINT@@ token for the URL, safe regardless
# of the / and : it contains). Returns non-zero if the template can't be found.
write_alloy_conf() {
  local target="$1" url="$2"
  resolve_template "$ALLOY_CONFIG_SRC" "alloy/config.alloy" || return 1
  awk -v url="$url" '{ gsub(/@@LOKI_ENDPOINT@@/, url); print }' "$RESOLVED_TEMPLATE" > "$target"
  [[ "$RESOLVED_TEMPLATE_IS_TMP" == "1" ]] && rm -f "$RESOLVED_TEMPLATE"
  return 0
}

# ==============================================================================
#  Splash
# ==============================================================================
# Don't wipe the terminal when run nested by init.sh — keep the previous
# script's output visible. (BOOTSTRAP_NESTED is set by init.sh.)
[[ "${BOOTSTRAP_NESTED:-0}" == "1" ]] || clear 2>/dev/null || true
printf '%s%s  Debian 13 Homelab Bootstrap — ancillary (extra packages + fish)%s\n' "$BOLD" "$CYN" "$RESET"
hr '─'

require_root
if ! command -v apt-get >/dev/null 2>&1; then err "apt-get not found — this targets Debian/apt systems."; exit 1; fi
choose_run_mode

if [[ "$DRY_RUN" == "1" ]]; then info "Mode: ${MAG}DRY RUN (no changes)${RESET}"; else info "Mode: ${RED}ACTUAL RUN${RESET}"; fi
hr '─'

info "Packages to install: ${BOLD}${SELECTED_PKGS[*]:-<none>}${RESET}"
hr '─'

# ==============================================================================
#  Decide which users get fish (before installing, so the recap is accurate)
# ==============================================================================
FISH_TARGETS=()

if ! pkg_selected fish; then
  info "fish not selected — no default-shell changes."
elif [[ "${FISH_USERS,,}" == "none" ]]; then
  # Explicit opt-out — change no shells.
  info "fish default-shell change disabled (FISH_USERS=none)."
elif [[ -n "$FISH_USERS" ]]; then
  # Explicit override.
  read -ra FISH_TARGETS <<< "$FISH_USERS"
  info "fish users from FISH_USERS: ${BOLD}${FISH_TARGETS[*]}${RESET}"
elif [[ -s "$CREATED_USERS_FILE" ]]; then
  # harden.sh created user(s) this round → fish for them automatically.
  mapfile -t FISH_TARGETS < <(awk 'NF' "$CREATED_USERS_FILE" | sort -u)
  info "harden.sh newly created: ${BOLD}${FISH_TARGETS[*]:-<none>}${RESET}"
  note "fish will be installed and set as the default shell for the above user(s)."
else
  # No newly-created users recorded → ask which current users want fish.
  info "No newly-created users were recorded by harden.sh (${CREATED_USERS_FILE})."
  mapfile -t HUMAN_USERS < <(awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | sort)
  if (( ${#HUMAN_USERS[@]} == 0 )); then
    warn "No regular (human) user accounts found to offer fish to."
  elif [[ "$INTERACTIVE" -eq 1 || "$ASSUME_YES" == "1" ]]; then
    info "Choose which existing users should get fish as their default shell:"
    for u in "${HUMAN_USERS[@]}"; do
      confirm "Set fish as the default shell for '${u}'?" N && FISH_TARGETS+=("$u")
    done
  else
    note "Non-interactive with no FISH_USERS set — skipping fish shell changes."
  fi
fi

# qemu-guest-agent, zabbix-agent2 and alloy have their own steps below; install the rest here.
APT_PKGS=()
for p in "${SELECTED_PKGS[@]}"; do
  case "$p" in qemu-guest-agent|zabbix-agent2|alloy) ;; *) APT_PKGS+=("$p");; esac
done

# ==============================================================================
banner "Installing extra packages"
# ==============================================================================
export DEBIAN_FRONTEND=noninteractive
if (( ${#SELECTED_PKGS[@]} == 0 )); then
  note "No packages selected — nothing to install."
  record "Packages" "none selected"
elif (( ${#APT_PKGS[@]} == 0 )); then
  info "Refreshing package lists..."
  run apt-get update
  note "Only qemu-guest-agent selected — it's installed in the next step."
else
  info "Refreshing package lists..."
  run apt-get update
  info "Installing: ${DIM}${APT_PKGS[*]}${RESET}"
  run apt-get install -y "${APT_PKGS[@]}"
  _desc=""; for p in "${APT_PKGS[@]}"; do _desc+="${p} = ${PKG_DESC[$p]:-extra package}; "; done
  log "Installed: ${APT_PKGS[*]} (${_desc%; })."
  record "Packages" "installed: ${APT_PKGS[*]}"
fi

# ==============================================================================
if pkg_selected qemu-guest-agent; then
banner "Installing the QEMU guest agent"
# ==============================================================================
info "Ensuring qemu-guest-agent is installed..."
run apt-get install -y qemu-guest-agent
# qemu-guest-agent.service is a STATIC unit (no [Install] section): it is started
# automatically by udev when the host attaches the guest-agent virtio-serial
# channel. So we do NOT 'enable' it (that just errors) — we only 'start' it when
# we're actually a QEMU/KVM guest. On bare metal it simply stays inactive.
QEMU_ACTIVE=0   # tracks whether the guest agent ended up running
if [[ "$DRY_RUN" == "1" ]]; then
  dry "start qemu-guest-agent only if the guest-agent channel is present"
  record "Guest agent" "[dry-run] would install qemu-guest-agent"
else
  VIRT="$(systemd-detect-virt 2>/dev/null || true)"; [[ -n "$VIRT" ]] || VIRT="none"
  if systemctl is-active --quiet qemu-guest-agent 2>/dev/null; then
    log "qemu-guest-agent already active (virt: ${VIRT})."
    record "Guest agent" "active (${VIRT})"; QEMU_ACTIVE=1
  elif [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
    # Only start when the channel device exists, so the .device dependency is
    # satisfiable (otherwise systemctl start fails with a dependency error).
    systemctl start qemu-guest-agent >/dev/null 2>&1 || true
    if systemctl is-active --quiet qemu-guest-agent 2>/dev/null; then
      log "qemu-guest-agent started (virt: ${VIRT})."
      record "Guest agent" "active (${VIRT})"; QEMU_ACTIVE=1
    else
      note "qemu-guest-agent installed; the guest-agent channel is present but it did not start."
      record "Guest agent" "installed (start failed)"
    fi
  else
    # No virtio guest-agent channel: nothing to start. udev auto-activates the
    # (static) service if/when the host ever attaches the channel.
    note "qemu-guest-agent installed; no guest-agent channel attached (virt: ${VIRT}) — left inactive."
    record "Guest agent" "installed (inactive; no agent channel)"
  fi
fi
fi   # end: pkg_selected qemu-guest-agent

# ==============================================================================
if pkg_selected zabbix-agent2; then
banner "Installing Zabbix agent 2"
# ==============================================================================
# Follows the official agent install: add Zabbix's apt repo, install the agent,
# then drop in the custom config (Hostname = this host; ServerActive = the
# address provided). See https://www.zabbix.com/documentation/7.4/en/manual/concepts/agent
ZBX_HOSTNAME="$(hostname)"

# CPU thermal sensors only exist on bare metal. If this is a VM or a container
# (LXC/etc.), the cpuTemperature UserParameter is commented out in the config.
ZBX_VIRT=0
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q 2>/dev/null; then
  ZBX_VIRT=1
fi

# Resolve the Zabbix server address for active checks — required, no default.
if [[ -z "$ZBX_SERVER_ACTIVE" ]]; then
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    while [[ -z "$ZBX_SERVER_ACTIVE" ]]; do
      printf '%s%s Zabbix server/proxy for active checks (host or host:port, e.g. zbx.example.com:10051): %s' \
        "$YEL" "$S_INFO" "$RESET" > /dev/tty
      read -r ZBX_SERVER_ACTIVE < /dev/tty || ZBX_SERVER_ACTIVE=""
      ZBX_SERVER_ACTIVE="${ZBX_SERVER_ACTIVE//[[:space:]]/}"
    done
  fi
fi

if [[ -z "$ZBX_SERVER_ACTIVE" ]]; then
  warn "No Zabbix server address provided (set ZABBIX_SERVER_ACTIVE=host:port) — skipping zabbix-agent2."
  record "Zabbix agent 2" "skipped (no ZABBIX_SERVER_ACTIVE)"
elif [[ "$DRY_RUN" == "1" ]]; then
  dry "add Zabbix ${ZBX_VERSION} apt repo, then apt-get install zabbix-agent2 inxi"
  if [[ -r "$ZBX_CONFIG_SRC" ]]; then
    dry "render ${ZBX_CONFIG_SRC} -> ${ZBX_CONF} with Hostname=${ZBX_HOSTNAME} and ServerActive=${ZBX_SERVER_ACTIVE}"
  else
    dry "fetch zabbix/zabbix_agent2.conf from repo -> ${ZBX_CONF} with Hostname=${ZBX_HOSTNAME} and ServerActive=${ZBX_SERVER_ACTIVE}"
  fi
  if [[ "$ZBX_VIRT" == "1" ]]; then
    dry "VM/container detected — comment out the ${ZBX_HOSTNAME}.cpuTemperature UserParameter"
  else
    dry "set the cpuTemperature UserParameter key to ${ZBX_HOSTNAME}.cpuTemperature"
  fi
  dry "enable + restart zabbix-agent2"
  record "Zabbix agent 2" "[dry-run] would install + configure (server ${ZBX_SERVER_ACTIVE})"
else
  # Derive the Debian major version for the release package name (e.g. debian13).
  _osrel="$(awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null || true)"
  _osrel="${_osrel%%.*}"; _osrel="${_osrel:-13}"
  _rel_deb="zabbix-release_latest_${ZBX_VERSION}+debian${_osrel}_all.deb"
  _rel_url="https://repo.zabbix.com/zabbix/${ZBX_VERSION}/release/debian/pool/main/z/zabbix-release/${_rel_deb}"
  _rel_tmp="/tmp/${_rel_deb}"

  info "Adding the Zabbix ${ZBX_VERSION} apt repository..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$_rel_url" -o "$_rel_tmp"
  else
    wget -qO "$_rel_tmp" "$_rel_url"
  fi
  dpkg -i "$_rel_tmp"
  rm -f "$_rel_tmp"
  apt-get update

  # inxi backs the pve2.cpuTemperature UserParameter in the config below.
  info "Installing zabbix-agent2 and inxi..."
  apt-get install -y zabbix-agent2 inxi

  # Back up the package default before replacing it with the custom config.
  if [[ -f "$ZBX_CONF" ]]; then
    cp -a "$ZBX_CONF" "${ZBX_CONF}.bak.$(date +%F-%H%M%S)"
  fi
  install -d -m 755 "$(dirname "$ZBX_CONF")"
  _zbx_tmp="$(mktemp)"
  if write_zabbix_conf "$_zbx_tmp" "$ZBX_HOSTNAME" "$ZBX_SERVER_ACTIVE" "$ZBX_VIRT"; then
    install -m 0644 "$_zbx_tmp" "$ZBX_CONF"
    rm -f "$_zbx_tmp"
    log "Wrote ${ZBX_CONF} (Hostname=${ZBX_HOSTNAME}, ServerActive=${ZBX_SERVER_ACTIVE})."
    if [[ "$ZBX_VIRT" == "1" ]]; then
      note "VM/container detected — ${ZBX_HOSTNAME}.cpuTemperature UserParameter commented out (no CPU sensors)."
    else
      note "cpuTemperature UserParameter key set to ${ZBX_HOSTNAME}.cpuTemperature."
    fi

    systemctl enable zabbix-agent2 >/dev/null 2>&1 || true
    if systemctl restart zabbix-agent2 2>/dev/null; then
      log "zabbix-agent2 enabled and running."
      record "Zabbix agent 2" "installed; host=${ZBX_HOSTNAME}, server=${ZBX_SERVER_ACTIVE}"
    else
      warn "zabbix-agent2 installed but did not start — check: systemctl status zabbix-agent2"
      record "Zabbix agent 2" "installed; service not running (check status)"
    fi
  else
    rm -f "$_zbx_tmp"
    warn "zabbix-agent2 installed but its config could not be written — service left as-is."
    record "Zabbix agent 2" "installed; config NOT written (template missing)"
  fi
fi
fi   # end: pkg_selected zabbix-agent2

# ==============================================================================
if pkg_selected alloy; then
banner "Installing Grafana Alloy (log shipper)"
# ==============================================================================
# Adds Grafana's apt repo, installs alloy, then drops in the journal-first
# config with the Loki endpoint substituted in. See https://grafana.com/docs/alloy
ALLOY_LOKI_DEFAULT="http://localhost:3100"

# Resolve the Loki base URL — prompt if unset; default to localhost:3100.
if [[ -z "$LOKI_URL" ]]; then
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    printf '%s%s Loki base URL for Alloy to push to (scheme://host:port) [default: %s]: %s' \
      "$YEL" "$S_INFO" "$ALLOY_LOKI_DEFAULT" "$RESET" > /dev/tty
    read -r LOKI_URL < /dev/tty || LOKI_URL=""
    LOKI_URL="${LOKI_URL//[[:space:]]/}"
  fi
  LOKI_URL="${LOKI_URL:-$ALLOY_LOKI_DEFAULT}"
fi
# Normalise: add a scheme if the user omitted it, and trim any trailing slash
# (the /loki/api/v1/push path is appended in the config template).
[[ "$LOKI_URL" =~ ^https?:// ]] || LOKI_URL="http://${LOKI_URL}"
LOKI_URL="${LOKI_URL%/}"

if [[ "$DRY_RUN" == "1" ]]; then
  dry "add Grafana apt repo, then apt-get install alloy"
  if [[ -r "$ALLOY_CONFIG_SRC" ]]; then
    dry "render ${ALLOY_CONFIG_SRC} -> ${ALLOY_CONF} (root:alloy 0640) pushing to ${LOKI_URL}/loki/api/v1/push"
  else
    dry "fetch alloy/config.alloy from repo -> ${ALLOY_CONF} (root:alloy 0640) pushing to ${LOKI_URL}/loki/api/v1/push"
  fi
  dry "enable + restart alloy"
  record "Grafana Alloy" "[dry-run] would install + configure (Loki ${LOKI_URL})"
else
  # gpg --dearmor needs gnupg; ensure it's present before adding the repo key.
  command -v gpg >/dev/null 2>&1 || apt-get install -y gnupg

  info "Adding the Grafana apt repository..."
  install -d -m 0755 /etc/apt/keyrings
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
  else
    wget -qO- https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
  fi
  chmod 0644 /etc/apt/keyrings/grafana.gpg
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update

  info "Installing alloy..."
  apt-get install -y alloy

  # Back up the package default before replacing it with the custom config.
  if [[ -f "$ALLOY_CONF" ]]; then
    cp -a "$ALLOY_CONF" "${ALLOY_CONF}.bak.$(date +%F-%H%M%S)"
  fi
  # The alloy user/group is created by the package above. The config must be
  # readable by the alloy user (root:alloy 0640) and /etc/alloy must be group
  # accessible — otherwise the service exits with "permission denied" on start.
  _alloy_grp="alloy"; getent group alloy >/dev/null 2>&1 || _alloy_grp="root"
  install -d -o root -g "$_alloy_grp" -m 0750 /etc/alloy
  _alloy_tmp="$(mktemp)"
  if write_alloy_conf "$_alloy_tmp" "$LOKI_URL"; then
    install -o root -g "$_alloy_grp" -m 0640 "$_alloy_tmp" "$ALLOY_CONF"
    rm -f "$_alloy_tmp"
    log "Wrote ${ALLOY_CONF} (pushing to ${LOKI_URL}/loki/api/v1/push)."

    systemctl enable alloy >/dev/null 2>&1 || true
    systemctl reset-failed alloy >/dev/null 2>&1 || true
    if systemctl restart alloy 2>/dev/null; then
      log "alloy enabled and running."
      record "Grafana Alloy" "installed; pushing to ${LOKI_URL}"
    else
      warn "alloy installed but did not start — check: systemctl status alloy"
      record "Grafana Alloy" "installed; service not running (check status)"
    fi
  else
    rm -f "$_alloy_tmp"
    warn "alloy installed but its config could not be written — service left as-is."
    record "Grafana Alloy" "installed; config NOT written (template missing)"
  fi
fi
fi   # end: pkg_selected alloy

# ==============================================================================
if pkg_selected fish; then
banner "Configuring fish shell"
# ==============================================================================
if (( ${#FISH_TARGETS[@]} > 0 )); then
  for u in "${FISH_TARGETS[@]}"; do
    if ! id "$u" >/dev/null 2>&1; then
      warn "User '$u' does not exist — skipping."
      continue
    fi
    set_fish_default "$u"
  done
else
  note "No users selected for fish — leaving default shells unchanged."
  record "fish" "no users changed"
fi
fi   # end: pkg_selected fish

# ==============================================================================
#  Recap
# ==============================================================================
ELAPSED=$(( $(date +%s) - START_TS )); MM=$(( ELAPSED / 60 )); SS=$(( ELAPSED % 60 ))
printf '\n'; hr '═'
if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s%s  🧪  DRY RUN COMPLETE — NO CHANGES MADE — RECAP%s\n' "$BOLD" "$MAG" "$RESET"
else
  printf '%s%s  ✅  ANCILLARY SETUP COMPLETE — RECAP%s\n' "$BOLD" "$GRN" "$RESET"
fi
hr '═'
printf '%s  Host: %s   |   Elapsed: %dm %ds%s\n' "$DIM" "$(hostname)" "$MM" "$SS" "$RESET"
hr '─'
printf '%s%s  WHAT %s%s\n' "$BOLD" "$CYN" "$( [[ $DRY_RUN == 1 ]] && echo 'WOULD BE DONE' || echo 'WAS DONE' )" "$RESET"
for entry in "${SUMMARY[@]}"; do
  key="${entry%%$'\t'*}"; val="${entry#*$'\t'}"
  printf '   %s%s%-16s%s %s\n' "$GRN" "$S_OK " "$key" "$RESET" "$val"
done
hr '─'
printf '%s%s  ⏭ NEXT STEPS%s\n' "$BOLD" "$MAG" "$RESET"
_had_step=0
if (( ${#FISH_TARGETS[@]} > 0 )); then
  printf '   %s•%s  Affected users get fish on their NEXT login. Try it now: %sexec fish%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"; _had_step=1
fi
if pkg_selected btop; then
  printf '   %s•%s  Launch the resource monitor with: %sbtop%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"; _had_step=1
fi
if pkg_selected zabbix-agent2; then
  printf '   %s•%s  Add this host on your Zabbix server using hostname %s%s%s, then confirm data\n' "$BOLD" "$RESET" "$BOLD" "$(hostname)" "$RESET"
  printf '       with: %ssystemctl status zabbix-agent2%s and %stail -f /var/log/zabbix/zabbix_agent2.log%s\n' "$DIM" "$RESET" "$DIM" "$RESET"; _had_step=1
fi
if pkg_selected alloy; then
  printf '   %s•%s  Confirm logs are flowing: %ssystemctl status alloy%s, then in Grafana query\n' "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '       %s{host="%s"}%s against your Loki source. Auditd logs need read access for the alloy user.\n' "$DIM" "$(hostname)" "$RESET"; _had_step=1
fi
if pkg_selected qemu-guest-agent; then
  if [[ "$DRY_RUN" == "1" || "${QEMU_ACTIVE:-0}" -ne 1 ]]; then
    _verb="$( [[ $DRY_RUN == 1 ]] && echo 'would be installed' || echo 'is installed' )"
    printf '   %s%s%s qemu-guest-agent %s but inactive. If this is a VM, enable the guest\n' "$YEL" "$S_WARN" "$RESET" "$_verb"
    printf '       agent on the hypervisor, then %sfully shut down and start the VM%s (a cold power-cycle —\n' "$BOLD" "$RESET"
    printf '       not just a reboot) so the agent channel is attached and the service activates.\n'; _had_step=1
  fi
fi
(( _had_step == 0 )) && printf '   %s•%s  Nothing further to do.\n' "$BOLD" "$RESET"
printf '%s%s  Done. 🐟%s\n\n' "$BOLD" "$GRN" "$RESET"

# One-line summary for init.sh's bootstrap report (actual runs only).
if [[ "$DRY_RUN" != "1" ]]; then
  if (( ${#FISH_TARGETS[@]} > 0 )); then _fish="fish default for: ${FISH_TARGETS[*]}"
  elif pkg_selected fish; then _fish="fish: no users changed"
  else _fish="fish: not selected"; fi
  if (( ${#SELECTED_PKGS[@]} > 0 )); then _pkgs="installed ${SELECTED_PKGS[*]}"; else _pkgs="no packages selected"; fi
  mkdir -p /var/lib/homelab-bootstrap/summaries
  printf '%s; %s\n' "$_pkgs" "$_fish" \
    > /var/lib/homelab-bootstrap/summaries/ancillary.sh
fi
