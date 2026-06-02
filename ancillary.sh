#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — ancillary
#  Installs extra/quality-of-life packages and sets up the fish shell.
#
#  - Installs btop, fish, and qemu-guest-agent (started only when run inside a
#    QEMU/KVM guest with the guest-agent channel; otherwise left inactive).
#  - fish shell: if harden.sh NEWLY created user(s) this run, fish is installed
#    and made their default shell automatically. Otherwise it asks which current
#    users should get fish as their default shell.
#  - Any user fish is set up for gets it as their DEFAULT login shell.
#
#  Run as root, e.g.  sudo ./ancillary.sh
#
#  Environment overrides:
#    FISH_USERS="u1 u2 ..." -> set fish for exactly these users (skips prompts)
#    DRY_RUN=1|0            -> force preview / actual (else asks)
#    ASSUME_YES=1           -> answer "yes" to every prompt (automation)
# ==============================================================================

set -euo pipefail

# Ensure sbin paths are present even under non-login shells / restricted sudo.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ASSUME_YES="${ASSUME_YES:-0}"
FISH_USERS="${FISH_USERS:-}"

if [[ -n "${DRY_RUN+x}" ]]; then DRY_RUN_EXPLICIT=1; else DRY_RUN_EXPLICIT=0; fi
DRY_RUN="${DRY_RUN:-}"

START_TS="$(date +%s)"

# Extra packages this script installs.
ANCILLARY_PKGS=(btop fish)

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
TOTAL_STEPS=3
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

# ==============================================================================
#  Splash
# ==============================================================================
clear 2>/dev/null || true
printf '%s%s  Debian 13 Homelab Bootstrap — ancillary (extra packages + fish)%s\n' "$BOLD" "$CYN" "$RESET"
hr '─'

require_root
if ! command -v apt-get >/dev/null 2>&1; then err "apt-get not found — this targets Debian/apt systems."; exit 1; fi
choose_run_mode

if [[ "$DRY_RUN" == "1" ]]; then info "Mode: ${MAG}DRY RUN (no changes)${RESET}"; else info "Mode: ${RED}ACTUAL RUN${RESET}"; fi
hr '─'

# ==============================================================================
#  Decide which users get fish (before installing, so the recap is accurate)
# ==============================================================================
FISH_TARGETS=()

if [[ -n "$FISH_USERS" ]]; then
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

# ==============================================================================
banner "Installing extra packages"
# ==============================================================================
export DEBIAN_FRONTEND=noninteractive
info "Refreshing package lists..."
run apt-get update
info "Installing: ${DIM}${ANCILLARY_PKGS[*]}${RESET}"
run apt-get install -y "${ANCILLARY_PKGS[@]}"
log "Installed: ${ANCILLARY_PKGS[*]} (btop = resource monitor; fish = friendly shell)."
record "Packages" "installed: ${ANCILLARY_PKGS[*]}"

# ==============================================================================
banner "Installing the QEMU guest agent"
# ==============================================================================
info "Ensuring qemu-guest-agent is installed..."
run apt-get install -y qemu-guest-agent
# qemu-guest-agent.service is a STATIC unit (no [Install] section): it is started
# automatically by udev when the host attaches the guest-agent virtio-serial
# channel. So we do NOT 'enable' it (that just errors) — we only 'start' it when
# we're actually a QEMU/KVM guest. On bare metal it simply stays inactive.
if [[ "$DRY_RUN" == "1" ]]; then
  dry "start qemu-guest-agent only if the guest-agent channel is present"
  record "Guest agent" "[dry-run] would install qemu-guest-agent"
else
  VIRT="$(systemd-detect-virt 2>/dev/null || true)"; [[ -n "$VIRT" ]] || VIRT="none"
  if systemctl is-active --quiet qemu-guest-agent 2>/dev/null; then
    log "qemu-guest-agent already active (virt: ${VIRT})."
    record "Guest agent" "active (${VIRT})"
  elif [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
    # Only start when the channel device exists, so the .device dependency is
    # satisfiable (otherwise systemctl start fails with a dependency error).
    systemctl start qemu-guest-agent >/dev/null 2>&1 || true
    if systemctl is-active --quiet qemu-guest-agent 2>/dev/null; then
      log "qemu-guest-agent started (virt: ${VIRT})."
      record "Guest agent" "active (${VIRT})"
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

# ==============================================================================
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
if (( ${#FISH_TARGETS[@]} > 0 )); then
  printf '%s%s  ⏭ NEXT STEPS%s\n' "$BOLD" "$MAG" "$RESET"
  printf '   %s•%s  Affected users get fish on their NEXT login. Try it now: %sexec fish%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '   %s•%s  Launch the resource monitor with: %sbtop%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
fi
printf '%s%s  Done. 🐟%s\n\n' "$BOLD" "$GRN" "$RESET"

# One-line summary for init.sh's bootstrap report (actual runs only).
if [[ "$DRY_RUN" != "1" ]]; then
  if (( ${#FISH_TARGETS[@]} > 0 )); then _fish="fish default for: ${FISH_TARGETS[*]}"; else _fish="fish: no users changed"; fi
  mkdir -p /var/lib/homelab-bootstrap/summaries
  printf 'installed %s, qemu-guest-agent; %s\n' "${ANCILLARY_PKGS[*]}" "$_fish" \
    > /var/lib/homelab-bootstrap/summaries/ancillary.sh
fi
