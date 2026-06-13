#!/usr/bin/env bash
# ==============================================================================
#  Debian 13 Homelab Bootstrap — documentation
#  Generates the "Connecting to the Server" HTML doc (docs/connect.html) that
#  documents a server and how to SSH into it on its hardened port. The page is
#  an HTML fragment matching the other files in docs/ (subtitle + BookStack
#  "callout info / success / warning" callouts, a TOC, a server details table
#  and a cross-linking footer).
#
#  Everything is parameterised: run it on the box itself to auto-detect the
#  details, or pass overrides via the environment for any other host.
#
#  Run as your normal user, e.g.  ./documentation.sh
#
#  Environment overrides (each is prompted/auto-detected if unset):
#    CONN_FQDN=<name>     -> DNS name           (default: hostname -f)
#    CONN_IP=<addr>       -> LAN address        (default: primary route src IP)
#    CONN_PORT=<port>     -> SSH port           (default: Port from sshd_config, else 22)
#    CONN_USER=<user>     -> login user         (default: SUDO_USER / logname)
#    CONN_ALIAS=<alias>   -> ssh / fish alias   (default: short hostname)
#    CONN_KEY=<name>      -> IdentityFile base  (default: id_ed25519)
#    CONN_OS=<string>     -> OS description     (default: PRETTY_NAME)
#    CONN_ROOT=<string>   -> root access note   (default: detected from sshd_config + root pw lock)
#    OUT_FILE=<path>      -> output file        (default: <script dir>/docs/connect.html)
#    DRY_RUN=1|0          -> force preview / actual (else asks)
#    ASSUME_YES=1         -> accept all defaults, no prompts (automation)
# ==============================================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

START_TS="$(date +%s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ASSUME_YES="${ASSUME_YES:-0}"
if [[ -n "${DRY_RUN+x}" ]]; then DRY_RUN_EXPLICIT=1; else DRY_RUN_EXPLICIT=0; fi
DRY_RUN="${DRY_RUN:-}"

OUT_FILE="${OUT_FILE:-${SCRIPT_DIR}/docs/connect.html}"

# ==============================================================================
#  Output helpers (shared house style with the other bootstrap scripts)
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
header() { printf '\n'; hr '═'; printf '%s%s %s%s\n' "$BOLD$CYN" "$S_STEP" "$*" "$RESET"; hr '═'; }
log()  { printf '%s%s%s %s\n' "$GRN" "$S_OK"   "$RESET" "$*"; }
info() { printf '%s%s%s %s\n' "$BLU" "$S_INFO" "$RESET" "$*"; }
warn() { printf '%s%s %s%s\n' "$YEL" "$S_WARN" "$*" "$RESET"; }
err()  { printf '%s%s %s%s\n' "$RED" "$S_ERR" "$*" "$RESET" >&2; }
note() { printf '   %s%s%s\n' "$DIM" "$*" "$RESET"; }
dry()  { printf '   %s[dry-run]%s %s\n' "$MAG" "$RESET" "$*"; }

INTERACTIVE=0
if [[ "$ASSUME_YES" != "1" && -r /dev/tty ]]; then INTERACTIVE=1; fi

# ask "Question" "default" -> echoes the answer (reads /dev/tty); honours automation.
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ "$ASSUME_YES" == "1" || ! -r /dev/tty ]]; then printf '%s' "$default"; return; fi
  printf '%s%s %s%s%s ' "$YEL" "$S_INFO" "$prompt" "${default:+ [default: $default]}" "$RESET" > /dev/tty
  read -r reply < /dev/tty || reply=""
  reply="${reply:-$default}"
  reply="${reply#"${reply%%[![:space:]]*}"}"; reply="${reply%"${reply##*[![:space:]]}"}"
  printf '%s' "$reply"
}

choose_run_mode() {
  if [[ "$DRY_RUN_EXPLICIT" == "1" ]]; then [[ "$DRY_RUN" == "1" ]] && DRY_RUN=1 || DRY_RUN=0; return; fi
  if [[ "$INTERACTIVE" -eq 0 ]]; then [[ "$ASSUME_YES" == "1" ]] && DRY_RUN=0 || DRY_RUN=1; return; fi
  local choice=""
  printf '\n%s%sHow do you want to run the doc generator?%s\n' "$BOLD" "$WHT" "$RESET" > /dev/tty
  printf '   %s[1]%s %sDry run%s — preview the HTML, write NOTHING (recommended first)\n' "$BOLD" "$RESET" "$GRN" "$RESET" > /dev/tty
  printf '   %s[2]%s %sActual run%s — write the file\n' "$BOLD" "$RESET" "$RED" "$RESET" > /dev/tty
  printf '%s%s Choose 1 or 2 [default: 1]: %s' "$YEL" "$S_WARN" "$RESET" > /dev/tty
  read -r choice < /dev/tty || choice=""
  case "${choice:-1}" in 2) DRY_RUN=0 ;; *) DRY_RUN=1 ;; esac
}

# HTML-escape a value destined for element text / table cells.
esc() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  printf '%s' "$s"
}

# ==============================================================================
#  Splash
# ==============================================================================
[[ "${BOOTSTRAP_NESTED:-0}" == "1" ]] || clear 2>/dev/null || true
printf '%s%s  Debian 13 Homelab Bootstrap — connection documentation%s\n' "$BOLD" "$CYN" "$RESET"
hr '─'
choose_run_mode
[[ "$DRY_RUN" == "1" ]] && info "Mode: ${MAG}DRY RUN${RESET}" || info "Mode: ${RED}ACTUAL RUN${RESET}"

# ==============================================================================
#  Gather server details (auto-detect, then let the user confirm/override)
# ==============================================================================
header "Server details"

det_fqdn="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo localhost)"
det_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[[ -z "$det_ip" ]] && det_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "$det_ip" ]] && det_ip="n/a"
det_port="$(awk 'tolower($1)=="port"{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
[[ -z "$det_port" ]] && det_port="22"
det_user="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER:-user}")}"
det_alias="${det_fqdn%%.*}"
det_os="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}" )"

# Root access pattern: harden.sh disables root SSH (PermitRootLogin no) and can
# optionally LOCK the root password (su-by-password). Detect both: root SSH from
# sshd_config (world-readable), the password lock via `passwd -S root` (only
# readable as root — otherwise assume su-by-password still works, harden's default).
det_root_ssh="$(awk 'tolower($1)=="permitrootlogin"{print tolower($2); exit}' /etc/ssh/sshd_config 2>/dev/null)"
case "$det_root_ssh" in
  yes|prohibit-password|without-password|forced-commands-only) det_root_ssh="enabled" ;;
  *) det_root_ssh="disabled" ;;
esac
det_root_pw="enabled"
if _rs="$(passwd -S root 2>/dev/null)" && [[ " $_rs " == *" L "* ]]; then det_root_pw="disabled (root locked)"; fi
det_root="SSH login ${det_root_ssh}; password su ${det_root_pw}"

FQDN="${CONN_FQDN:-$(ask "DNS hostname" "$det_fqdn")}"
IP="${CONN_IP:-$(ask "LAN address" "$det_ip")}"
PORT="${CONN_PORT:-$(ask "SSH port" "$det_port")}"
USER_NAME="${CONN_USER:-$(ask "Login user" "$det_user")}"
ALIAS="${CONN_ALIAS:-$(ask "ssh / fish alias" "${det_alias:-server}")}"
KEY="${CONN_KEY:-$(ask "IdentityFile name (~/.ssh/<name>)" "id_ed25519")}"
OS_DESC="${CONN_OS:-$(ask "OS description" "$det_os")}"
ROOT_ACCESS="${CONN_ROOT:-$(ask "Root access pattern" "$det_root")}"

note "Host:   ${FQDN}  (${IP})  port ${PORT}"
note "Login:  ${USER_NAME}   alias: ${ALIAS}   key: ~/.ssh/${KEY}"
note "System: ${OS_DESC}"
note "Root:   ${ROOT_ACCESS}"

# Pre-escape everything that lands in the HTML.
e_fqdn="$(esc "$FQDN")"; e_ip="$(esc "$IP")"; e_port="$(esc "$PORT")"
e_user="$(esc "$USER_NAME")"; e_alias="$(esc "$ALIAS")"; e_key="$(esc "$KEY")"
e_os="$(esc "$OS_DESC")"; e_root="$(esc "$ROOT_ACCESS")"

# ==============================================================================
#  Render the HTML fragment
# ==============================================================================
header "Generate $(basename "$OUT_FILE")"

# Build into a variable first so we can either preview it or write it.
# Unquoted heredoc => ${...} expand; literal shell '$' in samples is escaped \$.
HTML="$(cat <<EOF
<h1>🔌 Connecting to the Server</h1>
<p class="subtitle">How to reach the <code>${e_alias}</code> Docker host and open an SSH session on the hardened port — Debian 13 Homelab Bootstrap.</p>

<div class="callout info">
  <strong>SSH is not on port 22.</strong> <code>harden.sh</code> moves the daemon to a non-standard
  port and the nftables firewall is <em>deny-by-default</em>, so only the configured SSH port is reachable.
  On this host that port is <code>${e_port}</code> — every example below sets it explicitly.
</div>

<nav class="toc">
  <strong>Contents</strong>
  <ol>
    <li><a href="#server">The ${e_alias} server</a></li>
    <li><a href="#ssh">SSH on port ${e_port}</a></li>
    <li><a href="#fish-alias">A fish alias for the connection</a></li>
    <li><a href="#config">SSH client config</a></li>
    <li><a href="#trouble">Troubleshooting</a></li>
  </ol>
</nav>

<h2 id="server">🖥️ The ${e_alias} server</h2>
<p>This is the primary Docker host for the homelab — it runs the <code>/opt/docker</code> compose stacks.</p>
<table>
  <tr><th>Hostname</th><td><code>${e_fqdn}</code></td></tr>
  <tr><th>LAN address</th><td><code>${e_ip}</code></td></tr>
  <tr><th>SSH port</th><td><code>${e_port}</code></td></tr>
  <tr><th>OS</th><td>${e_os}</td></tr>
  <tr><th>User</th><td>${e_user}</td></tr>
  <tr><th>Root access</th><td>${e_root}</td></tr>
  <tr><th>SSH Key</th><td>${e_key}</td></tr>
</table>
<div class="callout success">
  <strong>Name vs. address.</strong> Prefer the hostname <code>${e_fqdn}</code> so the box can
  change IP without breaking your config. If internal DNS isn't resolving it yet, fall back to
  <code>${e_ip}</code> or add a line to your local <code>/etc/hosts</code>.
</div>

<h2 id="ssh">🔑 SSH on port ${e_port}</h2>
<p>Connect by hostname:</p>
<pre><code class="language-bash">ssh -p ${e_port} ${e_user}@${e_fqdn}</code></pre>
<p>Or straight to the LAN address:</p>
<pre><code class="language-bash">ssh -p ${e_port} ${e_user}@${e_ip}</code></pre>
<div class="callout warning">
  <strong>Plain <code>ssh ${e_fqdn}</code> will time out</strong> — it defaults to port 22, which the
  firewall drops. Always pass <code>-p ${e_port}</code>, or set the port in your SSH config (below) so you can omit it.
</div>

<h2 id="fish-alias">🐟 A fish alias for the connection</h2>
<p>On a <code>fish</code> shell you can save a <code>${e_alias}</code> alias so the whole SSH command collapses to one word. Define it with <code>--save</code> to persist it across sessions:</p>
<pre><code class="language-bash">alias --save ${e_alias} "ssh -p ${e_port} ${e_user}@${e_fqdn}"</code></pre>
<p>Or against the LAN address:</p>
<pre><code class="language-bash">alias --save ${e_alias} "ssh -p ${e_port} ${e_user}@${e_ip}"</code></pre>
<p>Then just run:</p>
<pre><code class="language-bash">${e_alias}</code></pre>
<div class="callout success">
  <strong>Want passthrough args?</strong> Write it as a function instead so you can append flags like a tunnel —
  e.g. <code>${e_alias} -L 3000:localhost:3000</code>:
</div>
<pre><code class="language-bash">function ${e_alias} --description "SSH to the ${e_alias} Docker host on port ${e_port}"
    ssh -p ${e_port} ${e_user}@${e_fqdn} \$argv
end
funcsave ${e_alias}</code></pre>
<div class="callout info">
  <strong>Shell-specific.</strong> <code>alias --save</code> and <code>funcsave</code> are <code>fish</code> features —
  in bash/zsh use <code>~/.ssh/config</code> (the <a href="#config">SSH client config</a> section below) instead, which every SSH tool inherits.
</div>

<h2 id="config">⚙️ SSH client config</h2>
<p>Add a host entry to <code>~/.ssh/config</code> on your <em>local</em> machine so the port and user are remembered:</p>
<pre><code class="language-text">Host ${e_alias}
    HostName ${e_fqdn}
    #HostName ${e_ip}
    Port ${e_port}
    User ${e_user}
    IdentityFile ~/.ssh/${e_key}</code></pre>
<p>Then the connection collapses to a short alias:</p>
<pre><code class="language-bash">ssh ${e_alias}</code></pre>
<div class="callout success">
  <strong>One alias, everywhere.</strong> Once <code>Host ${e_alias}</code> exists, <code>scp</code>, <code>rsync</code>,
  <code>sftp</code>, and tools that read your SSH config all inherit the port and user — no <code>-p ${e_port}</code> needed.
</div>

<h2 id="trouble">🔧 Troubleshooting</h2>
<p>Connection times out or is refused — verify the host is up and the port is reachable:</p>
<pre><code class="language-bash">ping ${e_fqdn}
nc -vz ${e_fqdn} ${e_port}</code></pre>
<p>See verbose handshake detail to diagnose key or config problems:</p>
<pre><code class="language-bash">ssh -vvv -p ${e_port} ${e_user}@${e_fqdn}</code></pre>
<p>Host key changed (e.g. after a rebuild)? Remove the stale entry, then reconnect to accept the new one:</p>
<pre><code class="language-bash">ssh-keygen -R "[${e_fqdn}]:${e_port}"
ssh-keygen -R "[${e_ip}]:${e_port}"</code></pre>
<div class="callout warning">
  <strong>Timeout almost always means the firewall or the wrong port.</strong> A <em>connection refused</em> means
  you reached the host but nothing is listening on that port — check you used <code>${e_port}</code> and that
  <code>sshd</code> is running on the server.
</div>

<footer>
  Debian 13 Homelab Bootstrap — see <a href="docker-cheatsheet.html">Docker Cheat Sheet</a>,
  <a href="add-container.html">Adding a Docker Service</a>, and
  <a href="container-format-and-examples.html">Container Format &amp; Examples</a> for what to do once you're connected.
</footer>
EOF
)"

if [[ "$DRY_RUN" == "1" ]]; then
  dry "write ${BOLD}${OUT_FILE}${RESET} ($(printf '%s\n' "$HTML" | wc -l) lines):"
  printf '%s\n' "$HTML" | sed 's/^/        │ /'
  record "Output (preview)" "$OUT_FILE"
else
  mkdir -p "$(dirname "$OUT_FILE")"
  printf '%s\n' "$HTML" > "$OUT_FILE"
  log "Wrote ${BOLD}${OUT_FILE}${RESET} ($(wc -l < "$OUT_FILE") lines)."
  record "Output" "$OUT_FILE"
fi
record "Host" "${FQDN} (${IP})"
record "SSH" "port ${PORT}, user ${USER_NAME}, alias ${ALIAS}"

# ==============================================================================
#  Recap
# ==============================================================================
ELAPSED=$(( $(date +%s) - START_TS )); MM=$(( ELAPSED / 60 )); SS=$(( ELAPSED % 60 ))
printf '\n'; hr '═'
if [[ "$DRY_RUN" == "1" ]]; then
  printf '%s%s  🧪  DRY RUN COMPLETE — NO FILE WRITTEN — RECAP%s\n' "$BOLD" "$MAG" "$RESET"
else
  printf '%s%s  ✅  CONNECTION DOC GENERATED — RECAP%s\n' "$BOLD" "$GRN" "$RESET"
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
  printf '   %s•%s  Re-run and choose %sActual%s (or %sDRY_RUN=0 ./%s%s) to write the file.\n' \
    "$BOLD" "$RESET" "$BOLD" "$RESET" "$DIM" "$(basename "$0")" "$RESET"
else
  printf '   %s•%s  Preview it in a browser, or publish %s%s%s to your docs wiki.\n' \
    "$BOLD" "$RESET" "$DIM" "$OUT_FILE" "$RESET"
  printf '   %s•%s  Regenerate for another host with the %sCONN_*%s env overrides (see header).\n' \
    "$BOLD" "$RESET" "$DIM" "$RESET"
fi
printf '%s%s  Done. 🖥️%s\n\n' "$BOLD" "$GRN" "$RESET"

# One-line summary for init.sh's bootstrap report (actual runs only).
if [[ "$DRY_RUN" != "1" ]]; then
  mkdir -p /var/lib/homelab-bootstrap/summaries 2>/dev/null \
    && printf 'connection doc generated (%s) for %s on port %s\n' "$OUT_FILE" "$FQDN" "$PORT" \
       > /var/lib/homelab-bootstrap/summaries/documentation.sh 2>/dev/null || true
fi
