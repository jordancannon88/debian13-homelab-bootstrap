#!/usr/bin/env bash
# fleet-check.sh — read-only audit: does this host match the bootstrap standard?
#
# Prints one line per component (OK / MISSING / WARN / n/a) so hosts can be
# compared side by side. Changes nothing. Run as root.
#
#   sudo bash fleet-check.sh            # full table
#   sudo bash fleet-check.sh --summary  # one line: host ok=N total=N missing=a,b,c
#
# "n/a" = not expected on this host type (containers have no AppArmor/auditd,
# non-ZFS hosts have no pool exclusions, ...). Anything MISSING or WARN is drift
# from debian13-homelab-bootstrap main (harden.sh, monitoring.sh, motd.sh).
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
SUMMARY=0; [[ "${1:-}" == "--summary" ]] && SUMMARY=1
[[ $EUID -eq 0 ]] || { echo "fleet-check: run as root" >&2; exit 2; }

HOST="$(hostname)"
VIRT="$(systemd-detect-virt 2>/dev/null)"; VIRT="${VIRT:-none}"   # prints "none" and exits 1 on metal
IS_CT=0; [[ "$VIRT" == "lxc" || "$VIRT" == "lxc-libvirt" ]] && IS_CT=1
IS_PVE=0; command -v pveversion >/dev/null 2>&1 && IS_PVE=1
HAS_ZFS=0; command -v zfs >/dev/null 2>&1 && zfs list -H -d 0 >/dev/null 2>&1 && HAS_ZFS=1

OK=0; TOTAL=0; MISSING=()
row() {  # row <component> <OK|MISSING|WARN|n/a> <detail>
  local c="$1" s="$2" d="${3:-}"
  if [[ "$s" != "n/a" ]]; then TOTAL=$((TOTAL+1)); [[ "$s" == "OK" ]] && OK=$((OK+1)) || MISSING+=("$c"); fi
  (( SUMMARY )) || printf '%-26s %-8s %s\n' "$c" "$s" "$d"
}
active() { systemctl is-active "$1" >/dev/null 2>&1; }
enabled() { systemctl is-enabled "$1" >/dev/null 2>&1; }
pkg() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
age_days() { echo $(( ( $(date +%s) - $(stat -c %Y "$1") ) / 86400 )); }

(( SUMMARY )) || { printf '%-26s %-8s %s\n' "== $HOST" "$VIRT" "pve=$IS_PVE zfs=$HAS_ZFS $(date -Is)"; }

# --- bootstrap run ---------------------------------------------------------
if [[ -f /var/log/homelab-bootstrap/install-latest.log ]]; then
  row "bootstrap log" OK "last run $(stat -c %y /var/log/homelab-bootstrap/install-latest.log | cut -c1-16)"
else
  row "bootstrap log" MISSING "no /var/log/homelab-bootstrap/install-latest.log"
fi

# --- admin user: a non-root sudoer with an SSH key ---------------------------
adm=""
for u in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
  h="$(getent passwd "$u" | cut -d: -f6)"
  [[ -s "$h/.ssh/authorized_keys" ]] && adm="$adm $u"
done
[[ -n "$adm" ]] && row "admin user (sudo+key)" OK "${adm# }" || row "admin user (sudo+key)" MISSING "no sudo user with authorized_keys"

# --- sshd -------------------------------------------------------------------
if command -v sshd >/dev/null 2>&1; then
  T="$(sshd -T 2>/dev/null)"
  port="$(awk '$1=="port"{print $2; exit}' <<<"$T")"
  prl="$(awk '$1=="permitrootlogin"{print $2}' <<<"$T")"
  pa="$(awk '$1=="passwordauthentication"{print $2}' <<<"$T")"
  mat="$(awk '$1=="maxauthtries"{print $2}' <<<"$T")"
  # PVE nodes: port 22 and key-only root are required for inter-node ssh.
  want_prl="no"; (( IS_PVE )) && want_prl="prohibit-password"
  [[ "$prl" == "without-password" ]] && prl="prohibit-password"   # sshd -T prints the legacy alias
  if [[ "$prl" == "$want_prl" && "$pa" == "no" && "$mat" == "3" ]]; then row "sshd lockdown" OK "port=$port root=$prl pass=no tries=3"
  else row "sshd lockdown" MISSING "port=$port root=$prl (want $want_prl) pass=$pa tries=$mat"; fi
else row "sshd lockdown" MISSING "sshd not found"; fi

# --- firewall ---------------------------------------------------------------
if (( IS_PVE )); then row "nftables deny-by-default" n/a "PVE node: firewall step skipped (pve-firewall + upstream segmentation)"
elif active nftables && grep -q 'policy drop' /etc/nftables.conf 2>/dev/null; then row "nftables deny-by-default" OK "active, policy drop"
elif active nftables; then row "nftables deny-by-default" WARN "active but no 'policy drop' in /etc/nftables.conf"
else row "nftables deny-by-default" MISSING "nftables not active"; fi

# --- fail2ban ---------------------------------------------------------------
if active fail2ban && [[ -f /etc/fail2ban/jail.d/ssh.local ]]; then row "fail2ban sshd jail" OK "active, jail.d/ssh.local"
elif active fail2ban; then row "fail2ban sshd jail" WARN "active, no jail.d/ssh.local"
else row "fail2ban sshd jail" MISSING "fail2ban not active"; fi

# --- unattended-upgrades ----------------------------------------------------
if pkg unattended-upgrades && [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] && active apt-daily-upgrade.timer; then row "unattended-upgrades" OK "20auto-upgrades, timer active"
else row "unattended-upgrades" MISSING "pkg=$(pkg unattended-upgrades && echo y || echo n) conf=$([[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] && echo y || echo n) timer=$(systemctl is-active apt-daily-upgrade.timer 2>/dev/null)"; fi

# --- journald ---------------------------------------------------------------
if grep -qs '^Storage=persistent' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null && [[ -d /var/log/journal ]]; then row "journald persistent" OK "/var/log/journal"
else row "journald persistent" MISSING "Storage=persistent not set or /var/log/journal absent"; fi

# --- sysctl, login.defs, banner ---------------------------------------------
[[ -f /etc/sysctl.d/99-hardening.conf ]] && row "sysctl hardening" OK "99-hardening.conf" || row "sysctl hardening" MISSING "no /etc/sysctl.d/99-hardening.conf"
um="$(awk '$1=="UMASK"{print $2}' /etc/login.defs 2>/dev/null)"
want_um="027"; (( IS_PVE )) && want_um="022"   # 027 breaks pct create on PVE (sdds9tw12dv3)
[[ "$um" == "$want_um" ]] && row "login.defs UMASK $want_um" OK "" || row "login.defs UMASK $want_um" MISSING "UMASK=${um:-unset}"
grep -qsi 'authorized' /etc/issue.net && row "login banner" OK "/etc/issue.net" || row "login banner" MISSING "no warning text in /etc/issue.net"

# --- AppArmor, auditd (hosts only) ------------------------------------------
if (( IS_CT )); then row "apparmor" n/a "container: host-managed"; row "auditd" n/a "container: host-managed"
else
  active apparmor && row "apparmor" OK "active" || row "apparmor" MISSING "not active"
  active auditd && row "auditd" OK "active" || row "auditd" MISSING "not active"
fi

# --- AIDE -------------------------------------------------------------------
if ! pkg aide; then row "aide installed" MISSING "package absent"; row "aide baseline" MISSING "no aide"; row "aide excludes" MISSING "no aide"; row "aide daily check" MISSING "no aide"
else
  row "aide installed" OK "$(dpkg-query -W -f='${Version}' aide)"
  if [[ -f /var/lib/aide/aide.db ]]; then
    a="$(age_days /var/lib/aide/aide.db)"; (( a <= 30 )) && row "aide baseline" OK "${a}d old" || row "aide baseline" WARN "${a}d old (>30d)"
  else row "aide baseline" MISSING "no /var/lib/aide/aide.db"; fi
  ex=/etc/aide/aide.conf.d/99_homelab_exclude
  if [[ -f "$ex" ]] && grep -q '^-/mnt' "$ex"; then
    want=""; (( HAS_ZFS )) && for mp in $(zfs list -H -d 0 -o mountpoint 2>/dev/null); do [[ "$mp" == "/" || "$mp" == none || "$mp" == legacy || "$mp" == - ]] && continue; grep -q "^-$mp\$" "$ex" || want="$want $mp"; done
    [[ -z "$want" ]] && row "aide excludes" OK "$(grep -c '^-' "$ex") rules" || row "aide excludes" WARN "pool(s) not excluded:${want}"
  elif [[ -f "$ex" ]]; then row "aide excludes" WARN "drop-in uses '!' not '-' (still walks the tree)"
  else row "aide excludes" MISSING "no $ex"; fi
  r="$(systemctl show -p Result --value dailyaidecheck.service 2>/dev/null)"
  case "$r" in success) row "aide daily check" OK "last result success";; "") row "aide daily check" WARN "never ran";; *) row "aide daily check" WARN "last result $r";; esac
fi

# --- Lynis, rkhunter present ------------------------------------------------
pkg lynis && row "lynis" OK "" || row "lynis" MISSING "package absent"
pkg rkhunter && row "rkhunter" OK "" || row "rkhunter" MISSING "package absent"

# --- Zabbix agent 2 ---------------------------------------------------------
if pkg zabbix-agent2; then
  sa="$(grep -E '^ServerActive=' /etc/zabbix/zabbix_agent2.conf 2>/dev/null | cut -d= -f2)"
  hn="$(grep -E '^Hostname=' /etc/zabbix/zabbix_agent2.conf 2>/dev/null | cut -d= -f2)"
  bad="$(find /etc/zabbix/zabbix_agent2.d -type f ! -perm -o=r 2>/dev/null | wc -l)"
  if active zabbix-agent2 && [[ -n "$sa" && "$bad" == "0" ]]; then row "zabbix-agent2" OK "active, ServerActive=$sa, Hostname=${hn:-$HOST}"
  else row "zabbix-agent2" WARN "active=$(systemctl is-active zabbix-agent2 2>/dev/null) ServerActive=${sa:-unset} unreadable_dropins=$bad"; fi
else row "zabbix-agent2" MISSING "package absent"; fi

# --- Alloy ------------------------------------------------------------------
if pkg alloy; then
  dr="$(grep -o -- '--disable-reporting' /etc/default/alloy 2>/dev/null)"
  loki="$(sed -n 's@.*url *= *"\(https\?://[^"]*\)/loki/api/v1/push".*@\1@p' /etc/alloy/config.alloy 2>/dev/null | head -1)"
  if active alloy && [[ -n "$dr" && -n "$loki" ]]; then row "alloy" OK "active, reporting off, loki=$loki"
  else row "alloy" WARN "active=$(systemctl is-active alloy 2>/dev/null) reporting_off=$([[ -n $dr ]] && echo y || echo n) loki=${loki:-unset}"; fi
else row "alloy" MISSING "package absent"; fi

# --- MOTD -------------------------------------------------------------------
[[ -x /etc/update-motd.d/20-homelab ]] && row "motd generator" OK "/etc/update-motd.d/20-homelab" || row "motd generator" MISSING "no /etc/update-motd.d/20-homelab"

# --- summary ----------------------------------------------------------------
miss="$(IFS=,; echo "${MISSING[*]:-}")"
if (( SUMMARY )); then echo "$HOST ok=$OK total=$TOTAL missing=${miss:-none}"
else printf '%-26s %-8s %s\n' "== result" "$OK/$TOTAL" "${miss:+drift: $miss}"; fi
