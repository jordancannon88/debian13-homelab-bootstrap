#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — monitoring
#  Installs monitoring / observability agents from their vendor apt repos.
#
#  - zabbix-agent2 (if selected) adds Zabbix's official apt repo, installs the
#    agent (+ inxi for CPU-temperature), and writes a custom config with this
#    host's name and the Zabbix server address (ZABBIX_SERVER_ACTIVE, or asked
#    when run interactively). When a ROOTLESS Docker daemon is detected it also
#    offers to set the agent up to monitor it (ZABBIX_MONITOR_ROOTLESS_DOCKER,
#    or asked): rootless Docker's socket lives in the owner's runtime dir, so
#    this points the Docker plugin at it, enables lingering, and runs the agent
#    as that user so it can reach the socket.
#  - alloy (if selected) adds Grafana's official apt repo, installs Grafana
#    Alloy, and writes a journal-first log-shipping config pointing at the Loki
#    server (LOKI_URL, or asked when run interactively; defaults to localhost).
#    Optionally also captures Docker container logs (ALLOY_DOCKER_LOGS, or
#    asked): when enabled, Alloy keeps relabel rules that promote the journal's
#    container/image fields to labels. This relies on Docker using the journald
#    log-driver — and if Docker is already installed on this host, monitoring.sh
#    offers to set that driver itself (rootful and/or rootless), so you don't
#    need to (re)run container.sh. Works for both rootful and rootless Docker.
#
#  - buzz (if selected) sets this host up to report alerts to a buzz relay dev
#    box over forced-command ssh (the v3 protocol): it generates a dedicated
#    ed25519 key (/root/.ssh/buzz_report) and installs the chosen watch scripts
#    with their crons. Every watch has been retired in favour of Zabbix
#    (disk, repl, backup, ha on 2026-09-15/16; tbmesh on 2026-09-16, its heal
#    now installs with the Zabbix helpers, see ZABBIX_TBMESH), so selecting
#    alerts only generates the key today. Kept for the delivery plumbing until
#    the bootstrap revamp (Kan 6sjz7rdp0r9p) removes it.
#
#  Config templates live alongside this script in zabbix/, alloy/ and buzz/; if
#  this script is run on its own (no repo checkout) they're fetched from the repo.
#
#  Run as root, e.g.  sudo ./monitoring.sh
#
#  Environment overrides:
#    MONITORING_PKGS="zabbix-agent2 alloy" -> install exactly these (or "none"
#                                       for nothing); unset = the full default set
#    ZABBIX_SERVER_ACTIVE="host[:port]" -> Zabbix server/proxy for active checks
#                                       (required when zabbix-agent2 is selected;
#                                       asked interactively if unset)
#    ZABBIX_HOST_METADATA="tok tok" -> replace the autoregistration token list
#                                       (default: derived from what is installed)
#    ZABBIX_MONITOR_ROOTLESS_DOCKER=1|0 -> set the agent up to monitor a rootless
#                                       Docker daemon. Empty = ask when a rootless
#                                       daemon is detected (default no)
#    ZABBIX_DOCKER_USER=<user> -> the rootless Docker owner to monitor (default:
#                                       auto-detected from the running daemon)
#    ZABBIX_DISK_HEALTH=1|0 -> install the disk-health helpers the homelab
#                                       Zabbix templates need: smartmontools, a
#                                       sudoers rule so the agent can run smartctl,
#                                       the NVMe available-spare UserParameter, the
#                                       ZFS pool/vdev UserParameter (when zpool is
#                                       present), and a smartd self-test schedule.
#                                       Default 1
#    SMARTD_SCHEDULE="<smartd -s regex>" -> self-test schedule written into
#                                       /etc/smartd.conf. Default: short test daily
#                                       02:00, long test Sunday 03:00
#                                       (S/../.././02|L/../../7/03). Use
#                                       L/../01/./03 for monthly long tests on
#                                       very large disks
#    ZABBIX_SNAPRAID=1|0 -> install the snapraid watch and the daily
#                                       snapraid-runner timer (sync + partial scrub,
#                                       mass-delete guarded). Default: on when
#                                       /etc/snapraid.conf exists, else off
#    ZABBIX_PVE_EVENTS=1|0 -> install the Proxmox events collectors for the
#                                       "Homelab Proxmox events" template (today:
#                                       replication jobs from pvesr status via a
#                                       sudoers line). Default: on when pvesr
#                                       exists, else off
#    ZABBIX_NIC_FLAP=1|0 -> install the physical-NIC link-flap UserParameters
#                                       (LLD of real NICs + carrier_down_count) and
#                                       the PCIe-detach counter (kernel journal,
#                                       zabbix user joins systemd-journal).
#                                       Default 1 on bare metal, 0 on VMs/containers
#    ZABBIX_TBMESH=1|0 -> install the Thunderbolt mesh auto-heal
#                                       (tb-mesh-heal.sh, cron every minute) and its
#                                       Zabbix collector for the "Homelab TB3 mesh"
#                                       template (custom.tbmesh.status). Default: on
#                                       when the TB reset scripts exist (mesh nodes),
#                                       else off
#    ZABBIX_BOOTCHECK=1|0 -> install the collector for the "Homelab boot
#                                       check" template (custom.bootcheck.status
#                                       reads the post-outage runbook's
#                                       latest.json). Default: on when
#                                       pve-outage-boot-check.service exists,
#                                       else off. The runbook itself is not part
#                                       of the bootstrap (get-installer channel)
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
#    BUZZ_TARGET="user@host" -> the buzz relay dev box the watches ssh to
#                                       (required when buzz is selected; asked
#                                       interactively if unset)
#    BUZZ_PORT=6523          -> ssh port on the dev box (default 6523)
#    BUZZ_ALERTS="disk repl ha backup tbmesh" -> which watches to install (subset,
#                                       or "none"); unset = "disk"
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

START_TS="$(date +%s)"

# All agents this installer knows how to install (slug -> short description).
declare -A PKG_DESC=(
  [zabbix-agent2]="Zabbix agent 2 monitoring (needs a Zabbix server)"
  [alloy]="Grafana Alloy log shipper (needs a Loki server)"
  [alerts]="health & event alerts, delivered via buzz relay or ntfy"
)
ALL_PKGS=(zabbix-agent2 alloy alerts)

# Zabbix agent 2 specifics (its own repo + custom config; see the step below).
ZBX_VERSION="7.4"
ZBX_CONF="/etc/zabbix/zabbix_agent2.conf"
ZBX_SERVER_ACTIVE="${ZABBIX_SERVER_ACTIVE:-}"
# Whether to also set the agent up to monitor a ROOTLESS Docker daemon (1/0).
# Empty = ask interactively when a rootless Docker socket is detected (default
# no). The owning user is auto-detected unless ZABBIX_DOCKER_USER overrides it.
ZBX_ROOTLESS_DOCKER="${ZABBIX_MONITOR_ROOTLESS_DOCKER:-}"
ZBX_DOCKER_USER="${ZABBIX_DOCKER_USER:-}"
# Disk-health helpers for the homelab SMART/ZFS templates (1/0, default on) and
# the smartd self-test schedule. NIC link-flap helpers default to bare metal only
# (empty = decide from systemd-detect-virt).
ZBX_DISK_HEALTH="${ZABBIX_DISK_HEALTH:-1}"
SMARTD_SCHEDULE="${SMARTD_SCHEDULE:-(S/../.././02|L/../../7/03)}"
ZBX_NIC_FLAP="${ZABBIX_NIC_FLAP:-}"
ZBX_SNAPRAID="${ZABBIX_SNAPRAID:-}"
ZBX_PVE_EVENTS="${ZABBIX_PVE_EVENTS:-}"
ZBX_TBMESH="${ZABBIX_TBMESH:-}"
ZBX_BOOTCHECK="${ZABBIX_BOOTCHECK:-}"
# Helper scripts shipped in zabbix/ next to this script (fetched from the repo
# when absent), installed under /usr/local/bin.
ZBX_HELPER_DIR="${ZBX_HELPER_DIR:-${SCRIPT_DIR}/zabbix}"

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
# means an existing Docker host needs no separate container.sh run.
ALLOY_SET_DOCKER_DRIVER="${ALLOY_SET_DOCKER_DRIVER:-}"
# Container labels the journald driver attaches to each line so they can be
# grouped in Loki (Alloy promotes compose project/service to labels). Default
# the Compose project+service; empty = attach none.
DOCKER_LOG_LABELS="${DOCKER_LOG_LABELS:-com.docker.compose.project,com.docker.compose.service}"
DOCKER_DRIVER_SET=0   # set to 1 once we've configured Docker's journald driver

# Health & event alerts. BUZZ_ALERTS picks the watch scripts (watches whose
# tooling is absent on this host are skipped); ALERTS_SINK picks how alerts
# leave the host:
#   buzz  -> forced-command ssh to a relay dev box (dedicated per-node key;
#            the dev box renders/pretties and posts). Needs BUZZ_TARGET.
#   ntfy  -> HTTP push to an ntfy topic (https://ntfy.sh/<topic> or a
#            self-hosted server). Needs NTFY_URL; NTFY_TOKEN optional.
#            Messages carry the raw v3 payload text (terse but complete).
# ALERTS_SINKS may list BOTH ("buzz ntfy") — every alert then goes to both.
# ALERTS_SINK (singular) is accepted as a legacy alias.
ALERTS_SINKS="${ALERTS_SINKS:-${ALERTS_SINK:-buzz}}"
BUZZ_TARGET="${BUZZ_TARGET:-}"
BUZZ_PORT="${BUZZ_PORT:-6523}"
NTFY_URL="${NTFY_URL:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
BUZZ_ALERTS="${BUZZ_ALERTS:-none}"
BUZZ_KEY="/root/.ssh/buzz_report"

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
# Legacy name: "buzz" used to be the slug for the alerts feature.
for _i in "${!SELECTED_PKGS[@]}"; do [[ "${SELECTED_PKGS[$_i]}" == "buzz" ]] && SELECTED_PKGS[$_i]="alerts"; done
pkg_selected() { local p; for p in "${SELECTED_PKGS[@]}"; do [[ "$p" == "$1" ]] && return 0; done; return 1; }
# Normalise ALERTS_SINKS to a validated list; at least the tokens buzz/ntfy.
_sinks=()
for _t in ${ALERTS_SINKS}; do case "$_t" in buzz|ntfy) _sinks+=("$_t");; esac; done
ALERTS_SINKS="${_sinks[*]:-buzz}"
sink_enabled() { [[ " ${ALERTS_SINKS} " == *" $1 "* ]]; }

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
pkg_selected alerts        && TOTAL_STEPS=$((TOTAL_STEPS + 1))
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

INTERACTIVE=0
if [[ "$ASSUME_YES" != "1" && -r /dev/tty ]]; then INTERACTIVE=1; fi

require_root() { if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then err "Run as root (e.g. sudo $0)."; exit 1; fi; }

# open_firewall_port <tcp|udp> <port> <what> — self-service firewall opening:
# a step that installs a network listener opens its own port in the hardened
# nftables ruleset (idempotent; inserted above the input chain's final drop,
# then reloaded). No-op when harden.sh's firewall isn't present — the host
# then has no deny-by-default filter for us to open.
open_firewall_port() {
  local proto="$1" port="$2" what="${3:-service}"
  local conf=/etc/nftables.conf
  if ! { [[ -f "$conf" ]] && grep -q 'deny-by-default' "$conf"; }; then
    # No firewall from this bootstrap. Two possibilities:
    #  - no filtering at all (Debian default ACCEPT): nothing to open, silent;
    #  - a FOREIGN firewall (ufw/firewalld/custom nftables): never edit
    #    someone else's ruleset — tell the operator what to open instead.
    if systemctl is-active --quiet ufw 2>/dev/null \
       || systemctl is-active --quiet firewalld 2>/dev/null \
       || { [[ -f "$conf" ]] && systemctl is-active --quiet nftables 2>/dev/null; }; then
      warn "A firewall not managed by this bootstrap is active — open ${proto}/${port} for ${what} in it yourself."
    fi
    return 0
  fi
  if grep -qE "^[[:space:]]*${proto} dport ${port} ct state new accept" "$conf"; then
    return 0
  fi
  sed -i "s/^\([[:space:]]*\)drop\$/\1${proto} dport ${port} ct state new accept\n\1drop/" "$conf"
  if command -v nft >/dev/null 2>&1 && nft -c -f "$conf" 2>/dev/null; then
    nft -f "$conf" 2>/dev/null || true
  fi
  log "Firewall: opened ${proto}/${port} for ${what} (persisted in ${conf})."
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

# write_zabbix_conf <target> <hostname> <serveractive> — render the custom
# zabbix_agent2.conf to <target>, substituting this host's name and the Zabbix
# server address into the two relevant lines. The cpuTemperature UserParameter
# is no longer in this template; it ships as a plugins.d drop-in written by
# write_cpu_temp_dropin(). The template is zabbix/zabbix_agent2.conf alongside
# this script (or fetched from the repo); awk -v then swaps the values safely
# regardless of characters they contain. Returns non-zero if the template can't
# be found.
write_zabbix_conf() {
  local target="$1" hn="$2" sa="$3"
  resolve_template "$ZBX_CONFIG_SRC" "zabbix/zabbix_agent2.conf" || return 1
  # Anchor on the key only (not the placeholder value) so substitution still
  # works if the template's placeholder ever changes.
  awk -v hn="$hn" -v sa="$sa" '
    /^Hostname=/     { print "Hostname=" hn; next }
    /^ServerActive=/ { print "ServerActive=" sa; next }
    { print }
  ' "$RESOLVED_TEMPLATE" > "$target"
  [[ "$RESOLVED_TEMPLATE_IS_TMP" == "1" ]] && rm -f "$RESOLVED_TEMPLATE"
  return 0
}

# write_cpu_temp_dropin <hostname> <virtualized> — write the cpuTemperature
# UserParameter as a plugins.d drop-in so it's independent of the packaged
# config (upgrade-safe, easy to add/remove). The key is prefixed with the
# hostname (item key "<host>.cpuTemperature", matching the Zabbix template).
# The command is label-matched (greps the value after inxi's "cpu:" label)
# rather than positional, so it survives inxi reordering its sensor fields;
# -c 0 strips ANSI colour codes that would otherwise corrupt the value. On a
# VM/container the line is commented out (no real CPU thermal sensors there).
write_cpu_temp_dropin() {
  local hn="$1" virt="${2:-0}" dir="/etc/zabbix/zabbix_agent2.d/plugins.d" pfx=""
  [[ "$virt" == "1" ]] && pfx="#"
  install -d -m 755 "$dir"
  cat > "${dir}/cpu-temperature.conf" <<EOF
# CPU temperature for Zabbix (bare-metal only) — debian13-homelab-bootstrap.
# Label-matched so it survives inxi reordering fields; -c 0 strips colour codes.
${pfx}UserParameter=${hn}.cpuTemperature,inxi -s -c 0 | grep -oP 'cpu:\s*\K[0-9.]+'
EOF
  # harden.sh sets UMASK 027; an include the zabbix user cannot read stops the
  # agent from starting at all (restart loop), so force the mode explicitly.
  chmod 0644 "${dir}/cpu-temperature.conf"
}

# install_zbx_helper <name> <mode> — install zabbix/<name> from beside this
# script (or fetched from the repo) to /usr/local/bin/<name> with an explicit
# mode. Explicit modes matter: harden.sh sets UMASK 027, so a plain redirect
# would leave the file unreadable by the zabbix user.
install_zbx_helper() {
  local name="$1" mode="${2:-0755}" dest="${3:-/usr/local/bin}"
  resolve_template "${ZBX_HELPER_DIR}/${name}" "zabbix/${name}" || return 1
  install -m "$mode" "$RESOLVED_TEMPLATE" "${dest}/${name}"
  [[ "$RESOLVED_TEMPLATE_IS_TMP" == "1" ]] && rm -f "$RESOLVED_TEMPLATE"
  return 0
}

# write_agent_dropin <file> <content> — write a zabbix_agent2.d/<file> drop-in
# world-readable (0644). The agent refuses to start on an unreadable include.
write_agent_dropin() {
  local dir="/etc/zabbix/zabbix_agent2.d"
  install -d -m 755 "$dir"
  printf '%s\n' "$2" > "${dir}/$1.tmp"
  install -m 0644 "${dir}/$1.tmp" "${dir}/$1"
  rm -f "${dir}/$1.tmp"
}

# setup_disk_health — everything the "SMART by Zabbix agent 2 active" template
# (with the Homelab additions) and the "Homelab ZFS pools" template need on the
# host side:
#   - smartmontools (smartctl for the agent's SMART plugin, smartd for tests)
#   - /etc/sudoers.d/zabbix-smart: the agent runs smartctl via sudo
#   - custom.nvme.smart[*]: raw smartctl JSON for NVMe available spare (the stock
#     plugin does not expose it). Harmless on hosts without NVMe.
#   - custom.zfs.status: pool/vdev JSON from zpool status -j (OpenZFS 2.3+, no
#     root needed). Only when zpool exists; rerun after adding ZFS.
#   - smartd -s schedule so the stock "self-test is not passed" trigger has a
#     real result to report (it also fires when no test was ever run).
# Inside a VM Debian's smartmontools unit refuses to start
# (ConditionVirtualization=no); passed-through disks are real, so a drop-in
# clears that and retries if the daemon starts before the disks appear.
setup_disk_health() {
  local virt="${1:-0}" summary="" conf=/etc/smartd.conf

  apt-get install -y smartmontools >/dev/null

  printf 'zabbix ALL=(root) NOPASSWD: /usr/sbin/smartctl\n' > /etc/sudoers.d/zabbix-smart.tmp
  if visudo -cf /etc/sudoers.d/zabbix-smart.tmp >/dev/null 2>&1; then
    install -m 0440 /etc/sudoers.d/zabbix-smart.tmp /etc/sudoers.d/zabbix-smart
    summary="sudoers"
  else
    warn "sudoers rule for smartctl failed validation — not installed."
  fi
  rm -f /etc/sudoers.d/zabbix-smart.tmp

  if install_zbx_helper nvme-smart-json.sh 0755; then
    write_agent_dropin nvme-smart.conf 'UserParameter=custom.nvme.smart[*],/usr/local/bin/nvme-smart-json.sh "$1"'
    summary+="${summary:+, }nvme-spare"
  else
    warn "nvme-smart-json.sh not available — NVMe available-spare items will be unsupported."
  fi

  if command -v zpool >/dev/null 2>&1; then
    if install_zbx_helper zfs-status-json.py 0755; then
      write_agent_dropin zfs-status.conf 'UserParameter=custom.zfs.status,/usr/local/bin/zfs-status-json.py'
      summary+="${summary:+, }zfs"
    else
      warn "zfs-status-json.py not available — ZFS items will be unsupported."
    fi
  else
    note "No zpool on this host — ZFS UserParameter skipped (rerun monitoring.sh after adding ZFS)."
  fi

  # smartd: keep the packaged DEVICESCAN line, add the self-test schedule once.
  if [[ -f "$conf" ]] && grep -q '^DEVICESCAN' "$conf"; then
    cp -n "$conf" "${conf}.orig" 2>/dev/null || true
    if grep -q '^DEVICESCAN.* -s ' "$conf"; then
      sed -i -E "s#^(DEVICESCAN.*) -s \([^)]*\)#\1 -s ${SMARTD_SCHEDULE}#" "$conf"
    else
      sed -i -E "s#^DEVICESCAN #DEVICESCAN -s ${SMARTD_SCHEDULE} #" "$conf"
    fi
  else
    printf 'DEVICESCAN -d removable -n standby -s %s -m root -M exec /usr/share/smartmontools/smartd-runner\n' \
      "$SMARTD_SCHEDULE" > "$conf"
  fi
  if [[ "$virt" == "1" ]]; then
    install -d -m 755 /etc/systemd/system/smartmontools.service.d
    printf '[Unit]\nConditionVirtualization=\n[Service]\nRestart=on-failure\nRestartSec=60\n' \
      > /etc/systemd/system/smartmontools.service.d/virt.conf
    chmod 0644 /etc/systemd/system/smartmontools.service.d/virt.conf
    systemctl daemon-reload
  fi
  systemctl enable smartmontools >/dev/null 2>&1 || true
  if systemctl restart smartmontools 2>/dev/null; then
    summary+="${summary:+, }smartd tests ${SMARTD_SCHEDULE}"
  else
    warn "smartd did not start — check: systemctl status smartmontools (no SMART-capable disks?)"
  fi
  record "Zabbix disk health" "${summary:-nothing installed}"
}

# setup_snapraid — the "Homelab snapraid" template's host side plus the job it
# reports on: snapraid-runner.sh on a daily timer (diff, refuse to sync after a
# mass deletion, sync, scrub a slice of the oldest blocks), and
# snapraid-status-json.sh behind custom.snapraid.status, which the agent runs
# through a sudoers rule limited to `snapraid status` and `snapraid diff -q`.
setup_snapraid() {
  local ok=1 f
  command -v snapraid >/dev/null 2>&1 || apt-get install -y snapraid >/dev/null
  install_zbx_helper snapraid-status-json.sh 0755 || ok=0
  install_zbx_helper snapraid-runner.sh 0755 || ok=0
  for f in snapraid-runner.service snapraid-runner.timer; do
    if resolve_template "${ZBX_HELPER_DIR}/${f}" "zabbix/${f}"; then
      install -m 0644 "$RESOLVED_TEMPLATE" "/etc/systemd/system/${f}"
      [[ "$RESOLVED_TEMPLATE_IS_TMP" == "1" ]] && rm -f "$RESOLVED_TEMPLATE"
    else
      ok=0
    fi
  done
  if [[ "$ok" != "1" ]]; then
    warn "snapraid helpers not available — skipped."
    record "Zabbix snapraid" "skipped (helpers missing)"
    return 0
  fi
  printf 'zabbix ALL=(root) NOPASSWD: /usr/bin/snapraid status, /usr/bin/snapraid diff -q\n' > /etc/sudoers.d/zabbix-snapraid.tmp
  if visudo -cf /etc/sudoers.d/zabbix-snapraid.tmp >/dev/null 2>&1; then
    install -m 0440 /etc/sudoers.d/zabbix-snapraid.tmp /etc/sudoers.d/zabbix-snapraid
  else
    warn "sudoers rule for snapraid failed validation — not installed."
  fi
  rm -f /etc/sudoers.d/zabbix-snapraid.tmp
  write_agent_dropin snapraid-status.conf 'UserParameter=custom.snapraid.status,/usr/local/bin/snapraid-status-json.sh'
  systemctl daemon-reload
  systemctl enable --now snapraid-runner.timer >/dev/null 2>&1 || warn "snapraid-runner.timer did not enable — check: systemctl status snapraid-runner.timer"
  record "Zabbix snapraid" "installed (custom.snapraid.status; snapraid-runner.timer daily 04:00)"
}

# setup_pve_events — host side of the "Homelab Proxmox events" template:
# pve-replication-json.sh behind custom.pve.replication (every pvesr job as an
# LLD row) and pve-backup-json.py behind custom.pve.backup (finished vzdump
# tasks, failures as a sticky High), both through sudoers lines limited to
# `pvesr status` and the node's own `pvesh get /nodes/<host>/tasks`, and
# pve-ha-events-json.sh behind custom.pve.ha (recover/migrate/relocate from
# the pve-ha-crm journal, no sudo). Replaces the buzz repl-health-report,
# backup-health-report and ha-event-report watches.
setup_pve_events() {
  if ! install_zbx_helper pve-replication-json.sh 0755 || ! install_zbx_helper pve-backup-json.py 0755 || ! install_zbx_helper pve-ha-events-json.sh 0755; then
    warn "Proxmox events helpers not available — skipped."
    record "Zabbix PVE events" "skipped (helper missing)"
    return 0
  fi
  # State for the backup collector (cursor + monotonic counter), owned by the agent user.
  install -d -o zabbix -g zabbix -m 0750 /var/lib/zabbix/homelab
  # Two read-only commands: pvesr status, and the node's own task list via pvesh.
  printf 'zabbix ALL=(root) NOPASSWD: /usr/bin/pvesr status\nzabbix ALL=(root) NOPASSWD: /usr/bin/pvesh get /nodes/%s/tasks *\n' "$(hostname -s)" > /etc/sudoers.d/zabbix-pve.tmp
  if visudo -cf /etc/sudoers.d/zabbix-pve.tmp >/dev/null 2>&1; then
    install -m 0440 /etc/sudoers.d/zabbix-pve.tmp /etc/sudoers.d/zabbix-pve
  else
    warn "sudoers rule for pvesr failed validation — not installed."
  fi
  rm -f /etc/sudoers.d/zabbix-pve.tmp
  # The HA collector reads the pve-ha-crm journal: journal group for the agent user.
  if getent group systemd-journal >/dev/null 2>&1 && id zabbix >/dev/null 2>&1; then
    usermod -aG systemd-journal zabbix
  fi
  write_agent_dropin pve-events.conf 'UserParameter=custom.pve.replication,/usr/local/bin/pve-replication-json.sh
UserParameter=custom.pve.backup,/usr/local/bin/pve-backup-json.py
UserParameter=custom.pve.ha,/usr/local/bin/pve-ha-events-json.sh'
  record "Zabbix PVE events" "installed (custom.pve.replication, custom.pve.backup, custom.pve.ha)"
}

# setup_nic_flap — physical-NIC link-flap UserParameters for the "Homelab
# physical NIC flapping" template: an LLD of real, non-wireless NICs and the
# kernel's carrier_down_count per interface (driver-agnostic; a bouncing cable
# on a corosync NIC self-fences a Proxmox node within a minute).
setup_nic_flap() {
  if install_zbx_helper physnic-discovery.sh 0755 && install_zbx_helper nic-carrier-down.sh 0755 && install_zbx_helper nic-pcie-detach.sh 0755; then
    write_agent_dropin physnic.conf 'UserParameter=custom.physnic.discovery,/usr/local/bin/physnic-discovery.sh
UserParameter=custom.nic.carrier_down[*],/usr/local/bin/nic-carrier-down.sh "$1"
UserParameter=custom.nic.pcie_detach,/usr/local/bin/nic-pcie-detach.sh'
    # The PCIe-detach counter reads the kernel journal; dmesg is root-only on a
    # hardened host (kernel.dmesg_restrict=1), journal access is a group.
    if getent group systemd-journal >/dev/null 2>&1 && id zabbix >/dev/null 2>&1; then
      usermod -aG systemd-journal zabbix
    fi
    record "Zabbix NIC flap" "installed (custom.physnic.discovery, custom.nic.carrier_down, custom.nic.pcie_detach)"
  else
    warn "NIC flap helper scripts not available — skipped."
    record "Zabbix NIC flap" "skipped (helpers missing)"
  fi
}

# setup_tbmesh — the Thunderbolt mesh auto-heal and its Zabbix collector for
# the "Homelab TB3 mesh" template. The heal (tb-mesh-heal.sh, root cron every
# minute) repairs the mesh itself and appends every action to
# /var/lib/tb-mesh-heal/events.log; tb-mesh-status-json.py turns that plus the
# heal's state files into custom.tbmesh.status as the zabbix user. No sudoers
# line: the state dir is 0755 and the heal writes with umask 022. Mesh nodes
# only (the pve-enXX-disconnect-bug-fix.sh reset scripts must exist).
setup_tbmesh() {
  if ! install_zbx_helper tb-mesh-heal.sh 0755 /usr/local/sbin || ! install_zbx_helper tb-mesh-status-json.py 0755; then
    warn "TB3 mesh helpers not available — skipped."
    record "Zabbix TB3 mesh" "skipped (helpers missing)"
    return 0
  fi
  install -d -m 0755 /var/lib/tb-mesh-heal
  chmod 0644 /var/lib/tb-mesh-heal/* 2>/dev/null || true   # files from an older heal (umask 027)
  install_buzz_cron tb-mesh-heal "* * * * *" /usr/local/sbin/tb-mesh-heal.sh
  write_agent_dropin tbmesh.conf 'UserParameter=custom.tbmesh.status,/usr/local/bin/tb-mesh-status-json.py'
  record "Zabbix TB3 mesh" "installed (tb-mesh-heal cron every minute, custom.tbmesh.status)"
}

# setup_kernel_watch — the "Homelab kernel" template's host side: a counter of
# kernel "task blocked for more than N seconds" lines this boot, read from the
# kernel journal as the zabbix user (systemd-journal group). A hung task is a
# device that stopped answering; on 2026-09-17 a stalled SSD on pve1 froze the
# firewall VM for 40 minutes. Every bare-metal node and VM gets it; containers
# have no kernel journal of their own.
setup_kernel_watch() {
  if ! install_zbx_helper kernel-hung-tasks.sh 0755; then
    warn "Kernel watch helper not available — skipped."
    record "Zabbix kernel watch" "skipped (helper missing)"
    return 0
  fi
  if getent group systemd-journal >/dev/null 2>&1 && id zabbix >/dev/null 2>&1; then
    usermod -aG systemd-journal zabbix
  fi
  write_agent_dropin kernel-watch.conf 'UserParameter=custom.kernel.hung_tasks,/usr/local/bin/kernel-hung-tasks.sh'
  record "Zabbix kernel watch" "installed (custom.kernel.hung_tasks)"
}

# setup_host_metadata — HostMetadata for Zabbix autoregistration: a token
# list derived from what this run installed (drop-ins in zabbix_agent2.d), so
# the server's autoregistration actions link the right templates with no GUI
# step. ZABBIX_HOST_METADATA overrides the whole list. Runs last, after every
# other setup_* has written its drop-in, right before the agent restart.
setup_host_metadata() {
  if ! install_zbx_helper zabbix-host-metadata.sh 0755; then
    warn "Host metadata helper not available — HostMetadata not set (link templates by hand)."
    record "Zabbix host metadata" "skipped (helper missing)"
    return 0
  fi
  local md
  md="$(ZABBIX_HOST_METADATA="${ZABBIX_HOST_METADATA:-}" /usr/local/bin/zabbix-host-metadata.sh)"
  local tmp; tmp="$(mktemp)"
  grep -vE '^(HostMetadata|HostMetadataItem)=' "$ZBX_CONF" > "$tmp"
  printf 'HostMetadata=%s\n' "$md" >> "$tmp"
  install -m 0644 "$tmp" "$ZBX_CONF"; rm -f "$tmp"
  log "HostMetadata=${md} (autoregistration tokens)."
  record "Zabbix host metadata" "HostMetadata=${md}"
}

# setup_bootcheck — collector for the "Homelab boot check" template. The
# post-outage runbook (pve-outage-runbook.sh, run once per boot by
# pve-outage-boot-check.service; not part of this repo) writes
# /var/lib/pve-outage-runbook/latest.json; bootcheck-status-json.py reads it as
# the zabbix user and adds the computed fields. No sudoers line: the runbook
# writes with umask 022 and keeps its dir 0755 since 2026-09-16.
setup_bootcheck() {
  if ! install_zbx_helper bootcheck-status-json.py 0755; then
    warn "Boot check helper not available — skipped."
    record "Zabbix boot check" "skipped (helper missing)"
    return 0
  fi
  if [[ -d /var/lib/pve-outage-runbook ]]; then
    chmod 0755 /var/lib/pve-outage-runbook 2>/dev/null || true
    chmod 0644 /var/lib/pve-outage-runbook/*.json 2>/dev/null || true   # files from a manual run under umask 027
  fi
  write_agent_dropin bootcheck.conf 'UserParameter=custom.bootcheck.status,/usr/local/bin/bootcheck-status-json.py'
  record "Zabbix boot check" "installed (custom.bootcheck.status)"
}

# detect_rootless_docker_users — print the username(s) that currently own a
# running ROOTLESS Docker daemon (one per line), discovered from their API
# sockets at /run/user/<uid>/docker.sock. Empty output = none running right now.
detect_rootless_docker_users() {
  local sock uid u
  for sock in /run/user/*/docker.sock; do
    [[ -S "$sock" ]] || continue
    uid="$(basename "$(dirname "$sock")")"
    u="$(id -un "$uid" 2>/dev/null)" || continue
    printf '%s\n' "$u"
  done
}

# setup_zabbix_rootless_docker <docker_user> — make zabbix-agent2 monitor <user>'s
# ROOTLESS Docker. Rootless Docker exposes its API at /run/user/<uid>/docker.sock
# (not the rootful /var/run/docker.sock), inside a 0700 runtime dir only the
# owner can traverse — so the agent's Docker plugin both looks in the wrong place
# AND lacks permission. The durable fix, in four parts:
#   [1] a Docker-plugin drop-in pointing Plugins.Docker.Endpoint at the socket;
#   [2] lingering, so the runtime dir + socket survive logout/reboot;
#   [3] a systemd override running the agent AS that user (shares socket owner),
#       with RuntimeDirectory/LogsDirectory so /run/zabbix and /var/log/zabbix
#       are re-owned by that user at every service start (reboot-proof —
#       /run is tmpfs, so a one-time chown would decay on the first boot);
#   [4] ownership/group repair so the re-usered agent can start and read its
#       0640 root:zabbix configs;
#   [5] the packaged logrotate rule repointed at that user — it recreates the
#       log as zabbix:zabbix 0640 (not group-writable), which would kill the
#       agent at its next start after a rotation.
# Then reload + restart + verify docker.info. Idempotent.
# (Folds in the former fix-zabbix-rootless-docker.sh.)
setup_zabbix_rootless_docker() {
  local du="$1" uid runtime sock dropin_dir dropin ovr_dir ovr d lr
  if ! uid="$(id -u "$du" 2>/dev/null)"; then
    warn "User '$du' does not exist — skipping rootless Docker monitoring."
    record "Zabbix rootless Docker" "skipped (no such user: $du)"
    return 1
  fi
  runtime="/run/user/${uid}"
  sock="${runtime}/docker.sock"
  dropin_dir="/etc/zabbix/zabbix_agent2.d/plugins.d"
  dropin="${dropin_dir}/docker.conf"
  ovr_dir="/etc/systemd/system/zabbix-agent2.service.d"
  ovr="${ovr_dir}/override.conf"
  lr="/etc/logrotate.d/zabbix-agent2"

  info "Configuring zabbix-agent2 to monitor rootless Docker for ${BOLD}${du}${RESET} (UID ${uid}, socket ${sock})."
  [[ -S "$sock" ]] || warn "${sock} not present yet — lingering (below) plus a running rootless daemon will create it."

  # [1] Docker-plugin drop-in pointing at the rootless socket. Agent 2 reads
  #     every *.conf under plugins.d/, so this overrides the endpoint without
  #     editing the main config (upgrade-safe and easy to remove).
  install -d -m 755 "$dropin_dir"
  cat > "$dropin" <<EOF
# Zabbix Agent 2 - Docker plugin endpoint for ROOTLESS Docker.
# Rootless Docker for ${du} (UID ${uid}); the default
# unix:///var/run/docker.sock does not exist under rootless mode.
Plugins.Docker.Endpoint=unix://${sock}
EOF
  chmod 644 "$dropin"

  # [2] Keep the runtime dir (and socket) alive without an active login.
  loginctl enable-linger "$du"

  # [3] Run the agent as the rootless user so it shares ownership of the socket.
  #     RuntimeDirectory/LogsDirectory make systemd (re-)own /run/zabbix and
  #     /var/log/zabbix as User=/Group= at every start — /run is tmpfs, so
  #     without this the PID file/sockets break on the first reboot.
  #     UPGRADE-PROOFING: the zabbix-agent2 package postinst resets
  #     /var/log/zabbix back to zabbix:zabbix on every (unattended) upgrade,
  #     which locks the re-usered agent out of its log -> "Cannot open log
  #     file" and a crash-loop. LogsDirectory= already re-owns the dir at
  #     start, but (a) drop-ins written before this fix lacked it and (b) it
  #     does not touch a stale log *file* left owned by zabbix inside. The
  #     '+'-prefixed ExecStartPre runs as root regardless of User= and chowns
  #     the whole tree to the run-as user immediately before the agent opens
  #     its log — so no package upgrade or log rotation can desync it again.
  install -d -m 755 "$ovr_dir"
  cat > "$ovr" <<EOF
[Service]
User=${du}
Group=${du}
Environment=XDG_RUNTIME_DIR=${runtime}
RuntimeDirectory=zabbix
LogsDirectory=zabbix
ExecStartPre=+/bin/chown -R ${du}:${du} /var/log/zabbix
EOF

  # [4] Repair ownership/group so the re-usered agent can start and read configs.
  for d in /var/log/zabbix /run/zabbix; do
    [[ -d "$d" ]] && chown -R "${du}:${du}" "$d"
  done
  getent group zabbix >/dev/null 2>&1 && usermod -aG zabbix "$du"

  # [5] Keep rotated logs writable: the packaged rule recreates the log as
  #     'create 0640 zabbix zabbix', which the re-usered agent can't open.
  if [[ -f "$lr" ]] && grep -qE '^[[:space:]]*create[[:space:]]' "$lr" \
     && ! grep -qE "^[[:space:]]*create[[:space:]]+[0-7]+[[:space:]]+${du}[[:space:]]+${du}([[:space:]]|$)" "$lr"; then
    cp -a "$lr" "${lr}.bak.$(date +%F-%H%M%S)"
    sed -i -E "s/^([[:space:]]*create[[:space:]]+[0-7]+)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+/\1 ${du} ${du}/" "$lr"
    log "Repointed the logrotate 'create' rule in ${lr} at ${du} (backup kept)."
  fi

  # Apply the override and verify the Docker plugin can reach the socket.
  systemctl daemon-reload
  if systemctl restart zabbix-agent2 2>/dev/null; then
    sleep 1
    if runuser -u "$du" -- env XDG_RUNTIME_DIR="$runtime" zabbix_agent2 -t docker.info >/dev/null 2>&1; then
      log "zabbix-agent2 now monitoring ${du}'s rootless Docker (docker.info returned data)."
      record "Zabbix rootless Docker" "monitoring ${du} (UID ${uid})"
    else
      warn "Agent restarted but docker.info is still failing — check: journalctl -u zabbix-agent2 -n 40 --no-pager"
      record "Zabbix rootless Docker" "configured for ${du}; docker.info not yet returning (check the rootless daemon)"
    fi
  else
    warn "zabbix-agent2 did not restart after the rootless Docker override — check: systemctl status zabbix-agent2"
    record "Zabbix rootless Docker" "configured for ${du}; service not running (check status)"
  fi
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
# if it couldn't apply the setting. (Same logic as container.sh.)
write_journald_daemon_json() {
  local path="$1" owner="$2" dir; dir="$(dirname "$path")"
  local labels="$DOCKER_LOG_LABELS"
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
  # /bin/sh, never the account's login shell — POSIX 'export' breaks in fish.
  runuser -u "$u" -- /bin/sh -c \
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
      systemctl restart docker 2>/dev/null || true
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
    log "Docker now logs to the journal (journald)${DOCKER_LOG_LABELS:+; grouping labels: ${DOCKER_LOG_LABELS}}."
    note "Recreate running containers to adopt it: ${DIM}docker compose up -d --force-recreate${RESET}"
    record "Docker log-driver" "journald (${targets})"
  fi
}

# write_watch_script <template-name> <target-path> — render a watch script
# from buzz/<template-name>, injecting the chosen alert sink (a send_alert
# shell function) at the @@SEND_ALERT@@ marker, and install it 0755.
# Returns non-zero if the template can't be found.
write_watch_script() {
  local tpl="$1" target="$2"
  resolve_template "${SCRIPT_DIR}/buzz/${tpl}" "buzz/${tpl}" || return 1
  local tmp sink; tmp="$(mktemp)"; sink="$(mktemp)"
  # Compose send_alert from every enabled sink — with both enabled, every
  # alert goes to both (each delivery individually fail-soft).
  {
    printf 'send_alert() {\n'
    if sink_enabled buzz && [[ -n "$BUZZ_TARGET" ]]; then
      printf '  ssh -i /root/.ssh/buzz_report -o BatchMode=yes -o ConnectTimeout=10 \\\n'
      printf '    -o StrictHostKeyChecking=accept-new -p %s %s "v3 $1" >/dev/null 2>&1 || true\n' "$BUZZ_PORT" "$BUZZ_TARGET"
    fi
    if sink_enabled ntfy && [[ -n "$NTFY_URL" ]]; then
      local _auth=""
      [[ -n "$NTFY_TOKEN" ]] && _auth=' -H "Authorization: Bearer '"$NTFY_TOKEN"'"'
      printf '  curl -fsS -m 10 -H "Title: $(hostname) homelab alert"%s \\\n' "$_auth"
      printf '    -d "$1" "%s" >/dev/null 2>&1 || true\n' "$NTFY_URL"
    fi
    printf '  return 0\n}\n'
  } > "$sink"
  awk -v sinkfile="$sink" '
    /@@SEND_ALERT@@/ { while ((getline l < sinkfile) > 0) print l; close(sinkfile); next }
    { print }
  ' "$RESOLVED_TEMPLATE" > "$tmp"
  [[ "$RESOLVED_TEMPLATE_IS_TMP" == "1" ]] && rm -f "$RESOLVED_TEMPLATE"
  rm -f "$sink"
  install -m 0755 "$tmp" "$target"
  rm -f "$tmp"
  return 0
}

# install_buzz_cron <name> <schedule> <script> — write an /etc/cron.d entry
# with an explicit PATH (cron's default lacks /usr/sbin, where qm/pct/smartctl
# live) and root-only perms (harden.sh chmods /etc/cron.d to 700 anyway).
install_buzz_cron() {
  local name="$1" sched="$2" script="$3"
  {
    printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
    printf '%s root %s >/dev/null 2>&1\n' "$sched" "$script"
  } > "/etc/cron.d/${name}"
  chmod 0644 "/etc/cron.d/${name}"
}

# ==============================================================================
#  Splash
# ==============================================================================
# Don't wipe the terminal when run nested by init.sh — keep the previous
# script's output visible. (BOOTSTRAP_NESTED is set by init.sh.)
[[ "${BOOTSTRAP_NESTED:-0}" == "1" ]] || clear 2>/dev/null || true
printf '%s%s  Debian 13 Homelab Bootstrap — monitoring (Zabbix, Grafana Alloy, buzz)%s\n' "$BOLD" "$CYN" "$RESET"
hr '─'

require_root
if ! command -v apt-get >/dev/null 2>&1; then err "apt-get not found — this targets Debian/apt systems."; exit 1; fi

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
# (LXC/etc.), the cpuTemperature UserParameter drop-in is written commented out.
ZBX_VIRT=0; ZBX_CONTAINER=0
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q 2>/dev/null; then
  ZBX_VIRT=1
  # A container (LXC etc.) sees no disks of its own: SMART, ZFS and smartd are
  # the host's business, so the disk-health helpers default to off there unless
  # ZABBIX_DISK_HEALTH says otherwise. A VM keeps them (passed-through disks).
  systemd-detect-virt -cq 2>/dev/null && ZBX_CONTAINER=1
fi
if [[ "$ZBX_CONTAINER" == "1" && -z "${ZABBIX_DISK_HEALTH:-}" ]]; then
  ZBX_DISK_HEALTH=0
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

  # inxi backs the cpuTemperature UserParameter drop-in (written below).
  info "Installing zabbix-agent2 and inxi..."
  apt-get install -y zabbix-agent2 inxi

  # Back up the package default before replacing it with the custom config.
  if [[ -f "$ZBX_CONF" ]]; then
    cp -a "$ZBX_CONF" "${ZBX_CONF}.bak.$(date +%F-%H%M%S)"
  fi
  install -d -m 755 "$(dirname "$ZBX_CONF")"
  _zbx_tmp="$(mktemp)"
  if write_zabbix_conf "$_zbx_tmp" "$ZBX_HOSTNAME" "$ZBX_SERVER_ACTIVE"; then
    install -m 0644 "$_zbx_tmp" "$ZBX_CONF"
    rm -f "$_zbx_tmp"
    log "Wrote ${ZBX_CONF} (Hostname=${ZBX_HOSTNAME}, ServerActive=${ZBX_SERVER_ACTIVE})."
    write_cpu_temp_dropin "$ZBX_HOSTNAME" "$ZBX_VIRT"
    if [[ "$ZBX_VIRT" == "1" ]]; then
      note "VM/container detected — ${ZBX_HOSTNAME}.cpuTemperature UserParameter commented out (no CPU sensors)."
    else
      note "cpuTemperature UserParameter key set to ${ZBX_HOSTNAME}.cpuTemperature (plugins.d drop-in)."
    fi

    # The agent LISTENS on 10050 for passive checks — open it in the hardened
    # firewall so the Zabbix server can poll this host. (ServerActive is
    # outbound and needs no rule.)
    open_firewall_port tcp 10050 "Zabbix agent 2 passive checks"

    # Disk-health helpers (SMART via sudo, NVMe spare, ZFS, smartd self-tests).
    if [[ "${ZBX_DISK_HEALTH,,}" =~ ^(1|y|yes|true|on)$ ]]; then
      info "Installing disk-health helpers for the SMART and ZFS templates..."
      setup_disk_health "$ZBX_VIRT"
    else
      if [[ "$ZBX_CONTAINER" == "1" ]]; then
        note "Container detected: disks belong to the host; disk-health helpers skipped (set ZABBIX_DISK_HEALTH=1 to force)."
        record "Zabbix disk health" "skipped (container)"
      else
        note "Disk-health helpers skipped (ZABBIX_DISK_HEALTH=0)."
        record "Zabbix disk health" "skipped (ZABBIX_DISK_HEALTH=0)"
      fi
    fi
    # NIC link-flap helpers: bare metal by default; a VM's virtual NIC never
    # carries a real cable, so its flaps belong to the host.
    if [[ -z "$ZBX_NIC_FLAP" ]]; then
      [[ "$ZBX_VIRT" == "1" ]] && ZBX_NIC_FLAP=0 || ZBX_NIC_FLAP=1
    fi
    if [[ "${ZBX_NIC_FLAP,,}" =~ ^(1|y|yes|true|on)$ ]]; then
      info "Installing physical-NIC link-flap helpers..."
      setup_nic_flap
    else
      note "NIC link-flap helpers skipped (virtualized host, or ZABBIX_NIC_FLAP=0)."
    fi
    # snapraid watch + runner: only where a snapraid array is configured.
    if [[ -z "$ZBX_SNAPRAID" ]]; then
      [[ -f /etc/snapraid.conf ]] && ZBX_SNAPRAID=1 || ZBX_SNAPRAID=0
    fi
    if [[ "${ZBX_SNAPRAID,,}" =~ ^(1|y|yes|true|on)$ ]]; then
      info "Installing the snapraid watch and daily runner..."
      setup_snapraid
    fi
    # Proxmox events (replication jobs today): only where pvesr exists.
    if [[ -z "$ZBX_PVE_EVENTS" ]]; then
      command -v pvesr >/dev/null 2>&1 && ZBX_PVE_EVENTS=1 || ZBX_PVE_EVENTS=0
    fi
    if [[ "${ZBX_PVE_EVENTS,,}" =~ ^(1|y|yes|true|on)$ ]]; then
      info "Installing the Proxmox events collectors (replication, backups, HA events)..."
      setup_pve_events
    fi
    # TB3 mesh auto-heal + collector: only on mesh nodes (the TB reset scripts exist).
    if [[ -z "$ZBX_TBMESH" ]]; then
      [[ -x /usr/local/bin/pve-en02-disconnect-bug-fix.sh ]] && ZBX_TBMESH=1 || ZBX_TBMESH=0
    fi
    if [[ "${ZBX_TBMESH,,}" =~ ^(1|y|yes|true|on)$ ]]; then
      info "Installing the Thunderbolt mesh auto-heal and its Zabbix collector..."
      setup_tbmesh
    fi
    # Kernel hung-task counter: every host that has its own kernel (not containers).
    if [[ "$ZBX_CONTAINER" == "1" ]]; then
      note "Container detected: kernel watch skipped (the kernel journal belongs to the host)."
    else
      info "Installing the kernel hung-task watch..."
      setup_kernel_watch
    fi
    # Boot check collector: only where the post-outage boot service is installed.
    if [[ -z "$ZBX_BOOTCHECK" ]]; then
      [[ -f /etc/systemd/system/pve-outage-boot-check.service ]] && ZBX_BOOTCHECK=1 || ZBX_BOOTCHECK=0
    fi
    if [[ "${ZBX_BOOTCHECK,,}" =~ ^(1|y|yes|true|on)$ ]]; then
      info "Installing the boot check collector..."
      setup_bootcheck
    fi

    setup_host_metadata

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

# --- Optionally monitor a ROOTLESS Docker daemon from this agent --------------
# Only worth offering once the agent itself was set up (server address present).
if [[ -n "$ZBX_SERVER_ACTIVE" ]]; then
  # Auto-detect the rootless Docker owner (first running daemon) unless told.
  [[ -z "$ZBX_DOCKER_USER" ]] && ZBX_DOCKER_USER="$(detect_rootless_docker_users | head -n1)"
  _do_rootless="$ZBX_ROOTLESS_DOCKER"

  if [[ -z "$_do_rootless" ]]; then
    # Ask only when we actually found a rootless daemon worth monitoring.
    if [[ -n "$ZBX_DOCKER_USER" && "$INTERACTIVE" -eq 1 ]]; then
      info "Rootless Docker detected for ${BOLD}${ZBX_DOCKER_USER}${RESET}."
      note "Monitoring it needs extra tweaks: point the plugin at the user's socket, enable lingering, and run the agent as that user."
      printf '%s%s Set up zabbix-agent2 to monitor rootless Docker for %s? [y/N]: %s' \
        "$YEL" "$S_WARN" "$ZBX_DOCKER_USER" "$RESET" > /dev/tty
      read -r _r < /dev/tty || _r=""
      [[ "$_r" =~ ^[Yy] ]] && _do_rootless=1 || _do_rootless=0
    else
      _do_rootless=0
    fi
  fi
  [[ "${_do_rootless,,}" =~ ^(1|y|yes|true|on)$ ]] && _do_rootless=1 || _do_rootless=0

  if [[ "$_do_rootless" == "1" ]]; then
    # Forced on via env without a detected daemon — resolve the owner.
    if [[ -z "$ZBX_DOCKER_USER" ]]; then
      if [[ "$INTERACTIVE" -eq 1 ]]; then
        printf '%s%s Which user owns the rootless Docker daemon?%s%s ' \
          "$YEL" "$S_INFO" "${SUDO_USER:+ [default: $SUDO_USER]}" "$RESET" > /dev/tty
        read -r ZBX_DOCKER_USER < /dev/tty || ZBX_DOCKER_USER=""
      fi
      ZBX_DOCKER_USER="${ZBX_DOCKER_USER:-${SUDO_USER:-}}"
    fi
    if [[ -n "$ZBX_DOCKER_USER" ]]; then
      setup_zabbix_rootless_docker "$ZBX_DOCKER_USER" || true
    else
      warn "Rootless Docker monitoring requested but no owning user resolved — set ZABBIX_DOCKER_USER=<user>."
      record "Zabbix rootless Docker" "skipped (no user resolved)"
    fi
  elif [[ -n "$ZBX_DOCKER_USER" ]]; then
    note "Skipped rootless Docker monitoring (agent left on the default rootful socket)."
    record "Zabbix rootless Docker" "skipped (declined)"
  fi
fi
fi   # end: pkg_selected zabbix-agent2

# ==============================================================================
if pkg_selected alloy; then
banner "Installing Grafana Alloy (log shipper)"
# ==============================================================================
# Adds Grafana's apt repo, installs alloy, then drops in the journal-first
# config with the Loki endpoint substituted in. See https://grafana.com/docs/alloy
ALLOY_LOKI_DEFAULT="localhost:3100"

# Resolve the Loki base URL — prompt if unset; default to localhost:3100.
if [[ -z "$LOKI_URL" ]]; then
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    printf '%s%s Loki base URL for Alloy to push to (host:port) [default: %s]: %s' \
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
  # No usage reports to stats.grafana.org: on this LAN the resolver answers
  # such names with 0.0.0.0 and Alloy retried five times a minute, every
  # minute, into the journal (seen on every node, 2026-09-17). The Debian
  # package reads CUSTOM_ARGS from /etc/default/alloy into the unit.
  if ! grep -q -- '--disable-reporting' /etc/default/alloy 2>/dev/null; then
    if grep -q '^CUSTOM_ARGS=' /etc/default/alloy 2>/dev/null; then
      sed -i 's/^CUSTOM_ARGS="\(.*\)"$/CUSTOM_ARGS="\1 --disable-reporting"/; s/^CUSTOM_ARGS=" /CUSTOM_ARGS="/' /etc/default/alloy
    else
      printf 'CUSTOM_ARGS="--disable-reporting"\n' >> /etc/default/alloy
    fi
  fi

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

# If Docker-log capture is on and Docker is already installed on THIS host, offer
# to set its journald log-driver ourselves — so an existing Docker host needs no
# separate container.sh run. (On a fresh host where container.sh installs Docker
# later, Docker isn't present yet here, so this is skipped and container.sh handles it.)
if [[ "$ALLOY_DOCKER_LOGS" == "1" ]] && command -v docker >/dev/null 2>&1; then
  configure_docker_journald
fi
fi   # end: pkg_selected alloy

# ==============================================================================
if pkg_selected alerts; then
banner "Installing health & event alerts (${ALERTS_SINK} delivery)"
# ==============================================================================
# Installs the chosen watch scripts + crons; each watch hands its payload to
# the injected send_alert sink. buzz: forced-command ssh to the relay dev box
# (dedicated key; alerts flow only after the printed public key is registered
# there). ntfy: HTTP push to a topic — works immediately, messages carry the
# raw v3 payload text.

# Resolve each enabled sink's config; an unconfigured sink is dropped with a
# warning, and alerts are skipped only when NO sink remains usable.
_active_sinks=()
if sink_enabled buzz; then
  if [[ -z "$BUZZ_TARGET" && "$INTERACTIVE" -eq 1 ]]; then
    printf '%s%s buzz relay dev box the watches ssh to (user@host): %s' \
      "$YEL" "$S_INFO" "$RESET" > /dev/tty
    read -r BUZZ_TARGET < /dev/tty || BUZZ_TARGET=""
    BUZZ_TARGET="${BUZZ_TARGET//[[:space:]]/}"
  fi
  if [[ -n "$BUZZ_TARGET" ]]; then
    _active_sinks+=(buzz)
  else
    warn "buzz delivery enabled but no relay target (BUZZ_TARGET=user@host) — dropping the buzz sink."
  fi
fi
if sink_enabled ntfy; then
  if [[ -z "$NTFY_URL" && "$INTERACTIVE" -eq 1 ]]; then
    printf '%s%s ntfy topic URL to push alerts to (e.g. https://ntfy.sh/my-topic): %s' \
      "$YEL" "$S_INFO" "$RESET" > /dev/tty
    read -r NTFY_URL < /dev/tty || NTFY_URL=""
    NTFY_URL="${NTFY_URL//[[:space:]]/}"
  fi
  if [[ -n "$NTFY_URL" ]]; then
    command -v curl >/dev/null 2>&1 || apt-get install -y curl >/dev/null
    _active_sinks+=(ntfy)
  else
    warn "ntfy delivery enabled but no topic URL (NTFY_URL=https://host/topic) — dropping the ntfy sink."
  fi
fi
ALERTS_SINKS="${_active_sinks[*]:-}"

if [[ -z "$ALERTS_SINKS" ]]; then
  warn "No usable alert delivery configured — skipping alerts."
  record "alerts" "skipped (no configured sink)"
else
  # Normalise the alert list ("none" or blank = nothing to install).
  [[ "${BUZZ_ALERTS,,}" == "none" ]] && BUZZ_ALERTS=""
  read -ra _buzz_sel <<< "$BUZZ_ALERTS"
  alert_selected() { local a; for a in "${_buzz_sel[@]:-}"; do [[ "$a" == "$1" ]] && return 0; done; return 1; }

  if sink_enabled buzz; then
    if [[ ! -f "$BUZZ_KEY" ]]; then
      ssh-keygen -t ed25519 -N '' -C "$(hostname)-buzz-report" -f "$BUZZ_KEY" >/dev/null
      log "Generated ${BUZZ_KEY} (dedicated alert key for this node)."
    else
      info "Using the existing key at ${BUZZ_KEY}."
    fi
  fi

  _buzz_installed=()
  _buzz_skipped=()

  if alert_selected disk || alert_selected repl || alert_selected backup || alert_selected ha; then
    note "The disk, repl, backup and ha buzz watches were retired (2026-09-15/16): Zabbix covers them (SMART/ZFS templates, Homelab Proxmox events). Nothing installed for them."
    _buzz_skipped+=("disk/repl/backup/ha (retired, now Zabbix)")
  fi

  if alert_selected tbmesh; then
    note "The tbmesh buzz watch was retired (2026-09-16): the mesh heal now installs with the Zabbix helpers (ZABBIX_TBMESH) and reports through the Homelab TB3 mesh template. Nothing installed for it here."
    _buzz_skipped+=("tbmesh (retired, now Zabbix)")
  fi

  _sink_desc=""
  sink_enabled buzz && _sink_desc="buzz ${BUZZ_TARGET}:${BUZZ_PORT}"
  sink_enabled ntfy && _sink_desc="${_sink_desc:+${_sink_desc} + }ntfy ${NTFY_URL}"
  if (( ${#_buzz_installed[@]} )); then
    log "alert watches installed: ${_buzz_installed[*]} (via ${ALERTS_SINKS})"
    record "alerts" "watches: ${_buzz_installed[*]}; sink ${_sink_desc}${_buzz_skipped[*]:+; skipped: ${_buzz_skipped[*]}}"
  else
    warn "No alert watches ended up installed${_buzz_skipped[*]:+ (${_buzz_skipped[*]})}."
    record "alerts" "no watches installed${_buzz_skipped[*]:+ (${_buzz_skipped[*]})}"
  fi
fi
fi   # end: pkg_selected alerts

# ==============================================================================
#  Recap
# ==============================================================================
ELAPSED=$(( $(date +%s) - START_TS )); MM=$(( ELAPSED / 60 )); SS=$(( ELAPSED % 60 ))
printf '\n'; hr '═'
printf '%s%s  ✅  MONITORING SETUP COMPLETE — RECAP%s\n' "$BOLD" "$GRN" "$RESET"
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
if pkg_selected zabbix-agent2; then
  printf '   %s•%s  Add this host on your Zabbix server using hostname %s%s%s, then confirm data\n' "$BOLD" "$RESET" "$BOLD" "$(hostname)" "$RESET"
  printf '       with: %ssystemctl status zabbix-agent2%s and %stail -f /var/log/zabbix/zabbix_agent2.log%s\n' "$DIM" "$RESET" "$DIM" "$RESET"; _had_step=1
  if [[ "${ZBX_DISK_HEALTH,,}" =~ ^(1|y|yes|true|on)$ ]]; then
    printf '   %s•%s  Link the templates on the server: %sSMART by Zabbix agent 2 active%s (with the Homelab\n' "$BOLD" "$RESET" "$BOLD" "$RESET"
    printf '       additions from zabbix/templates/) and, on ZFS hosts, %sHomelab ZFS pools%s. Active-only agents:\n' "$BOLD" "$RESET"
    printf '       discovery runs on the agent'"'"'s 10-minute clock, so give it up to 15 minutes before judging.\n'
    printf '       On a VM whose boot disk is virtual, set the host macro %s{$SMART.DISK.NAME.NOT_MATCHES}%s to hide it.\n' "$DIM" "$RESET"
  fi
  if [[ "${ZBX_NIC_FLAP,,}" =~ ^(1|y|yes|true|on)$ ]]; then
    printf '   %s•%s  Also link %sHomelab physical NIC flapping%s (bare-metal hosts).\n' "$BOLD" "$RESET" "$BOLD" "$RESET"
  fi
  if [[ "${ZBX_PVE_EVENTS:-0}" == "1" ]]; then
    printf '   %s•%s  Also link %sHomelab Proxmox events%s (zabbix/templates/homelab-proxmox-events.yaml) on cluster nodes.\n' "$BOLD" "$RESET" "$BOLD" "$RESET"
  fi
  if [[ "${ZBX_SNAPRAID:-0}" == "1" ]]; then
    printf '   %s•%s  Also link %sHomelab snapraid%s (zabbix/templates/homelab-snapraid.yaml); first run: %s/usr/local/bin/snapraid-runner.sh%s\n' "$BOLD" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
  fi
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
if pkg_selected alerts && sink_enabled ntfy && [[ -n "${NTFY_URL:-}" ]]; then
  printf '   %s•%s  Alerts push to %s%s%s — subscribe to that topic in the ntfy app/web UI.\n' "$BOLD" "$RESET" "$BOLD" "$NTFY_URL" "$RESET"
  printf '       Test now: %scurl -d "test alert" %s%s\n' "$DIM" "$NTFY_URL" "$RESET"
  _had_step=1
fi
if pkg_selected alerts && sink_enabled buzz && [[ -n "${BUZZ_TARGET:-}" && -f "${BUZZ_KEY}.pub" ]]; then
  printf '   %s•%s  Register this node on the dev box (%s) or no alert will ever arrive:\n' "$BOLD" "$RESET" "$BUZZ_TARGET"
  printf '       append to the dev box user'"'"'s ~/.ssh/authorized_keys (forced-command dispatcher, one line):\n'
  printf '       %scommand="/path/to/pve-dispatch.sh %s",restrict %s%s\n' "$DIM" "$(hostname)" "$(cat "${BUZZ_KEY}.pub")" "$RESET"
  printf '       then test from this node: %sssh -i %s -p %s %s "v3 sata TEST health=PASSED realloc=0 pending=0 offline=0"%s\n' \
    "$DIM" "$BUZZ_KEY" "$BUZZ_PORT" "$BUZZ_TARGET" "$RESET"
  _had_step=1
fi
(( _had_step == 0 )) && printf '   %s•%s  Nothing further to do.\n' "$BOLD" "$RESET"
printf '%s%s  Done. 📈%s\n\n' "$BOLD" "$GRN" "$RESET"

# One-line summary for init.sh's bootstrap report.
if (( ${#SELECTED_PKGS[@]} > 0 )); then _agents="installed ${SELECTED_PKGS[*]}"; else _agents="no agents selected"; fi
mkdir -p /var/lib/homelab-bootstrap/summaries
printf '%s\n' "$_agents" \
  > /var/lib/homelab-bootstrap/summaries/monitoring.sh
