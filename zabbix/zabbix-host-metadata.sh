#!/usr/bin/env bash
# zabbix-host-metadata.sh — the HostMetadata token list for this host, derived
# from what the bootstrap actually installed, so Zabbix autoregistration
# actions can link the right templates with no GUI step.
#
#   zabbix-host-metadata.sh          # print the tokens
#   zabbix-host-metadata.sh --apply  # write HostMetadata= into the agent
#                                    # config and restart zabbix-agent2
#
# ZABBIX_HOST_METADATA="..." in the environment replaces the whole list.
#
# Tokens (each maps to one autoregistration action on the server; none is a
# substring of another, because the action condition is "contains"):
#   homelab    every bootstrapped host: Linux by Zabbix agent active, PSI
#   pve | pbs  Proxmox VE node | Proxmox Backup Server
#   lxc | vm | metal   what systemd-detect-virt says
#   smart      SMART by Zabbix agent 2 active (nvme-smart.conf or smartd present)
#   zfs        Homelab ZFS pools            (zfs-status.conf)
#   snapraid   Homelab snapraid             (snapraid-status.conf)
#   events     Homelab Proxmox events       (pve-events.conf)
#   nic        Homelab physical NIC flapping (physnic.conf)
#   tbmesh     Homelab TB3 mesh             (tbmesh.conf)
#   kernel     Homelab kernel               (kernel-watch.conf)
#   bootcheck  Homelab boot check           (bootcheck.conf)
#   keeper     Homelab Seafile keeper       (seafile-keeper.conf)
#   docker     rootless docker monitoring   (docker.conf)
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
CONF=/etc/zabbix/zabbix_agent2.conf
D=/etc/zabbix/zabbix_agent2.d

tokens() {
  if [[ -n "${ZABBIX_HOST_METADATA:-}" ]]; then printf '%s\n' "$ZABBIX_HOST_METADATA"; return; fi
  local t="homelab"
  command -v pveversion >/dev/null 2>&1 && t="$t pve"
  command -v proxmox-backup-manager >/dev/null 2>&1 && t="$t pbs"
  # systemd-detect-virt prints "none" AND exits 1 on bare metal: read the
  # output only, never "|| echo none" (that yields "none\nnone").
  local virt; virt="$(systemd-detect-virt 2>/dev/null)"; virt="${virt:-none}"
  case "$virt" in
    lxc|lxc-libvirt) t="$t lxc";;
    none) t="$t metal";;
    *) t="$t vm";;
  esac
  { [[ -f "$D/nvme-smart.conf" ]] || [[ -f /etc/smartd.conf && "$virt" != lxc ]]; } && t="$t smart"
  [[ -f "$D/zfs-status.conf" ]]      && t="$t zfs"
  [[ -f "$D/snapraid-status.conf" ]] && t="$t snapraid"
  [[ -f "$D/pve-events.conf" ]]      && t="$t events"
  [[ -f "$D/physnic.conf" ]]         && t="$t nic"
  [[ -f "$D/tbmesh.conf" ]]          && t="$t tbmesh"
  [[ -f "$D/kernel-watch.conf" ]]    && t="$t kernel"
  [[ -f "$D/bootcheck.conf" ]]       && t="$t bootcheck"
  [[ -f "$D/seafile-keeper.conf" ]]  && t="$t keeper"
  [[ -f "$D/docker.conf" || -f "$D/plugins.d/docker.conf" ]] && t="$t docker"
  printf '%s\n' "$t"
}

T="$(tokens)"
if [[ "${1:-}" != "--apply" ]]; then printf '%s\n' "$T"; exit 0; fi

[[ $EUID -eq 0 ]] || { echo "zabbix-host-metadata: --apply needs root" >&2; exit 2; }
[[ -f "$CONF" ]] || { echo "zabbix-host-metadata: $CONF not found" >&2; exit 2; }
tmp="$(mktemp)"
# Drop any existing HostMetadata / HostMetadataItem line, append ours.
grep -vE '^(HostMetadata|HostMetadataItem)=' "$CONF" > "$tmp"
printf 'HostMetadata=%s\n' "$T" >> "$tmp"
install -m 0644 "$tmp" "$CONF"; rm -f "$tmp"
systemctl restart zabbix-agent2 2>/dev/null || true
echo "HostMetadata=$T ($(systemctl is-active zabbix-agent2 2>/dev/null))"
