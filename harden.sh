#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Hardening (All-In-One)
#  Safe, idempotent, with backups. Run as root.
#
#  Features:
#   - Rich, colorful, easy-to-read progress output + full end-of-run recap
#   - Interactive pre-flight that surfaces every gotcha and asks to proceed
#   - Idempotent: safe to re-run; guards prevent destructive re-work
#
#  NOTE: user creation + SSH key install moved to bootstrap.sh — run it FIRST.
#  This script VERIFIES the admin user(s) exist and have keys (password auth is
#  disabled here), but no longer creates accounts or installs keys itself.
#
#  Environment overrides:
#   ADMIN_USERS, SSH_PORT, ALLOW_HTTP, ALLOW_HTTPS, ALLOW_SSH_CIDRS,
#   ALLOW_SSH_PORT_22, ENABLE_SSH_2FA
#   ALLOW_TCP_PORTS="8080 8096" -> open extra TCP ports (e.g. published container
#                                  ports — rootless Docker ports need this!)
#   ALLOW_UDP_PORTS="51820"     -> open extra UDP ports
#   ADMIN_USERS="u1 u2 ..."  -> EXISTING admin users to harden around (default:
#                               asks; create them with bootstrap.sh first)
#   DISABLE_ROOT_LOGIN=1|0   -> lock the root account password (root SSH is off
#                               regardless; sudo still works). Only applied if an
#                               admin user is keyed; never expires root. Else asks.
#   BLACKLIST_USB_STORAGE=1|0-> also blacklist the usb-storage module (disables
#                               USB drives). Default: asks; off if unanswered.
#   BACKUP_DNS="ip ip"       -> fallback DNS servers (default "1.1.1.1 9.9.9.9")
#   REMOTE_SYSLOG="host:port"-> forward logs to a remote syslog host (opt-in)
#   GRUB_PASSWORD="..."      -> set a GRUB password (opt-in; normal boot stays free)
#   HARDEN_COMPILERS=0       -> do NOT restrict compilers (gcc/cc/...) to root
#                               (default: restricted to root only — HRDN-7222)
#   ASSUME_YES=1     -> answer "yes" to every prompt (for automation)
#   SKIP_UPGRADE=1   -> skip the full apt upgrade
#   REBUILD_AIDE=1   -> force-rebuild the AIDE baseline even if present
#   PVE_FIREWALL=1   -> on a Proxmox VE node, run the nftables step anyway
#                       (default: skipped there; see the PVE profile notes)
#   AIDE_EXCLUDES="/mnt /media /export /var/lib/vz" -> paths AIDE never indexes
#                     (bulk-data mounts; /var/lib/vz = PVE guest disk images, ISOs, dumps)
#   Per-component toggles (all default 1 = run; set 0 to skip that component):
#   HARDEN_UNATTENDED, HARDEN_JOURNALD, HARDEN_SSH, HARDEN_FIREWALL,
#   HARDEN_FAIL2BAN, HARDEN_APPARMOR, HARDEN_AIDE, HARDEN_SYSCTL,
#   HARDEN_EXTRA (Lynis-suggestion fixes incl. auditd/banners/blacklists),
#   HARDEN_LYNIS (the closing audit)
#   DOCKER_COMPAT=1|0-> force Docker-compatible firewall/sysctl (else auto/prompt)
#                       (see https://docs.docker.com/engine/install/debian/#prerequisites)
# ==============================================================================

set -euo pipefail

# Ensure the admin sbin paths are present — adduser, usermod, sshd, nft, sysctl,
# aa-status, aideinit, etc. live in /usr/sbin and /sbin, which some non-login
# shells / sudo configs drop from PATH (causes "adduser: command not found").
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# =======================
# Config (env overridable)
# =======================
# EXISTING admin users to harden around (created beforehand by bootstrap.sh).
# There is NO default user — if ADMIN_USERS is not set, the script interactively
# asks which admin username(s) to use. ADMIN_USER is just the first one (used
# for messaging). Set ADMIN_USERS="u1 u2 ..." to skip the prompt entirely.
if [[ -n "${ADMIN_USERS+x}" ]]; then ADMIN_USERS_EXPLICIT=1; else ADMIN_USERS_EXPLICIT=0; fi
ADMIN_USERS="${ADMIN_USERS:-}"
read -ra ADMIN_USER_LIST <<< "$ADMIN_USERS"
# De-duplicate while preserving order.
_seen=" "; _dedup=()
for _u in "${ADMIN_USER_LIST[@]}"; do
  [[ "$_seen" == *" $_u "* ]] && continue
  _dedup+=("$_u"); _seen+="$_u "
done
ADMIN_USER_LIST=("${_dedup[@]}")
ADMIN_USER="${ADMIN_USER_LIST[0]:-}"
declare -A USER_EXISTS USER_HASKEY

# Was SSH_PORT explicitly provided? (decide before applying the default)
if [[ -n "${SSH_PORT+x}" ]]; then SSH_PORT_EXPLICIT=1; else SSH_PORT_EXPLICIT=0; fi
SSH_PORT="${SSH_PORT:-22}"
ALLOW_HTTP="${ALLOW_HTTP:-0}"               # 1 to allow TCP/80
ALLOW_HTTPS="${ALLOW_HTTPS:-0}"             # 1 to allow TCP/443
# Extra ports to open in the firewall (e.g. for published container ports).
# Space/comma separated, e.g. ALLOW_TCP_PORTS="8080 8096 32400".
ALLOW_TCP_PORTS="${ALLOW_TCP_PORTS:-}"
ALLOW_UDP_PORTS="${ALLOW_UDP_PORTS:-}"
ALLOW_SSH_CIDRS="${ALLOW_SSH_CIDRS:-}"      # e.g. "1.2.3.4/32,5.6.7.0/24" ; empty = any
ALLOW_SSH_PORT_22="${ALLOW_SSH_PORT_22:-0}" # keep TCP/22 allowed too (safety)
ENABLE_SSH_2FA="${ENABLE_SSH_2FA:-0}"       # 1 to enable TOTP for SSH
# Lock the root account password for tighter security (root SSH is disabled
# regardless; sudo still works). Empty = ask. Only applied if an admin user has
# a key so a path to root remains. Locks only — never expires root.
DISABLE_ROOT_LOGIN="${DISABLE_ROOT_LOGIN:-}"

# Docker compatibility (firewall + sysctl). Empty = auto-detect / prompt.
# See https://docs.docker.com/engine/install/debian/#prerequisites
if [[ -n "${DOCKER_COMPAT+x}" ]]; then DOCKER_COMPAT_EXPLICIT=1; else DOCKER_COMPAT_EXPLICIT=0; fi
DOCKER_COMPAT="${DOCKER_COMPAT:-}"
# Packages Docker's prerequisites say to remove before installing Docker Engine
DOCKER_CONFLICT_PKGS=(docker.io docker-compose docker-doc podman-docker containerd runc)
FOUND_CONFLICTS=()

ASSUME_YES="${ASSUME_YES:-0}"
# One timezone across the fleet. A mixed fleet makes every timestamp ambiguous:
# on 2026-09-20 four containers were on Etc/UTC and two on America/Boise, which
# led to a running job being read six hours wrong. Set TIMEZONE= to override.
TIMEZONE="${TIMEZONE:-America/Denver}"
SKIP_UPGRADE="${SKIP_UPGRADE:-0}"
REBUILD_AIDE="${REBUILD_AIDE:-0}"

# Per-component toggles: 1 = run that hardening component, 0 = skip it.
# Normalised to exactly 0/1 so TOTAL_STEPS arithmetic below stays honest.
HARDEN_COMPONENTS=(HARDEN_UNATTENDED HARDEN_JOURNALD HARDEN_SSH HARDEN_FIREWALL
  HARDEN_FAIL2BAN HARDEN_APPARMOR HARDEN_AIDE HARDEN_SYSCTL HARDEN_EXTRA HARDEN_LYNIS)
for _hc in "${HARDEN_COMPONENTS[@]}"; do
  eval "$_hc=\"\${$_hc:-1}\""
  [[ "${!_hc}" == "1" ]] || eval "$_hc=0"
done

START_TS="$(date +%s)"
BACKUP_DIR="/tmp/hardening-backups/$(date +%F-%H%M%S)"

# ==============================================================================
#  Output helpers — colors, banners, steps, and a running recap log
# ==============================================================================
if [[ -t 1 ]]; then
  BOLD=$'\033[1m';  DIM=$'\033[2m';   RESET=$'\033[0m'
  RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'
  BLU=$'\033[1;34m'; MAG=$'\033[1;35m'; CYN=$'\033[1;36m'; WHT=$'\033[1;37m'
else
  BOLD=''; DIM=''; RESET=''; RED=''; GRN=''; YEL=''; BLU=''; MAG=''; CYN=''; WHT=''
fi

S_OK="✔"; S_INFO="•"; S_WARN="!"; S_ERR="✗"; S_STEP="▸"

STEP_NO=0
# 3 fixed steps (packages, core tools, user verification) + one per enabled component.
TOTAL_STEPS=$(( 3 + HARDEN_UNATTENDED + HARDEN_JOURNALD + HARDEN_SSH + HARDEN_FIREWALL \
  + HARDEN_FAIL2BAN + HARDEN_APPARMOR + HARDEN_AIDE + HARDEN_SYSCTL + HARDEN_EXTRA + HARDEN_LYNIS ))
SUMMARY=()        # collected lines for the final recap
WARNINGS=()       # collected warnings for the final recap

record()        { SUMMARY+=("$1"$'\t'"$2"); }
remember_warn() { WARNINGS+=("$1"); }

hr() {
  local ch="${1:-─}" width=72 line=""
  printf -v line '%*s' "$width" ''
  printf '%s%s%s\n' "$DIM" "${line// /$ch}" "$RESET"
}

banner() {
  STEP_NO=$((STEP_NO + 1))
  printf '\n'
  hr '═'
  printf '%s%s STEP %d/%d %s %s%s\n' "$BOLD$CYN" "$S_STEP" "$STEP_NO" "$TOTAL_STEPS" "│" "$*" "$RESET"
  hr '═'
}

header() {
  printf '\n'
  hr '═'
  printf '%s%s %s%s\n' "$BOLD$CYN" "$S_STEP" "$*" "$RESET"
  hr '═'
}

log()  { printf '%s%s%s %s\n'  "$GRN"  "$S_OK"   "$RESET" "$*"; }
info() { printf '%s%s%s %s\n'  "$BLU"  "$S_INFO" "$RESET" "$*"; }
warn() { printf '%s%s %s%s\n'  "$YEL"  "$S_WARN" "$*" "$RESET"; remember_warn "$*"; }
err()  { printf '%s%s %s%s\n'  "$RED"  "$S_ERR" "$*" "$RESET" >&2; }
note() { printf '   %s%s%s\n'  "$DIM"  "$*" "$RESET"; }

# ------------------------------------------------------------------------------
#  Action wrappers
# ------------------------------------------------------------------------------
# run CMD [ARGS...]   — execute a command
run() { "$@"; }

# write_file PATH  (content on stdin)  — write a file
write_file() {
  local path="$1"
  cat > "$path"
}

# append_line FILE LINE  — append a line if not already present
append_line() {
  local f="$1" line="$2"
  # Idempotent: skip if the exact line is already in the file.
  [[ -f "$f" ]] && grep -qxF "$line" "$f" && return 0
  printf '%s\n' "$line" >> "$f"
}

# Interactivity: a real terminal is needed to prompt. ASSUME_YES bypasses prompts.
INTERACTIVE=0
if [[ "$ASSUME_YES" != "1" && -r /dev/tty ]]; then
  INTERACTIVE=1
fi

# confirm "Question?" [default Y|N]  -> returns 0 for yes, 1 for no
confirm() {
  local prompt="$1" default="${2:-N}" reply hint
  if [[ "$default" =~ ^[Yy]$ ]]; then hint="[Y/n]"; else hint="[y/N]"; fi

  if [[ "$ASSUME_YES" == "1" ]]; then
    info "auto-confirm (ASSUME_YES=1): ${prompt} → yes"
    return 0
  fi
  if [[ "$INTERACTIVE" -eq 0 ]]; then
    info "non-interactive: ${prompt} → using default (${default})"
    [[ "$default" =~ ^[Yy] ]]
    return
  fi

  printf '%s%s %s %s%s ' "$YEL" "$S_WARN" "$prompt" "$hint" "$RESET" > /dev/tty
  read -r reply < /dev/tty || reply=""
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root."
    exit 1
  fi
}

# detect_container -> prints the container type (lxc, docker, ...) and returns 0
# when running inside a container; returns 1 on bare metal / a full VM. Several
# hardening steps (AppArmor profiles, some sysctls, the audit subsystem) are
# owned by the HOST kernel and cannot be managed from inside an unprivileged
# LXC/container, so we detect this and skip those steps gracefully.
detect_container() {
  local v=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    v="$(systemd-detect-virt -c 2>/dev/null || true)"
  fi
  if [[ -n "$v" && "$v" != "none" ]]; then printf '%s' "$v"; return 0; fi
  if [[ -r /run/systemd/container ]]; then printf '%s' "$(cat /run/systemd/container)"; return 0; fi
  if grep -qa 'container=lxc' /proc/1/environ 2>/dev/null; then printf 'lxc'; return 0; fi
  return 1
}

# prompt_for_ssh_port — ask which port sshd should listen on (default 22)
prompt_for_ssh_port() {
  [[ "$SSH_PORT_EXPLICIT" == "1" ]] && return 0   # env override wins
  [[ "$INTERACTIVE" -eq 1 ]] || return 0          # cannot prompt without a TTY
  local p
  while true; do
    printf '\n%s%sWhich port should SSH (sshd) listen on?%s\n' "$BOLD" "$WHT" "$RESET" > /dev/tty
    printf '   %s(22 = default; a high port like 2222 reduces drive-by scans)%s\n' "$DIM" "$RESET" > /dev/tty
    printf '%s%s Port [default: %s]: %s' "$YEL" "$S_INFO" "$SSH_PORT" "$RESET" > /dev/tty
    read -r p < /dev/tty || p=""
    p="${p:-$SSH_PORT}"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
      SSH_PORT="$p"
      printf '%s%s%s Using SSH port %s%s%s\n' "$GRN" "$S_OK" "$RESET" "$BOLD" "$SSH_PORT" "$RESET" > /dev/tty
      return 0
    fi
    printf '%s%s Invalid port — enter a number between 1 and 65535.%s\n' "$RED" "$S_ERR" "$RESET" > /dev/tty
  done
}

# detect_docker_conflicts — populate FOUND_CONFLICTS with installed conflicting pkgs
detect_docker_conflicts() {
  FOUND_CONFLICTS=()
  local p
  for p in "${DOCKER_CONFLICT_PKGS[@]}"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
      FOUND_CONFLICTS+=("$p")
    fi
  done
}

# prompt_for_docker — resolve DOCKER_COMPAT (Docker-friendly firewall/sysctl)
prompt_for_docker() {
  # Detect existing/intended Docker
  DOCKER_DETECTED=0
  if command -v docker >/dev/null 2>&1 || [[ -d /var/lib/docker ]] \
     || systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
    DOCKER_DETECTED=1
  fi

  if [[ "$DOCKER_COMPAT_EXPLICIT" == "1" ]]; then
    [[ "$DOCKER_COMPAT" == "1" ]] && DOCKER_COMPAT=1 || DOCKER_COMPAT=0
    return 0
  fi
  if [[ "$INTERACTIVE" -ne 1 ]]; then
    DOCKER_COMPAT="$DOCKER_DETECTED"   # auto: match what we detected
    return 0
  fi

  if [[ "$DOCKER_DETECTED" -eq 1 ]]; then
    if confirm "Docker detected — keep the firewall & sysctl Docker-compatible?" Y; then
      DOCKER_COMPAT=1; else DOCKER_COMPAT=0; fi
  else
    if confirm "Will this host run Docker (adjust firewall & sysctl to its prerequisites)?" N; then
      DOCKER_COMPAT=1; else DOCKER_COMPAT=0; fi
  fi
}

# prompt_for_admin_users — ask which EXISTING admin username(s) this hardening
# should rely on (lockout checks, root locking, 2FA notes). Users are created by
# bootstrap.sh, not here — a name that doesn't exist is rejected. Requires at
# least one (unless ADMIN_USERS was set via env, or there is no TTY). Press
# Enter on an empty prompt once at least one user has been added to finish.
prompt_for_admin_users() {
  [[ "$ADMIN_USERS_EXPLICIT" == "1" ]] && return 0
  [[ "$INTERACTIVE" -eq 1 ]] || return 0
  local name uid shell
  mapfile -t _humans < <(awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd | sort)
  while true; do
    printf '\n%s%sAdmin username this hardening should rely on (existing, with an SSH key)?%s\n' "$BOLD" "$WHT" "$RESET" > /dev/tty
    if (( ${#ADMIN_USER_LIST[@]} > 0 )); then
      note "Added so far: ${ADMIN_USER_LIST[*]} — enter another, or press Enter to finish." > /dev/tty
    else
      (( ${#_humans[@]} > 0 )) && note "Existing users: ${_humans[*]}" > /dev/tty
      note "At least one is required. To CREATE a user, run bootstrap.sh first." > /dev/tty
    fi
    printf '%s%s username> %s' "$YEL" "$S_INFO" "$RESET" > /dev/tty
    IFS= read -r name < /dev/tty || name=""
    # Trim whitespace.
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"

    if [[ -z "$name" ]]; then
      if (( ${#ADMIN_USER_LIST[@]} > 0 )); then return 0; fi
      printf '%s%s At least one admin user is required (password login is disabled).%s\n' \
        "$YEL" "$S_WARN" "$RESET" > /dev/tty
      continue
    fi
    # Validate a Linux username: start with a lowercase letter/underscore.
    if ! [[ "$name" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
      printf '%s%s Invalid username — use lowercase letters, digits, - and _ (start with a letter).%s\n' \
        "$RED" "$S_ERR" "$RESET" > /dev/tty
      continue
    fi
    # Ignore duplicates already in the list.
    if printf '%s\n' "${ADMIN_USER_LIST[@]}" | grep -qx "$name"; then
      note "'$name' is already in the admin list." > /dev/tty
      continue
    fi
    # Users must already exist — creation is bootstrap.sh's job.
    if ! id "$name" >/dev/null 2>&1; then
      printf '%s%s User '\''%s'\'' does not exist — run bootstrap.sh first to create it.%s\n' \
        "$RED" "$S_ERR" "$name" "$RESET" > /dev/tty
      continue
    fi
    # Warn hard for system/service accounts (UID < 1000 or a nologin/false
    # shell) — relying on those for SSH/sudo access is almost certainly a typo.
    uid="$(id -u "$name" 2>/dev/null || echo 0)"
    shell="$(getent passwd "$name" | cut -d: -f7)"
    if (( uid < 1000 )) || [[ "$shell" == */nologin || "$shell" == */false ]]; then
      printf '%s%s '\''%s'\'' looks like a SYSTEM account (uid %s, shell %s).%s\n' \
        "$RED" "$S_ERR" "$name" "$uid" "${shell:-?}" "$RESET" > /dev/tty
      printf '   %sRelying on it for SSH/sudo access is almost certainly NOT what you want.%s\n' "$DIM" "$RESET" > /dev/tty
      if ! confirm "Use the system account '$name' anyway?" N; then
        note "Not using '$name' — enter a different username." > /dev/tty
        continue
      fi
    fi
    ADMIN_USER_LIST+=("$name")
    ADMIN_USER="${ADMIN_USER_LIST[0]}"
    log "Added admin user: ${BOLD}${name}${RESET}" > /dev/tty
  done
}

# ==============================================================================
#  Intro splash
# ==============================================================================
# Don't wipe the terminal when run nested by init.sh — keep the previous
# script's output visible. (BOOTSTRAP_NESTED is set by init.sh.)
[[ "${BOOTSTRAP_NESTED:-0}" == "1" ]] || clear 2>/dev/null || true
printf '%s' "$BOLD$MAG"
cat <<'EOF'
  ██   ██  █████  ██████  ██████  ███████ ███    ██
  ██   ██ ██   ██ ██   ██ ██   ██ ██      ████   ██
  ███████ ███████ ██████  ██   ██ █████   ██ ██  ██
  ██   ██ ██   ██ ██   ██ ██   ██ ██      ██  ██ ██
  ██   ██ ██   ██ ██   ██ ██████  ███████ ██   ████
EOF
printf '%s' "$RESET"
printf '%s        Debian 13 Hardening  •  AIO  •  safe / idempotent / backed-up%s\n' "$DIM" "$RESET"
hr '─'

require_root

# Basic sanity
if ! command -v apt >/dev/null 2>&1; then
  err "This script targets Debian-like systems with apt."
  exit 1
fi

# Are we inside a container (e.g. a Proxmox LXC)? Host-managed steps adapt below.
CONTAINER_TYPE="$(detect_container || true)"
[[ -n "$CONTAINER_TYPE" ]] && IS_CONTAINER=1 || IS_CONTAINER=0

# Ask which SSH port to use (defaults to 22).
prompt_for_ssh_port

# Ask whether to keep the firewall/sysctl Docker-compatible (per Docker prereqs).
prompt_for_docker

# Ask which admin user(s) to create/harden, unless ADMIN_USERS was set via env.
prompt_for_admin_users

# At least one admin user is required (password login is disabled by hardening).
if (( ${#ADMIN_USER_LIST[@]} == 0 )); then
  err "No admin user specified. Set ADMIN_USERS=\"name\" or run interactively — at least one is required."
  exit 1
fi

# When SSH stays on 22 there is no separate "port 22 fallback" to manage.
if [[ "$SSH_PORT" == "22" ]]; then
  ALLOW_SSH_PORT_22=0
fi

# --- Competing firewall managers ----------------------------------------------
# ufw/firewalld also program netfilter; running them alongside this nftables
# ruleset means packets must pass BOTH filters and rules fight each other.
if [[ "$HARDEN_FIREWALL" == "1" ]]; then
  for _fw in ufw firewalld; do
    if systemctl is-active --quiet "$_fw" 2>/dev/null; then
      warn "${_fw} is active — it will filter alongside this nftables ruleset (both apply; either can drop). Disable one: systemctl disable --now ${_fw}, or skip this firewall with HARDEN_FIREWALL=0."
    fi
  done
fi

# --- Proxmox VE host guard ----------------------------------------------------
# A bare PVE host reached over its web UI must not be cut off by the firewall,
# and cluster ssh assumes port 22. Auto-repair the ports; warn on the rest.
IS_PVE=0
if command -v pveversion >/dev/null 2>&1 || [[ -d /etc/pve/local ]] || [[ "${ENV_TYPE:-}" == "pve" ]]; then IS_PVE=1; fi
if [[ "$IS_PVE" == "1" ]]; then
  if [[ "$HARDEN_FIREWALL" == "1" ]] && ! grep -qw 8006 <<<"${ALLOW_TCP_PORTS//,/ }"; then
    warn "Proxmox VE host: adding 8006 (web UI) and 3128 (SPICE console) to ALLOW_TCP_PORTS so hardening does not cut off the UI."
    ALLOW_TCP_PORTS="${ALLOW_TCP_PORTS:+${ALLOW_TCP_PORTS} }8006 3128"
  fi
  if [[ "$HARDEN_SSH" == "1" && "$SSH_PORT" != "22" ]]; then
    warn "Proxmox VE host with SSH on ${SSH_PORT}: inter-node ssh (migration, replication, cluster join) assumes port 22 — change it only fleet-wide."
  fi
  if [[ "$HARDEN_FIREWALL" == "1" && "$DOCKER_COMPAT" != "1" ]] && systemctl is-active --quiet pve-firewall 2>/dev/null; then
    warn "pve-firewall is active: this firewall's 'flush ruleset' will clobber its rules on every load. Use DOCKER_COMPAT=1 (scoped flush) or disable pve-firewall."
  fi
  # PVE profile (2026-09-18, fleet-parity work): a deny-by-default nftables
  # ruleset on a cluster node with no corosync (5405-5412/udp), migration
  # (60000-60050/tcp, VNC 5900-5999) or Thunderbolt-mesh rules drops quorum and
  # the HA watchdog fences the node. Until a PVE ruleset exists the firewall
  # step is skipped here; pve-firewall and the upstream segmentation stay in
  # charge. PVE_FIREWALL=1 forces the old behaviour (you own the peer rules).
  if [[ "$HARDEN_FIREWALL" == "1" && "${PVE_FIREWALL:-0}" != "1" ]]; then
    warn "Proxmox VE host: skipping the nftables step (no cluster/migration/mesh rules yet; PVE_FIREWALL=1 to force)."
    HARDEN_FIREWALL=0
    TOTAL_STEPS=$((TOTAL_STEPS - 1))
  fi
fi

info "Run date     : $(date '+%Y-%m-%d %H:%M:%S %Z')"
info "Hostname     : $(hostname -f 2>/dev/null || hostname)"
[[ "$IS_CONTAINER" == "1" ]] && info "Environment  : ${BOLD}${CONTAINER_TYPE} container${RESET} (host-managed steps will be skipped)"
info "Backup dir   : ${BOLD}${BACKUP_DIR}${RESET}"
info "Admin users  : ${BOLD}${ADMIN_USER_LIST[*]}${RESET}"
info "SSH port     : ${BOLD}${SSH_PORT}${RESET}   (also allow 22: ${ALLOW_SSH_PORT_22})"
info "SSH sources  : ${BOLD}${ALLOW_SSH_CIDRS:-<any>}${RESET}"
info "HTTP / HTTPS : 80=${ALLOW_HTTP}  443=${ALLOW_HTTPS}"
info "SSH 2FA      : ${ENABLE_SSH_2FA}"
hr '─'

# Create the backup directory
run mkdir -p "$BACKUP_DIR"

# ==============================================================================
#  PRE-FLIGHT — detect state, surface every gotcha, and ask before proceeding
# ==============================================================================
header "Pre-flight checks & gotchas"

# --- Resolve which admin users to use ----------------------------------------
# Users must already EXIST — creation moved to bootstrap.sh. Missing names are
# skipped here with a pointer at bootstrap.sh.
EFFECTIVE_USERS=()
for u in "${ADMIN_USER_LIST[@]}"; do
  if id "$u" >/dev/null 2>&1; then
    EFFECTIVE_USERS+=("$u")
  else
    warn "User '$u' does not exist — skipping (run bootstrap.sh first to create it)."
    record "User:$u" "skipped (absent — create with bootstrap.sh)"
  fi
done
ADMIN_USER_LIST=("${EFFECTIVE_USERS[@]}")
ADMIN_USER="${ADMIN_USER_LIST[0]:-}"

# After resolution there must still be at least one admin user.
if (( ${#ADMIN_USER_LIST[@]} == 0 )); then
  err "No admin users left (none of the names exist). Run bootstrap.sh first — at least one existing admin user is required."
  exit 1
fi

# --- Per-user: VERIFY key + sudo membership (set up by bootstrap.sh) ---------
# At least one admin user must have a key (password auth is disabled below).
key_login_ok=0
NO_KEY_USERS=()
NO_SUDO_USERS=()
for u in "${ADMIN_USER_LIST[@]}"; do
  USER_EXISTS[$u]=1; USER_HASKEY[$u]=0
  uh="$(getent passwd "$u" | cut -d: -f6)"
  [[ -n "$uh" && -s "${uh}/.ssh/authorized_keys" ]] && USER_HASKEY[$u]=1
  if [[ "${USER_HASKEY[$u]}" == "1" ]]; then
    key_login_ok=1
  else
    NO_KEY_USERS+=("$u")
  fi
  id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx sudo || NO_SUDO_USERS+=("$u")
done

# --- Optional: lock the ROOT account (tighter security) ----------------------
# Root SSH is already disabled (PermitRootLogin no). This also LOCKS root's
# password so console/su password login as root is refused; sudo still works.
# Only offered/allowed when at least one admin user has a usable SSH key AND is
# in sudo, so you keep a path to root. We LOCK the password only — never
# expire root, as an expired account can make sudo itself fail.
LOCK_ROOT_NOW=0
ROOT_ALREADY_LOCKED=0
if [[ "$(passwd -S root 2>/dev/null | awk '{print $2}')" == "L" ]]; then
  ROOT_ALREADY_LOCKED=1
fi
# Pick a keyed admin user WITH sudo to name in the messaging (and to gate on —
# bootstrap.sh ensures sudo, but a hand-made account might lack it).
KEYED_ADMIN=""
for u in "${ADMIN_USER_LIST[@]}"; do
  if [[ "${USER_HASKEY[$u]:-0}" == "1" ]] && id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
    KEYED_ADMIN="$u"; break
  fi
done
if [[ "$ROOT_ALREADY_LOCKED" -eq 1 ]]; then
  : # nothing to do; reported in the step
elif [[ "$IS_PVE" == "1" ]]; then
  # Proxmox VE: the web UI and the API log in as root@pam with the root
  # password. Locking it would lock the GUI. Never on a PVE node.
  LOCK_ROOT_NOW=0
  [[ "$DISABLE_ROOT_LOGIN" == "1" ]] && warn "Proxmox VE host: DISABLE_ROOT_LOGIN ignored (root@pam is the web UI login)."
elif [[ -n "$KEYED_ADMIN" ]]; then
  if [[ -n "$DISABLE_ROOT_LOGIN" ]]; then
    [[ "$DISABLE_ROOT_LOGIN" == "1" ]] && LOCK_ROOT_NOW=1
  # Interactive-only question: under ASSUME_YES this used to auto-answer YES
  # and lock root without being asked for. Non-interactive + unset = no lock.
  elif [[ "$INTERACTIVE" -eq 1 ]] && confirm "Lock the root account password (root SSH already off; sudo via '$KEYED_ADMIN' still works)?" N; then
    LOCK_ROOT_NOW=1
  fi
elif [[ "$DISABLE_ROOT_LOGIN" == "1" ]]; then
  warn "Ignoring DISABLE_ROOT_LOGIN — no admin user has both a key and sudo, so locking root could leave no path to root."
fi

# --- Detect a likely re-run (idempotency awareness) -------------------------
RERUN_NOTES=()
if grep -qiE "^\s*Port\s+${SSH_PORT}\b" /etc/ssh/sshd_config 2>/dev/null; then
  RERUN_NOTES+=("sshd already configured for port ${SSH_PORT}")
fi
if [[ -f /etc/nftables.conf ]] && grep -q "deny-by-default\|flush ruleset" /etc/nftables.conf 2>/dev/null; then
  RERUN_NOTES+=("/etc/nftables.conf already present")
fi
if [[ -f /var/lib/aide/aide.db ]]; then
  RERUN_NOTES+=("AIDE baseline already exists")
fi

# --- Build the gotcha list --------------------------------------------------
info "Reviewing the changes this script will make:"
echo
printf '   %s%sCHANGES & GOTCHAS%s\n' "$BOLD" "$WHT" "$RESET"
printf '   %s%s%s SSH will move to port %s%s%s — update your client and any cloud/VPC firewall.\n' \
  "$YEL" "$S_WARN" "$RESET" "$BOLD" "$SSH_PORT" "$RESET"
printf '   %s%s%s Root SSH login and password authentication will be %sDISABLED%s.\n' \
  "$YEL" "$S_WARN" "$RESET" "$BOLD" "$RESET"
printf '   %s%s%s Firewall switches to %sdeny-by-default%s — only SSH%s will be reachable.\n' \
  "$YEL" "$S_WARN" "$RESET" "$BOLD" "$RESET" \
  "$( { [[ $ALLOW_HTTP == 1 ]] && printf ', HTTP'; [[ $ALLOW_HTTPS == 1 ]] && printf ', HTTPS'; } )"
printf '   %s%s%s fail2ban will ban an IP after 5 failed SSH logins for 1 hour.\n' \
  "$YEL" "$S_WARN" "$RESET"
if [[ "$ALLOW_SSH_PORT_22" != "1" && "$SSH_PORT" != "22" ]]; then
  printf '   %s%s%s Port 22 will be %sCLOSED%s once the new firewall loads.\n' \
    "$YEL" "$S_WARN" "$RESET" "$BOLD" "$RESET"
fi
if [[ "$SKIP_UPGRADE" != "1" ]]; then
  printf '   %s%s%s A full system upgrade will run — slow, and a reboot may be required after.\n' \
    "$YEL" "$S_WARN" "$RESET"
fi
if [[ "$ENABLE_SSH_2FA" == "1" ]]; then
  printf '   %s%s%s TOTP 2FA will be required; you must enroll with google-authenticator after.\n' \
    "$YEL" "$S_WARN" "$RESET"
fi

# The big one: lockout risk — no admin user will have a usable key.
if [[ "$key_login_ok" -eq 0 ]]; then
  printf '   %s%s%s %sLOCKOUT RISK:%s no SSH key for any admin user (%s) —\n' \
    "$RED" "$S_ERR" "$RESET" "$BOLD$RED" "$RESET" "${ADMIN_USER_LIST[*]}"
  printf '        with password auth disabled you may be unable to log back in.\n'
elif (( ${#NO_KEY_USERS[@]} > 0 )); then
  printf '   %s%s%s These admin users will have NO SSH key (cannot log in): %s%s%s\n' \
    "$YEL" "$S_WARN" "$RESET" "$BOLD" "${NO_KEY_USERS[*]}" "$RESET"
fi
if (( ${#NO_SUDO_USERS[@]} > 0 )); then
  printf '   %s%s%s NOT in the sudo group (no path to root for them): %s%s%s — fix via bootstrap.sh or usermod -aG sudo.\n' \
    "$YEL" "$S_WARN" "$RESET" "$BOLD" "${NO_SUDO_USERS[*]}" "$RESET"
fi
if [[ "$LOCK_ROOT_NOW" -eq 1 ]]; then
  printf '   %s%s%s The %sroot%s account password will be %sLOCKED%s (sudo via %s%s%s still works; root SSH already off).\n' \
    "$YEL" "$S_WARN" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$KEYED_ADMIN" "$RESET"
elif [[ "$ROOT_ALREADY_LOCKED" -eq 1 ]]; then
  printf '   %s%s%s The root account is already locked (no change).\n' "$CYN" "$S_INFO" "$RESET"
fi

# Re-run awareness
if (( ${#RERUN_NOTES[@]} > 0 )); then
  echo
  printf '   %s%sLOOKS LIKE A RE-RUN (safe — script is idempotent):%s\n' "$BOLD" "$CYN" "$RESET"
  for n in "${RERUN_NOTES[@]}"; do
    printf '   %s%s%s %s\n' "$CYN" "$S_INFO" "$RESET" "$n"
  done
fi

# --- Docker compatibility (per docs.docker.com prerequisites) ---------------
if [[ "$DOCKER_COMPAT" == "1" ]]; then
  echo
  printf '   %s%sDOCKER COMPATIBILITY (firewall/sysctl tuned to Docker prereqs)%s\n' "$BOLD" "$CYN" "$RESET"
  printf '   %s%s%s IPv4 forwarding kept %sENABLED%s and the FORWARD chain is %snot dropped%s (Docker needs both).\n' \
    "$CYN" "$S_INFO" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET"
  printf '   %s%s%s nftables flushes only its own %sinet filter%s table, leaving Docker'\''s iptables-nft rules intact.\n' \
    "$CYN" "$S_INFO" "$RESET" "$BOLD" "$RESET"
  printf '   %s%s%s Heads-up: published ports (docker run -p) DNAT in prerouting and %sbypass%s these input rules —\n' \
    "$YEL" "$S_WARN" "$RESET" "$BOLD" "$RESET"
  printf '        filter container traffic via the %sDOCKER-USER%s iptables chain or bind to 127.0.0.1.\n' "$BOLD" "$RESET"
  printf '   %s%s%s Docker supports only iptables-nft/iptables-legacy; keep host rules in the nft %sinet%s table only.\n' \
    "$YEL" "$S_WARN" "$RESET" "$BOLD" "$RESET"

  detect_docker_conflicts
  if (( ${#FOUND_CONFLICTS[@]} > 0 )); then
    warn "Conflicting packages present (Docker prereqs say remove before installing Docker): ${FOUND_CONFLICTS[*]}"
  else
    log "No conflicting Docker packages installed (docker.io, containerd, runc, ...)."
  fi
fi
echo

# --- Targeted prompts driven by the gotchas above ---------------------------

PURGE_CONFLICTS=0
# 1) Offer to keep port 22 open as a safety net (only if we moved off 22).
if [[ "$ALLOW_SSH_PORT_22" != "1" && "$SSH_PORT" != "22" ]]; then
  if confirm "Keep port 22 open as a fallback during this change (recommended)?" Y; then
    ALLOW_SSH_PORT_22=1
    log "Port 22 will be kept open as a fallback."
  else
    note "Port 22 will be closed. Make sure ${SSH_PORT} works before disconnecting."
  fi
fi

# 2) Lockout guard — require explicit acknowledgement, or abort. Only relevant
#    when the SSH component actually runs (it is what disables password auth).
#    ASSUME_YES must NOT be able to wave this through: a non-interactive run
#    with no key needs the explicit ACCEPT_LOCKOUT_RISK=1 opt-in.
if [[ "$HARDEN_SSH" == "1" && "$key_login_ok" -eq 0 ]]; then
  warn "No usable SSH key for any admin user (${ADMIN_USER_LIST[*]})."
  if [[ "$INTERACTIVE" -ne 1 && "${ACCEPT_LOCKOUT_RISK:-0}" != "1" ]]; then
    err "Refusing to disable SSH password auth with no SSH key in a non-interactive run."
    err "Fix one of: install a key first (bootstrap.sh), skip the SSH component (HARDEN_SSH=0),"
    err "or accept the risk explicitly (ACCEPT_LOCKOUT_RISK=1)."
    exit 1
  fi
  if [[ "${ACCEPT_LOCKOUT_RISK:-0}" == "1" ]]; then
    warn "ACCEPT_LOCKOUT_RISK=1 set — proceeding without a key."
  elif ! confirm "Continue anyway with password auth DISABLED (high lockout risk)?" N; then
    err "Aborting. Run bootstrap.sh to install an SSH key first, then re-run."
    exit 1
  else
    warn "Proceeding without a key — you accepted the lockout risk."
  fi
fi

# 3) Upgrade choice.
DO_UPGRADE=1
[[ "$SKIP_UPGRADE" == "1" ]] && DO_UPGRADE=0
if [[ "$DO_UPGRADE" -eq 1 ]]; then
  confirm "Run a full system upgrade now (can be slow; reboot may be needed)?" Y || DO_UPGRADE=0
fi
[[ "$DO_UPGRADE" -eq 0 ]] && note "Full upgrade will be skipped."

# 3b) Offer to remove Docker-conflicting packages (Docker prereq).
if [[ "$DOCKER_COMPAT" == "1" ]] && (( ${#FOUND_CONFLICTS[@]} > 0 )); then
  # Purging docker.io/containerd/runc can kill running containers — under
  # ASSUME_YES this used to auto-answer YES. Non-interactive runs now need
  # the explicit PURGE_DOCKER_CONFLICTS=1 opt-in.
  if [[ "${PURGE_DOCKER_CONFLICTS:-0}" == "1" ]]; then
    PURGE_CONFLICTS=1
  elif [[ "$INTERACTIVE" -eq 1 ]] && confirm "Remove conflicting packages now (${FOUND_CONFLICTS[*]})?" N; then
    PURGE_CONFLICTS=1
  else
    note "Leaving them in place — remove manually before installing Docker Engine (or set PURGE_DOCKER_CONFLICTS=1)."
  fi
fi

# 4) Master confirmation.
echo
if ! confirm "Proceed with hardening using the settings above?" N; then
  err "Aborted by user. No changes made."
  exit 1
fi
log "Confirmed — beginning hardening."

# ==============================================================================
banner "Updating packages"
# ==============================================================================
export DEBIAN_FRONTEND=noninteractive
info "Refreshing package lists..."
run apt update
if [[ "$DO_UPGRADE" -eq 1 ]]; then
  # full-upgrade (= dist-upgrade) is deliberately the Proxmox-blessed form:
  # plain 'apt upgrade' can hold back packages with changed dependencies and
  # break PVE. pveupgrade is only a wrapper around dist-upgrade whose extra
  # (the new-kernel reboot notice) detect_reboot_required already provides —
  # and the wrapper takes no -y, so it would hang/abort non-interactive runs.
  info "Applying full upgrade (this can take a while)..."
  run apt -y full-upgrade
  log "System packages updated."
  record "Packages" "apt update + full-upgrade completed"
else
  log "Package lists refreshed (full upgrade skipped)."
  record "Packages" "apt update only (full upgrade skipped)"
fi

# ==============================================================================
banner "Installing core security tools"
# ==============================================================================
CORE_PKGS=(
  openssh-server sudo gnupg lsb-release ca-certificates
  nftables fail2ban aide apparmor apparmor-utils
  unattended-upgrades apt-listchanges
  rsyslog rsyslog-gnutls logwatch
  lynis needrestart
)
info "Ensuring packages installed: ${DIM}${CORE_PKGS[*]}${RESET}"
run apt -y install "${CORE_PKGS[@]}"
log "Core tools present (${#CORE_PKGS[@]} packages)."
record "Core tools" "${#CORE_PKGS[@]} packages ensured (nftables, fail2ban, aide, apparmor, lynis, ...)"

# /tmp must not live in RAM on a container. Debian 13 mounts /tmp as tmpfs
# (tmp.mount) sized from the HOST's RAM, so inside a 2 GB LXC a logwatch run or
# an app that keeps state under /tmp (Loki's example config does) eats the whole
# memory allowance and the kernel starts killing services (grf, 2026-09-19).
# logwatch gets a disk-backed TmpDir everywhere; containers also mask tmp.mount
# so /tmp is on the root filesystem from the next boot.
# Timezone: every host, VM and container reads the same clock.
if [[ -n "$TIMEZONE" ]]; then
  CUR_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || readlink -f /etc/localtime | sed 's#.*/zoneinfo/##')"
  if [[ "$CUR_TZ" == "$TIMEZONE" ]]; then
    note "Timezone already $TIMEZONE."
  elif timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
    log "Timezone set to $TIMEZONE (was ${CUR_TZ:-unknown})."
    record "Timezone" "$TIMEZONE (was ${CUR_TZ:-unknown})"
  elif [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    # An unprivileged container often cannot reach systemd-timedated.
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    [[ -f /etc/timezone ]] && printf '%s\n' "$TIMEZONE" > /etc/timezone
    log "Timezone set to $TIMEZONE by symlink (was ${CUR_TZ:-unknown}); timedatectl unavailable here."
    record "Timezone" "$TIMEZONE by symlink (was ${CUR_TZ:-unknown})"
  else
    warn "Timezone $TIMEZONE not found in /usr/share/zoneinfo; left at ${CUR_TZ:-unknown}."
  fi
fi

mkdir -p /etc/logwatch/conf; touch /etc/logwatch/conf/logwatch.conf
if grep -q '^TmpDir' /etc/logwatch/conf/logwatch.conf; then
  sed -i 's#^TmpDir.*#TmpDir = /var/tmp#' /etc/logwatch/conf/logwatch.conf
else
  printf 'TmpDir = /var/tmp\n' >> /etc/logwatch/conf/logwatch.conf
fi
if detect_container >/dev/null 2>&1; then
  if findmnt -n -t tmpfs /tmp >/dev/null 2>&1 || systemctl is-enabled tmp.mount >/dev/null 2>&1; then
    run systemctl mask tmp.mount >/dev/null 2>&1 || true
    log "/tmp on disk from the next boot (tmp.mount masked; container memory is too small for a RAM /tmp)."
    record "/tmp on disk" "tmp.mount masked (container), logwatch TmpDir=/var/tmp"
  fi
else
  record "/tmp on disk" "logwatch TmpDir=/var/tmp"
fi

# A container reads the HOST's load average unless lxcfs virtualises it, so a
# 1-core LXC shows the node's load (seafile-keeper read 6.45 at 3.5 % CPU while
# pve2 scrubbed, 2026-09-20) and every per-container load trigger is noise.
# lxcfs -l gives each container its own figure from its cgroup.
if [[ "$IS_PVE" == "1" ]] && systemctl list-unit-files lxcfs.service >/dev/null 2>&1; then
  LXCFS_DROPIN=/etc/systemd/system/lxcfs.service.d/override.conf
  # Older lxcfs builds spell the flag -l; accept either in the drop-in, or a re-run
  # on such a node rewrites it and restarts lxcfs for nothing.
  LXCFS_FLAG=--enable-loadavg
  lxcfs --help 2>&1 | grep -q -- "--enable-loadavg" || LXCFS_FLAG=-l
  if ! grep -qsE -- "(--enable-loadavg|[[:space:]]-l[[:space:]])" "$LXCFS_DROPIN"; then
    mkdir -p "$(dirname "$LXCFS_DROPIN")"
    LXCFS_BIN="$(systemctl show -p ExecStart --value lxcfs.service | sed -n 's/.*path=\([^ ;]*\).*/\1/p')"
    LXCFS_BIN="${LXCFS_BIN:-/usr/bin/lxcfs}"
    write_file "$LXCFS_DROPIN" "[Service]
ExecStart=
ExecStart=$LXCFS_BIN $LXCFS_FLAG /var/lib/lxcfs
" 0644
    run systemctl daemon-reload
    # Restarting lxcfs breaks every lxcfs file inside RUNNING containers
    # (/proc/loadavg, meminfo, cpuinfo, stat, uptime: "Transport endpoint is not
    # connected") until each container restarts. That took down all eight
    # containers on 2026-09-20. So restart only when none is running; otherwise the
    # drop-in waits for the next node reboot.
    LXC_RUNNING="$(pct list 2>/dev/null | awk 'NR>1 && $2=="running"' | wc -l)"
    if [[ "${LXC_RUNNING:-0}" == "0" ]]; then
      run systemctl restart lxcfs.service || warn "lxcfs restart failed; containers keep the host load average until it restarts."
      log "lxcfs: per-container load average enabled ($LXCFS_FLAG)."
      record "lxcfs loadavg" "containers report their own load, not the node's"
    else
      warn "lxcfs: drop-in written but NOT restarted, ${LXC_RUNNING} container(s) running. A restart would break their /proc files. Takes effect at the next node reboot."
      record "lxcfs loadavg" "pending next reboot (${LXC_RUNNING} containers were running)"
    fi
  else
    note "lxcfs already reports per-container load averages."
  fi
fi

# Remove Docker-conflicting packages if the operator opted in (Docker prereq).
if [[ "${PURGE_CONFLICTS:-0}" == "1" ]]; then
  info "Removing conflicting Docker packages: ${DIM}${FOUND_CONFLICTS[*]}${RESET}"
  run apt -y purge "${FOUND_CONFLICTS[@]}"
  run apt -y autoremove
  log "Conflicting packages removed."
  record "Docker prereq" "Removed conflicting packages: ${FOUND_CONFLICTS[*]}"
fi

# ==============================================================================
banner "Verifying admin users (created by bootstrap.sh)"
# ==============================================================================
# User creation + SSH key install moved to bootstrap.sh — here we only VERIFY
# and report, so the recap shows exactly what this hardening will rely on.
for u in "${ADMIN_USER_LIST[@]}"; do
  _sudo_ok=0; _key_ok="${USER_HASKEY[$u]:-0}"
  id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx sudo && _sudo_ok=1
  if [[ "$_sudo_ok" == "1" && "$_key_ok" == "1" ]]; then
    log "User '$u': in sudo, authorized_keys present."
    record "User:$u" "verified (sudo + SSH key)"
  elif [[ "$_key_ok" == "1" ]]; then
    warn "User '$u' has a key but is NOT in sudo — run bootstrap.sh (or: usermod -aG sudo $u)."
    record "User:$u" "key present; NOT in sudo"
  elif [[ "$_sudo_ok" == "1" ]]; then
    warn "User '$u' is in sudo but has NO SSH key — it cannot log in via SSH (run bootstrap.sh to add one)."
    record "User:$u" "in sudo; NO SSH key"
  else
    warn "User '$u' has NO SSH key and is NOT in sudo — run bootstrap.sh to set it up."
    record "User:$u" "NO key, NOT in sudo"
  fi
done

# Optionally lock the ROOT account — an admin user with sudo + key exists.
# (Gated earlier on KEYED_ADMIN — locking root can never remove the sudo path.)
if [[ "$ROOT_ALREADY_LOCKED" -eq 1 ]]; then
  log "root account password is already locked (no change)."
  record "Root lockdown" "already locked (no change)"
elif [[ "$LOCK_ROOT_NOW" -eq 1 ]]; then
  info "Locking the root account password (tighter security)..."
  # Lock the password ONLY. Do NOT expire root — an expired account can break
  # sudo (PAM account check), which would remove every path to root.
  run passwd -l root
  warn "root password is now LOCKED — use '$KEYED_ADMIN' (sudo) for admin tasks. Root SSH is already disabled."
  note "Reverse it (via sudo): sudo passwd -u root"
  record "Root lockdown" "root password LOCKED (sudo via $KEYED_ADMIN; not expired)"
else
  record "Root lockdown" "not applied (root password left as-is; root SSH already disabled)"
fi

# ==============================================================================
if [[ "$HARDEN_UNATTENDED" == "1" ]]; then
banner "Configuring unattended-upgrades"
# ==============================================================================
info "Enabling automatic security updates..."
run dpkg-reconfigure -f noninteractive unattended-upgrades
write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
log "Unattended-upgrades enabled (daily lists + automatic security upgrades)."
record "Auto-upgrades" "Enabled via /etc/apt/apt.conf.d/20auto-upgrades"
fi   # end: HARDEN_UNATTENDED

# ==============================================================================
if [[ "$HARDEN_JOURNALD" == "1" ]]; then
banner "Enabling persistent journald logs"
# ==============================================================================
run mkdir -p /var/log/journal
if [[ -f /etc/systemd/journald.conf ]]; then
  run cp -a /etc/systemd/journald.conf "$BACKUP_DIR"/journald.conf.bak
  run sed -i 's/^#\?Storage=.*/Storage=persistent/g' /etc/systemd/journald.conf
  note "Backed up journald.conf -> $BACKUP_DIR/journald.conf.bak"
fi
run systemctl restart systemd-journald
log "journald now stores logs persistently in /var/log/journal."
record "journald" "Persistent storage enabled"
fi   # end: HARDEN_JOURNALD

# ==============================================================================
SSH_2FA_NOTE="disabled"
if [[ "$HARDEN_SSH" == "1" ]]; then
banner "Hardening SSH"
# ==============================================================================
SSHD_CFG="/etc/ssh/sshd_config"
run cp -a "$SSHD_CFG" "$BACKUP_DIR/sshd_config.bak"
note "Backed up sshd_config -> $BACKUP_DIR/sshd_config.bak"

# ensure config lines (append or replace) — idempotent
ensure_sshd_opt () {
  local key="$1" val="$2"
  if grep -qiE "^\s*#?\s*${key}\b" "$SSHD_CFG"; then
    sed -i -E "s@^\s*#?\s*(${key})\b.*@\1 ${val}@i" "$SSHD_CFG"
  else
    echo "${key} ${val}" >> "$SSHD_CFG"
  fi
  note "${key} ${DIM}->${RESET} ${BOLD}${val}${RESET}"
}

info "Applying hardened sshd options..."
ensure_sshd_opt Port "$SSH_PORT"
# Cluster nodes ssh to each other as root with keys (migration, replication,
# pvecm), so a PVE node keeps key-only root login; everywhere else it is off.
if [[ "$IS_PVE" == "1" ]]; then
  ensure_sshd_opt PermitRootLogin "prohibit-password"
  note "Proxmox VE host: PermitRootLogin prohibit-password (key-only root for inter-node ssh)."
else
  ensure_sshd_opt PermitRootLogin "no"
fi
ensure_sshd_opt PasswordAuthentication "no"
ensure_sshd_opt ChallengeResponseAuthentication "no"
ensure_sshd_opt PubkeyAuthentication "yes"
ensure_sshd_opt AuthorizedKeysFile ".ssh/authorized_keys"
ensure_sshd_opt X11Forwarding "no"
ensure_sshd_opt AllowTcpForwarding "no"
ensure_sshd_opt LoginGraceTime "30"
ensure_sshd_opt ClientAliveInterval "300"
ensure_sshd_opt ClientAliveCountMax "2"
ensure_sshd_opt MaxAuthTries "3"
# Lynis SSH-7408 hardening suggestions.
ensure_sshd_opt LogLevel "VERBOSE"
ensure_sshd_opt MaxSessions "2"
ensure_sshd_opt TCPKeepAlive "no"
ensure_sshd_opt AllowAgentForwarding "no"
ensure_sshd_opt Banner "/etc/issue.net"

SSH_2FA_NOTE="disabled"
if [[ "$ENABLE_SSH_2FA" == "1" ]]; then
  info "Enabling SSH TOTP (Google Authenticator)..."
  run apt -y install libpam-google-authenticator
  PAM_SSHD="/etc/pam.d/sshd"
  run cp -a "$PAM_SSHD" "$BACKUP_DIR/sshd.pam.bak"
  if ! grep -q 'pam_google_authenticator.so' "$PAM_SSHD" 2>/dev/null; then
    append_line "$PAM_SSHD" "auth required pam_google_authenticator.so nullok"
  fi
  ensure_sshd_opt AuthenticationMethods "publickey,keyboard-interactive"
  warn "Each admin user must enroll TOTP: run 'google-authenticator' as ${ADMIN_USER_LIST[*]}."
  SSH_2FA_NOTE="ENABLED (publickey + TOTP)"
fi

# Validate sshd config before reload
info "Validating sshd configuration (sshd -t)..."
if ! sshd -t; then
  err "sshd config test FAILED — restoring backup and aborting."
  cp -a "$BACKUP_DIR/sshd_config.bak" "$SSHD_CFG"
  exit 1
fi
log "sshd config valid."

# Debian 13 may socket-activate SSH via ssh.socket. When it's active, the
# LISTENING port comes from the socket unit (ListenStream, default 22), NOT
# from sshd_config's Port — so our port change would be silently ignored and
# connections to ${SSH_PORT} get refused. Worse, even after a runtime restart
# binds the right port, on the NEXT BOOT only ssh.socket starts (ssh.service
# isn't enabled in socket mode), so SSH reverts to :22 and ${SSH_PORT} refuses.
# MASK the socket (not just disable) so neither boot nor a package preset can
# re-activate it, and run the standalone ssh.service on the configured Port.
if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled ssh.socket >/dev/null 2>&1; then
  warn "ssh.socket is in use — masking socket activation so Port ${SSH_PORT} persists across reboots."
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true
  systemctl mask ssh.socket >/dev/null 2>&1 || true
  record "SSH socket" "ssh.socket masked (port now governed by sshd_config, survives reboot)"
fi

# Enable ssh.service for boot and (re)start it so the new Port is bound now.
systemctl enable ssh >/dev/null 2>&1 || true
systemctl restart ssh || systemctl reload ssh

# Confirm the boot-time setup is correct: ssh.service enabled, and sshd is
# actually listening on the new port. Warn loudly otherwise so a lockout is
# caught now (while port 22 may still be open as a firewall fallback).
systemctl is-enabled ssh >/dev/null 2>&1 \
  && log "ssh.service is enabled at boot (will bind Port ${SSH_PORT} on reboot)." \
  || warn "ssh.service is NOT enabled at boot — run: systemctl enable ssh"
if command -v ss >/dev/null 2>&1; then
  if ss -ltnH 2>/dev/null | grep -qE "[:.]${SSH_PORT}([[:space:]]|$)"; then
    log "Confirmed: sshd is listening on port ${SSH_PORT}."
  else
    warn "sshd does NOT appear to be listening on ${SSH_PORT} — do not disconnect yet!"
    note "Check: systemctl status ssh   |   ss -ltnp   |   journalctl -u ssh -n 50"
  fi
fi
log "SSH hardened on port ${BOLD}${SSH_PORT}${RESET}."
record "SSH" "port=$SSH_PORT, root login off, password auth off, 2FA: $SSH_2FA_NOTE"
fi   # end: HARDEN_SSH

# ==============================================================================
if [[ "$HARDEN_FIREWALL" == "1" ]]; then
banner "Configuring nftables firewall (deny-by-default)"
# ==============================================================================
NFT_CONF="/etc/nftables.conf"
if [[ -f "$NFT_CONF" ]]; then
  run cp -a "$NFT_CONF" "$BACKUP_DIR/nftables.conf.bak"
  note "Backed up nftables.conf -> $BACKUP_DIR/nftables.conf.bak"
fi

# --- Build SSH allow rules (emits REAL newlines) ----------------------------
# Emit the address-family that matches the CIDR: an IPv4 literal under `ip6
# saddr` (or vice-versa) is an nft type error that fails the WHOLE ruleset load
# — which, after sshd is already key-only on the new port, is a lockout. So pick
# the family per-CIDR (':' ⇒ IPv6).
emit_ssh_rule() {
  local cidr="$1" port="$2"
  if [[ -z "$cidr" ]]; then
    printf '    tcp dport %s ct state new accept\n' "$port"
  elif [[ "$cidr" == *:* ]]; then
    printf '    ip6 saddr %s tcp dport %s ct state new accept\n' "$cidr" "$port"
  else
    printf '    ip saddr %s tcp dport %s ct state new accept\n' "$cidr" "$port"
  fi
}

build_ssh_rules_for_port() {
  local port="$1"
  if [[ -n "$ALLOW_SSH_CIDRS" ]]; then
    local c; IFS=',' read -ra CIDRS <<< "$ALLOW_SSH_CIDRS"
    for c in "${CIDRS[@]}"; do
      emit_ssh_rule "$c" "$port"
    done
  else
    emit_ssh_rule "" "$port"
  fi
}

SSH_ALLOW_RULES="$(build_ssh_rules_for_port "$SSH_PORT")"
if [[ "$ALLOW_SSH_PORT_22" == "1" ]]; then
  SSH_ALLOW_RULES+=$'\n'"$(build_ssh_rules_for_port 22)"
fi

HTTP_RULE=""
HTTPS_RULE=""
[[ "$ALLOW_HTTP"  == "1" ]] && HTTP_RULE="    tcp dport 80  ct state new accept"
[[ "$ALLOW_HTTPS" == "1" ]] && HTTPS_RULE="    tcp dport 443 ct state new accept"

# Extra TCP/UDP ports (e.g. published container ports). Accept space- or
# comma-separated lists; emit one accept rule per port.
EXTRA_PORT_RULES=""
emit_port_rules() {  # $1=proto (tcp|udp)  $2=list
  local proto="$1" list="$2" p
  list="${list//,/ }"
  for p in $list; do
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )) || continue
    EXTRA_PORT_RULES+="    ${proto} dport ${p} ct state new accept"$'\n'
  done
}
emit_port_rules tcp "$ALLOW_TCP_PORTS"
emit_port_rules udp "$ALLOW_UDP_PORTS"
EXTRA_PORT_RULES="${EXTRA_PORT_RULES%$'\n'}"

# Docker-compatible firewall: flush ONLY our own table (so we never clobber
# Docker's iptables-nft tables), and don't drop the forward hook (Docker
# manages forwarding via its own chains + DOCKER-USER). See Docker prereqs.
if [[ "$DOCKER_COMPAT" == "1" ]]; then
  NFT_TITLE="# Hardened firewall — deny-by-default input (Docker-compatible)"
  NFT_FLUSH=$'# Docker-safe: replace only our table, leaving iptables-nft (ip/ip6) tables intact\ntable inet filter\ndelete table inet filter'
  FWD_POLICY="accept"
  FWD_COMMENT=$'\n    # Docker-compat: forwarding handled by Docker\'s iptables-nft chains / DOCKER-USER'
else
  NFT_TITLE="# Hardened firewall — deny-by-default"
  NFT_FLUSH="flush ruleset"
  FWD_POLICY="drop"
  FWD_COMMENT=""
fi

write_file "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f
${NFT_TITLE}

${NFT_FLUSH}

table inet filter {
  set allowed_icmp_v4_types {
    type icmp_type; elements = { echo-request, time-exceeded, destination-unreachable }
  }

  chain input {
    type filter hook input priority 0;
    policy drop;

    iif lo accept
    ct state established,related accept

    # ICMP with simple rate limit
    ip protocol icmp icmp type @allowed_icmp_v4_types limit rate 10/second accept
    ip6 nexthdr icmpv6 limit rate 10/second accept

${SSH_ALLOW_RULES}
${HTTP_RULE}
${HTTPS_RULE}
${EXTRA_PORT_RULES}

    # Optional log (comment out if too noisy)
    # counter log prefix "nftables-drop: " flags all drop
    drop
  }

  chain forward {
    type filter hook forward priority 0;
    policy ${FWD_POLICY};${FWD_COMMENT}
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
EOF

info "Loading firewall ruleset..."
# Validate BEFORE applying. A malformed ruleset must never abort the run with
# the new sshd config already live and no firewall — that's a lockout. If the
# check fails, restore the backup (if any) and warn loudly instead of dying.
if ! nft -c -f "$NFT_CONF" 2>/tmp/nft-check.$$; then
  err "Generated nftables ruleset is invalid — NOT applying it (your current firewall is untouched)."
  sed 's/^/    /' /tmp/nft-check.$$ 2>/dev/null | head -n 10 || true
  rm -f /tmp/nft-check.$$
  if [[ -f "$BACKUP_DIR/nftables.conf.bak" ]]; then
    run cp -a "$BACKUP_DIR/nftables.conf.bak" "$NFT_CONF"
    note "Restored previous nftables.conf from backup."
  fi
  warn "Fix the firewall inputs (e.g. ALLOW_SSH_CIDRS / ALLOW_TCP_PORTS) and re-run. SSH on ${SSH_PORT} is configured but may be unprotected/unreachable until the firewall loads."
else
  rm -f /tmp/nft-check.$$
  run nft -f "$NFT_CONF"
  run systemctl enable --now nftables
  log "Firewall configured: default-drop input, SSH allowed, established/related kept."
fi
note "SSH allowed on: ${SSH_PORT}$( [[ $ALLOW_SSH_PORT_22 == 1 ]] && echo ' + 22' )  | sources: ${ALLOW_SSH_CIDRS:-any}"
[[ -n "$HTTP_RULE"  ]] && note "HTTP/80 allowed"
[[ -n "$HTTPS_RULE" ]] && note "HTTPS/443 allowed"
[[ -n "$ALLOW_TCP_PORTS" ]] && note "Extra TCP ports allowed: ${ALLOW_TCP_PORTS//,/ }"
[[ -n "$ALLOW_UDP_PORTS" ]] && note "Extra UDP ports allowed: ${ALLOW_UDP_PORTS//,/ }"
if [[ "$DOCKER_COMPAT" == "1" ]]; then
  note "Docker-compatible: forward=accept, scoped flush (Docker's iptables-nft rules preserved)."
  record "Firewall" "nftables (Docker-compat); input deny-by-default, forward=accept, SSH=${SSH_PORT}$( [[ $ALLOW_SSH_PORT_22 == 1 ]] && echo '+22' ), HTTP=$ALLOW_HTTP, HTTPS=$ALLOW_HTTPS"
else
  record "Firewall" "nftables deny-by-default; SSH=${SSH_PORT}$( [[ $ALLOW_SSH_PORT_22 == 1 ]] && echo '+22' ), HTTP=$ALLOW_HTTP, HTTPS=$ALLOW_HTTPS"
fi
fi   # end: HARDEN_FIREWALL

# ==============================================================================
if [[ "$HARDEN_FAIL2BAN" == "1" ]]; then
banner "Configuring fail2ban"
# ==============================================================================
run mkdir -p /etc/fail2ban/jail.d
write_file /etc/fail2ban/jail.d/ssh.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = /var/log/auth.log
backend = systemd
maxretry = 5
bantime = 3600
findtime = 600
EOF
run systemctl enable --now fail2ban
log "fail2ban watching sshd: 5 retries / 10 min → 1 h ban."
record "fail2ban" "sshd jail on port $SSH_PORT (maxretry=5, bantime=3600s)"
fi   # end: HARDEN_FAIL2BAN

# ==============================================================================
if [[ "$HARDEN_APPARMOR" == "1" ]]; then
banner "Ensuring AppArmor is enabled"
# ==============================================================================
# Note: keeping AppArmor enabled also enforces Debian's unprivileged-userns
# restriction (kernel.apparmor_restrict_unprivileged_userns) where the kernel
# has it. That's fine — container.sh grants ONLY the rootless binaries
# (rootlesskit and/or podman) the 'userns' permission via dedicated AppArmor
# profiles, so rootless Docker/Podman work without weakening this.
# See https://docs.docker.com/engine/security/apparmor/
if [[ "$IS_CONTAINER" == "1" ]]; then
  # Inside an LXC/container the kernel's AppArmor is owned by the Proxmox HOST;
  # apparmor.service can't load profiles here and would fail to start. Skip it.
  warn "Skipping AppArmor — managed by the host in a ${CONTAINER_TYPE} container."
  note "Enable/confirm AppArmor on the Proxmox host, not inside the container."
  record "AppArmor" "Skipped (host-managed in ${CONTAINER_TYPE} container)"
elif ! run systemctl enable --now apparmor; then
  # Don't abort the whole run if the unit won't start (e.g. unusual kernels).
  warn "Could not enable apparmor.service — continuing without it."
  note "Check 'systemctl status apparmor' and the kernel's AppArmor support."
  record "AppArmor" "Enable failed (continued; see systemctl status apparmor)"
elif aa-status >/dev/null 2>&1; then
  AA_PROFILES="$(aa-status --profiled 2>/dev/null || echo '?')"
  log "AppArmor active — ${AA_PROFILES} profiles loaded."
  record "AppArmor" "Enabled (${AA_PROFILES} profiles loaded)"
else
  log "AppArmor will be enabled at boot."
  record "AppArmor" "Enabled (status read skipped/unavailable)"
fi
fi   # end: HARDEN_APPARMOR

# ==============================================================================
if [[ "$HARDEN_AIDE" == "1" ]]; then
banner "Initializing AIDE baseline"
# ==============================================================================
run_aideinit() {
  info "Building file-integrity database (this can take a minute)..."
  aideinit || true
  if [[ -f /var/lib/aide/aide.db.new ]]; then
    cp -a /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    log "AIDE baseline database installed at /var/lib/aide/aide.db."
    record "AIDE" "Baseline DB initialized"
  else
    warn "AIDE baseline DB not found after init — review 'aideinit' output."
    record "AIDE" "Init attempted (baseline DB not confirmed)"
  fi
}

# Bulk-data mounts (NFS datastores, docked disks, media) are never part of the
# integrity baseline: indexing them can pin a CPU for days (pbs0, 2026-09-17,
# 16 h of CPU walking a 937 GB PBS chunk store over NFS). Debian's aide.conf
# pulls in /etc/aide/aide.conf.d via @@x_include, so a drop-in is enough.
# The rule must be the NON-recursive form "-<regex>" (AIDE 0.19+): the
# classic "!<regex>" only drops the results and still walks the whole tree,
# which costs exactly the same CPU. Debian 13 ships AIDE 0.19.
AIDE_EXCLUDES="${AIDE_EXCLUDES:-/mnt /media /export /var/lib/vz}"
# ZFS hosts (PVE nodes): every pool mounted somewhere other than / holds guest
# data (container root filesystems as subvol-* datasets, replicas, dumps).
# Each pool's top mountpoint is excluded as a whole; the root dataset is a
# child mounted at / and is unaffected. pve4 had no baseline at all because
# its bootstrap-day init tried to hash every container's files.
if command -v zfs >/dev/null 2>&1; then
  while IFS= read -r _mp; do
    [[ -z "$_mp" || "$_mp" == "/" || "$_mp" == "none" || "$_mp" == "legacy" || "$_mp" == "-" ]] && continue
    case " $AIDE_EXCLUDES " in *" $_mp "*) ;; *) AIDE_EXCLUDES="$AIDE_EXCLUDES $_mp";; esac
  done < <(zfs list -H -d 0 -o mountpoint 2>/dev/null)
fi
# Container image stores are bulk data too: rootful docker under /var/lib/docker
# and rootless docker under every user's ~/.local/share/docker (dkr's daily
# check cost 3 h of CPU and 6.6 GB of RAM walking it, 2026-09-18).
if command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; then
  for _d in /var/lib/docker /var/lib/containers; do
    [[ -d "$_d" ]] && case " $AIDE_EXCLUDES " in *" $_d "*) ;; *) AIDE_EXCLUDES="$AIDE_EXCLUDES $_d";; esac
  done
  for _h in /home/*/.local/share/docker /home/*/.local/share/containers /root/.local/share/docker; do
    [[ -d "$_h" ]] && AIDE_EXCLUDES="$AIDE_EXCLUDES $_h"
  done
fi
# App data that only this host knows about (recordings, media, big caches)
# goes in /etc/aide/aide.conf.d/98_local_exclude, written by hand with the
# same "-/path" lines; the bootstrap never touches that file.
if [[ -d /etc/aide/aide.conf.d ]]; then
  # AIDE 0.19 (Debian 13) has the non-recursive "-" rule; 0.18 (Debian 12)
  # rejects it, so there the classic "!" is written (valid, but it still walks
  # the tree: upgrade such hosts to Debian 13 to get the real exclusion).
  _aide_ver="$(aide --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
  _aide_pfx='-'
  if [[ -n "$_aide_ver" ]] && ! dpkg --compare-versions "$_aide_ver" ge 0.19; then
    _aide_pfx='!'
    warn "AIDE ${_aide_ver} has no non-recursive rule: writing '!' excludes (they still walk the tree)."
  fi
  {
    printf '# Written by harden.sh: bulk-data mounts are not part of the integrity baseline.\n'
    printf '# "-" = non-recursive negative rule (AIDE 0.19+): the directory is never entered.\n'
    printf '# Override with AIDE_EXCLUDES="/path /path" at run time; ZFS pool mountpoints are added.\n'
    for p in $AIDE_EXCLUDES; do printf -- '%s%s\n' "$_aide_pfx" "$p"; done
  } > /etc/aide/aide.conf.d/99_homelab_exclude
  log "AIDE excludes written (${_aide_pfx}): $AIDE_EXCLUDES (/etc/aide/aide.conf.d/99_homelab_exclude)."
fi

# FINT-4402: make sure the AIDE config references SHA-512 checksums.
if [[ -f /etc/aide/aide.conf ]] && ! grep -q 'sha512' /etc/aide/aide.conf 2>/dev/null; then
  cp -a /etc/aide/aide.conf "$BACKUP_DIR/aide.conf.bak" 2>/dev/null || true
  printf '\n# Lynis FINT-4402: reference strong checksums in the AIDE config\nHardening_Checksums = sha256+sha512\n' >> /etc/aide/aide.conf
  log "AIDE config now references SHA-512 checksums."
fi

if [[ -f /var/lib/aide/aide.db && "$REBUILD_AIDE" != "1" ]]; then
  info "AIDE baseline already exists."
  # Interactive-only question: under ASSUME_YES this used to auto-answer YES
  # and rebuild the baseline on every re-run. Non-interactive keeps the
  # existing baseline; REBUILD_AIDE=1 forces a rebuild.
  if [[ "$INTERACTIVE" -eq 1 ]] && confirm "Rebuild the AIDE baseline database now?" N; then
    run_aideinit
  else
    log "Keeping existing AIDE baseline (idempotent skip)."
    record "AIDE" "Existing baseline kept (rebuild skipped)"
  fi
else
  run_aideinit
fi
fi   # end: HARDEN_AIDE

# ==============================================================================
if [[ "$HARDEN_SYSCTL" == "1" ]]; then
banner "Applying kernel/network sysctl hardening"
# ==============================================================================
SYSCTL_H="/etc/sysctl.d/99-hardening.conf"
run cp -a /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak" 2>/dev/null || true
# Docker requires IPv4 forwarding; otherwise keep it off for a non-router host.
if [[ "$DOCKER_COMPAT" == "1" ]]; then IP_FWD=1; IP_FWD_NOTE="enabled for Docker"; else IP_FWD=0; IP_FWD_NOTE="off (host is not a router)"; fi
# A PVE node routes for its guests and for the Thunderbolt mesh (routed
# fallback between nodes), so forwarding stays on and reverse-path filtering
# is loose (2) rather than strict (1), which drops asymmetric mesh paths.
RPF=1
if [[ "$IS_PVE" == "1" ]]; then IP_FWD=1; IP_FWD_NOTE="enabled (Proxmox VE node: guests and mesh routing)"; RPF=2; fi
write_file "$SYSCTL_H" <<EOF
# Minimal kernel/network hardening
net.ipv4.ip_forward = ${IP_FWD}   # ${IP_FWD_NOTE}
net.ipv4.conf.all.rp_filter = ${RPF}
net.ipv4.conf.default.rp_filter = ${RPF}
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
# IPv6 redirect/source-route protection
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# Kernel hardening (Lynis KRNL-6000)
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.sysrq = 0
kernel.core_uses_pid = 1
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF
run sysctl --system || true
log "sysctl hardening applied (rp_filter, syncookies, redirect/martian protection, ...)."
note "net.ipv4.ip_forward = ${IP_FWD} (${IP_FWD_NOTE})."
record "sysctl" "Hardening applied to $SYSCTL_H (ip_forward=${IP_FWD})"
fi   # end: HARDEN_SYSCTL

# ==============================================================================
if [[ "$HARDEN_EXTRA" == "1" ]]; then
banner "Applying extra hardening (Lynis suggestions)"
# ==============================================================================
# USB-SATA bridges: every ASMedia bridge in the fleet (174c:55aa enclosures
# and dock, 174c:1153 single-disk cable) corrupts reads under the uas driver
# (aborts + device resets: pms0 XFS 2026-09-16, 152 ZFS checksum errors on
# pve2 2026-09-18, "slow IOs rising" on pve3/pve4). Pin them to usb-storage
# everywhere; harmless on hosts without such a bridge. Takes effect for
# devices plugged after this run and at the next boot (initramfs updated).
USB_STORAGE_QUIRKS="${USB_STORAGE_QUIRKS:-174c:55aa:u,174c:1153:u}"
if [[ -n "$USB_STORAGE_QUIRKS" ]]; then
  write_file /etc/modprobe.d/usb-storage-quirks.conf <<EOF
# debian13-homelab-bootstrap: ASMedia USB-SATA bridges on usb-storage, never uas
options usb-storage quirks=${USB_STORAGE_QUIRKS}
EOF
  [[ -w /sys/module/usb_storage/parameters/quirks ]] && echo "$USB_STORAGE_QUIRKS" > /sys/module/usb_storage/parameters/quirks 2>/dev/null || true
  run update-initramfs -u >/dev/null 2>&1 || true
  log "usb-storage quirks set: ${USB_STORAGE_QUIRKS} (uas disabled for those bridges)."
  record "USB bridges" "usb-storage quirks ${USB_STORAGE_QUIRKS}"
fi

# Safe, automatable fixes for common Lynis suggestions, applied BEFORE the audit.

# set_logindef KEY VALUE — set a directive in /etc/login.defs (idempotent).
set_logindef() {
  local key="$1" val="$2" f=/etc/login.defs
  if grep -qiE "^\s*#?\s*${key}\b" "$f" 2>/dev/null; then
    sed -i -E "s@^\s*#?\s*(${key})\b.*@\1 ${val}@i" "$f"
  else
    printf '%s\t%s\n' "$key" "$val" >> "$f"
  fi
  note "${key} ${DIM}->${RESET} ${val}"
}

# 1) Packages: PAM/tmp, package auditing, accounting, malware scanner, etc.
# apt-listbugs is deliberately NOT here: it hooks every apt run and aborts
# non-interactive installs when it cannot reach the bug tracker (broke the
# pbs upgrade prep on 2026-09-18). Hosts that already have it get it removed.
EXTRA_PKGS=(
  libpam-tmpdir libpam-pwquality debsums apt-show-versions
  acct sysstat rkhunter
)
if dpkg-query -W -f='${Status}' apt-listbugs 2>/dev/null | grep -q 'install ok installed'; then
  DEBIAN_FRONTEND=noninteractive APT_LISTBUGS_FRONTEND=none apt-get -y -q purge apt-listbugs >/dev/null 2>&1 || true
  log "apt-listbugs removed (its apt hook breaks unattended package runs)."
fi
# auditd's kernel audit subsystem is host-owned and cannot run inside an
# (unprivileged) LXC/container — its postinst even errors out trying to start
# the service. Only install it on bare metal / full VMs (see header comment).
if [[ "$IS_CONTAINER" != "1" ]]; then
  EXTRA_PKGS+=(auditd)
else
  note "Skipping auditd install — audit subsystem is host-managed in a ${CONTAINER_TYPE} container."
fi
info "Installing hardening helpers: ${DIM}${EXTRA_PKGS[*]}${RESET}"
run apt -y install "${EXTRA_PKGS[@]}"
record "Extra pkgs" "${#EXTRA_PKGS[@]} installed (pwquality, debsums, auditd, sysstat, acct, rkhunter, ...)"

# 2) Enable accounting/audit collectors (ACCT-9622/9626/9628).
[[ -f /etc/default/sysstat ]] && sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
run systemctl enable --now sysstat 2>/dev/null || true
[[ "$IS_CONTAINER" != "1" ]] && run systemctl enable --now auditd 2>/dev/null || true
run systemctl enable --now acct 2>/dev/null || run systemctl enable --now acct.service 2>/dev/null || true
if [[ "$IS_CONTAINER" != "1" ]]; then
  log "Process accounting (acct), sysstat and auditd enabled."
else
  log "Process accounting (acct) and sysstat enabled (auditd skipped in container)."
fi

# 3) /etc/login.defs: password aging, hashing rounds, umask (AUTH-9230/9286/9328).
info "Hardening /etc/login.defs..."
run cp -a /etc/login.defs "$BACKUP_DIR/login.defs.bak" 2>/dev/null || true
set_logindef PASS_MAX_DAYS 365
set_logindef PASS_MIN_DAYS 1
set_logindef PASS_WARN_AGE 7
set_logindef SHA_CRYPT_MIN_ROUNDS 65536
set_logindef SHA_CRYPT_MAX_ROUNDS 65536
if [[ "$IS_PVE" == "1" ]]; then
  # UMASK 027 makes 'pct create' build a 0750 rootfs the userns root cannot
  # traverse (Kan sdds9tw12dv3). A PVE node keeps the Debian default.
  set_logindef UMASK 022
  note "Proxmox VE host: login.defs UMASK kept at 022 (027 breaks pct create, Kan sdds9tw12dv3)."
else
  set_logindef UMASK 027
fi
record "login.defs" "password aging + SHA rounds + UMASK 027"

# 4) fail2ban jail.local so updates can't clobber config (DEB-0880).
if [[ -f /etc/fail2ban/jail.conf && ! -f /etc/fail2ban/jail.local ]]; then
  run cp -a /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
  log "Created /etc/fail2ban/jail.local from jail.conf."
fi

# 5) Blacklist rare/unused kernel modules (NETW-3200, STRG-1846; USB-1000 opt-in).
#    usb-storage is OPT-IN — blacklisting it disables USB flash/disk drives, which
#    is often unwanted on a homelab. Set BLACKLIST_USB_STORAGE=1 (or answer the
#    prompt) to include it.
if [[ -z "${BLACKLIST_USB_STORAGE:-}" ]]; then
  # Interactive-only question: under ASSUME_YES this used to auto-answer YES.
  if [[ "$INTERACTIVE" -eq 1 ]] && confirm "Also blacklist usb-storage (disables USB drives) for tighter security?" N; then
    BLACKLIST_USB_STORAGE=1
  else
    BLACKLIST_USB_STORAGE=0
  fi
fi
# Never blacklist usb-storage when the root filesystem lives on a USB disk:
# modprobe.d blacklists are copied into the next initramfs, and a USB-booted
# host would then fail to find its root device. Best-effort detection.
if [[ "$BLACKLIST_USB_STORAGE" == "1" ]]; then
  _rootsrc="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  _rootdisk="$(lsblk -no PKNAME "$_rootsrc" 2>/dev/null | head -n1 || true)"
  _roottran="$(lsblk -dno TRAN "/dev/${_rootdisk}" 2>/dev/null || true)"
  if [[ "$_roottran" == "usb" ]]; then
    warn "Root filesystem is on a USB disk (/dev/${_rootdisk}) — REFUSING to blacklist usb-storage (the next initramfs would leave the host unbootable)."
    BLACKLIST_USB_STORAGE=0
  fi
fi
{
  printf '%s\n' "# Disable rarely-used network protocols and storage drivers (Lynis hardening)."
  printf '%s\n' "# Reverse by deleting this file. Remove a line if you actually need that module."
  printf '%s\n' "install dccp /bin/true"
  printf '%s\n' "install sctp /bin/true"
  printf '%s\n' "install rds /bin/true"
  printf '%s\n' "install tipc /bin/true"
  printf '%s\n' "install firewire-core /bin/true"
  # NB: keep this `if` (not `[[ ]] && printf`) — as the brace group's last command,
  # a false `&&` test exits 1, which pipefail+set -e would turn into a script abort.
  if [[ "$BLACKLIST_USB_STORAGE" == "1" ]]; then printf '%s\n' "install usb-storage /bin/true"; fi
} | write_file /etc/modprobe.d/99-hardening-blacklist.conf
if [[ "$BLACKLIST_USB_STORAGE" == "1" ]]; then
  log "Blacklisted dccp, sctp, rds, tipc, firewire-core, usb-storage (reversible)."
  note "Remove /etc/modprobe.d/99-hardening-blacklist.conf if you need USB storage."
  record "Module blacklist" "rare protocols + firewire + usb-storage (reversible)"
else
  log "Blacklisted dccp, sctp, rds, tipc, firewire-core (usb-storage left enabled)."
  note "usb-storage NOT blacklisted (USB drives still work). Set BLACKLIST_USB_STORAGE=1 to include it."
  record "Module blacklist" "rare protocols + firewire (usb-storage left enabled)"
fi

# 6) Legal login banners (BANN-7126, BANN-7130).
BANNER_TEXT="Authorized access only. All connections and activity may be monitored and logged."
write_file /etc/issue     <<EOF
${BANNER_TEXT}
EOF
write_file /etc/issue.net <<EOF
${BANNER_TEXT}
EOF
log "Wrote legal login banners to /etc/issue and /etc/issue.net."
record "Login banner" "legal warning set (/etc/issue, /etc/issue.net)"

# 6b) Restrict permissions on sensitive files/dirs (FILE-7524). Only existing
#     paths are touched; these are the files Lynis expects to be tightened.
_perm_targets=(
  "/etc/crontab:600"
  "/etc/cron.d:700" "/etc/cron.daily:700" "/etc/cron.hourly:700"
  "/etc/cron.weekly:700" "/etc/cron.monthly:700"
  "/etc/cron.allow:600" "/etc/cron.deny:600"
  "/etc/at.allow:600" "/etc/at.deny:600"
  "/etc/ssh/sshd_config:600"
  "/boot/grub/grub.cfg:600"
)
_perm_changed=0
for _t in "${_perm_targets[@]}"; do
  _path="${_t%%:*}"; _mode="${_t##*:}"
  [[ -e "$_path" ]] || continue
  chmod "$_mode" "$_path" 2>/dev/null || true
  _perm_changed=$((_perm_changed + 1))
done
log "Restricted permissions on ${_perm_changed} sensitive files/dirs (cron, sshd_config, grub.cfg)."
record "File perms" "tightened ${_perm_changed} paths (FILE-7524)"

# 7) debsums: schedule regular verification via cron (PKGS-7370).
# The cron wrapper (/etc/cron.daily/debsums) reads CRON_CHECK from this file;
# it defaults to "never". Valid values: never|daily|weekly|monthly. We ensure
# the file exists (it isn't always shipped) and set it to weekly.
DEBSUMS_DEFAULT="/etc/default/debsums"
if [[ -f "$DEBSUMS_DEFAULT" ]] && grep -qE '^#?\s*CRON_CHECK=' "$DEBSUMS_DEFAULT"; then
  sed -i -E 's@^#?\s*CRON_CHECK=.*@CRON_CHECK="weekly"@' "$DEBSUMS_DEFAULT"
else
  printf '# debsums config — verify installed packages against known-good MD5s.\nCRON_CHECK="weekly"\n' >> "$DEBSUMS_DEFAULT"
fi
log "debsums scheduled to verify packages weekly (${DEBSUMS_DEFAULT})."
record "debsums" "CRON_CHECK=weekly in ${DEBSUMS_DEFAULT}"

# 8) auditd: install a basic ruleset so it is not "enabled with empty ruleset" (ACCT-9630).
#    Skipped in containers — auditd isn't installed there (host-owned subsystem).
if [[ "$IS_CONTAINER" == "1" ]]; then
  note "Skipping auditd ruleset — audit subsystem is host-managed in a ${CONTAINER_TYPE} container."
else
write_file /etc/audit/rules.d/99-hardening.rules <<'EOF'
## Minimal hardening audit ruleset (Lynis ACCT-9630)
-D
-b 8192
-f 1
# Watch sensitive identity & auth files
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/pam.d/ -p wa -k pam
-w /etc/login.defs -p wa -k logindefs
# Enable auditing (use 2 to lock rules until reboot if you prefer)
-e 1
EOF
augenrules --load 2>/dev/null || true
log "auditd given a basic ruleset (identity, sudoers, sshd, pam)."
record "auditd rules" "basic ruleset installed (ACCT-9630)"
fi

# 9) Backup DNS resolver so 2 nameservers are reachable (NETW-2705).
BACKUP_DNS="${BACKUP_DNS:-1.1.1.1 9.9.9.9}"
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  RC=/etc/systemd/resolved.conf
  run cp -a "$RC" "$BACKUP_DIR/resolved.conf.bak" 2>/dev/null || true
  if grep -qE '^#?FallbackDNS=' "$RC" 2>/dev/null; then
    sed -i -E "s@^#?FallbackDNS=.*@FallbackDNS=${BACKUP_DNS}@" "$RC"
  else
    printf 'FallbackDNS=%s\n' "$BACKUP_DNS" >> "$RC"
  fi
  systemctl restart systemd-resolved 2>/dev/null || true
  log "systemd-resolved FallbackDNS set to: ${BACKUP_DNS}."
  record "Backup DNS" "systemd-resolved FallbackDNS=${BACKUP_DNS}"
elif [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]]; then
  if (( $(grep -c '^nameserver' /etc/resolv.conf 2>/dev/null || echo 0) < 2 )); then
    for _ns in $BACKUP_DNS; do
      grep -qE "^nameserver[[:space:]]+${_ns}\b" /etc/resolv.conf || printf 'nameserver %s\n' "$_ns" >> /etc/resolv.conf
    done
    log "Added backup nameserver(s) to /etc/resolv.conf: ${BACKUP_DNS}."
    record "Backup DNS" "added to /etc/resolv.conf (${BACKUP_DNS})"
  fi
else
  note "DNS managed elsewhere (resolv.conf is a symlink); skipping backup-DNS edit."
fi

# 10) OPT-IN extras (off unless requested) -----------------------------------
# Remote syslog forwarding (LOGG-2154): set REMOTE_SYSLOG="host:port".
if [[ -n "${REMOTE_SYSLOG:-}" ]]; then
  write_file /etc/rsyslog.d/99-remote.conf <<EOF
# Forward all logs to a remote syslog host over TCP (Lynis LOGG-2154).
*.* @@${REMOTE_SYSLOG}
EOF
  run systemctl restart rsyslog 2>/dev/null || true
  log "Forwarding logs to remote syslog: ${REMOTE_SYSLOG}."
  record "Remote syslog" "forwarding to ${REMOTE_SYSLOG}"
fi

# GRUB boot-loader password (BOOT-5122): set GRUB_PASSWORD="..." to enable.
# Uses --unrestricted so normal boot is NOT blocked; only editing entries /
# single-user mode requires the password.
if [[ -n "${GRUB_PASSWORD:-}" ]] && command -v grub-mkpasswd-pbkdf2 >/dev/null 2>&1; then
  _grub_hash="$(printf '%s\n%s\n' "$GRUB_PASSWORD" "$GRUB_PASSWORD" | grub-mkpasswd-pbkdf2 2>/dev/null | awk '/grub\.pbkdf2/{print $NF}')"
  if [[ -n "$_grub_hash" ]]; then
    cp -a /etc/grub.d/40_custom "$BACKUP_DIR/40_custom.bak" 2>/dev/null || true
    # Idempotent: update the hash in place if already configured, else append.
    if grep -q '^password_pbkdf2 root ' /etc/grub.d/40_custom 2>/dev/null; then
      sed -i -E "s@^password_pbkdf2 root .*@password_pbkdf2 root ${_grub_hash}@" /etc/grub.d/40_custom
      grep -q '^set superusers=' /etc/grub.d/40_custom || printf 'set superusers="root"\n' >> /etc/grub.d/40_custom
      log "GRUB password updated (existing entry)."
    else
      cat >> /etc/grub.d/40_custom <<EOF

# Lynis BOOT-5122: protect GRUB editing / single-user mode with a password.
set superusers="root"
password_pbkdf2 root ${_grub_hash}
EOF
      log "GRUB password set (normal boot stays password-free)."
    fi
    # Keep normal boot password-free by marking menu entries unrestricted.
    if [[ -f /etc/grub.d/10_linux ]] && ! grep -q -- '--unrestricted' /etc/grub.d/10_linux; then
      sed -i -E 's@^(CLASS=".*)"@\1 --unrestricted"@' /etc/grub.d/10_linux || true
    fi
    update-grub 2>/dev/null || update-grub2 2>/dev/null || true
    record "GRUB password" "set (superuser=root, --unrestricted)"
  else
    warn "Could not generate a GRUB password hash — skipped."
  fi
fi

# Restrict compilers to root only (HRDN-7222). Applied by default; set
# HARDEN_COMPILERS=0 to skip (e.g. if non-root users must compile on this host).
if [[ "${HARDEN_COMPILERS:-1}" != "0" ]]; then
  _comp_done=()
  for _c in cc gcc g++ c++ clang clang++ as ld; do
    _p="$(command -v "$_c" 2>/dev/null || true)"
    [[ -n "$_p" ]] || continue
    _rp="$(readlink -f "$_p" 2>/dev/null || echo "$_p")"
    chown root:root "$_rp" 2>/dev/null || true
    chmod 0750 "$_rp" 2>/dev/null || true
    _comp_done+=("$_c")
  done
  if (( ${#_comp_done[@]} > 0 )); then
    log "Restricted compilers to root only: ${_comp_done[*]}."
    record "Compilers" "restricted to root (${_comp_done[*]})"
  fi
fi
fi   # end: HARDEN_EXTRA

# ==============================================================================
LYNIS_SCORE="n/a"; LYNIS_WARN=0; LYNIS_SUGG=0
LYNIS_REPORT="/var/log/lynis-report.dat"; LYNIS_LOG="/var/log/lynis.log"
if [[ "$HARDEN_LYNIS" == "1" ]]; then
banner "Running Lynis quick audit (non-blocking)"
# ==============================================================================
info "Auditing the system with Lynis..."
lynis audit system --quick || true
if [[ -r "$LYNIS_REPORT" ]]; then
  LYNIS_SCORE="$(awk -F= '/^hardening_index=/{print $2}' "$LYNIS_REPORT" | tail -n1)"; [[ -n "$LYNIS_SCORE" ]] || LYNIS_SCORE="n/a"
  LYNIS_WARN="$(grep -c '^warning\[\]=' "$LYNIS_REPORT" 2>/dev/null || echo 0)"
  LYNIS_SUGG="$(grep -c '^suggestion\[\]=' "$LYNIS_REPORT" 2>/dev/null || echo 0)"
fi
log "Lynis audit complete. Hardening index: ${BOLD}${LYNIS_SCORE}${RESET} (${LYNIS_WARN} warnings, ${LYNIS_SUGG} suggestions)."
fi   # end: HARDEN_LYNIS

# ==============================================================================
#  Live status block
# ==============================================================================
header "Live status"
printf '\n%s%sListening services:%s\n' "$BOLD" "$WHT" "$RESET"
ss -tulpen 2>/dev/null || true

printf '\n%s%sfail2ban (first 12 lines):%s\n' "$BOLD" "$WHT" "$RESET"
systemctl --no-pager status fail2ban 2>/dev/null | sed -n '1,12p' || true

printf '\n%s%sActive nftables ruleset:%s\n' "$BOLD" "$WHT" "$RESET"
nft list ruleset 2>/dev/null || true

# ==============================================================================
#  Reboot-required detection (read-only)
# ==============================================================================
# Sets REBOOT_REQUIRED (0/1) and REBOOT_REASON by checking the standard flag
# file (created by needrestart / unattended-upgrades / kernel postinst) and by
# comparing the running kernel against the newest installed one.
REBOOT_REQUIRED=0
REBOOT_REASON=""
detect_reboot_required() {
  local running newest pkgs
  if [[ -f /run/reboot-required || -f /var/run/reboot-required ]]; then
    REBOOT_REQUIRED=1
    REBOOT_REASON="system flagged /run/reboot-required"
    if [[ -f /run/reboot-required.pkgs ]]; then
      pkgs="$(tr '\n' ' ' < /run/reboot-required.pkgs 2>/dev/null | sed 's/[[:space:]]\+$//')"
      [[ -n "$pkgs" ]] && REBOOT_REASON="updated packages need it: ${pkgs}"
    fi
  fi
  running="$(uname -r)"
  # Containers share the HOST kernel and have no /boot/vmlinuz-*, so comparing
  # the running kernel to an "installed" one is meaningless inside one (and the
  # non-matching glob would make `ls` fail with exit 2, aborting under set -e).
  # Only do the kernel comparison on bare metal / full VMs.
  if [[ "$IS_CONTAINER" != "1" ]]; then
    newest="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n1 || true)"
    if [[ -n "$newest" && "$newest" != "$running" ]]; then
      REBOOT_REQUIRED=1
      if [[ -n "$REBOOT_REASON" ]]; then
        REBOOT_REASON="${REBOOT_REASON}; newer kernel installed (${newest}, running ${running})"
      else
        REBOOT_REASON="newer kernel installed (${newest}; running ${running})"
      fi
    fi
  fi
}
detect_reboot_required
if [[ "$REBOOT_REQUIRED" -eq 1 ]]; then
  record "Reboot" "RECOMMENDED — ${REBOOT_REASON}"
else
  record "Reboot" "not required (hardening applied live)"
fi

# ==============================================================================
#  FINAL RECAP / SUMMARY
# ==============================================================================
ELAPSED=$(( $(date +%s) - START_TS ))
MM=$(( ELAPSED / 60 )); SS=$(( ELAPSED % 60 ))

printf '\n'
hr '═'
printf '%s%s  ✅  HARDENING COMPLETE  —  RECAP%s\n' "$BOLD" "$GRN" "$RESET"
hr '═'
printf '%s  Host: %s   |   Elapsed: %dm %ds   |   Backups: %s%s\n' \
  "$DIM" "$(hostname)" "$MM" "$SS" "$BACKUP_DIR" "$RESET"
hr '─'

printf '%s%s  WHAT WAS DONE%s\n' "$BOLD" "$CYN" "$RESET"
for entry in "${SUMMARY[@]}"; do
  key="${entry%%$'\t'*}"
  val="${entry#*$'\t'}"
  printf '   %s%s%-14s%s %s\n' "$GRN" "$S_OK " "$key" "$RESET" "$val"
done

hr '─'
printf '%s%s  KEY SETTINGS%s\n' "$BOLD" "$CYN" "$RESET"
printf '   %sAdmin users%s  : %s\n' "$WHT" "$RESET" "${ADMIN_USER_LIST[*]}"
printf '   %sSSH port%s     : %s  (port 22 also allowed: %s)\n' "$WHT" "$RESET" "$SSH_PORT" "$ALLOW_SSH_PORT_22"
printf '   %sSSH sources%s  : %s\n' "$WHT" "$RESET" "${ALLOW_SSH_CIDRS:-<any>}"
printf '   %sHTTP / HTTPS%s : 80=%s  443=%s\n' "$WHT" "$RESET" "$ALLOW_HTTP" "$ALLOW_HTTPS"
printf '   %sSSH 2FA%s      : %s\n' "$WHT" "$RESET" "$SSH_2FA_NOTE"
if [[ "$DOCKER_COMPAT" == "1" ]]; then
  printf '   %sDocker-compat%s: %syes%s — ip_forward=1, forward=accept, scoped nft flush; filter via DOCKER-USER\n' \
    "$WHT" "$RESET" "$GRN" "$RESET"
else
  printf '   %sDocker-compat%s: no (firewall is pure-nft, forward dropped, ip_forward=0)\n' "$WHT" "$RESET"
fi

# Lynis security scan — details
hr '─'
printf '%s%s  🔎 LYNIS SECURITY SCAN%s\n' "$BOLD" "$CYN" "$RESET"
# Color the index: >=80 green, 60-79 yellow, <60 red.
_idx_color="$WHT"
if [[ "$LYNIS_SCORE" =~ ^[0-9]+$ ]]; then
  if   (( LYNIS_SCORE >= 80 )); then _idx_color="$GRN"
  elif (( LYNIS_SCORE >= 60 )); then _idx_color="$YEL"
  else _idx_color="$RED"; fi
fi
printf '   %sHardening index%s : %s%s / 100%s   (%s warnings, %s suggestions)\n' \
  "$WHT" "$RESET" "$_idx_color" "$LYNIS_SCORE" "$RESET" "$LYNIS_WARN" "$LYNIS_SUGG"
note "Details: ${LYNIS_REPORT}  |  review: sudo lynis show details"

# Reboot status — prominent, color-coded
hr '─'
if [[ "$REBOOT_REQUIRED" -eq 1 ]]; then
  printf '%s%s  ⚠ REBOOT RECOMMENDED%s\n' "$BOLD" "$YEL" "$RESET"
  printf '   %s%s%s %s\n' "$YEL" "$S_WARN" "$RESET" "$REBOOT_REASON"
  printf '   %sReboot with%s %ssudo systemctl reboot%s %safter confirming your new SSH session works.%s\n' \
    "$DIM" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
else
  printf '%s%s  ✔ NO REBOOT REQUIRED%s\n' "$BOLD" "$GRN" "$RESET"
  printf '   %sHardening was applied live and the running kernel is current.%s\n' "$DIM" "$RESET"
fi

if (( ${#WARNINGS[@]} > 0 )); then
  hr '─'
  printf '%s%s  ⚠ WARNINGS / ACTION ITEMS%s\n' "$BOLD" "$YEL" "$RESET"
  for w in "${WARNINGS[@]}"; do
    printf '   %s%s%s %s\n' "$YEL" "$S_WARN" "$RESET" "$w"
  done
fi

hr '─'
printf '%s%s  ⏭ NEXT STEPS (do not skip)%s\n' "$BOLD" "$MAG" "$RESET"
printf '   %s1.%s KEEP THIS SESSION OPEN. From another terminal, test a NEW login as an admin user:\n' "$BOLD" "$RESET"
for u in "${ADMIN_USER_LIST[@]}"; do
  printf '        %sssh -p %s %s@<host>%s\n' "$DIM" "$SSH_PORT" "$u" "$RESET"
done
printf '   %s2.%s Only close this session AFTER a new SSH connection succeeds.\n' "$BOLD" "$RESET"
if [[ "$LOCK_ROOT_NOW" -eq 1 || "$ROOT_ALREADY_LOCKED" -eq 1 ]]; then
  printf '   %s%s%s root password is locked — use %s%s%s + %ssudo%s for root tasks (reverse: %ssudo passwd -u root%s).\n' \
    "$YEL" "$S_WARN" "$RESET" "$BOLD" "${KEYED_ADMIN:-an admin user}" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
fi
if [[ "$ENABLE_SSH_2FA" == "1" ]]; then
  printf '   %s3.%s Enroll TOTP for each user, e.g.: %ssudo -u %s -H google-authenticator%s\n' "$BOLD" "$RESET" "$DIM" "$ADMIN_USER" "$RESET"
fi
printf '   %s•%s  Restore any change from backups in: %s%s%s\n' "$BOLD" "$RESET" "$DIM" "$BACKUP_DIR" "$RESET"
printf '   %s•%s  To install a container runtime (Docker and/or Podman, rootless) next, run: %ssudo ./container.sh%s\n' \
  "$BOLD" "$RESET" "$DIM" "$RESET"
hr '═'
printf '%s%s  Done. Stay safe. 🔐%s\n\n' "$BOLD" "$GRN" "$RESET"

# One-line summary for init.sh's bootstrap report — only what actually ran.
_root_state="unchanged"
{ [[ "${LOCK_ROOT_NOW:-0}" -eq 1 ]] || [[ "${ROOT_ALREADY_LOCKED:-0}" -eq 1 ]]; } && _root_state="locked"
_comps=()
[[ "$HARDEN_SSH"      == "1" ]] && _comps+=("SSH:${SSH_PORT} key-only")
[[ "$HARDEN_FIREWALL" == "1" ]] && _comps+=("nftables deny-by-default")
[[ "$HARDEN_FAIL2BAN" == "1" ]] && _comps+=(fail2ban)
[[ "$HARDEN_APPARMOR" == "1" ]] && _comps+=(AppArmor)
[[ "$HARDEN_AIDE"     == "1" ]] && _comps+=(AIDE)
[[ "$HARDEN_SYSCTL"   == "1" ]] && _comps+=(sysctl)
[[ "$HARDEN_EXTRA"    == "1" ]] && _comps+=(extras)
_skips=()
for _hc in "${HARDEN_COMPONENTS[@]}"; do
  [[ "${!_hc}" == "1" ]] || _skips+=("${_hc#HARDEN_}")
done
_comps_str="$(IFS='+'; printf '%s' "${_comps[*]:-none}")"
mkdir -p /var/lib/homelab-bootstrap/summaries
printf 'admins: %s (verified); %s; root %s; Lynis %s%s\n' \
  "${ADMIN_USER_LIST[*]}" "$_comps_str" "$_root_state" "${LYNIS_SCORE:-n/a}" \
  "$( (( ${#_skips[@]} )) && printf '; skipped: %s' "${_skips[*],,}" )" \
  > /var/lib/homelab-bootstrap/summaries/harden.sh
