#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — motd
#  Installs a cool, dynamic login banner (MOTD) showing live server details:
#  hostname, IP, uptime, OS/kernel, load, memory, disk and active sessions —
#  plus a pointer to your homelab documentation.
#
#  How it works:
#    - Drops an executable generator at /etc/update-motd.d/20-homelab which
#      pam_motd runs at every login to (re)build /run/motd.dynamic. Because it
#      runs per-login, the figures (uptime, load, …) are always current.
#    - Blanks the stock static /etc/motd (backed up first) so only the new
#      banner shows.
#
#  Run as root, e.g.  sudo ./motd.sh
#
#  Environment overrides:
#    DOC_URL=<url>          -> documentation link shown in the banner (no default;
#                              prompted if unset, leave blank to omit the section)
#    BLANK_STATIC_MOTD=1|0  -> blank the stock /etc/motd (default 1)
#    DRY_RUN=1|0            -> force preview / actual (else asks)
#    ASSUME_YES=1           -> answer "yes" to every prompt (automation)
# ==============================================================================

set -euo pipefail

# Ensure sbin paths are present even under non-login shells / restricted sudo.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ASSUME_YES="${ASSUME_YES:-0}"
# DOC_URL: documentation link shown in the banner. If set via env (incl. by
# init.sh's wizard) we use it as-is; otherwise we prompt for it. Leave it blank
# to omit the documentation section from the banner entirely.
if [[ -n "${DOC_URL+x}" ]]; then DOC_URL_EXPLICIT=1; else DOC_URL_EXPLICIT=0; fi
DOC_URL="${DOC_URL:-}"
BLANK_STATIC_MOTD="${BLANK_STATIC_MOTD:-1}"

if [[ -n "${DRY_RUN+x}" ]]; then DRY_RUN_EXPLICIT=1; else DRY_RUN_EXPLICIT=0; fi
DRY_RUN="${DRY_RUN:-}"

START_TS="$(date +%s)"

MOTD_DIR="/etc/update-motd.d"
MOTD_FILE="${MOTD_DIR}/20-homelab"
STATIC_MOTD="/etc/motd"
STATIC_BAK="/etc/motd.bootstrap-bak"

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

write_file() {
  local path="$1"
  if [[ "$DRY_RUN" == "1" ]]; then dry "write ${BOLD}${path}${RESET}:"; sed 's/^/        │ /'; return 0; fi
  cat > "$path"
}

INTERACTIVE=0
if [[ "$ASSUME_YES" != "1" && -r /dev/tty ]]; then INTERACTIVE=1; fi

require_root() { if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then err "Run as root (e.g. sudo $0)."; exit 1; fi; }

# ask "Question" "default" -> echoes the answer (reads /dev/tty); honours automation.
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ "$ASSUME_YES" == "1" || ! -r /dev/tty ]]; then printf '%s' "$default"; return; fi
  printf '%s%s %s%s%s ' "$YEL" "$S_INFO" "$prompt" "${default:+ [default: $default]}" "$RESET" > /dev/tty
  read -r reply < /dev/tty || reply=""
  reply="${reply:-$default}"
  # trim surrounding whitespace
  reply="${reply#"${reply%%[![:space:]]*}"}"; reply="${reply%"${reply##*[![:space:]]}"}"
  printf '%s' "$reply"
}

choose_run_mode() {
  if [[ "$DRY_RUN_EXPLICIT" == "1" ]]; then [[ "$DRY_RUN" == "1" ]] && DRY_RUN=1 || DRY_RUN=0; return; fi
  if [[ "$INTERACTIVE" -eq 0 ]]; then [[ "$ASSUME_YES" == "1" ]] && DRY_RUN=0 || DRY_RUN=1; return; fi
  local choice=""
  printf '\n%s%sHow do you want to run the MOTD installer?%s\n' "$BOLD" "$WHT" "$RESET" > /dev/tty
  printf '   %s[1]%s %sDry run%s — preview, change NOTHING (recommended first)\n' "$BOLD" "$RESET" "$GRN" "$RESET" > /dev/tty
  printf '   %s[2]%s %sActual run%s — install the banner\n' "$BOLD" "$RESET" "$RED" "$RESET" > /dev/tty
  printf '%s%s Choose 1 or 2 [default: 1]: %s' "$YEL" "$S_WARN" "$RESET" > /dev/tty
  read -r choice < /dev/tty || choice=""
  case "${choice:-1}" in 2) DRY_RUN=0 ;; *) DRY_RUN=1 ;; esac
}

# ==============================================================================
#  Splash
# ==============================================================================
# Don't wipe the terminal when run nested by init.sh — keep the previous
# script's output visible. (BOOTSTRAP_NESTED is set by init.sh.)
[[ "${BOOTSTRAP_NESTED:-0}" == "1" ]] || clear 2>/dev/null || true
printf '%s%s  Debian 13 Homelab Bootstrap — MOTD login banner%s\n' "$BOLD" "$CYN" "$RESET"
hr '─'

require_root
choose_run_mode
[[ "$DRY_RUN" == "1" ]] && info "Mode: ${MAG}DRY RUN${RESET}" || info "Mode: ${RED}ACTUAL RUN${RESET}"

# Ask for the documentation URL unless it was supplied via env / automation
# (e.g. init.sh's wizard exports DOC_URL, and ASSUME_YES runs unattended).
if [[ "$DOC_URL_EXPLICIT" != "1" ]]; then
  DOC_URL="$(ask "Documentation URL to show in the login banner (leave blank to omit)" "")"
fi
if [[ -n "$DOC_URL" ]]; then
  note "Documentation link: ${DOC_URL}"
else
  note "No documentation URL given — the docs section will be omitted from the banner."
fi

# ==============================================================================
banner "Ensuring ${MOTD_DIR} exists"
# ==============================================================================
if [[ -d "$MOTD_DIR" ]]; then
  log "${MOTD_DIR} already present."
else
  info "Creating ${MOTD_DIR}..."
  run install -d -m 0755 "$MOTD_DIR"
  log "Created ${MOTD_DIR}."
fi
record "update-motd.d" "ready at ${MOTD_DIR}"

# ==============================================================================
banner "Installing the dynamic banner generator"
# ==============================================================================
# Quoted heredoc: everything is written verbatim so the $(...) / ${...} below
# are evaluated at LOGIN time (always-current figures), not now. The docs URL is
# the one install-time value, injected via the @@DOC_URL@@ placeholder afterward.
write_file "$MOTD_FILE" <<'MOTD_SCRIPT'
#!/usr/bin/env bash
# Homelab dynamic MOTD — generated by motd.sh (Debian 13 Homelab Bootstrap).
# Run at each login by pam_motd via /etc/update-motd.d. Edit DOC_URL by re-running
# motd.sh. No 'set -e' on purpose: a failing probe must never blank the banner.

C0=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'; REV=$'\033[7m'
CYN=$'\033[1;36m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; BLU=$'\033[1;34m'

# Documentation link (injected at install time; blank => docs section omitted).
DOC_URL='@@DOC_URL@@'

# --- gather details (each guarded so the MOTD never breaks) -------------------
host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"
os="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}" )"
kernel="$(uname -r 2>/dev/null)"
ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[ -z "$ip" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$ip" ] && ip="n/a"
up="$(uptime -p 2>/dev/null | sed 's/^up //')"
[ -z "$up" ] && up="$(awk '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60); printf "%dd %dh %dm", d,h,m}' /proc/uptime 2>/dev/null)"
load="$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)"
mem="$(free -h 2>/dev/null | awk '/^Mem:/{print $3" / "$2}')"
disk="$(df -h / 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5" used)"}')"
sessions="$(who 2>/dev/null | wc -l | tr -d ' ')"
cores="$(nproc 2>/dev/null || echo '?')"
now="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"

# --- banner -------------------------------------------------------------------
printf '\n%s%s' "$CYN" "$B"
cat <<'ART'
   ██   ██  ██████  ███    ███ ███████ ██       █████  ██████
   ██   ██ ██    ██ ████  ████ ██      ██      ██   ██ ██   ██
   ███████ ██    ██ ██ ████ ██ █████   ██      ███████ ██████
   ██   ██ ██    ██ ██  ██  ██ ██      ██      ██   ██ ██   ██
   ██   ██  ██████  ██      ██ ███████ ███████ ██   ██ ██████
ART
printf '%s' "$C0"

# Prominent hostname headline (reverse-video bar) right under the logo.
printf '\n   %s %s %s   %s%s%s\n\n' "${B}${CYN}${REV}" "$host" "${C0}" "${DIM}" "$os" "${C0}"

rule() { printf '   %s%s%s\n' "$DIM" "────────────────────────────────────────────────────────────" "$C0"; }
field() { printf '   %s●%s %s%-9s%s %s│%s %s\n' "$GRN" "$C0" "$B" "$1" "$C0" "$DIM" "$C0" "$2"; }

rule
field "Kernel"   "$kernel"
field "Address"  "$ip"
field "Uptime"   "$up"
field "Load"     "${load}   ${DIM}(${cores} cores)${C0}"
field "Memory"   "$mem"
field "Disk /"   "$disk"
field "Sessions" "${sessions} active   ${DIM}${now}${C0}"
rule
if [ -n "$DOC_URL" ]; then
  printf '   %s📚 Docs:%s %s%s%s\n' "$YEL$B" "$C0" "$BLU$B" "$DOC_URL" "$C0"
  printf '   %sNeed help with this server? Browse the Homelab shelf above.%s\n' "$DIM" "$C0"
fi
printf '\n'
MOTD_SCRIPT

if [[ "$DRY_RUN" != "1" ]]; then
  # Escape sed-special chars in the URL (\, &, and the | delimiter) before injecting.
  doc_esc="$(printf '%s' "$DOC_URL" | sed -e 's/[\\&|]/\\&/g')"
  sed -i "s|@@DOC_URL@@|${doc_esc}|g" "$MOTD_FILE"
  chmod 0755 "$MOTD_FILE"
  log "Installed ${MOTD_FILE} (executable)."
else
  dry "inject DOC_URL='${DOC_URL:-<blank — docs section omitted>}' into ${MOTD_FILE}"
  dry "chmod 0755 ${MOTD_FILE}"
fi
record "MOTD banner" "${MOTD_FILE} ($([[ -n "$DOC_URL" ]] && echo "docs: ${DOC_URL}" || echo "no docs link"))"

# ==============================================================================
banner "Tidying the stock static MOTD"
# ==============================================================================
if [[ "$BLANK_STATIC_MOTD" == "1" ]]; then
  if [[ -s "$STATIC_MOTD" ]]; then
    if [[ ! -e "$STATIC_BAK" ]]; then
      run cp -a "$STATIC_MOTD" "$STATIC_BAK"
      [[ "$DRY_RUN" == "1" ]] || log "Backed up ${STATIC_MOTD} -> ${STATIC_BAK}."
    else
      note "Backup ${STATIC_BAK} already exists — not overwriting it."
    fi
    run truncate -s 0 "$STATIC_MOTD"
    [[ "$DRY_RUN" == "1" ]] || log "Blanked ${STATIC_MOTD} (so only the dynamic banner shows)."
    record "static /etc/motd" "blanked (backup: ${STATIC_BAK})"
  else
    log "${STATIC_MOTD} is already empty — nothing to do."
    record "static /etc/motd" "already empty"
  fi
else
  note "Leaving ${STATIC_MOTD} untouched (BLANK_STATIC_MOTD=0)."
  record "static /etc/motd" "left as-is"
fi

# ==============================================================================
#  Preview
# ==============================================================================
if [[ "$DRY_RUN" != "1" ]]; then
  header "Preview (this is what users will see at login)"
  bash "$MOTD_FILE" 2>/dev/null || warn "Could not render preview — check ${MOTD_FILE}."
fi

# ==============================================================================
#  Recap
# ==============================================================================
ELAPSED=$(( $(date +%s) - START_TS )); MM=$(( ELAPSED / 60 )); SS=$(( ELAPSED % 60 ))
printf '\n'; hr '═'
if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s%s  🧪  DRY RUN COMPLETE — NO CHANGES MADE — RECAP%s\n' "$BOLD" "$MAG" "$RESET"
else
  printf '%s%s  ✅  MOTD BANNER INSTALLED — RECAP%s\n' "$BOLD" "$GRN" "$RESET"
fi
hr '═'
printf '%s  Host: %s   |   Elapsed: %dm %ds%s\n' "$DIM" "$(hostname)" "$MM" "$SS" "$RESET"
hr '─'
printf '%s%s  WHAT %s%s\n' "$BOLD" "$CYN" "$( [[ $DRY_RUN == 1 ]] && echo 'WOULD BE DONE' || echo 'WAS DONE' )" "$RESET"
for entry in "${SUMMARY[@]}"; do
  key="${entry%%$'\t'*}"; val="${entry#*$'\t'}"
  printf '   %s%s%-18s%s %s\n' "$GRN" "$S_OK " "$key" "$RESET" "$val"
done
hr '─'
printf '%s%s  ⏭ NEXT STEPS%s\n' "$BOLD" "$MAG" "$RESET"
if [[ "$DRY_RUN" == "1" ]]; then
  printf '   %s•%s  Re-run and choose %sActual%s (or %sDRY_RUN=0 sudo ./%s%s) to install.\n' \
    "$BOLD" "$RESET" "$BOLD" "$RESET" "$DIM" "$(basename "$0")" "$RESET"
else
  printf '   %s•%s  Open a new SSH session to see the banner, or render it now with:\n' "$BOLD" "$RESET"
  printf '       %ssudo run-parts %s%s\n' "$DIM" "$MOTD_DIR" "$RESET"
  printf '   %s•%s  Change the link later by re-running with %sDOC_URL=<url>%s (blank to omit it).\n' "$BOLD" "$RESET" "$DIM" "$RESET"
  if [[ -n "$DOC_URL" ]]; then
    printf '   %s•%s  Documentation: %s%s%s\n' "$BOLD" "$RESET" "$BLU" "$DOC_URL" "$RESET"
  else
    printf '   %s•%s  No documentation link set — the docs section is omitted from the banner.\n' "$BOLD" "$RESET"
  fi
fi
printf '%s%s  Done. 🖥️%s\n\n' "$BOLD" "$GRN" "$RESET"

# One-line summary for init.sh's bootstrap report (actual runs only).
if [[ "$DRY_RUN" != "1" ]]; then
  mkdir -p /var/lib/homelab-bootstrap/summaries
  if [[ -n "$DOC_URL" ]]; then _docs="docs: ${DOC_URL}"; else _docs="no docs link"; fi
  printf 'dynamic MOTD banner installed (%s); %s\n' "$MOTD_FILE" "$_docs" \
    > /var/lib/homelab-bootstrap/summaries/motd.sh
fi
