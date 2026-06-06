#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — ancillary
#  Installs extra/quality-of-life packages and sets up the fish shell.
#
#  - Installs a selectable set of packages: btop, fish, rsync, qemu-guest-agent,
#    zabbix-agent2. By default (standalone run) it installs them all; init.sh's
#    wizard lets you pick a subset and passes it via ANCILLARY_PKGS.
#  - qemu-guest-agent (if selected) is started only when run inside a QEMU/KVM
#    guest with the guest-agent channel; otherwise it's left inactive.
#  - zabbix-agent2 (if selected) adds Zabbix's official apt repo, installs the
#    agent, and writes a custom config with this host's name and the Zabbix
#    server address (ZABBIX_SERVER_ACTIVE, or asked when run interactively).
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

# All packages this installer knows how to install (slug -> short description).
declare -A PKG_DESC=(
  [btop]="resource monitor (htop-like)"
  [fish]="friendly interactive shell"
  [rsync]="fast file copy / sync"
  [qemu-guest-agent]="QEMU/KVM guest integration (VMs only)"
  [zabbix-agent2]="Zabbix agent 2 monitoring (needs a Zabbix server)"
)
ALL_PKGS=(btop fish rsync qemu-guest-agent zabbix-agent2)

# Zabbix agent 2 specifics (its own repo + custom config; see the step below).
ZBX_VERSION="7.4"
ZBX_CONF="/etc/zabbix/zabbix_agent2.conf"
ZBX_SERVER_ACTIVE="${ZABBIX_SERVER_ACTIVE:-}"

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

# write_zabbix_conf <target> <hostname> <serveractive> <virtualized> — write the
# custom zabbix_agent2.conf, substituting this host's name and the Zabbix server
# address into the two relevant lines. The cpuTemperature UserParameter's key
# prefix is rewritten from pve2 to this host's name; on a VM/container it's
# commented out (no real CPU thermal sensors there). The body is written verbatim
# (single-quoted heredoc, so $/`/awk snippets inside are preserved); awk -v then
# swaps the values safely regardless of characters they contain.
write_zabbix_conf() {
  local target="$1" hn="$2" sa="$3" virt="${4:-0}" tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<'ZBXEOF'
# This is a configuration file for Zabbix agent 2 (Unix)
# To get more information about Zabbix, visit https://www.zabbix.com

############ GENERAL PARAMETERS #################

### Option: PidFile
#       Name of PID file.
#
# Mandatory: no
# Default:
# PidFile=/tmp/zabbix_agent2.pid

PidFile=/run/zabbix/zabbix_agent2.pid

### Option: LogType
#       Specifies where log messages are written to:
#               system  - syslog
#               file    - file specified with LogFile parameter
#               console - standard output
#
# Mandatory: no
# Default:
# LogType=file

### Option: LogFile
#       Log file name for LogType 'file' parameter.
#
# Mandatory: yes, if LogType is set to file, otherwise no
# Default:
# LogFile=/tmp/zabbix_agent2.log

LogFile=/var/log/zabbix/zabbix_agent2.log

### Option: LogFileSize
#       Maximum size of log file in MB.
#       0 - disable automatic log rotation.
#
# Mandatory: no
# Range: 0-1024
# Default:
# LogFileSize=1

LogFileSize=0

### Option: DebugLevel
#       Specifies debug level:
#       0 - basic information about starting and stopping of Zabbix processes
#       1 - critical information
#       2 - error information
#       3 - warnings
#       4 - for debugging (produces lots of information)
#       5 - extended debugging (produces even more information)
#
# Mandatory: no
# Range: 0-5
# Default:
# DebugLevel=3

### Option: SourceIP
#       Source IP address for outgoing connections.
#
# Mandatory: no
# Default:
# SourceIP=

##### Passive checks related

### Option: Server
#       List of comma delimited IP addresses, optionally in CIDR notation, or DNS names of Zabbix servers and Zabbix proxies.
#       Incoming connections will be accepted only from the hosts listed here.
#       If IPv6 support is enabled then '127.0.0.1', '::127.0.0.1', '::ffff:127.0.0.1' are treated equally
#       and '::/0' will allow any IPv4 or IPv6 address.
#       '0.0.0.0/0' can be used to allow any IPv4 address.
#       Example: Server=127.0.0.1,192.168.1.0/24,::1,2001:db8::/32,zabbix.example.com
#
#   If left empty or not set will disable passive checks, and Zabbix agent 2 will not listen on the ListenPort.
#
# Mandatory: no
# Default:
# Server=

Server=127.0.0.1

### Option: ListenPort
#       Agent will listen on this port for connections from the server.
#
# Mandatory: no
# Range: 1024-32767
# Default:
# ListenPort=10050

### Option: ListenIP
#       List of comma delimited IP addresses that the agent should listen on.
#       First IP address is sent to Zabbix server if connecting to it to retrieve list of active checks.
#
# Mandatory: no
# Default:
# ListenIP=0.0.0.0

### Option: StatusPort
#       Agent will listen on this port for HTTP status requests.
#
# Mandatory: no
# Range: 1024-32767
# Default:
# StatusPort=

##### Active checks related

### Option: ServerActive
#       Zabbix server/proxy address or cluster configuration to get active checks from.
#       Server/proxy address is IP address or DNS name and optional port separated by colon.
#       Cluster configuration is one or more server addresses separated by semicolon.
#       Multiple Zabbix servers/clusters and Zabbix proxies can be specified, separated by comma.
#       More than one Zabbix proxy should not be specified from each Zabbix server/cluster.
#       If Zabbix proxy is specified then Zabbix server/cluster for that proxy should not be specified.
#       Multiple comma-delimited addresses can be provided to use several independent Zabbix servers in parallel. Spaces are allowed.
#       If port is not specified, default port is used.
#       IPv6 addresses must be enclosed in square brackets if port for that host is specified.
#       If port is not specified, square brackets for IPv6 addresses are optional.
#       If this parameter is not specified, active checks are disabled.
#       Example for Zabbix proxy:
#               ServerActive=127.0.0.1:10051
#       Example for multiple servers:
#               ServerActive=127.0.0.1:20051,zabbix.domain,[::1]:30051,::1,[12fc::1]
#       Example for high availability:
#               ServerActive=zabbix.cluster.node1;zabbix.cluster.node2:20051;zabbix.cluster.node3
#       Example for high availability with two clusters and one server:
#               ServerActive=zabbix.cluster.node1;zabbix.cluster.node2:20051,zabbix.cluster2.node1;zabbix.cluster2.node2,zabbix.domain
#
# Mandatory: no
# Default:
# ServerActive=

ServerActive=zabbix:10051

### Option: Hostname
#       List of comma delimited unique, case sensitive hostnames.
#       Required for active checks and must match hostnames as configured on the server.
#       Value is acquired from HostnameItem if undefined.
#
# Mandatory: no
# Default:
# Hostname=

Hostname=machine001

### Option: HostnameItem
#       Item used for generating Hostname if it is undefined. Ignored if Hostname is defined.
#       Does not support UserParameters or aliases.
#
# Mandatory: no
# Default:
# HostnameItem=system.hostname

### Option: HostMetadata
#       Optional parameter that defines host metadata.
#       Host metadata is used at host auto-registration process.
#       An agent will issue an error and not start if the value is over limit of 2034 bytes.
#       If not defined, value will be acquired from HostMetadataItem.
#
# Mandatory: no
# Range: 0-2034 bytes
# Default:
# HostMetadata=

### Option: HostMetadataItem
#       Optional parameter that defines an item used for getting host metadata.
#       Host metadata is used at host auto-registration process.
#       During an auto-registration request an agent will log a warning message if
#       the value returned by specified item is over limit of 65535 characters.
#       This option is only used when HostMetadata is not defined.
#
# Mandatory: no
# Default:
# HostMetadataItem=

### Option: HostInterface
#       Optional parameter that defines host interface.
#       Host interface is used at host auto-registration process.
#       An agent will issue an error and not start if the value is over limit of 255 characters.
#       If not defined, value will be acquired from HostInterfaceItem.
#
# Mandatory: no
# Range: 0-255 characters
# Default:
# HostInterface=

### Option: HostInterfaceItem
#       Optional parameter that defines an item used for getting host interface.
#       Host interface is used at host auto-registration process.
#       During an auto-registration request an agent will log a warning message if
#       the value returned by specified item is over limit of 255 characters.
#       This option is only used when HostInterface is not defined.
#
# Mandatory: no
# Default:
# HostInterfaceItem=

### Option: RefreshActiveChecks
#       How often list of active checks is refreshed, in seconds.
#
# Mandatory: no
# Range: 1-86400
# Default:
# RefreshActiveChecks=5

### Option: BufferSend
#       Do not keep data longer than N seconds in buffer.
#
# Mandatory: no
# Range: 1-3600
# Default:
# BufferSend=5

### Option: BufferSize
#       Maximum number of values in a memory buffer. The agent will send
#       all collected data to Zabbix Server or Proxy if the buffer is full.
#       Option is not valid if EnablePersistentBuffer=1
#
# Mandatory: no
# Range: 2-65535
# Default:
# BufferSize=1000

### Option: EnablePersistentBuffer
#       Enable usage of local persistent storage for active items.
#       0 - disabled, in-memory buffer is used (default); 1 - use persistent buffer
# Mandatory: no
# Range: 0-1
# Default:
# EnablePersistentBuffer=0

### Option: PersistentBufferPeriod
#       Zabbix Agent2 will keep data for this time period in case of no
#       connectivity with Zabbix server or proxy. Older data will be lost. Log data will be preserved.
#       Option is valid if EnablePersistentBuffer=1
#
# Mandatory: no
# Range: 1m-365d
# Default:
# PersistentBufferPeriod=1h

### Option: PersistentBufferFile
#       Full filename. Zabbix Agent2 will keep SQLite database in this file.
#       Option is valid if EnablePersistentBuffer=1
#
# Mandatory: no
# Default:
# PersistentBufferFile=

### Option: HeartbeatFrequency
#       Frequency of heartbeat messages in seconds.
#       Used for monitoring availability of active checks.
#       0 - heartbeat messages disabled.
#
# Mandatory: no
# Range: 0-3600
# Default: 60
# HeartbeatFrequency=

############ ADVANCED PARAMETERS #################

### Option: Alias
#       Sets an alias for an item key. It can be used to substitute long and complex item key with a smaller and simpler one.
#       Multiple Alias parameters may be present. Multiple parameters with the same Alias key are not allowed.
#       Different Alias keys may reference the same item key.
#       For example, to retrieve the ID of user 'zabbix':
#       Alias=zabbix.userid:vfs.file.regexp[/etc/passwd,^zabbix:.:([0-9]+),,,,\1]
#       Now shorthand key zabbix.userid may be used to retrieve data.
#       Aliases can be used in HostMetadataItem but not in HostnameItem parameters.
#
# Mandatory: no
# Range:
# Default:

### Option: Timeout
#       Specifies how long to wait (in seconds) for establishing connection and exchanging data with Zabbix proxy or server.
#
# Mandatory: no
# Range: 1-30
# Default:
# Timeout=3

### Option: Include
#       You may include individual files or all files in a directory in the configuration file.
#       Installing Zabbix will create include directory in /usr/local/etc, unless modified during the compile time.
#
# Mandatory: no
# Default:
# Include=

Include=/etc/zabbix/zabbix_agent2.d/*.conf

# Include=/usr/local/etc/zabbix_agent2.userparams.conf
# Include=/usr/local/etc/zabbix_agent2.conf.d/
# Include=/usr/local/etc/zabbix_agent2.conf.d/*.conf

### Option:PluginTimeout
#       Timeout for connections with external plugins.
#
# Mandatory: no
# Range: 1-30
# Default: <Global timeout>
# PluginTimeout=

### Option:PluginSocket
#       Path to unix socket for external plugin communications.
#
# Mandatory: no
# Default:/tmp/agent.plugin.sock
# PluginSocket=

PluginSocket=/run/zabbix/agent.plugin.sock

####### USER-DEFINED MONITORED PARAMETERS #######

### Option: UnsafeUserParameters
#       Allow all characters to be passed in arguments to user-defined parameters.
#       The following characters are not allowed:
#       \ ' " ` * ? [ ] { } ~ $ ! & ; ( ) < > | # @
#       Additionally, newline characters are not allowed.
#       0 - do not allow
#       1 - allow
#
# Mandatory: no
# Range: 0-1
# Default:
# UnsafeUserParameters=0

UnsafeUserParameters=1

### Option: UserParameter
#       User-defined parameter to monitor. There can be several user-defined parameters.
#       Format: UserParameter=<key>,<shell command>
#       See 'zabbix_agentd' directory for examples.
#
# Mandatory: no
# Default:
# UserParameter=

#UserParameter=pve2.cpuTemperature,sensors | grep Tctl | awk -F'[:+°]' '{avg+=$3}END{print avg/NR}'

### New command
UserParameter=pve2.cpuTemperature,inxi -s | head -n 2 | tail -n 1 | awk '{print $6}'

### Option: UserParameterDir
#       Directory to execute UserParameter commands from. Only one entry is allowed.
#       When executing UserParameter commands the agent will change the working directory to the one
#       specified in the UserParameterDir option.
#       This way UserParameter commands can be specified using the relative ./ prefix.
#
# Mandatory: no
# Default:
# UserParameterDir=

### Option: ControlSocket
#       The control socket, used to send runtime commands with '-R' option.
#
# Mandatory: no
# Default:
# ControlSocket=

ControlSocket=/run/zabbix/agent.sock

####### TLS-RELATED PARAMETERS #######

### Option: TLSConnect
#       How the agent should connect to server or proxy. Used for active checks.
#       Only one value can be specified:
#               unencrypted - connect without encryption
#               psk         - connect using TLS and a pre-shared key
#               cert        - connect using TLS and a certificate
#
# Mandatory: yes, if TLS certificate or PSK parameters are defined (even for 'unencrypted' connection)
# Default:
# TLSConnect=unencrypted

### Option: TLSAccept
#       What incoming connections to accept.
#       Multiple values can be specified, separated by comma:
#               unencrypted - accept connections without encryption
#               psk         - accept connections secured with TLS and a pre-shared key
#               cert        - accept connections secured with TLS and a certificate
#
# Mandatory: yes, if TLS certificate or PSK parameters are defined (even for 'unencrypted' connection)
# Default:
# TLSAccept=unencrypted

### Option: TLSCAFile
#       Full pathname of a file containing the top-level CA(s) certificates for
#       peer certificate verification.
#
# Mandatory: no
# Default:
# TLSCAFile=

### Option: TLSCRLFile
#       Full pathname of a file containing revoked certificates.
#
# Mandatory: no
# Default:
# TLSCRLFile=

### Option: TLSServerCertIssuer
#               Allowed server certificate issuer.
#
# Mandatory: no
# Default:
# TLSServerCertIssuer=

### Option: TLSServerCertSubject
#               Allowed server certificate subject.
#
# Mandatory: no
# Default:
# TLSServerCertSubject=

### Option: TLSCertFile
#       Full pathname of a file containing the agent certificate or certificate chain.
#
# Mandatory: no
# Default:
# TLSCertFile=

### Option: TLSKeyFile
#       Full pathname of a file containing the agent private key.
#
# Mandatory: no
# Default:
# TLSKeyFile=

### Option: TLSPSKIdentity
#       Unique, case sensitive string used to identify the pre-shared key.
#
# Mandatory: no
# Default:
# TLSPSKIdentity=

### Option: TLSPSKFile
#       Full pathname of a file containing the pre-shared key.
#
# Mandatory: no
# Default:
# TLSPSKFile=

####### PLUGIN-SPECIFIC PARAMETERS #######

### Option: Plugins
#       A plugin can have one or more plugin specific configuration parameters in format:
#     Plugins.<PluginName>.<Parameter1>=<value1>
#     Plugins.<PluginName>.<Parameter2>=<value2>
#
# Mandatory: no
# Range:
# Default:

### Option: Plugins.Log.MaxLinesPerSecond
#       Maximum number of new lines the agent will send per second to Zabbix Server
#       or Proxy processing 'log' and 'logrt' active checks.
#       The provided value will be overridden by the parameter 'maxlines',
#       provided in 'log' or 'logrt' item keys.
#
# Mandatory: no
# Range: 1-1000
# Default:
# Plugins.Log.MaxLinesPerSecond=20

### Option: AllowKey
#       Allow execution of item keys matching pattern.
#       Multiple keys matching rules may be defined in combination with DenyKey.
#       Key pattern is wildcard expression, which support "*" character to match any number of any characters in certain position. It might be used in both key name and key arguments.
#       Parameters are processed one by one according their appearance order.
#       If no AllowKey or DenyKey rules defined, all keys are allowed.
#
# Mandatory: no

### Option: DenyKey
#       Deny execution of items keys matching pattern.
#       Multiple keys matching rules may be defined in combination with AllowKey.
#       Key pattern is wildcard expression, which support "*" character to match any number of any characters in certain position. It might be used in both key name and key arguments.
#       Parameters are processed one by one according their appearance order.
#       If no AllowKey or DenyKey rules defined, all keys are allowed.
#       Unless another system.run[*] rule is specified DenyKey=system.run[*] is added by default.
#
# Mandatory: no
# Default:
# DenyKey=system.run[*]

### Option: Plugins.SystemRun.LogRemoteCommands
#       Enable logging of executed shell commands as warnings.
#       0 - disabled
#       1 - enabled
#
# Mandatory: no
# Default:
# Plugins.SystemRun.LogRemoteCommands=0

### Option: ForceActiveChecksOnStart
#       Perform active checks immediately after restart for first received configuration.
#       Also available as per plugin configuration, example: Plugins.Uptime.System.ForceActiveChecksOnStart=1
#
# Mandatory: no
# Range: 0-1
# Default:
# ForceActiveChecksOnStart=0

# Include configuration files for plugins
Include=/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf

####### For advanced users - TLS ciphersuite selection criteria #######

### Option: TLSCipherCert13
#       Cipher string for OpenSSL 1.1.1 or newer in TLS 1.3.
#       Override the default ciphersuite selection criteria for certificate-based encryption.
#
# Mandatory: no
# Default:
# TLSCipherCert13=

### Option: TLSCipherCert
#       OpenSSL (TLS 1.2) cipher string.
#       Override the default ciphersuite selection criteria for certificate-based encryption.
#       Example:
#               EECDH+aRSA+AES128:RSA+aRSA+AES128
#
# Mandatory: no
# Default:
# TLSCipherCert=

### Option: TLSCipherPSK13
#       Cipher string for OpenSSL 1.1.1 or newer in TLS 1.3.
#       Override the default ciphersuite selection criteria for PSK-based encryption.
#       Example:
#               TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
#
# Mandatory: no
# Default:
# TLSCipherPSK13=

### Option: TLSCipherPSK
#       OpenSSL (TLS 1.2) cipher string.
#       Override the default ciphersuite selection criteria for PSK-based encryption.
#       Example:
#               kECDHEPSK+AES128:kPSK+AES128
#
# Mandatory: no
# Default:
# TLSCipherPSK=

### Option: TLSCipherAll13
#       Cipher string for OpenSSL 1.1.1 or newer in TLS 1.3.
#       Override the default ciphersuite selection criteria for certificate- and PSK-based encryption.
#       Example:
#               TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
#
# Mandatory: no
# Default:
# TLSCipherAll13=

### Option: TLSCipherAll
#       OpenSSL (TLS 1.2) cipher string.
#       Override the default ciphersuite selection criteria for certificate- and PSK-based encryption.
#       Example:
#               EECDH+aRSA+AES128:RSA+aRSA+AES128:kECDHEPSK+AES128:kPSK+AES128
#
# Mandatory: no
# Default:
# TLSCipherAll=
ZBXEOF
  awk -v hn="$hn" -v sa="$sa" -v virt="$virt" '
    /^Hostname=machine001$/       { print "Hostname=" hn; next }
    /^ServerActive=zabbix:10051$/ { print "ServerActive=" sa; next }
    /^UserParameter=pve2\.cpuTemperature,/ {
      sub(/^UserParameter=pve2\./, "UserParameter=" hn ".")   # key prefix -> hostname
      if (virt == "1") $0 = "#" $0                            # VM/container: no CPU sensors
      print; next
    }
    { print }
  ' "$tmp" > "$target"
  rm -f "$tmp"
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

# qemu-guest-agent and zabbix-agent2 have their own steps below; install the rest here.
APT_PKGS=()
for p in "${SELECTED_PKGS[@]}"; do
  case "$p" in qemu-guest-agent|zabbix-agent2) ;; *) APT_PKGS+=("$p");; esac
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
  dry "write ${ZBX_CONF} with Hostname=${ZBX_HOSTNAME} and ServerActive=${ZBX_SERVER_ACTIVE}"
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
  write_zabbix_conf "$ZBX_CONF" "$ZBX_HOSTNAME" "$ZBX_SERVER_ACTIVE" "$ZBX_VIRT"
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
fi
fi   # end: pkg_selected zabbix-agent2

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
