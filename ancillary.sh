#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — ancillary
#  Installs extra/quality-of-life packages and sets up the fish shell.
#
#  - Installs a selectable set of packages: vim, btop, duf, fish, rsync,
#    qemu-guest-agent.
#    By default (standalone run) it installs them all; init.sh's wizard lets you
#    pick a subset and passes it via ANCILLARY_PKGS.
#    (Monitoring agents — Zabbix, Grafana Alloy — moved to monitoring.sh.)
#  - qemu-guest-agent (if selected) is started only when run inside a QEMU/KVM
#    guest with the guest-agent channel; otherwise it's left inactive.
#  - fish shell (if selected): if bootstrap.sh NEWLY created user(s) this run, fish
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
#    ASSUME_YES=1           -> answer "yes" to every prompt (automation)
# ==============================================================================

set -euo pipefail

# Ensure sbin paths are present even under non-login shells / restricted sudo.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ASSUME_YES="${ASSUME_YES:-0}"
FISH_USERS="${FISH_USERS:-}"

START_TS="$(date +%s)"

# All packages this installer knows how to install (slug -> short description).
declare -A PKG_DESC=(
  [vim]="Vim text editor"
  [btop]="resource monitor (htop-like)"
  [duf]="disk usage/free utility (df-like, friendlier)"
  [fish]="friendly interactive shell"
  [rsync]="fast file copy / sync"
  [qemu-guest-agent]="QEMU/KVM guest integration (VMs only)"
)
ALL_PKGS=(vim btop duf fish rsync qemu-guest-agent)

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

# State written by bootstrap.sh: users it NEWLY created this round.
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
# Steps shown depend on what's selected: packages (always) + QEMU + fish.
TOTAL_STEPS=1
pkg_selected qemu-guest-agent && TOTAL_STEPS=$((TOTAL_STEPS + 1))
pkg_selected fish             && TOTAL_STEPS=$((TOTAL_STEPS + 1))
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

run() { "$@"; }

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

# set_fish_default <user> — ensure fish is in /etc/shells, then chsh the user.
set_fish_default() {
  local user="$1" fish_path
  fish_path="$(command -v fish 2>/dev/null || echo /usr/bin/fish)"
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
  # bootstrap.sh created user(s) this round → fish for them automatically.
  mapfile -t FISH_TARGETS < <(awk 'NF' "$CREATED_USERS_FILE" | sort -u)
  info "bootstrap.sh newly created: ${BOLD}${FISH_TARGETS[*]:-<none>}${RESET}"
  note "fish will be installed and set as the default shell for the above user(s)."
else
  # No newly-created users recorded → ask which current users want fish.
  info "No newly-created users were recorded by bootstrap.sh (${CREATED_USERS_FILE})."
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

# qemu-guest-agent has its own step below; install the rest here.
APT_PKGS=()
for p in "${SELECTED_PKGS[@]}"; do
  case "$p" in qemu-guest-agent) ;; *) APT_PKGS+=("$p");; esac
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
fi   # end: pkg_selected qemu-guest-agent

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
printf '%s%s  ✅  ANCILLARY SETUP COMPLETE — RECAP%s\n' "$BOLD" "$GRN" "$RESET"
hr '═'
printf '%s  Host: %s   |   Elapsed: %dm %ds%s\n' "$DIM" "$(hostname)" "$MM" "$SS" "$RESET"
hr '─'
printf '%s%s  WHAT %s%s\n' "$BOLD" "$CYN" "WAS DONE" "$RESET"
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
if pkg_selected qemu-guest-agent; then
  if [[ "${QEMU_ACTIVE:-0}" -ne 1 ]]; then
    printf '   %s%s%s qemu-guest-agent is installed but inactive. If this is a VM, enable the guest\n' "$YEL" "$S_WARN" "$RESET"
    printf '       agent on the hypervisor, then %sfully shut down and start the VM%s (a cold power-cycle —\n' "$BOLD" "$RESET"
    printf '       not just a reboot) so the agent channel is attached and the service activates.\n'; _had_step=1
  fi
fi
(( _had_step == 0 )) && printf '   %s•%s  Nothing further to do.\n' "$BOLD" "$RESET"
printf '%s%s  Done. 🐟%s\n\n' "$BOLD" "$GRN" "$RESET"

# One-line summary for init.sh's bootstrap report.
if (( ${#FISH_TARGETS[@]} > 0 )); then _fish="fish default for: ${FISH_TARGETS[*]}"
elif pkg_selected fish; then _fish="fish: no users changed"
else _fish="fish: not selected"; fi
if (( ${#SELECTED_PKGS[@]} > 0 )); then _pkgs="installed ${SELECTED_PKGS[*]}"; else _pkgs="no packages selected"; fi
mkdir -p /var/lib/homelab-bootstrap/summaries
printf '%s; %s\n' "$_pkgs" "$_fish" \
  > /var/lib/homelab-bootstrap/summaries/ancillary.sh
