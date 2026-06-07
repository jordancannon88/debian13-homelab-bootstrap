#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — monitoring
#  Installs monitoring / observability agents from their vendor apt repos.
#
#  - zabbix-agent2 (if selected) adds Zabbix's official apt repo, installs the
#    agent (+ inxi for CPU-temperature), and writes a custom config with this
#    host's name and the Zabbix server address (ZABBIX_SERVER_ACTIVE, or asked
#    when run interactively).
#  - alloy (if selected) adds Grafana's official apt repo, installs Grafana
#    Alloy, and writes a journal-first log-shipping config pointing at the Loki
#    server (LOKI_URL, or asked when run interactively; defaults to localhost).
#    Optionally also captures Docker container logs (ALLOY_DOCKER_LOGS, or
#    asked): when enabled, Alloy keeps relabel rules that promote the journal's
#    container/image fields to labels. This relies on Docker using the journald
#    log-driver — and if Docker is already installed on this host, monitoring.sh
#    offers to set that driver itself (rootful and/or rootless), so you don't
#    need to (re)run docker.sh. Works for both rootful and rootless Docker.
#
#  Config templates live alongside this script in zabbix/ and alloy/; if this
#  script is run on its own (no repo checkout) they're fetched from the repo.
#
#  Run as root, e.g.  sudo ./monitoring.sh
#
#  Environment overrides:
#    MONITORING_PKGS="zabbix-agent2 alloy" -> install exactly these (or "none"
#                                       for nothing); unset = the full default set
#    ZABBIX_SERVER_ACTIVE="host[:port]" -> Zabbix server/proxy for active checks
#                                       (required when zabbix-agent2 is selected;
#                                       asked interactively if unset)
#    LOKI_URL="scheme://host:port" -> Loki base URL for Alloy to push to
#                                       (used when alloy is selected; asked
#                                       interactively, defaults to localhost:3100)
#    ALLOY_DOCKER_LOGS=1|0 -> also capture Docker container logs (keeps the
#                                       journald container/image relabel rules;
#                                       needs Docker on the journald log-driver).
#                                       Used when alloy is selected; asked
#                                       interactively, defaults to off
#    ALLOY_SET_DOCKER_DRIVER=1|0 -> when the above is on and Docker is already
#                                       installed, set Docker's journald
#                                       log-driver here (rootful + rootless).
#                                       Empty = ask; default yes
#    DOCKER_LOG_LABELS=<csv> -> container labels the journald driver attaches for
#                                       grouping in Loki (default the Compose
#                                       project+service). Empty = none
#    DRY_RUN=1|0            -> force preview / actual (else asks)
#    ASSUME_YES=1           -> answer "yes" to every prompt (automation)
# ==============================================================================

set -euo pipefail

# Ensure sbin paths are present even under non-login shells / restricted sudo.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# Directory this script lives in — used to find bundled config templates.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Config templates. Default to the copies alongside this script; if absent
# (e.g. this script was downloaded on its own), they're fetched from the repo.
ALLOY_CONFIG_SRC="${ALLOY_CONFIG_SRC:-${SCRIPT_DIR}/alloy/config.alloy}"
ZBX_CONFIG_SRC="${ZBX_CONFIG_SRC:-${SCRIPT_DIR}/zabbix/zabbix_agent2.conf}"
# Raw base URL used to fetch a template when it isn't present locally.
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main}"

ASSUME_YES="${ASSUME_YES:-0}"

if [[ -n "${DRY_RUN+x}" ]]; then DRY_RUN_EXPLICIT=1; else DRY_RUN_EXPLICIT=0; fi
DRY_RUN="${DRY_RUN:-}"

START_TS="$(date +%s)"

# All agents this installer knows how to install (slug -> short description).
declare -A PKG_DESC=(
  [zabbix-agent2]="Zabbix agent 2 monitoring (needs a Zabbix server)"
  [alloy]="Grafana Alloy log shipper (needs a Loki server)"
)
ALL_PKGS=(zabbix-agent2 alloy)

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
# Whether to capture Docker container logs (1/0): keeps the journald
# container/image relabel rules in the Alloy config. Relies on Docker using the
# journald log-driver. Asked interactively when alloy is selected and unset.
ALLOY_DOCKER_LOGS="${ALLOY_DOCKER_LOGS:-}"
# When ALLOY_DOCKER_LOGS=1 and Docker is already installed here, whether to set
# Docker's journald log-driver ourselves (1/0). Empty = ask (default yes). This
# means an existing Docker host needs no separate docker.sh run.
ALLOY_SET_DOCKER_DRIVER="${ALLOY_SET_DOCKER_DRIVER:-}"
# Container labels the journald driver attaches to each line so they can be
# grouped in Loki (Alloy promotes compose project/service to labels). Default
# the Compose project+service; empty = attach none.
DOCKER_LOG_LABELS="${DOCKER_LOG_LABELS:-com.docker.compose.project,com.docker.compose.service}"
DOCKER_DRIVER_SET=0   # set to 1 once we've configured Docker's journald driver

# Which agents to install. MONITORING_PKGS (space-separated list, or "none")
# overrides the selection — init.sh sets it from the wizard's picker.
# Unset = install the full default set (so a standalone run behaves as before).
if [[ "${MONITORING_PKGS+x}" == "x" ]]; then
  if [[ "${MONITORING_PKGS,,}" == "none" || -z "${MONITORING_PKGS// /}" ]]; then
    SELECTED_PKGS=()
  else
    read -ra SELECTED_PKGS <<< "$MONITORING_PKGS"
  fi
else
  SELECTED_PKGS=("${ALL_PKGS[@]}")
fi
pkg_selected() { local p; for p in "${SELECTED_PKGS[@]}"; do [[ "$p" == "$1" ]] && return 0; done; return 1; }

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
# Steps shown depend on what's selected: Zabbix + Alloy.
TOTAL_STEPS=0
pkg_selected zabbix-agent2 && TOTAL_STEPS=$((TOTAL_STEPS + 1))
pkg_selected alloy         && TOTAL_STEPS=$((TOTAL_STEPS + 1))
SUMMARY=()
record() { SUMMARY+=("$1"$'\t'"$2"); }

hr()   { local ch="${1:-─}" w=72 l=""; printf -v l '%*s' "$w" ''; printf '%s%s%s\n' "$DIM" "${l// /$ch}" "$RESET"; }
banner() {
  STEP_NO=$((STEP_NO + 1)); printf '\n'; hr '═'
  printf '%s%s STEP %d/%d %s %s%s\n' "$BOLD$CYN" "$S_STEP" "$STEP_NO" "$TOTAL_STEPS" "│" "$*" "$RESET"; hr '═'
}
log()  { printf '%s%s%s %s\n' "$GRN" "$S_OK"   "$RESET" "$*"; }
info() { printf '%s%s%s %s\n' "$BLU" "$S_INFO" "$RESET" "$*"; }
warn() { printf '%s%s %s%s\n' "$YEL" "$S_WARN" "$*" "$RESET"; }
err()  { printf '%s%s %s%s\n' "$RED" "$S_ERR" "$*" "$RESET" >&2; }
note() { printf '   %s%s%s\n' "$DIM" "$*" "$RESET"; }
dry()  { printf '   %s[dry-run]%s %s\n' "$MAG" "$RESET" "$*"; }

INTERACTIVE=0
if [[ "$ASSUME_YES" != "1" && -r /dev/tty ]]; then INTERACTIVE=1; fi

require_root() { if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then err "Run as root (e.g. sudo $0)."; exit 1; fi; }

choose_run_mode() {
  if [[ "$DRY_RUN_EXPLICIT" == "1" ]]; then [[ "$DRY_RUN" == "1" ]] && DRY_RUN=1 || DRY_RUN=0; return; fi
  if [[ "$INTERACTIVE" -eq 0 ]]; then [[ "$ASSUME_YES" == "1" ]] && DRY_RUN=0 || DRY_RUN=1; return; fi
  local choice=""
  printf '\n%s%sHow do you want to run the monitoring installer?%s\n' "$BOLD" "$WHT" "$RESET" > /dev/tty
  printf '   %s[1]%s %sDry run%s — preview, change NOTHING (recommended first)\n' "$BOLD" "$RESET" "$GRN" "$RESET" > /dev/tty
  printf '   %s[2]%s %sActual run%s — install & configure\n' "$BOLD" "$RESET" "$RED" "$RESET" > /dev/tty
  printf '%s%s Choose 1 or 2 [default: 1]: %s' "$YEL" "$S_WARN" "$RESET" > /dev/tty
  read -r choice < /dev/tty || choice=""
  case "${choice:-1}" in 2) DRY_RUN=0 ;; *) DRY_RUN=1 ;; esac
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

# write_alloy_conf <target> <loki_base_url> <docker_logs> — render the
# journal-first Alloy config to <target>, substituting the Loki base URL into
# the loki.write endpoint (awk swaps the @@LOKI_ENDPOINT@@ token for the URL,
# safe regardless of the / and : it contains). The Docker-container log block
# (between the @@ALLOY_DOCKER_BEGIN@@/@@ALLOY_DOCKER_END@@ markers) is kept when
# <docker_logs> is "1" and removed otherwise; the marker lines are always
# dropped. Returns non-zero if the template can't be found.
write_alloy_conf() {
  local target="$1" url="$2" docker="${3:-0}"
  resolve_template "$ALLOY_CONFIG_SRC" "alloy/config.alloy" || return 1
  # Anchor to the dedicated marker lines ("// @@ALLOY_DOCKER_BEGIN@@", possibly
  # indented) so the header prose that merely mentions the tokens isn't matched.
  awk -v url="$url" -v docker="$docker" '
    /^[[:space:]]*\/\/ @@ALLOY_DOCKER_BEGIN@@[[:space:]]*$/ { indocker=1; next }   # drop begin marker
    /^[[:space:]]*\/\/ @@ALLOY_DOCKER_END@@[[:space:]]*$/   { indocker=0; next }    # drop end marker
    indocker && docker != "1" { next }                                            # skip body when disabled
    { gsub(/@@LOKI_ENDPOINT@@/, url); print }
  ' "$RESOLVED_TEMPLATE" > "$target"
  [[ "$RESOLVED_TEMPLATE_IS_TMP" == "1" ]] && rm -f "$RESOLVED_TEMPLATE"
  return 0
}

# write_journald_daemon_json <path> <owner:group> — set "log-driver":"journald"
# (and, if DOCKER_LOG_LABELS is non-empty, "log-opts":{"labels":"..."}). Creates
# the file + parent dirs if absent; to merge into an EXISTING file (preserving
# other keys) it uses jq, installing it first if missing. Returns non-zero only
# if it couldn't apply the setting. (Same logic as docker.sh.)
write_journald_daemon_json() {
  local path="$1" owner="$2" dir; dir="$(dirname "$path")"
  local labels="$DOCKER_LOG_LABELS"
  if [[ "$DRY_RUN" == "1" ]]; then
    dry "set \"log-driver\":\"journald\"${labels:+ + log-opts labels=${labels}} in ${path} (owner ${owner})"
    return 0
  fi
  install -d -o "${owner%:*}" -g "${owner#*:}" -m 0755 "$dir"
  if [[ -s "$path" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      info "Installing jq (needed to merge the existing ${path})..."
      apt-get install -y jq >/dev/null 2>&1 || true
    fi
    if command -v jq >/dev/null 2>&1; then
      cp -a "$path" "${path}.bak.$(date +%F-%H%M%S)"
      local tmp; tmp="$(mktemp)"
      if jq --arg labels "$labels" '
            ."log-driver" = "journald"
            | if $labels != "" then ."log-opts" = ((."log-opts" // {}) + {"labels": $labels}) else . end
          ' "$path" > "$tmp" && mv "$tmp" "$path"; then
        chown "$owner" "$path"; chmod 0644 "$path"
        log "Merged journald log-driver into existing ${path} (backup kept)."
        return 0
      fi
      rm -f "$tmp"
    fi
    warn "${path} exists and jq couldn't be installed to merge it — set log-driver=journald${labels:+ and log-opts.labels=${labels}} in it yourself, then restart Docker."
    return 1
  fi
  if [[ -n "$labels" ]]; then
    printf '{\n  "log-driver": "journald",\n  "log-opts": {\n    "labels": "%s"\n  }\n}\n' "$labels" > "$path"
  else
    printf '{\n  "log-driver": "journald"\n}\n' > "$path"
  fi
  chown "$owner" "$path"; chmod 0644 "$path"
  log "Wrote ${path} with the journald log-driver${labels:+ (labels: ${labels})}."
  return 0
}

# run_as_user_docker <user> <cmd...> — run a command in <user>'s systemd/D-Bus
# session (needed to restart their rootless `docker` user service).
run_as_user_docker() {
  local u="$1"; shift
  local uid; uid="$(id -u "$u" 2>/dev/null)" || return 1
  if [[ "$DRY_RUN" == "1" ]]; then dry "su - $u -c '$*'"; return 0; fi
  runuser -l "$u" -c \
    "export XDG_RUNTIME_DIR=/run/user/${uid} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus PATH=/usr/bin:/usr/sbin:/sbin:\$PATH; $*"
}

# configure_docker_journald — when Docker is installed here, detect the active
# daemon(s) and (after a prompt) point them at the journald log-driver so the
# Alloy journal scrape captures container logs. Handles BOTH the rootful system
# daemon (/etc/docker/daemon.json) and any running rootless daemon
# (~user/.config/docker/daemon.json, restarted via the user's systemd session).
configure_docker_journald() {
  local rootful=0; local -a rl_users=(); local sock uid u home
  systemctl is-active --quiet docker 2>/dev/null && rootful=1
  # A running rootless daemon exposes a socket at /run/user/<uid>/docker.sock.
  for sock in /run/user/*/docker.sock; do
    [[ -S "$sock" ]] || continue
    uid="$(basename "$(dirname "$sock")")"
    u="$(id -un "$uid" 2>/dev/null)" || continue
    rl_users+=("$u")
  done

  if (( rootful == 0 && ${#rl_users[@]} == 0 )); then
    note "Docker is installed but no running daemon was detected — set its journald log-driver yourself (see next steps)."
    return 0
  fi

  local targets=""
  (( rootful )) && targets+="rootful(/etc/docker) "
  (( ${#rl_users[@]} )) && targets+="rootless(${rl_users[*]})"
  info "Docker detected here — can set its journald log-driver so Alloy captures container logs."
  note "Would configure: ${targets}"

  local do_it="$ALLOY_SET_DOCKER_DRIVER" _r=""
  if [[ -z "$do_it" ]]; then
    if [[ "$INTERACTIVE" -eq 1 ]]; then
      printf '%s%s Set Docker'"'"'s journald log-driver now? [Y/n]: %s' "$YEL" "$S_WARN" "$RESET" > /dev/tty
      read -r _r < /dev/tty || _r=""
      [[ "$_r" =~ ^[Nn] ]] && do_it=0 || do_it=1
    else
      do_it=1   # non-interactive: they already asked for Docker logs
    fi
  fi
  [[ "${do_it,,}" =~ ^(1|y|yes|true|on)$ ]] && do_it=1 || do_it=0
  if [[ "$do_it" != "1" ]]; then
    note "Left Docker's log-driver unchanged — see next steps to set it manually."
    record "Docker log-driver" "skipped (set manually)"
    return 0
  fi

  local applied=0
  if (( rootful )); then
    if write_journald_daemon_json /etc/docker/daemon.json "root:root"; then
      if [[ "$DRY_RUN" == "1" ]]; then dry "systemctl restart docker"; else systemctl restart docker 2>/dev/null || true; fi
      applied=1
    fi
  fi
  for u in "${rl_users[@]}"; do
    home="$(getent passwd "$u" | cut -d: -f6)"
    if write_journald_daemon_json "${home}/.config/docker/daemon.json" "${u}:${u}"; then
      run_as_user_docker "$u" "systemctl --user restart docker" || true
      applied=1
    fi
  done

  if (( applied )); then
    DOCKER_DRIVER_SET=1
    if [[ "$DRY_RUN" == "1" ]]; then
      record "Docker log-driver" "[dry-run] would set journald (${targets})"
    else
      log "Docker now logs to the journal (journald)${DOCKER_LOG_LABELS:+; grouping labels: ${DOCKER_LOG_LABELS}}."
      note "Recreate running containers to adopt it: ${DIM}docker compose up -d --force-recreate${RESET}"
      record "Docker log-driver" "journald (${targets})"
    fi
  fi
}

# ==============================================================================
#  Splash
# ==============================================================================
# Don't wipe the terminal when run nested by init.sh — keep the previous
# script's output visible. (BOOTSTRAP_NESTED is set by init.sh.)
[[ "${BOOTSTRAP_NESTED:-0}" == "1" ]] || clear 2>/dev/null || true
printf '%s%s  Debian 13 Homelab Bootstrap — monitoring (Zabbix + Grafana Alloy)%s\n' "$BOLD" "$CYN" "$RESET"
hr '─'

require_root
if ! command -v apt-get >/dev/null 2>&1; then err "apt-get not found — this targets Debian/apt systems."; exit 1; fi
choose_run_mode

if [[ "$DRY_RUN" == "1" ]]; then info "Mode: ${MAG}DRY RUN (no changes)${RESET}"; else info "Mode: ${RED}ACTUAL RUN${RESET}"; fi
hr '─'

info "Agents to install: ${BOLD}${SELECTED_PKGS[*]:-<none>}${RESET}"
hr '─'

export DEBIAN_FRONTEND=noninteractive

if (( ${#SELECTED_PKGS[@]} == 0 )); then
  note "No monitoring agents selected — nothing to install."
  record "Monitoring" "none selected"
fi

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

# Resolve whether to also tail Docker container logs — prompt if unset.
if [[ -z "$ALLOY_DOCKER_LOGS" ]]; then
  ALLOY_DOCKER_LOGS=0
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    printf '%s%s Also capture Docker container logs (via the journald log-driver)? [y/N]: %s' \
      "$YEL" "$S_WARN" "$RESET" > /dev/tty
    read -r _dl < /dev/tty || _dl=""
    [[ "$_dl" =~ ^[Yy] ]] && ALLOY_DOCKER_LOGS=1
  fi
fi
# Normalise to 0/1 (accept yes/true/1 from the environment).
[[ "${ALLOY_DOCKER_LOGS,,}" =~ ^(1|y|yes|true|on)$ ]] && ALLOY_DOCKER_LOGS=1 || ALLOY_DOCKER_LOGS=0

if [[ "$DRY_RUN" == "1" ]]; then
  dry "add Grafana apt repo, then apt-get install alloy"
  _docker_note="$( [[ "$ALLOY_DOCKER_LOGS" == "1" ]] && echo ' + Docker container logs' || echo '' )"
  if [[ -r "$ALLOY_CONFIG_SRC" ]]; then
    dry "render ${ALLOY_CONFIG_SRC} -> ${ALLOY_CONF} (root:alloy 0640) pushing to ${LOKI_URL}/loki/api/v1/push${_docker_note}"
  else
    dry "fetch alloy/config.alloy from repo -> ${ALLOY_CONF} (root:alloy 0640) pushing to ${LOKI_URL}/loki/api/v1/push${_docker_note}"
  fi
  [[ "$ALLOY_DOCKER_LOGS" == "1" ]] && dry "keep the journald container/image relabel rules (set Docker's log-driver to journald separately)"
  dry "enable + restart alloy"
  record "Grafana Alloy" "[dry-run] would install + configure (Loki ${LOKI_URL}${_docker_note})"
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
  if write_alloy_conf "$_alloy_tmp" "$LOKI_URL" "$ALLOY_DOCKER_LOGS"; then
    install -o root -g "$_alloy_grp" -m 0640 "$_alloy_tmp" "$ALLOY_CONF"
    rm -f "$_alloy_tmp"
    _docker_note="$( [[ "$ALLOY_DOCKER_LOGS" == "1" ]] && echo ' + Docker container logs' || echo '' )"
    log "Wrote ${ALLOY_CONF} (pushing to ${LOKI_URL}/loki/api/v1/push${_docker_note})."

    systemctl enable alloy >/dev/null 2>&1 || true
    systemctl reset-failed alloy >/dev/null 2>&1 || true
    if systemctl restart alloy 2>/dev/null; then
      log "alloy enabled and running."
      record "Grafana Alloy" "installed; pushing to ${LOKI_URL}${_docker_note}"
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

# If Docker-log capture is on and Docker is already installed on THIS host, offer
# to set its journald log-driver ourselves — so an existing Docker host needs no
# separate docker.sh run. (On a fresh host where docker.sh installs Docker later,
# Docker isn't present yet here, so this is skipped and docker.sh handles it.)
if [[ "$ALLOY_DOCKER_LOGS" == "1" ]] && command -v docker >/dev/null 2>&1; then
  configure_docker_journald
fi
fi   # end: pkg_selected alloy

# ==============================================================================
#  Recap
# ==============================================================================
ELAPSED=$(( $(date +%s) - START_TS )); MM=$(( ELAPSED / 60 )); SS=$(( ELAPSED % 60 ))
printf '\n'; hr '═'
if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s%s  🧪  DRY RUN COMPLETE — NO CHANGES MADE — RECAP%s\n' "$BOLD" "$MAG" "$RESET"
else
  printf '%s%s  ✅  MONITORING SETUP COMPLETE — RECAP%s\n' "$BOLD" "$GRN" "$RESET"
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
if pkg_selected zabbix-agent2; then
  printf '   %s•%s  Add this host on your Zabbix server using hostname %s%s%s, then confirm data\n' "$BOLD" "$RESET" "$BOLD" "$(hostname)" "$RESET"
  printf '       with: %ssystemctl status zabbix-agent2%s and %stail -f /var/log/zabbix/zabbix_agent2.log%s\n' "$DIM" "$RESET" "$DIM" "$RESET"; _had_step=1
fi
if pkg_selected alloy; then
  printf '   %s•%s  Confirm logs are flowing: %ssystemctl status alloy%s, then in Grafana query\n' "$BOLD" "$RESET" "$DIM" "$RESET"
  printf '       %s{host="%s"}%s against your Loki source. Auditd logs need read access for the alloy user.\n' "$DIM" "$(hostname)" "$RESET"; _had_step=1
  if [[ "${ALLOY_DOCKER_LOGS:-0}" == "1" ]]; then
    if [[ "${DOCKER_DRIVER_SET:-0}" == "1" ]]; then
      # We configured Docker's journald driver — only the container recreate is left.
      printf '   %s•%s  Docker journald log-driver set. Recreate running containers to adopt it\n' "$BOLD" "$RESET"
      printf '       (%sdocker compose up -d --force-recreate%s), then group them in Grafana with\n' "$DIM" "$RESET"
      printf '       %s{host="%s", compose_project="<stack>"}%s or %s{container=~".+"}%s.\n' "$DIM" "$(hostname)" "$RESET" "$DIM" "$RESET"
    else
      # Docker not present / not configured here — give the manual instructions.
      printf '   %s•%s  Docker container logs: point Docker at the %sjournald%s log-driver, then they ship via\n' "$BOLD" "$RESET" "$BOLD" "$RESET"
      printf '       the journal — query %s{host="%s", container=~".+"}%s in Grafana.\n' "$DIM" "$(hostname)" "$RESET"
      printf '       %s• rootful:%s  set %s{"log-driver":"journald"}%s in /etc/docker/daemon.json, then %ssystemctl restart docker%s\n' "$BOLD" "$RESET" "$DIM" "$RESET" "$DIM" "$RESET"
      printf '       %s• rootless:%s set it in %s~/.config/docker/daemon.json%s, then %ssystemctl --user restart docker%s\n' "$BOLD" "$RESET" "$DIM" "$RESET" "$DIM" "$RESET"
      printf '       then recreate containers (%sdocker compose up -d --force-recreate%s) so the driver applies.\n' "$DIM" "$RESET"
    fi
  fi
fi
(( _had_step == 0 )) && printf '   %s•%s  Nothing further to do.\n' "$BOLD" "$RESET"
printf '%s%s  Done. 📈%s\n\n' "$BOLD" "$GRN" "$RESET"

# One-line summary for init.sh's bootstrap report (actual runs only).
if [[ "$DRY_RUN" != "1" ]]; then
  if (( ${#SELECTED_PKGS[@]} > 0 )); then _agents="installed ${SELECTED_PKGS[*]}"; else _agents="no agents selected"; fi
  mkdir -p /var/lib/homelab-bootstrap/summaries
  printf '%s\n' "$_agents" \
    > /var/lib/homelab-bootstrap/summaries/monitoring.sh
fi
