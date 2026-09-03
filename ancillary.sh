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
#  - Shells: SHELL_PKGS picks extra shells to install (fish, zsh, tcsh), and
#    DEFAULT_SHELL sets the login shell (keep|bash|sh|fish|zsh|tcsh) for the
#    target users: SHELL_USERS if given, else the users bootstrap.sh newly
#    created this run, else an interactive per-user ask. The shell is verified
#    (present + smoke test) before any chsh — a broken login shell is an SSH
#    lockout once password auth is off.
#
#  Run as root, e.g.  sudo ./ancillary.sh
#
#  Environment overrides:
#    ANCILLARY_PKGS="btop rsync ..." -> install exactly these (or "none" for
#                                       nothing); unset = the full default set
#                                       ("fish" here is a legacy alias that maps
#                                       to SHELL_PKGS=fish + DEFAULT_SHELL=fish)
#    SHELL_PKGS="fish zsh tcsh" -> extra shells to install (subset; unset = none)
#    DEFAULT_SHELL=keep|bash|sh|fish|zsh|tcsh -> login shell to set (default keep)
#    SHELL_USERS="u1 u2 ..." -> set the shell for exactly these users (skips
#                                       prompts; "none" = change nobody).
#                                       FISH_USERS is accepted as a legacy alias
#    ASSUME_YES=1           -> answer "yes" to every prompt (automation)
# ==============================================================================

set -euo pipefail

# Ensure sbin paths are present even under non-login shells / restricted sudo.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ASSUME_YES="${ASSUME_YES:-0}"
SHELL_USERS="${SHELL_USERS:-${FISH_USERS:-}}"
SHELL_PKGS="${SHELL_PKGS:-}"
DEFAULT_SHELL="${DEFAULT_SHELL:-}"

START_TS="$(date +%s)"

# All packages this installer knows how to install (slug -> short description).
declare -A PKG_DESC=(
  [vim]="Vim text editor"
  [btop]="resource monitor (htop-like)"
  [duf]="disk usage/free utility (df-like, friendlier)"
  [rsync]="fast file copy / sync"
  [qemu-guest-agent]="QEMU/KVM guest integration (VMs only)"
)
ALL_PKGS=(vim btop duf rsync qemu-guest-agent)

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
# Legacy: "fish" used to live in ANCILLARY_PKGS — map it to the shell section.
_newsel=()
for _p in "${SELECTED_PKGS[@]:-}"; do
  if [[ "$_p" == "fish" ]]; then
    [[ " $SHELL_PKGS " == *" fish "* ]] || SHELL_PKGS="${SHELL_PKGS:+${SHELL_PKGS} }fish"
    [[ -z "$DEFAULT_SHELL" ]] && DEFAULT_SHELL=fish
  elif [[ -n "$_p" ]]; then
    _newsel+=("$_p")
  fi
done
SELECTED_PKGS=("${_newsel[@]:-}")
DEFAULT_SHELL="${DEFAULT_SHELL:-keep}"
# Only real, installable shells may appear in SHELL_PKGS.
_shellsel=()
for _p in ${SHELL_PKGS}; do
  case "$_p" in fish|zsh|tcsh) _shellsel+=("$_p");; *) ;; esac
done
SHELL_PKG_LIST=("${_shellsel[@]:-}")
pkg_selected() { local p; for p in "${SELECTED_PKGS[@]}"; do [[ "$p" == "$1" ]] && return 0; done; return 1; }
shell_selected() { local p; for p in "${SHELL_PKG_LIST[@]:-}"; do [[ "$p" == "$1" ]] && return 0; done; return 1; }

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

# set_default_shell <user> <shell-name> — resolve the shell's path, verify it
# actually runs (a broken login shell is an SSH lockout once password auth is
# off), ensure /etc/shells lists it, then chsh the user.
set_default_shell() {
  local user="$1" name="$2" path
  case "$name" in
    bash) path="/bin/bash" ;;
    sh)   path="/bin/sh" ;;
    *)    path="$(command -v "$name" 2>/dev/null || echo "/usr/bin/${name}")" ;;
  esac
  if [[ ! -x "$path" ]]; then
    warn "${name} not found at ${path} — NOT changing ${user}'s shell."
    record "shell:${user}" "skipped (${name} not installed)"
    return 0
  fi
  if ! "$path" -c 'exit 0' >/dev/null 2>&1; then
    warn "${name} at ${path} failed a smoke test — NOT changing ${user}'s shell."
    record "shell:${user}" "skipped (${name} smoke test failed)"
    return 0
  fi
  if ! grep -qxF "$path" /etc/shells 2>/dev/null; then
    printf '%s\n' "$path" >> /etc/shells
    log "Added ${path} to /etc/shells."
  fi
  local cur; cur="$(getent passwd "$user" | cut -d: -f7)"
  if [[ "$cur" == "$path" ]]; then
    log "${user}'s default shell is already ${name}."
    record "shell:${user}" "already ${name} (${path})"
  else
    chsh -s "$path" "$user"
    log "Set ${user}'s default shell to ${name} (${path})."
    record "shell:${user}" "default shell set to ${name} (${path})"
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
#  Decide which users get the default shell (before installing, for the recap)
# ==============================================================================
SHELL_TARGETS=()

if [[ "$DEFAULT_SHELL" == "keep" ]]; then
  info "Default shell: keeping every user's current shell."
elif [[ "${SHELL_USERS,,}" == "none" ]]; then
  # Explicit opt-out — change no shells.
  info "Default-shell change disabled (SHELL_USERS=none)."
elif [[ -n "$SHELL_USERS" ]]; then
  # Explicit override.
  read -ra SHELL_TARGETS <<< "$SHELL_USERS"
  info "Default shell ${BOLD}${DEFAULT_SHELL}${RESET} for (SHELL_USERS): ${BOLD}${SHELL_TARGETS[*]}${RESET}"
elif [[ -s "$CREATED_USERS_FILE" ]]; then
  # bootstrap.sh created user(s) this round → set their shell automatically.
  mapfile -t SHELL_TARGETS < <(awk 'NF' "$CREATED_USERS_FILE" | sort -u)
  info "bootstrap.sh newly created: ${BOLD}${SHELL_TARGETS[*]:-<none>}${RESET}"
  note "${DEFAULT_SHELL} will be set as the default shell for the above user(s)."
else
  # No newly-created users recorded → ask which current users to change.
  info "No newly-created users were recorded by bootstrap.sh (${CREATED_USERS_FILE})."
  mapfile -t HUMAN_USERS < <(awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | sort)
  if (( ${#HUMAN_USERS[@]} == 0 )); then
    warn "No regular (human) user accounts found to offer ${DEFAULT_SHELL} to."
  elif [[ "$INTERACTIVE" -eq 1 ]]; then
    # Interactive-only: automation must name its targets via SHELL_USERS.
    info "Choose which existing users should get ${DEFAULT_SHELL} as their default shell:"
    for u in "${HUMAN_USERS[@]}"; do
      confirm "Set ${DEFAULT_SHELL} as the default shell for '${u}'?" N && SHELL_TARGETS+=("$u")
    done
  else
    note "Non-interactive with no SHELL_USERS set — skipping shell changes."
  fi
fi

# qemu-guest-agent has its own step below; install the rest here, plus any
# shells picked in the shell section (fish/zsh/tcsh are plain Debian packages).
APT_PKGS=()
for p in "${SELECTED_PKGS[@]}"; do
  case "$p" in qemu-guest-agent) ;; *) APT_PKGS+=("$p");; esac
done
for p in "${SHELL_PKG_LIST[@]:-}"; do
  [[ -n "$p" ]] && APT_PKGS+=("$p")
done

# ==============================================================================
banner "Installing extra packages"
# ==============================================================================
export DEBIAN_FRONTEND=noninteractive
if (( ${#SELECTED_PKGS[@]} == 0 && ${#APT_PKGS[@]} == 0 )); then
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
if [[ "$DEFAULT_SHELL" != "keep" ]]; then
banner "Configuring the login shell (${DEFAULT_SHELL})"
# ==============================================================================
if (( ${#SHELL_TARGETS[@]} > 0 )); then
  for u in "${SHELL_TARGETS[@]}"; do
    if ! id "$u" >/dev/null 2>&1; then
      warn "User '$u' does not exist — skipping."
      continue
    fi
    set_default_shell "$u" "$DEFAULT_SHELL"
  done
else
  note "No users selected — leaving default shells unchanged."
  record "shell" "no users changed"
fi
fi   # end: default shell

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
if [[ "$DEFAULT_SHELL" != "keep" ]] && (( ${#SHELL_TARGETS[@]} > 0 )); then
  printf '   %s•%s  Affected users get %s on their NEXT login. Try it now: %sexec %s%s\n' "$BOLD" "$RESET" "$DEFAULT_SHELL" "$DIM" "$DEFAULT_SHELL" "$RESET"; _had_step=1
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
if [[ "$DEFAULT_SHELL" != "keep" ]] && (( ${#SHELL_TARGETS[@]} > 0 )); then _fish="${DEFAULT_SHELL} default for: ${SHELL_TARGETS[*]}"
elif [[ "$DEFAULT_SHELL" != "keep" ]]; then _fish="${DEFAULT_SHELL}: no users changed"
else _fish="shells: current kept"; fi
_allpkgs=("${SELECTED_PKGS[@]:-}" "${SHELL_PKG_LIST[@]:-}")
if (( ${#_allpkgs[@]} > 0 )) && [[ -n "${_allpkgs[0]}" || ${#_allpkgs[@]} -gt 1 ]]; then _pkgs="installed ${_allpkgs[*]}"; else _pkgs="no packages selected"; fi
mkdir -p /var/lib/homelab-bootstrap/summaries 2>/dev/null || true
printf '%s; %s\n' "$_pkgs" "$_fish" \
  > /var/lib/homelab-bootstrap/summaries/ancillary.sh 2>/dev/null || true
