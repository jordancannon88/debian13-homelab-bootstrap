#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — bootstrap (admin user + SSH key)
#  Creates or updates the admin user(s) and installs their SSH public key.
#  Run this FIRST — harden.sh disables password authentication and expects the
#  admin account(s) + authorized_keys to already exist.
#
#  - Creates each admin user (disabled-password unless you provide one) or
#    adopts an existing account, ensures sudo membership, and installs the
#    given SSH public key into ~/.ssh/authorized_keys (idempotent).
#  - Records NEWLY-created users in /var/lib/homelab-bootstrap/created-users so
#    later scripts can target them (e.g. ancillary.sh's fish default shell).
#
#  Run as root, e.g.  sudo ./bootstrap.sh
#
#  Environment overrides:
#    ADMIN_USERS="u1 u2 ..." -> admin users to create/update (default: asks)
#    PUBKEY="ssh-..."         -> SSH key for the primary (first) user
#    PUBKEY_<user>="ssh-..."  -> SSH key for a specific user
#    ADMIN_PASSWORD="..."     -> password for the primary user IF newly created
#    PASSWORD_<user>="..."    -> password for a specific NEWLY-created user
#                                (existing accounts are never changed; blank =
#                                passwordless / SSH-key only)
#    CREATE_<user>=1|0        -> auto-answer the "create missing user?" prompt
#    ASSUME_YES=1             -> answer "yes" to every prompt (automation)
# ==============================================================================

set -euo pipefail

# Ensure the admin sbin paths are present — adduser, usermod, etc. live in
# /usr/sbin and /sbin, which some non-login shells / sudo configs drop from PATH.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ASSUME_YES="${ASSUME_YES:-0}"

START_TS="$(date +%s)"

# Admin users to create/update identically (sudo + SSH key). There is NO default
# user — if ADMIN_USERS is not set, the script interactively asks. ADMIN_USER is
# just the first one (used for messaging and as PUBKEY/ADMIN_PASSWORD's target).
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
PUBKEY="${PUBKEY:-}"
declare -A USER_EXISTS USER_HASKEY USER_PUBKEY USER_PASSWORD WANT_CREATE

# State shared with the other scripts: usernames this run NEWLY created.
STATE_DIR="/var/lib/homelab-bootstrap"
CREATED_USERS_FILE="$STATE_DIR/created-users"

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

SUMMARY=()
record() { SUMMARY+=("$1"$'\t'"$2"); }

hr()   { local ch="${1:-─}" w=72 l=""; printf -v l '%*s' "$w" ''; printf '%s%s%s\n' "$DIM" "${l// /$ch}" "$RESET"; }
banner() { printf '\n'; hr '═'; printf '%s%s %s%s\n' "$BOLD$CYN" "$S_STEP" "$*" "$RESET"; hr '═'; }
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

# valid_pubkey "<key line>" -> 0 if it looks like a valid SSH public key
valid_pubkey() {
  local key="$1" tmp
  # Structural sanity: "<type> <base64>[ comment]"
  [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]] || return 1
  # Authoritative check via ssh-keygen when available
  if command -v ssh-keygen >/dev/null 2>&1; then
    tmp="$(mktemp)"
    printf '%s\n' "$key" > "$tmp"
    if ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; return 0; fi
    rm -f "$tmp"; return 1
  fi
  return 0
}

# prompt_for_pubkey <user> -> interactively read & validate a key, store it in
# USER_PUBKEY[<user>] on success.
prompt_for_pubkey() {
  local user="$1"
  [[ "$INTERACTIVE" -eq 1 ]] || return 0   # cannot prompt without a TTY
  local key fp tmp haskey="${USER_HASKEY[$user]:-0}"
  while true; do
    printf '\n%s%sSSH key setup — paste the PUBLIC key to authorize for %s%s%s\n' \
      "$BOLD" "$WHT" "$BOLD" "$user" "$RESET" > /dev/tty
    note "No key yet? On YOUR machine (not this server) run:" > /dev/tty
    printf '        %sssh-keygen -t ed25519 -C "user@example.com"%s\n' "$CYN" "$RESET" > /dev/tty
    note "then paste the contents of ~/.ssh/id_ed25519.pub (the line below), e.g.:" > /dev/tty
    note "  ssh-ed25519 AAAAC3Nza... user@host" > /dev/tty
    if [[ "$haskey" -eq 1 ]]; then
      printf '   %s(press Enter to keep %s'\''s existing authorized_keys)%s\n' "$DIM" "$user" "$RESET" > /dev/tty
    else
      printf '   %s(press Enter to skip — %s will have NO key)%s\n' "$DIM" "$user" "$RESET" > /dev/tty
    fi
    printf '%s%s %s key> %s' "$YEL" "$S_INFO" "$user" "$RESET" > /dev/tty
    IFS= read -r key < /dev/tty || key=""
    # Trim surrounding whitespace
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"

    if [[ -z "$key" ]]; then
      return 0   # user chose to skip / keep existing
    fi
    if valid_pubkey "$key"; then
      USER_PUBKEY[$user]="$key"
      if command -v ssh-keygen >/dev/null 2>&1; then
        tmp="$(mktemp)"; printf '%s\n' "$key" > "$tmp"
        fp="$(ssh-keygen -l -f "$tmp" 2>/dev/null)"; rm -f "$tmp"
        printf '%s%s%s Accepted key for %s — %s%s%s\n' "$GRN" "$S_OK" "$RESET" "$user" "$DIM" "$fp" "$RESET" > /dev/tty
      else
        printf '%s%s%s Accepted key for %s.\n' "$GRN" "$S_OK" "$RESET" "$user" > /dev/tty
      fi
      return 0
    fi
    printf '%s%s That does not look like a valid SSH public key — try again.%s\n' \
      "$RED" "$S_ERR" "$RESET" > /dev/tty
  done
}

# prompt_for_password <user> -> interactively read a password (entered twice to
# confirm) for a NEW account and store it in USER_PASSWORD[<user>]. Pressing
# Enter skips, leaving the account passwordless (SSH-key only).
prompt_for_password() {
  local user="$1"
  [[ "$INTERACTIVE" -eq 1 ]] || return 0   # cannot prompt without a TTY
  local p1 p2
  while true; do
    printf '\n%s%sSet a login password for the new user %s%s%s\n' \
      "$BOLD" "$WHT" "$BOLD" "$user" "$RESET" > /dev/tty
    printf '   %s(press Enter to skip — the account stays passwordless / SSH-key only)%s\n' "$DIM" "$RESET" > /dev/tty
    printf '%s%s %s password> %s' "$YEL" "$S_INFO" "$user" "$RESET" > /dev/tty
    IFS= read -rs p1 < /dev/tty || p1=""; printf '\n' > /dev/tty
    [[ -z "$p1" ]] && return 0
    printf '%s%s %s confirm > %s' "$YEL" "$S_INFO" "$user" "$RESET" > /dev/tty
    IFS= read -rs p2 < /dev/tty || p2=""; printf '\n' > /dev/tty
    if [[ "$p1" != "$p2" ]]; then
      printf '%s%s Passwords do not match — try again.%s\n' "$RED" "$S_ERR" "$RESET" > /dev/tty
      continue
    fi
    USER_PASSWORD[$user]="$p1"
    printf '%s%s%s Password set for %s.\n' "$GRN" "$S_OK" "$RESET" "$user" > /dev/tty
    return 0
  done
}

# prompt_for_admin_users — ask which admin username(s) to create/update. There is
# no default user, so this requires at least one (unless ADMIN_USERS was set via
# env, or there is no TTY). Press Enter on an empty prompt once at least one user
# has been added to finish. Brand-new names are flagged in WANT_CREATE so they
# are created without a second "create it?" confirm.
prompt_for_admin_users() {
  [[ "$ADMIN_USERS_EXPLICIT" == "1" ]] && return 0
  [[ "$INTERACTIVE" -eq 1 ]] || return 0
  local name uid shell
  while true; do
    printf '\n%s%sAdmin username to create/update (sudo + SSH key)?%s\n' "$BOLD" "$WHT" "$RESET" > /dev/tty
    if (( ${#ADMIN_USER_LIST[@]} > 0 )); then
      note "Added so far: ${ADMIN_USER_LIST[*]} — enter another, or press Enter to finish." > /dev/tty
    else
      note "Enter a username (e.g. your own name). At least one is required." > /dev/tty
    fi
    printf '%s%s username> %s' "$YEL" "$S_INFO" "$RESET" > /dev/tty
    IFS= read -r name < /dev/tty || name=""
    # Trim whitespace.
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"

    if [[ -z "$name" ]]; then
      if (( ${#ADMIN_USER_LIST[@]} > 0 )); then return 0; fi
      printf '%s%s At least one admin user is required.%s\n' \
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
    # Safeguard: if the account ALREADY EXISTS, confirm before adopting it — and
    # warn hard for system/service accounts (UID < 1000 or a nologin/false
    # shell), since granting those sudo + SSH keys is almost certainly a typo.
    if id "$name" >/dev/null 2>&1; then
      uid="$(id -u "$name" 2>/dev/null || echo 0)"
      shell="$(getent passwd "$name" | cut -d: -f7)"
      if (( uid < 1000 )) || [[ "$shell" == */nologin || "$shell" == */false ]]; then
        printf '%s%s '\''%s'\'' already exists and looks like a SYSTEM account (uid %s, shell %s).%s\n' \
          "$RED" "$S_ERR" "$name" "$uid" "${shell:-?}" "$RESET" > /dev/tty
        printf '   %sAdding it to sudo + SSH key login is almost certainly NOT what you want.%s\n' "$DIM" "$RESET" > /dev/tty
        if ! confirm "Use the system account '$name' anyway?" N; then
          note "Not using '$name' — enter a different username." > /dev/tty
          continue
        fi
      else
        printf '%s%s User '\''%s'\'' already exists (uid %s) — it will be PROMOTED to sudo and given an SSH key.%s\n' \
          "$YEL" "$S_WARN" "$name" "$uid" "$RESET" > /dev/tty
        if ! confirm "Promote existing user '$name' to admin (sudo + SSH key)?" Y; then
          note "Skipping '$name' — enter a different username." > /dev/tty
          continue
        fi
      fi
    else
      WANT_CREATE[$name]=1   # brand-new: create without re-asking in pre-flight
    fi
    ADMIN_USER_LIST+=("$name")
    ADMIN_USER="${ADMIN_USER_LIST[0]}"
    log "Added admin user: ${BOLD}${name}${RESET}" > /dev/tty
  done
}

# ==============================================================================
#  Splash
# ==============================================================================
# Don't wipe the terminal when run nested by init.sh — keep the previous
# script's output visible. (BOOTSTRAP_NESTED is set by init.sh.)
[[ "${BOOTSTRAP_NESTED:-0}" == "1" ]] || clear 2>/dev/null || true
printf '%s%s  Debian 13 Homelab Bootstrap — bootstrap (admin user + SSH key)%s\n' "$BOLD" "$CYN" "$RESET"
hr '─'

require_root
hr '─'

# Ask which admin user(s) to create/update, unless ADMIN_USERS was set via env.
prompt_for_admin_users

# At least one admin user is required.
if (( ${#ADMIN_USER_LIST[@]} == 0 )); then
  err "No admin user specified. Set ADMIN_USERS=\"name\" or run interactively — at least one is required."
  exit 1
fi
info "Admin users: ${BOLD}${ADMIN_USER_LIST[*]}${RESET}"

# ==============================================================================
#  Pre-flight — resolve users to set up, their keys, and new-account passwords
# ==============================================================================
# Existing users are always updated. A MISSING user is created automatically if
# it was typed at the prompt (WANT_CREATE) or forced via CREATE_<user>=1; for a
# missing user that came from ADMIN_USERS env we ask.
EFFECTIVE_USERS=()
for u in "${ADMIN_USER_LIST[@]}"; do
  if id "$u" >/dev/null 2>&1; then
    EFFECTIVE_USERS+=("$u"); continue            # exists → always update
  fi
  cvar="CREATE_${u}"
  if [[ "${WANT_CREATE[$u]:-0}" == "1" ]]; then
    _do=1                                        # chosen at the prompt → create
  elif [[ -n "${!cvar:-}" ]]; then
    [[ "${!cvar}" == "1" ]] && _do=1 || _do=0
  elif confirm "User '$u' does not exist — create it?" Y; then
    _do=1
  else
    _do=0
  fi
  if [[ "$_do" -eq 1 ]]; then
    EFFECTIVE_USERS+=("$u")
  else
    note "Skipping '$u' — it does not exist and you chose not to create it."
    record "User:$u" "skipped (absent; not created)"
  fi
done
ADMIN_USER_LIST=("${EFFECTIVE_USERS[@]}")
ADMIN_USER="${ADMIN_USER_LIST[0]:-}"

# After resolution there must still be at least one admin user to set up.
if (( ${#ADMIN_USER_LIST[@]} == 0 )); then
  err "No admin users left to set up (all were skipped). Aborting — at least one is required."
  exit 1
fi

# Per-user: detect existence + existing key, resolve/prompt for a key, and
# collect a password for accounts that will be NEWLY created.
NO_KEY_USERS=()
for u in "${ADMIN_USER_LIST[@]}"; do
  USER_EXISTS[$u]=0; USER_HASKEY[$u]=0
  if id "$u" >/dev/null 2>&1; then
    USER_EXISTS[$u]=1
    uh="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$uh" && -s "${uh}/.ssh/authorized_keys" ]] && USER_HASKEY[$u]=1
  fi
  # Key from env: PUBKEY_<user>, or PUBKEY for the primary user.
  envvar="PUBKEY_${u}"
  if [[ -n "${!envvar:-}" ]]; then
    USER_PUBKEY[$u]="${!envvar}"
  elif [[ "$u" == "$ADMIN_USER" && -n "${PUBKEY:-}" ]]; then
    USER_PUBKEY[$u]="$PUBKEY"
  fi
  # Validate env-provided keys up front (a typo here means no SSH login later).
  if [[ -n "${USER_PUBKEY[$u]:-}" ]] && ! valid_pubkey "${USER_PUBKEY[$u]}"; then
    err "The SSH key provided for '$u' does not look like a valid public key."
    exit 1
  fi
  # Otherwise offer to paste one now.
  [[ -z "${USER_PUBKEY[$u]:-}" ]] && prompt_for_pubkey "$u"
  # Password — only for users we'll CREATE (existing accounts are never changed):
  # PASSWORD_<user>, else ADMIN_PASSWORD for the primary user, else prompt.
  if [[ "${USER_EXISTS[$u]}" == "0" ]]; then
    pwvar="PASSWORD_${u}"
    if [[ -n "${!pwvar:-}" ]]; then
      USER_PASSWORD[$u]="${!pwvar}"
    elif [[ "$u" == "$ADMIN_USER" && -n "${ADMIN_PASSWORD:-}" ]]; then
      USER_PASSWORD[$u]="$ADMIN_PASSWORD"
    else
      prompt_for_password "$u"
    fi
  fi
  # Track users that will end up with no key at all.
  if [[ -z "${USER_PUBKEY[$u]:-}" && "${USER_HASKEY[$u]}" != "1" ]]; then
    NO_KEY_USERS+=("$u")
  fi
done

# Heads-up (not fatal here): harden.sh disables SSH password auth, so a user
# without a key cannot log in over SSH once the system is hardened.
if (( ${#NO_KEY_USERS[@]} > 0 )); then
  warn "No SSH key for: ${NO_KEY_USERS[*]} — after harden.sh (password auth off) they cannot SSH in."
fi

# ==============================================================================
banner "Creating admin users + sudo + SSH keys"
# ==============================================================================
# The sudo group ships with the sudo package — present on most installs, but a
# minimal Debian may lack it (harden.sh used to pull it in; we now run first).
if ! getent group sudo >/dev/null 2>&1; then
  info "sudo is not installed — installing it (provides the sudo group)..."
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update
  run apt-get install -y sudo
fi

# setup_admin_user <user> — create (disabled-password) or update, ensure sudo,
# and install the resolved SSH key. Identical treatment for every admin user.
setup_admin_user() {
  local user="$1" key="${USER_PUBKEY[$1]:-}" home auth
  # 1) Create or ensure the account + sudo membership.
  if ! id "$user" >/dev/null 2>&1; then
    info "Creating admin user: ${BOLD}${user}${RESET}"
    run adduser --disabled-password --gecos "" "$user"
    run usermod -aG sudo "$user"
    # Set the password collected for this new account (if any); otherwise the
    # account stays passwordless (SSH-key only).
    if [[ -n "${USER_PASSWORD[$user]:-}" ]]; then
      printf '%s:%s\n' "$user" "${USER_PASSWORD[$user]}" | chpasswd
      log "Created '$user' (password set) and added to the sudo group."
      record "User:$user" "created (password set) + sudo"
    else
      log "Created '$user' and added to the sudo group."
      record "User:$user" "created (disabled-password) + sudo"
    fi
    # Record newly-created users so later scripts can target them (e.g. fish).
    mkdir -p "$STATE_DIR"
    grep -qxF "$user" "$CREATED_USERS_FILE" 2>/dev/null || printf '%s\n' "$user" >> "$CREATED_USERS_FILE"
  else
    if id -nG "$user" | tr ' ' '\n' | grep -qx sudo; then
      log "User '$user' already exists and is in sudo."
    else
      run usermod -aG sudo "$user"
      log "User '$user' existed; added to the sudo group."
    fi
    record "User:$user" "existed (sudo ensured)"
  fi

  # 2) Install the SSH key (idempotent), or report the existing/none state.
  if [[ -n "$key" ]]; then
    info "Installing SSH public key for $user"
    home="$(getent passwd "$user" | cut -d: -f6)"
    install -d -m 700 -o "$user" -g "$user" "$home/.ssh"
    auth="$home/.ssh/authorized_keys"
    touch "$auth"; chown "$user:$user" "$auth"; chmod 600 "$auth"
    if ! grep -qF "$key" "$auth"; then
      printf '%s\n' "$key" >> "$auth"
      log "Public key installed to $auth"
    else
      log "Public key already present for $user (no change)."
    fi
    record "Key:$user" "installed/verified"
  elif [[ "${USER_HASKEY[$user]}" == "1" ]]; then
    log "Existing authorized_keys found for $user (no new key needed)."
    record "Key:$user" "existing key reused"
  else
    warn "No key for '$user' — it cannot log in via SSH once the system is hardened."
    record "Key:$user" "NONE (no SSH login after hardening)"
  fi
}

for u in "${ADMIN_USER_LIST[@]}"; do
  setup_admin_user "$u"
done

# ==============================================================================
#  Recap
# ==============================================================================
ELAPSED=$(( $(date +%s) - START_TS )); MM=$(( ELAPSED / 60 )); SS=$(( ELAPSED % 60 ))
printf '\n'; hr '═'
printf '%s%s  ✅  BOOTSTRAP COMPLETE — RECAP%s\n' "$BOLD" "$GRN" "$RESET"
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
printf '   %s•%s  Verify the key works BEFORE hardening. From your machine:\n' "$BOLD" "$RESET"
for u in "${ADMIN_USER_LIST[@]}"; do
  printf '        %sssh %s@<host>%s\n' "$DIM" "$u" "$RESET"
done
printf '   %s•%s  Then harden the system: %ssudo ./harden.sh%s\n' "$BOLD" "$RESET" "$DIM" "$RESET"
printf '%s%s  Done. 👤%s\n\n' "$BOLD" "$GRN" "$RESET"

# One-line summary for init.sh's bootstrap report.
_keyed=(); _unkeyed=()
for u in "${ADMIN_USER_LIST[@]}"; do
  if [[ -n "${USER_PUBKEY[$u]:-}" || "${USER_HASKEY[$u]:-0}" == "1" ]]; then _keyed+=("$u"); else _unkeyed+=("$u"); fi
done
mkdir -p /var/lib/homelab-bootstrap/summaries
printf 'admins: %s (sudo); keys: %s%s\n' \
  "${ADMIN_USER_LIST[*]}" "${_keyed[*]:-none}" "${_unkeyed:+; NO key: ${_unkeyed[*]}}" \
  > /var/lib/homelab-bootstrap/summaries/bootstrap.sh
