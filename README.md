# debian13-homelab-bootstrap

Opinionated bootstrap scripts for a fresh Debian 13 (Trixie) homelab host.

`init.sh` is the entry point. It checks for root, then asks whether to run each
script, using a local copy if present or downloading it from GitHub if not. It
asks every question up front (which extra packages, which monitoring agents,
whether to install Docker), runs the chosen scripts unattended, and ends with
one consolidated report: a review of what ran plus a single next-steps list.

**Contents**

- [What's in the box](#whats-in-the-box)
- [Packages installed](#packages-installed)
- [Quick start](#quick-start)
- [VM, LXC or PVE host, and the setup menu](#vm-lxc-or-pve-host-and-the-setup-menu)
- [Container runtimes and the /opt/docker layout](#container-runtimes-and-the-optdocker-layout)
- [Environment overrides](#environment-overrides)
- [Troubleshooting](#troubleshooting)
- [Requirements](#requirements)

## What's in the box

| Script | What it does |
| --- | --- |
| `init.sh` | Orchestrator. Root check, then runs the scripts below (local copy or download) one at a time, with a single consolidated review and next-steps report at the end. |
| `bootstrap.sh` | Runs first. Creates the admin user (or updates an existing one), adds it to `sudo`, and installs its SSH public key into `~/.ssh/authorized_keys`. Optional password for newly created accounts (blank means SSH-key only). `harden.sh` relies on this account and key existing, since hardening disables password login. |
| `fleet-check.sh` | Read-only audit: one line per component (sshd lockdown, nftables, fail2ban, unattended-upgrades, journald, sysctl, UMASK, banner, AppArmor, auditd, AIDE package/baseline/excludes/daily check, Lynis, rkhunter, Zabbix agent 2, Alloy, MOTD) with OK / MISSING / WARN / n/a, and a `--summary` line for Zabbix. Run it on every host to see drift from this repo; changes nothing. |
| `zabbix/fleet-check-run.sh`, `zabbix/fleet-check-json.sh` | Installed by monitoring.sh (`setup_fleet_check`): a daily root timer runs `fleet-check.sh --summary` into `/var/lib/fleet-check/`, and the agent item `custom.fleet.check` reads it as JSON for the `Homelab fleet check` template (Warning naming the missing components). |
| `harden.sh` | System hardening. Verifies the admin users from `bootstrap.sh` (key + sudo), then SSH lockdown, nftables firewall (deny by default), fail2ban, unattended-upgrades, persistent journald, sysctl and kernel hardening, AppArmor, AIDE, auditd, extra fixes that clear common Lynis findings, and a Lynis audit at the end. Detects VM vs LXC and skips host-managed steps (AppArmor, auditd) inside containers. |
| `ancillary.sh` | Pick-and-install extras. Choose any of `vim`, `btop`, `duf`, `rsync`, `qemu-guest-agent`. It also owns the shell section: installs extra shells (`fish`, `zsh`, `tcsh`) and can set the default login shell (keep/bash/sh/fish/zsh/tcsh) — via the wizard it applies to the admin user and root; standalone it targets `SHELL_USERS`, the users `bootstrap.sh` created, or users you pick — the shell binary is smoke-tested before any `chsh`. |
| `monitoring.sh` | Pick-and-install monitoring agents from their vendor repos. `zabbix-agent2` adds Zabbix's official repo, installs the agent, and writes a config with this host's name and the Zabbix server address you provide, then installs the host side of the disk-health templates (SMART via sudo, NVMe spare, ZFS pool and vdev counters, smartd self-tests) and, on bare metal, the NIC link-flap helpers. When a rootless Docker daemon is detected, it offers to set the agent up to monitor it (socket path, lingering, running the agent as that user). `alloy` adds Grafana's official repo and installs Grafana Alloy, a journal-first log shipper pointed at the Loki URL you provide, with an optional prompt to also capture Docker container logs via Docker's `journald` log driver, which works for both rootful and rootless Docker. `alerts` only generates the buzz report key now: every buzz watch moved to Zabbix (disk health, replication, backups, HA events on 2026-09-15/16; the Thunderbolt mesh heal on 2026-09-16, it installs with the Zabbix helpers on mesh nodes). You pick the alert types first, then the delivery — a buzz relay dev box (forced-command ssh; a dedicated key is generated and alerting starts once you register its public half there) and/or an ntfy topic (HTTP push; works immediately in the ntfy app, messages carry the raw alert text). Both deliveries can be enabled at once. |
| `container.sh` | Container runtimes. Installs Docker and/or Podman (you're asked for each) for a chosen user, rootless. Docker brings Engine, Compose, and rootless Docker; Podman is daemonless and rootless with `podman-compose`, set up to coexist with Docker (the `podman-docker` shim that would hijack the `docker` command is never installed). Both share the rootless plumbing (uidmap, subuid/subgid, userns AppArmor). Creates the `/opt/docker` layout (always) with an optional example app, and optionally sets the `journald` log driver so container logs flow to the journal and on to Loki via Alloy, tagging Docker lines with the Compose project and service for grouping by stack. |
| `motd.sh` | Dynamic login banner (MOTD) showing live host, IP, uptime, OS/kernel, load, memory, disk and sessions, plus a link to your homelab documentation. |
| `documentation.sh` | Generates the connection doc (`docs/connect.html` by default): server details plus how to SSH in on the hardened port, with a `fish` alias and `~/.ssh/config` recipe. Auto-detects host, IP, port and user, or takes `CONN_*` overrides. Offered by `init.sh` as the optional final step, reusing the SSH port and user you configured. When run via `init.sh` the doc is always written to `/var/lib/homelab-bootstrap/connect.html`. |

Every setup script is idempotent, prompts before changes, backs up files it
edits, and prints a recap at the end. `documentation.sh` follows the same
conventions but writes a doc rather than changing the system, so it needs no
root and backs nothing up.

> Run on a fresh host, VM, or LXC container. `harden.sh` changes SSH and the
> firewall. Keep your current session open and test a new SSH login before
> disconnecting.

## Packages installed

Every third-party package these scripts pull in is listed below, grouped by the
script that installs it. Most come from Debian's own repositories; the ones from
an added third-party repo are flagged in the Source column. Nothing here is
installed without you selecting it. `harden.sh`'s core tools install when you
run hardening; everything in `ancillary.sh`, `monitoring.sh` and `container.sh`
is opt-in.

### harden.sh core security tools

Installed when you run hardening (skipped individually if already present).

| Package | Source | What it is |
| --- | :---: | --- |
| `openssh-server` | Debian | OpenSSH server daemon for remote login. |
| `sudo` | Debian | Run commands as root or another user. |
| `gnupg` | Debian | GnuPG, key handling and signature verification (apt repo keys). |
| `lsb-release` | Debian | Reports the distro and release version for other tooling. |
| `ca-certificates` | Debian | Trusted root CA certificates for TLS. |
| `nftables` | Debian | Linux kernel firewall, the deny-by-default backend. |
| `fail2ban` | Debian | Bans IPs after repeated failed logins (watches sshd). |
| `aide` | Debian | Advanced Intrusion Detection Environment, file-integrity database. |
| `apparmor` | Debian | Mandatory Access Control framework confining programs. |
| `apparmor-utils` | Debian | Tools to manage and audit AppArmor profiles. |
| `unattended-upgrades` | Debian | Applies security updates automatically. |
| `apt-listchanges` | Debian | Shows package changelogs at upgrade time. |
| `rsyslog` | Debian | System logging daemon. |
| `rsyslog-gnutls` | Debian | TLS transport for rsyslog (encrypted remote logging). |
| `logwatch` | Debian | Summarizes system logs into readable reports. |
| `lynis` | Debian | Security auditing and hardening scanner (run at the end). |
| `needrestart` | Debian | Flags services that need a restart after library upgrades. |
| `libpam-google-authenticator` | Debian | Optional. TOTP one-time-password PAM module, only installed when SSH 2FA is enabled. |

### ancillary.sh opt-in extras

Only the packages you tick in the picker are installed.

| Package | Source | What it is |
| --- | :---: | --- |
| `vim` | Debian | Vim text editor. |
| `btop` | Debian | Resource monitor (htop-like). |
| `duf` | Debian | Disk usage/free utility (a friendlier `df`). |
| `fish` | Debian | Friendly interactive shell (also settable as default shell). |
| `rsync` | Debian | Fast file copy and sync. |
| `qemu-guest-agent` | Debian | QEMU/KVM guest integration (VMs only). |

### monitoring.sh opt-in monitoring agents

Each agent is installed from its vendor's official apt repo. Only the ones you
tick in the picker are installed.

| Package | Source | What it is |
| --- | :---: | --- |
| `zabbix-release` | Zabbix repo | `.deb` that registers Zabbix's official apt repository. |
| `zabbix-agent2` | Zabbix repo | Zabbix monitoring agent 2. |
| `inxi` | Debian | System-information CLI; backs the CPU-temperature monitoring item. Installed alongside `zabbix-agent2`. |
| `gnupg` | Debian | Ensured present to import the Grafana repo key (usually already installed by `harden.sh`). |
| `alloy` | Grafana repo | Grafana Alloy, a journal-first log shipper to Loki. |
| `smartmontools` | Debian | `smartctl` for the agent's SMART plugin and the buzz disk-health watch; `smartd` for scheduled self-tests. Installed alongside `zabbix-agent2` (unless `ZABBIX_DISK_HEALTH=0`) and with the `buzz` disk alert. |

> If you opt into Docker container logs, Alloy captures them via the journal (no
> extra package, no Docker socket access): point Docker at the `journald` log
> driver and the lines flow in like any other journal entry, tagged with
> `container` and `image` labels. This works for both rootful and rootless
> Docker. You don't have to set the driver by hand: if Docker is already
> installed, `monitoring.sh` detects it and offers to set the `journald` driver
> itself (rootful and/or rootless) when you enable Docker-log capture, and
> `container.sh` sets it on fresh installs (its `DOCKER_JOURNALD_LOGS` step,
> auto-enabled when you opt into Alloy Docker logs via `init.sh`; for Podman it
> sets the user's `containers.conf` `log_driver`). To do it manually instead,
> put `{"log-driver":"journald"}` in `/etc/docker/daemon.json` (rootful) or
> `~/.config/docker/daemon.json` (rootless), restart Docker, and recreate your
> containers. Query them with `{host="<host>", container=~".+"}`, or group by
> Compose stack/service with `{compose_project="media"}` /
> `{compose_service="nginx"}`. `container.sh` attaches those labels by default
> (`DOCKER_LOG_LABELS`) and Alloy promotes them. The daemon's own logs already
> arrive via `docker.service`.

#### Disk health and NIC watch (host side of the homelab Zabbix templates)

A Zabbix template is only half of an agent item: the host still needs the
matching `UserParameter=` and whatever the command needs to run. When
`zabbix-agent2` is selected, `monitoring.sh` puts that half in place so a new
host gets the same disk and link coverage as the rest of the fleet as soon as
the templates are linked on the server:

| On the host | Feeds | Notes |
| --- | --- | --- |
| `smartmontools` + `/etc/sudoers.d/zabbix-smart` | `SMART by Zabbix agent 2 active` (stock template, plus the Homelab attribute items and triggers in [`zabbix/templates/smart-by-zabbix-agent2-active-homelab.yaml`](zabbix/templates/smart-by-zabbix-agent2-active-homelab.yaml)) | The stock template has **no** trigger on reallocated, pending or uncorrectable sectors; the Homelab additions add them, plus 24-hour "rising" tripwires. Import with *Update existing* on and every *Delete missing* off. |
| `/usr/local/bin/nvme-smart-json.sh` + `zabbix_agent2.d/nvme-smart.conf` | the NVMe *available spare* items in the same template | The stock SMART plugin does not expose available spare; this reads `smartctl -j -A` through the sudoers rule. Harmless on hosts without NVMe. |
| `/usr/local/bin/zfs-status-json.py` + `zabbix_agent2.d/zfs-status.conf` (only when `zpool` exists) | [`Homelab ZFS pools`](zabbix/templates/homelab-zfs-pools.yaml) | Pool health, capacity, permanent errors, scrub age and result, and **per-vdev** read/write/checksum/slow-IO counters, the numbers a pool summary hides. Needs OpenZFS 2.3+ (`zpool status -j`); runs as the zabbix user with no root. Rerun `monitoring.sh` after adding ZFS to an existing host. |
| smartd `-s` schedule in `/etc/smartd.conf` | the stock *self-test is not passed* trigger | That trigger also fires when no test was ever logged, so every disk needs a schedule. Default short daily / long weekly; `SMARTD_SCHEDULE` overrides. On a VM the smartmontools unit gets a drop-in clearing `ConditionVirtualization=` (Debian's unit otherwise never starts there). |
| `/usr/local/bin/snapraid-runner.sh` + `snapraid-runner.timer`, `/usr/local/bin/snapraid-status-json.sh` + `zabbix_agent2.d/snapraid-status.conf` (only where `/etc/snapraid.conf` exists) | [`Homelab snapraid`](zabbix/templates/homelab-snapraid.yaml) | Array errors, unsynced changes, scrub age, and the result of the daily runner (which refuses to sync after a mass deletion so a wiped disk cannot be "synced" into the parity). The agent may run only `snapraid status` and `snapraid diff -q`. |
| `/usr/local/bin/pve-replication-json.sh`, `pve-backup-json.py`, `pve-ha-events-json.sh` + `zabbix_agent2.d/pve-events.conf` + `/etc/sudoers.d/zabbix-pve` (where `pvesr` exists) | [`Homelab Proxmox events`](zabbix/templates/homelab-proxmox-events.yaml) | Every replication job as a discovery row: consecutive failures (High), more than 2 h past its own next sync (Warning); every failed vzdump task as a sticky High naming the guest and status; every HA recover from a fenced node as a sticky High and every migrate/relocate as a sticky Information; script failures (High). Replaces the buzz replication, backup and HA watches. Test markers `/etc/zabbix/homelab-test/replication` (synthetic failing job `TEST-0`) and `/etc/zabbix/homelab-test/backup` (one synthetic failed task) exist for dry runs; a real `vzdump 999999` also produces a genuine failed task. |
| `/usr/local/bin/physnic-discovery.sh`, `nic-carrier-down.sh`, `nic-pcie-detach.sh` + `zabbix_agent2.d/physnic.conf` (bare metal only) | [`Homelab physical NIC flapping`](zabbix/templates/homelab-physical-nic-flapping.yaml) | LLD of real, non-wireless NICs and the kernel's per-interface `carrier_down_count`. A bouncing cable on a corosync NIC self-fences a Proxmox node within a minute; this catches it as a High. NICs listed as `wan` in `/etc/zabbix/homelab-nic-roles` (one `<ifname> <role>` per line) get a softer "WAN-side NIC flapping (ISP router side)" Warning instead, since a bounce there is the ISP router's port. `custom.nic.pcie_detach` counts `PCIe link lost, device now detached` kernel lines this boot (the I225-V failure that fenced a node in 2026-09); the zabbix user is added to `systemd-journal` for it. Template: [`zabbix/templates/homelab-physical-nic-flapping.yaml`](zabbix/templates/homelab-physical-nic-flapping.yaml). |
| `/usr/local/sbin/tb-mesh-heal.sh` (root cron every minute) + `/usr/local/bin/tb-mesh-status-json.py` + `zabbix_agent2.d/tbmesh.conf` (mesh nodes only: the `pve-enXX-disconnect-bug-fix.sh` reset scripts exist) | [`Homelab TB3 mesh`](zabbix/templates/homelab-tb3-mesh.yaml) | The Thunderbolt mesh watchdog repairs the mesh itself (controller resets, PCI rescans, coordinated both-ends resets, cluster-serialised whole-mesh recovery, opt-in evacuate-and-reboot) and appends every action to `/var/lib/tb-mesh-heal/events.log`. The collector reads that and the heal's state files as the zabbix user (dir 0755, no sudoers) into `custom.tbmesh.status`. Triggers: edge stuck (High, needs a simultaneous cold cycle of both ends), controller off the PCI bus (High, reboot needed), whole mesh down (High), auto recovery gave up (High), heal not running (Warning, new: the cron itself), reset 3 or more times in 1 h (Warning), heal acted (Information, clears after 10 min), script error (High). Replaces the buzz tbmesh watch. Dry run: `/etc/zabbix/homelab-test/tbmesh` (one keyword per line: `linkstuck <if>`, `nobus <if>`, `meshdown <seconds>`, `paging`, `stale`) and a synthetic `events.log` line. |
| `/usr/local/bin/bootcheck-status-json.py` + `zabbix_agent2.d/bootcheck.conf` (only where `pve-outage-boot-check.service` exists) | [`Homelab boot check`](zabbix/templates/homelab-boot-check.yaml) | The post-outage runbook (`pve-outage-runbook.sh`, run once per boot by that service; shipped through the homelab's get-installer channel, not this repo) writes `/var/lib/pve-outage-runbook/latest.json`. The collector reads it as the zabbix user (the runbook writes with umask 022 and keeps its dir 0755) and adds `current_boot`, `age`, `uptime`, the failing-check list and two single-item trigger texts. Triggers: came back with N checks needing eyes (High, recovers on the next GREEN run), recovered clean (Information, one hour), boot check did not run this boot (Warning), JSON missing (High), test marker (Warning). Per-check discovery rows keep state and detail for history. Replaces the direct node-to-buzz boot check post. Dry run: a synthetic `latest.json` and the marker `/etc/zabbix/homelab-test/bootcheck` (`stale`). |
| `/usr/local/bin/kernel-hung-tasks.sh` + `zabbix_agent2.d/kernel-watch.conf` (every host with its own kernel; not containers) | [`Homelab kernel`](zabbix/templates/homelab-kernel.yaml) | Counts kernel `task ... blocked for more than N seconds` lines this boot from the kernel journal (zabbix user in `systemd-journal`). A hung task is a device that stopped answering (disk, USB bridge, NFS server); High on any increase, manual close. Added after a stalled SSD on pve1 froze the firewall VM for 40 minutes on 2026-09-17. Dry run: `echo "INFO: task txg_sync:1 blocked for more than 120 seconds." \| sudo tee /dev/kmsg`. |
| none on Debian hosts. `zabbix/opnsense/isp-gw-ping.sh` goes on the OPNsense firewall (`/usr/local/bin`, plus `extend ispgw` in `/usr/local/etc/snmp/snmpd.conf`); the rest are simple checks run by the Zabbix server | [`Homelab internet` and `Homelab DNS`](zabbix/templates/homelab-internet.yaml) | Internet reachability with the cause told apart: ISP router unreachable (root High, fping to opn1's default gateway), WAN link down on opn1 (SNMP ifOperStatus, index resolved from the interface name), no internet reachability (ICMP to Quad9 and TCP 443 to ghcr.io), router unreachable from the firewall itself (snmpd extend), latency; internal DNS through opn1 Unbound (High) and external DNS straight from Quad9 (Warning) on the Zabbix server host. Triggers depend on each other so one outage is one problem; two event correlation rules (built in the GUI) close the WAN-side NIC flap Warnings while the router is down and the external DNS Warning while the internet is down. Not installed by `monitoring.sh`. |

Every drop-in is written `0644` and every helper `0755` on purpose: `harden.sh`
sets `UMASK 027`, and an unreadable include stops `zabbix-agent2` from starting
at all. Turn the whole block off with `ZABBIX_DISK_HEALTH=0`; the NIC helpers
follow `ZABBIX_NIC_FLAP`, the mesh heal `ZABBIX_TBMESH`, the boot check collector `ZABBIX_BOOTCHECK`.

<br>

<br>

### container.sh Docker and/or Podman (rootless)

Docker packages (installed when you choose Docker):

| Package | Source | What it is |
| --- | :---: | --- |
| `docker-ce` | Docker repo | Docker Engine (the daemon). |
| `docker-ce-cli` | Docker repo | Docker command-line client. |
| `containerd.io` | Docker repo | containerd container runtime. |
| `docker-buildx-plugin` | Docker repo | Buildx build plugin. |
| `docker-compose-plugin` | Docker repo | Compose v2 plugin (`docker compose`). |
| `docker-ce-rootless-extras` | Docker repo | Rootless-mode support files. |

Podman packages (installed when you choose Podman):

| Package | Source | What it is |
| --- | :---: | --- |
| `podman` | Debian | Daemonless container engine (pulls in crun/conmon/netavark/passt). |
| `podman-compose` | Debian | Compose front-end (`podman compose` / `podman-compose`). |

Shared rootless prerequisites (installed when rootless Docker or Podman is selected):

| Package | Source | What it is |
| --- | :---: | --- |
| `uidmap` | Debian | `newuidmap`/`newgidmap`, user-namespace ID mapping for rootless. |
| `dbus-user-session` | Debian | Per-user D-Bus session, required for rootless systemd. |
| `slirp4netns` | Debian | User-mode networking for rootless containers. |

> When installing Docker, `container.sh` first removes any conflicting legacy
> packages it finds (`docker.io`, `docker-doc`, `docker-compose`,
> `podman-docker`, `containerd`, `runc`). Note `podman-docker` is intentionally
> never installed: it drops a `docker` shim that would shadow the real Docker
> CLI, so keeping it out is what lets Docker and Podman coexist.

### Third-party apt repositories added

| Repo | URL | Added by | Signing key |
| --- | --- | :---: | --- |
| Docker | `https://download.docker.com/linux/debian` | `container.sh` (Docker only) | `/etc/apt/keyrings/docker.asc` |
| Zabbix | `https://repo.zabbix.com` | `monitoring.sh` (via `zabbix-release`) | shipped in the `zabbix-release` package |
| Grafana | `https://apt.grafana.com` | `monitoring.sh` | `/etc/apt/keyrings/grafana.gpg` |

## Quick start

### Option 1: run init.sh

Recommended. Downloads the other scripts for you, nothing to clone. Run as root.

```bash
# One-liner
curl -fsSL https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main/init.sh | bash
```

Prefer to review before running (safer than piping to a shell):

```bash
curl -fsSL https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main/init.sh -o init.sh
less init.sh        # review it first
bash init.sh
```

For each script, `init.sh` will:

1. ask whether to run it (`Set up the admin user + SSH key (bootstrap)?`,
   `Harden the system?`, `Install extra packages?`, `Install monitoring
   agents?`, `Install Docker…?`), and for the Extra packages and Monitoring
   groups, let you pick which ones to install;
2. gather every answer up front, then use the local file if present, otherwise
   download it from GitHub;
3. run each chosen script unattended (no mid-run prompts), waiting for it to
   finish before the next;
4. finish with one consolidated report: a review of what ran and a single,
   merged next-steps list.

> `curl` is not installed by `init.sh`; it's assumed present (the one-liner
> above already uses it, and Debian ships it on all but the most minimal
> installs). The download fallback needs it too.

### Option 2: git clone and run locally

Skips downloading. Since the scripts sit next to `init.sh`, it uses the local
copies and never hits the network for them.

```bash
git clone https://github.com/jordancannon88/debian13-homelab-bootstrap.git
cd debian13-homelab-bootstrap
sudo ./init.sh
```

Or run the steps yourself, in order:

```bash
sudo ./bootstrap.sh   # 1. create/update the admin user + install the SSH key
sudo ./harden.sh      # 2. harden the system (relies on the user/key from step 1)
sudo ./ancillary.sh   # 3. extra packages (vim, btop, duf, fish, rsync, qemu-guest-agent) + fish shell
sudo ./monitoring.sh  # 4. monitoring agents (zabbix-agent2, alloy)
sudo ./container.sh   # 5. install Docker and/or Podman (rootless) + Compose
sudo ./motd.sh        # 6. install the dynamic login banner (MOTD)
./documentation.sh    # 7. generate docs/connect.html (no sudo needed)
```

## VM, LXC or PVE host, and the setup menu

When you run `init.sh`, the first question is what this host is: a VM, an LXC
container, or a Proxmox VE host (the hypervisor itself). Right after that, a
read-only system check inventories what the host already has — a hardened
firewall (and its current SSH port), ufw/firewalld conflicts, Docker/Podman
and running containers, an installed Zabbix agent or Alloy (with their
configured servers), buzz watches and their relay, an existing MOTD banner.
Its findings screen shows warnings up front, defaults are pre-filled from the
detected values (a re-run proposes the host's current settings, never a fresh
random SSH port), and installed services are marked `(installed)` in the
menus. It autodetects and
pre-selects the likely answer — `pveversion` on the system means PVE host. That
choice sets the defaults for everything that follows. For example the QEMU
guest agent defaults to yes on a VM and no elsewhere, where it has no use. Most
questions are the same everywhere; the environment switch just picks better
starting points.

The PVE-host defaults exist because a hypervisor breaks differently than a
guest: the root password lock is off (the web UI's `root@pam` login needs a
working root password), the SSH port defaults to 22 (inter-node ssh for
migration, replication and cluster joins assumes it — change it only
fleet-wide), the usb-storage blacklist is off (passthrough and installer
media), and the buzz repl/ha watches default on since their tooling lives
there. Everything stays editable in the menu.

Firewall ports are self-service: any step that installs a network listener
opens its own port in the hardened ruleset — harden.sh force-allows 8006 and
3128 on a PVE host, monitoring.sh opens 10050 for Zabbix passive checks, and
container.sh opens the example app's port. The `tcpports`/`udpports` fields in
the harden dialog are only for your own services and future container stacks.

`init.sh` then opens a whiptail menu (TUI): a single hub that lists every step
with its current state, pre-filled from those defaults. You don't answer a wall
of questions up front. Pick a step to open its options, or just choose Accept to
install with the defaults.

```text
        Setup  —  [VM]
  ┌────────────────────────────────────────────────────┐
  │  user         [ ⚠ ]  admin user + SSH key           │
  │  harden       [ ✔ ]  security hardening             │
  │  packages     [ ✔ ]  extra packages                 │
  │  shell        [ ✔ ]  login shell                    │
  │  monitoring   [ ✔ ]  monitoring & alerts            │
  │  container    [ ✗ ]  Docker / Podman                │
  │  banner       [ ✔ ]  login banner (MOTD)            │
  │  docs         [ ✔ ]  connection guide               │
  │               ────────────────────────────          │
  │  help         [ ? ]  what does each step do?        │
  │               ────────────────────────────          │
  │  ACCEPT       ✓  Accept these settings and install  │
  └────────────────────────────────────────────────────┘
        <Open>                              <Quit>
```

Each line is one step with a three-state icon: ✔ on and ready, ✗ off,
⚠ on but still needing configuration. The whole wizard follows one pattern at
every depth — hub, sub-hub, input screen — so every menu looks and behaves the
same. Opening a step shows the same kind of menu again, with each setting on
its own line showing its current value:

```text
        Setup › user (admin user + SSH key)
  ┌────────────────────────────────────────────────────┐
  │  enabled     [ ✔ ]  run this step                   │
  │  user        [ ⚠ ]  admin username: (not set)       │
  │  sshkey      [ ⚠ ]  SSH public key: (not set)       │
  │  password    [ ✗ ]  password: SSH-key only          │
  └────────────────────────────────────────────────────┘
        <Open>                              <Back>
```

While a step's `enabled` toggle is off, its option lines are hidden — only
`enabled` and `help` remain — so nothing inside a disabled step can be
changed until it is switched back on.

Toggle lines (`enabled`, yes/no settings) flip in place when you select them;
value lines open an input screen; list lines open a checklist. Breadcrumb
titles (`Setup › monitoring › buzz › relay address`) always show where you
are, and Cancel/Back never loses anything. Every menu also carries a
`[ ? ] help` line that opens a plain-language explanation of each setting on
that screen.

- Monitoring is a hub of services (zabbix, alloy, buzz), each opening its own
  sub-hub with exactly that service's settings — the Zabbix server address, the
  Loki URL, or for buzz the alert types and the relay address as one
  `user@host:port` field.
- The harden sub-hub has a `components` checklist — SSH lockdown, firewall,
  fail2ban, automatic updates, persistent journald, AppArmor, AIDE, sysctl,
  the extra Lynis fixes, and the closing audit, each toggleable (all on by
  default) — an `options` checklist (apt full-upgrade, root password lock,
  usb-storage blacklist, SSH TOTP 2FA, compiler restriction, 80/443), and
  value lines for the SSH port, extra TCP/UDP ports, and SSH source CIDRs.
  Deselecting the SSH component also lifts the SSH-key requirement, since
  password login stays enabled without it.
- Accept validates required inputs, then the chosen scripts run
  non-interactively. A missing required value (the SSH key, say) pops a message
  so you can fix it before install.
- Every run writes a full install log to
  `/var/log/homelab-bootstrap/install-<timestamp>.log` (symlinked as
  `install-latest.log`): the system-check findings, every chosen option, the
  exact configuration each script received, each script's complete output, and
  per-script results. Passwords and tokens are redacted. When something fails
  or crashes, start there.
- Defaults worth noting: `container.sh` is off by default (Docker or Podman in
  an LXC is advanced, and on a VM you opt in); the login banner is on for all
  host types; the SSH port is a random high port (22 on PVE, and a re-run keeps
  the current port); the root password lock is on for guests; the Zabbix server
  defaults to `zabbix:10051` and Loki to `loki:3100`. The admin username and
  the SSH public key are the two fields with no default — the hub marks
  bootstrap with ⚠ until you enter them.
- Per-environment tuning: the usb-storage blacklist defaults on only in a VM
  (in an LXC the kernel modules are host-owned, so the blacklist would be a
  no-op; PVE hosts need USB for passthrough and install media); the disk alert
  defaults on only where SMART data actually exists (PVE hosts and bare metal
  — virtio disks and containers have none); the QEMU guest agent is on only in
  VMs; the Proxmox repl/ha/backup alerts are on only on PVE hosts.

> `init.sh` is TUI-only. It requires an interactive terminal and whiptail
> (auto-installed if missing); there is no text-mode or unattended path. Run it
> on the console or over SSH, not piped or detached. The individual scripts can
> still be run directly and accept env overrides, see below.

> There is no dry-run mode. When you accept, the scripts make real changes. They
> are idempotent and back up files they edit, but review the screen first.

## Container runtimes and the /opt/docker layout

`container.sh` installs Docker and/or Podman (you choose for each) for a chosen
user. Docker brings the Engine, the Compose plugin and, by default, rootless
Docker; Podman is daemonless and rootless, with `podman-compose`. When you pick
both they coexist: the real `docker` CLI and `podman` live side by side (the
`podman-docker` shim is never installed), and they share the rootless plumbing
(uidmap, subuid/subgid, the userns AppArmor profiles). Either way it creates a
predictable home for your stacks under `/opt/docker`, one folder per app, usable
by `docker compose` or `podman compose` (same compose files).

### Directory hierarchy

```text
/opt/docker/
├── example-app/                # one folder per app/stack
│   ├── docker-compose.yml       #   the stack definition
│   ├── .env                     #   secrets / config  (chmod 600, keep out of git)
│   └── data/                    #   persistent bind-mount volume
│
└── shared/
    └── networks/                # reusable, externally-defined networks
        └── README.md            #   how to create & reference shared networks
```

### Conventions

- One directory per app under `/opt/docker/<app>/`.
- Each app has its own `docker-compose.yml`, `.env`, and `data/` directory.
- Persistent data lives in the app's `data/` folder (a relative bind mount), so
  a whole app is self-contained and easy to back up or move.
- `shared/networks/` is for networks you want multiple apps to join. Create one
  (`docker network create proxy`) and mark it `external: true` in each app.

### Ownership and permissions

| Mode | Owner | Notes |
| --- | --- | --- |
| Rootless (default; any rootless Docker or Podman) | `<container-user>:<container-user>` | the user runs the runtime and owns the files |
| Rootful (Docker root daemon only) | `root:docker` | when you keep the system daemon |

`.env` files are `600` (sensitive), `docker-compose.yml` is `644`.

### The example app

A minimal `traefik/whoami` service is dropped in at `/opt/docker/example-app/`
(published on host port 8080 by default). Start it:

```bash
cd /opt/docker/example-app
docker compose up -d        # or: podman compose up -d
# then browse http://<host>:8080
```

### Good to know (rootless)

- Your shell gets `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` so `docker`
  talks to the rootless daemon.
- Published ports bind on the host but are blocked by the deny-by-default
  firewall. Rootless port forwards are a userspace listener subject to the
  nftables input filter, unlike rootful, which bypasses it. Open each container
  port in `harden.sh`, e.g. `ALLOW_TCP_PORTS="8080 8096"` (or temporarily, note
  `insert` since the chain ends in an explicit `drop`:
  `sudo nft insert rule inet filter input tcp dport 8080 ct state new accept`).
- Rootless containers run without the `docker-default` AppArmor profile
  (loading a profile needs root); isolation relies on user namespaces plus
  seccomp.
- The daemon waits for DNS at boot. Lingering starts the user's `docker.service`
  seconds into boot, before the network is up, and user units can't order on the
  system's `network-online.target`. Containers brought up by restart policies
  would snapshot a not-yet-ready `resolv.conf` and keep broken DNS until
  manually recreated. A drop-in
  (`~/.config/systemd/user/docker.service.d/wait-online.conf`) makes `dockerd`
  poll until the host resolves names (fail-open after about 2 minutes) before
  starting.
- On Debian 13, `harden.sh` keeps AppArmor on; `container.sh` grants only the
  rootless binaries in play (`rootlesskit` for Docker and/or `podman`) the
  `userns` permission so rootless still works (`USERNS_METHOD`).

### Podman alongside Docker

- Pick Podman (with or without Docker) and it's set up rootless for the same
  user. It's daemonless, so there's no system service; containers run under the
  user's session (lingering is enabled so they survive logout).
- A Docker-API-compatible socket is enabled at
  `unix:///run/user/<uid>/podman/podman.sock`, so docker-API tools (the Zabbix
  Docker plugin, `lazydocker`) can talk to Podman too. If you install Podman
  only, your shell's `DOCKER_HOST` is pointed at that socket; if Docker is also
  installed, `DOCKER_HOST` stays on the Docker socket and you target Podman
  explicitly via `podman` / `podman compose`.
- `podman-docker` (which would alias `docker` to `podman`) is deliberately not
  installed, so the two CLIs never collide.
- With the journald log driver chosen, Podman's
  `~/.config/containers/containers.conf` gets `log_driver = "journald"` so its
  container logs ship to Loki via Alloy too.

To add a new app: make `/opt/docker/<app>/`, drop a `docker-compose.yml`
(plus optional `.env` and `data/`) in it, then `docker compose up -d` from that
folder.

## Unattended mode

`init.sh` is a whiptail wizard by default. For automation (cloud-init, `pct exec`, Ansible, a one-liner over ssh) run it with `UNATTENDED=1` (or `--unattended`): no menu, no terminal needed, every answer comes from the environment. The VM/LXC/PVE defaults apply first, then the variables below override them, then the same checks the wizard runs (a missing admin key, a Zabbix agent without a server address) stop the run with exit 2 and the list of what is missing, before anything is installed.

| Variable | Meaning |
|---|---|
| `ENV_TYPE=vm\|lxc\|pve` | Host type; autodetected when unset |
| `STEPS="bootstrap harden ancillary shell monitoring motd docs"` | Which steps run (add `container` for the container step). Unset = the wizard's defaults |
| `PRIMARY_USER`, `PUBKEY`, `ADMIN_PASSWORD` | The admin account (bootstrap.sh). A new account needs a password; harden.sh needs the key |
| `SSH_PORT`, `ALLOW_TCP_PORTS`, `ALLOW_UDP_PORTS`, `ALLOW_SSH_CIDRS` | harden.sh network settings |
| `SKIP_UPGRADE`, `DISABLE_ROOT_LOGIN`, `BLACKLIST_USB_STORAGE`, `ENABLE_SSH_2FA`, `HARDEN_COMPILERS`, `ALLOW_HTTP`, `ALLOW_HTTPS` | harden.sh options, `1`/`0` |
| `HARDEN_UNATTENDED`, `HARDEN_JOURNALD`, `HARDEN_SSH`, `HARDEN_FIREWALL`, `HARDEN_FAIL2BAN`, `HARDEN_APPARMOR`, `HARDEN_AIDE`, `HARDEN_SYSCTL`, `HARDEN_EXTRA`, `HARDEN_LYNIS` | harden.sh components, `1`/`0` |
| `AIDE_EXCLUDES="/mnt /media /export /var/lib/vz"` | Paths AIDE never indexes (bulk-data mounts such as NFS datastores and docked disks, and PVE guest disk images under `/var/lib/vz`); on ZFS hosts every pool mountpoint other than `/` is added automatically (container subvols, replica pools) |
| `ANCILLARY_PKGS="vim btop duf rsync qemu-guest-agent"` | Extra packages |
| `SHELL_PKGS="fish zsh tcsh"`, `DEFAULT_SHELL=fish\|zsh\|tcsh\|keep` | Shells |
| `MONITORING_PKGS="zabbix-agent2 alloy alerts"`, `ZABBIX_SERVER_ACTIVE`, `ZABBIX_HOST_METADATA`, `ZABBIX_MONITOR_ROOTLESS_DOCKER`, `LOKI_URL`, `ALLOY_DOCKER_LOGS`, `BUZZ_ALERTS`, `ALERTS_SINKS`, `BUZZ_TARGET`, `BUZZ_PORT`, `NTFY_URL`, `NTFY_TOKEN` | monitoring.sh |
| `INSTALL_DOCKER`, `INSTALL_PODMAN`, `DISABLE_ROOTFUL`, `CREATE_EXAMPLE_APP`, `DOCKER_JOURNALD_LOGS` | container.sh |
| `DOC_URL` | motd.sh |

Example, a Zabbix-monitored LXC with no Alloy and no alerts:

```bash
curl -fsSLo /root/init.sh https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main/init.sh
UNATTENDED=1 PRIMARY_USER=jordan PUBKEY="$(cat /root/jordan.pub)" ADMIN_PASSWORD='...' MONITORING_PKGS=zabbix-agent2 ZABBIX_SERVER_ACTIVE=zabbix:10051 bash /root/init.sh
```

The per-script environment overrides in the next section keep working underneath; unattended mode only replaces the menu that used to set them.

## Extras

`extras/` holds small single-purpose units that run on a host built by this bootstrap but are not part of the bootstrap itself:

| Dir | What |
|---|---|
| `extras/seafile-keeper/` | Keeps an encrypted Seafile library's password warm on the server every 50 minutes, so background uploads from the mobile app keep working (Seafile forgets the password after one hour; the app does not re-send it). Script, oneshot service, timer, Zabbix helper (`custom.seafile.keeper_age`, template [`Homelab Seafile keeper`](zabbix/templates/homelab-seafile-keeper.yaml)) and an `install.sh`. Secrets go in `/etc/seafile-keeper/env` (0600) by hand. Built for the `seafile-keeper` CT (Kan n1d54ezp98n7). |

## Environment overrides

<details open>
<summary><code>init.sh</code></summary>

| Variable | Effect |
| --- | --- |
| `REPO_RAW_BASE=<url>` | Base raw URL to download scripts from (a fork or branch) |
| `ENV_TYPE=vm\|lxc\|pve` | Preselect the environment choice in the menu (else autodetected) |

> `init.sh` is TUI-only and has no `ASSUME_YES`/unattended mode; it always opens the menu.

</details>

<details open>
<summary><code>bootstrap.sh</code></summary>

| Variable | Effect |
| --- | --- |
| `ADMIN_USERS="admin"` | Admin users to create/update (sudo + SSH key); skips the prompt |
| `PUBKEY=` / `PUBKEY_<user>=` | SSH public key(s); `PUBKEY` is the primary (first) user |
| `ADMIN_PASSWORD=` / `PASSWORD_<user>=` | Password for a newly created account (existing accounts are never changed; blank = SSH-key only) |
| `CREATE_<user>=1\|0` | Auto-answer the "create missing user?" prompt |

</details>

<details open>
<summary><code>harden.sh</code></summary>

| Variable | Effect |
| --- | --- |
| `ADMIN_USERS="admin"` | Existing admin users the hardening relies on (lockout checks, root locking); skips the prompt. Create them with `bootstrap.sh` first |
| `SSH_PORT=22` | SSH port |
| `ALLOW_SSH_CIDRS="1.2.3.4/32"` | Restrict SSH to source ranges |
| `ALLOW_HTTP=1` · `ALLOW_HTTPS=1` | Open 80 / 443 |
| `ALLOW_TCP_PORTS="8080 8096"` | Open extra TCP ports (needed for rootless container ports) |
| `ALLOW_UDP_PORTS="51820"` | Open extra UDP ports |
| `ENABLE_SSH_2FA=1` | Require TOTP 2FA |
| `SKIP_UPGRADE=1` | Skip the full `apt` upgrade |
| `DOCKER_COMPAT=1` | Docker-compatible firewall + sysctl |
| `DISABLE_ROOT_LOGIN=1` | Lock the root account password |
| `BLACKLIST_USB_STORAGE=1` | Also blacklist the `usb-storage` module (disables USB drives) |
| `HARDEN_COMPILERS=0` | Do not restrict compilers to root (default: restricted) |
| `BACKUP_DNS="1.1.1.1 9.9.9.9"` | Fallback DNS servers |
| `REMOTE_SYSLOG="host:port"` | Forward logs to a remote syslog host (opt-in) |
| `GRUB_PASSWORD="…"` | Set a GRUB password; normal boot stays password-free (opt-in) |
| `HARDEN_SSH=0` · `HARDEN_FIREWALL=0` · `HARDEN_FAIL2BAN=0` · `HARDEN_UNATTENDED=0` · `HARDEN_JOURNALD=0` · `HARDEN_APPARMOR=0` · `HARDEN_AIDE=0` · `HARDEN_SYSCTL=0` · `HARDEN_EXTRA=0` · `HARDEN_LYNIS=0` | Per-component toggles; each defaults to 1 (run). Set 0 to skip that component entirely — its step, packages-side effects and recap entry are all skipped |
| `AIDE_EXCLUDES="/mnt /media /export /var/lib/vz"` | Paths AIDE never indexes, written to `/etc/aide/aide.conf.d/99_homelab_exclude` as non-recursive `-<path>` rules (AIDE 0.19+; the classic `!` form still walks the tree). Default covers the usual bulk-data mount points; indexing an NFS datastore there once cost a host 16 h of CPU |
| `USB_STORAGE_QUIRKS="174c:55aa:u,174c:1153:u"` | Bridges pinned to the usb-storage driver (never uas) via `/etc/modprobe.d/usb-storage-quirks.conf`. Default: both ASMedia ids in the fleet; uas aborts and resets on them corrupt reads (pms0 XFS 2026-09-16, ZFS checksum errors on pve2 2026-09-18). Empty to skip |
| `PVE_FIREWALL=1` | On a Proxmox VE node harden.sh skips the nftables step by default (a deny-by-default ruleset without corosync, migration and mesh rules fences a cluster node) and also keeps `PermitRootLogin prohibit-password` (inter-node root ssh with keys), `UMASK 022` (027 breaks `pct create`), `ip_forward=1` and loose `rp_filter=2` (mesh routing). Set 1 to run the firewall step anyway, with your own peer rules in `ALLOW_*` |
| `ACCEPT_LOCKOUT_RISK=1` | Non-interactive runs (including `ASSUME_YES=1`) refuse to disable SSH password auth when no admin user has an SSH key, because that is a lockout. This flag is the explicit opt-in to proceed anyway; interactively you are asked (default No) |

</details>

<details open>
<summary><code>ancillary.sh</code></summary>

| Variable | Effect |
| --- | --- |
| `ANCILLARY_PKGS="vim btop duf rsync"` | Install exactly these packages (any of `vim btop duf rsync qemu-guest-agent`; `fish` here is a legacy alias for the shell options), or `none` for nothing; unset installs the full default set |
| `SHELL_PKGS="fish zsh tcsh"` | Extra shells to install (any subset; unset = none) |
| `DEFAULT_SHELL=keep\|bash\|sh\|fish\|zsh\|tcsh` | Login shell to set for the target users (default `keep`); the shell is verified before any `chsh` |
| `SHELL_USERS="u1 u2"` | Set the shell for exactly these users (skips prompts; `none` = change nobody). `FISH_USERS` is accepted as a legacy alias |

</details>

<details open>
<summary><code>monitoring.sh</code></summary>

| Variable | Effect |
| --- | --- |
| `MONITORING_PKGS="zabbix-agent2 alloy"` | Install exactly these agents (any of `zabbix-agent2 alloy alerts`; `buzz` is accepted as a legacy alias for `alerts`), or `none` for nothing; unset installs the full default set |
| `ZABBIX_SERVER_ACTIVE="host[:port]"` | Zabbix server/proxy for active checks. Required when `zabbix-agent2` is selected (asked interactively if unset). Written into `ServerActive=` in `/etc/zabbix/zabbix_agent2.conf` |
| `ZABBIX_HOST_METADATA="homelab pve ..."` | Replace the `HostMetadata` token list the agent announces for Zabbix autoregistration. Default: derived from what the run installed (`zabbix-host-metadata.sh`: `homelab`, then `pve`/`pbs`, `lxc`/`vm`/`metal`, and one token per installed helper: `smart zfs snapraid events nic tbmesh kernel bootcheck keeper docker lxcstat fleetcheck`). One autoregistration action per token on the server links that token's template, so a new host gets its templates with no GUI step. Re-apply on an existing host with `zabbix-host-metadata.sh --apply` |
| `ZABBIX_MONITOR_ROOTLESS_DOCKER=1\|0` | Set the agent up to monitor a rootless Docker daemon. Empty = ask when a rootless daemon is detected (default no). Writes a Docker-plugin drop-in pointing `Plugins.Docker.Endpoint` at the user's `/run/user/<uid>/docker.sock`, enables lingering, and adds a systemd override running `zabbix-agent2` as that user so it can reach the socket. The override also sets `RuntimeDirectory`/`LogsDirectory` so `/run/zabbix` and `/var/log/zabbix` are re-owned by that user at every start (reboot-proof), and the logrotate `create` rule is repointed at that user so rotated logs stay writable |
| `ZABBIX_DOCKER_USER=<user>` | The rootless Docker owner to monitor (default: auto-detected from the running daemon; falls back to `$SUDO_USER`) |
| `ZABBIX_DISK_HEALTH=1\|0` | Install the host side of the disk-health templates (default on): `smartmontools`, `/etc/sudoers.d/zabbix-smart` so the agent's SMART plugin can run `smartctl`, the `custom.nvme.smart[*]` UserParameter (NVMe available spare, which the stock plugin does not expose), the `custom.zfs.status` UserParameter when `zpool` exists (pool and per-vdev health from `zpool status -j`, no root needed), and a smartd self-test schedule. Inside a VM it also clears `ConditionVirtualization=` on the smartmontools unit, since passed-through disks are real. Defaults to off inside a container (LXC), where the disks belong to the host |
| `SMARTD_SCHEDULE="(S/../.././02\|L/../../7/03)"` | smartd `-s` self-test schedule written into `/etc/smartd.conf`. Default: short test daily 02:00, long test Sunday 03:00. Use `(S/../.././02\|L/../01/./03)` (long test monthly) for very large disks, where a long test runs a day or more |
| `ZABBIX_SNAPRAID=1\|0` | Install the snapraid watch (`custom.snapraid.status` from `snapraid status` and `snapraid diff -q`, via a sudoers rule limited to those two) and the daily `snapraid-runner.timer` (04:00: diff, refuse to sync after a mass deletion, sync, scrub 8 % of blocks older than 10 days; result reported to Zabbix). Default on when `/etc/snapraid.conf` exists |
| `ZABBIX_PVE_EVENTS=1\|0` | Install the host side of the `Homelab Proxmox events` template: `custom.pve.replication` (`pve-replication-json.sh`, every pvesr job as a discovery row) `custom.pve.backup` (`pve-backup-json.py`, finished vzdump tasks, failures as a sticky High) and `custom.pve.ha` (`pve-ha-events-json.sh`, HA recover/migrate/relocate events from the pve-ha-crm journal), through sudoers lines limited to `pvesr status` and the node's own `pvesh get /nodes/<host>/tasks` (the HA collector needs only the journal group). Default on when `pvesr` exists |
| `ZABBIX_NIC_FLAP=1\|0` | Install the physical-NIC link-flap UserParameters (`custom.physnic.discovery`, `custom.nic.carrier_down[*]`, from the kernel's `carrier_down_count`). Default on for bare metal, off for VMs and containers, whose virtual NICs never carry a cable |
| `ZABBIX_TBMESH=1\|0` | Install the Thunderbolt mesh auto-heal (`tb-mesh-heal.sh`, root cron every minute, `/var/lib/tb-mesh-heal` state) and its collector `tb-mesh-status-json.py` (`custom.tbmesh.status`) for the `Homelab TB3 mesh` template. Default on when `/usr/local/bin/pve-en02-disconnect-bug-fix.sh` exists (mesh nodes), else off |
| `ZABBIX_BOOTCHECK=1\|0` | Install the collector `bootcheck-status-json.py` (`custom.bootcheck.status`, reads the post-outage runbook's `latest.json`) for the `Homelab boot check` template. Default on when `/etc/systemd/system/pve-outage-boot-check.service` exists, else off. The runbook and its boot service are not part of this repo |
| `LOKI_URL="scheme://host:port"` | Loki base URL for Alloy to push to. Used when `alloy` is selected (asked interactively; defaults to `http://localhost:3100`). The `/loki/api/v1/push` path is appended automatically |
| `ALLOY_DOCKER_LOGS=1` | Also capture Docker container logs. Used when `alloy` is selected (asked interactively; defaults to off). Keeps the journald relabel rules that promote `container`/`image`/`compose_project`/`compose_service` labels; relies on Docker using the `journald` log driver (rootful or rootless). Container logs then ship via the journal under `{host="<host>", container=~".+"}` |
| `ALLOY_SET_DOCKER_DRIVER=1\|0` | When `ALLOY_DOCKER_LOGS=1` and Docker is already installed here, set Docker's `journald` log driver from `monitoring.sh` itself (rootful via `/etc/docker/daemon.json`, rootless via the user's `~/.config/docker/daemon.json`), so an existing Docker host needs no separate `container.sh` run. Empty = ask; default yes |
| `DOCKER_LOG_LABELS=<csv>` | Container labels the journald driver attaches for grouping in Loki (default `com.docker.compose.project,com.docker.compose.service`, promoted to `compose_project`/`compose_service`). Empty = none |
| `BUZZ_ALERTS="none"` | Legacy. Every buzz watch was retired: `disk`, `repl`, `backup`, `ha` on 2026-09-15/16 (SMART/ZFS templates, `Homelab Proxmox events`) and `tbmesh` on 2026-09-16 (`Homelab TB3 mesh`, installed by `ZABBIX_TBMESH`). Any value is accepted and ignored (Kan `a25kba4yp866`) |
| `ALERTS_SINKS="buzz ntfy"` | Where alerts are delivered — either or both (default `buzz`; `ALERTS_SINK` singular is a legacy alias) |
| `BUZZ_TARGET="user@host"` | buzz sink: the relay dev box the watches ssh to. Required when the sink is `buzz` (asked interactively if unset) |
| `BUZZ_PORT=6523` | buzz sink: ssh port on the dev box (default `6523`) |
| `NTFY_URL="https://host/topic"` | ntfy sink: the topic URL alerts are pushed to. Required when the sink is `ntfy` |
| `NTFY_TOKEN="tk_…"` | ntfy sink: access token for protected topics (optional) |

</details>

<details open>
<summary><code>container.sh</code></summary>

| Variable | Effect |
| --- | --- |
| `INSTALL_DOCKER=1\|0` | Install Docker (Engine + Compose, rootless). Else asks; default yes |
| `INSTALL_PODMAN=1\|0` | Install Podman (daemonless, rootless) alongside. Else asks; default no. At least one of Docker/Podman is required |
| `CONTAINER_USER=<name>` | User to set up rootless Docker/Podman for (`DOCKER_USER` is still accepted as an alias) |
| `SETUP_ROOTLESS=1` · `DISABLE_ROOTFUL=1` | Rootless Docker setup / disable the root daemon (Podman is always rootless) |
| `USERNS_METHOD=apparmor\|sysctl\|none` | How to allow unprivileged user namespaces. With `apparmor`, a targeted profile is added for each rootless binary in play (`rootlesskit` and/or `podman`) |
| `CREATE_EXAMPLE_APP=1\|0` | Also drop an example app into the layout (the `/opt/docker` hierarchy is always created) |
| `EXAMPLE_APP=<name>` · `EXAMPLE_PORT=8080` | Example app name / host port |
| `DOCKER_JOURNALD_LOGS=1\|0` | Set the `journald` log driver so container logs flow to the systemd journal (and on to Loki via Alloy, no socket needed). For Docker: the active daemon(s), rootful (`/etc/docker/daemon.json`) and/or rootless (`~/.config/docker/daemon.json`); for Podman: the user's `~/.config/containers/containers.conf`. Else asks; default no. When run via `init.sh`, auto-enabled if you opted into Alloy Docker-log capture |
| `DOCKER_LOG_LABELS=<csv>` | Docker container labels the journald driver attaches to each line for grouping in Loki (default `com.docker.compose.project,com.docker.compose.service`, which Alloy promotes to `compose_project` / `compose_service` labels). Empty = attach none |

</details>

<details open>
<summary><code>motd.sh</code></summary>

| Variable | Effect |
| --- | --- |
| `DOC_URL=<url>` | Documentation link shown in the banner. No default; if unset you're prompted. Leave it blank to omit the docs section entirely |
| `BLANK_STATIC_MOTD=1\|0` | Blank the stock `/etc/motd` so only the dynamic banner shows (default `1`; original is backed up to `/etc/motd.bootstrap-bak`) |

</details>

<details open>
<summary><code>documentation.sh</code></summary>

Every field auto-detects from the host it runs on (or is prompted); set any
`CONN_*` override to pin it, handy for documenting a different box.

| Variable | Effect |
| --- | --- |
| `CONN_FQDN=<name>` | DNS hostname (default: `hostname -f`) |
| `CONN_IP=<addr>` | LAN address (default: primary route source IP) |
| `CONN_PORT=<port>` | SSH port (default: `Port` from `sshd_config`, else `22`) |
| `CONN_USER=<user>` | Login user (default: `SUDO_USER` / `logname`) |
| `CONN_ALIAS=<alias>` | `ssh` / `fish` alias (default: short hostname) |
| `CONN_KEY=<name>` | `IdentityFile` basename under `~/.ssh/` (default: `id_ed25519`) |
| `CONN_OS=<string>` | OS description (default: `PRETTY_NAME`) |
| `CONN_ROOT=<string>` | Root access note shown in the server table (default: detected; root SSH from `sshd_config`, password `su` from the root password-lock state) |
| `OUT_FILE=<path>` | Output file (default: `docs/connect.html`) |

</details>

> The individual scripts accept `ASSUME_YES=1` (answer yes to every prompt) when
> run on their own. `init.sh` itself is TUI-only; it ignores `ASSUME_YES` and
> always opens the whiptail menu. It takes `ENV_TYPE=vm\|lxc\|pve` to preselect
> the environment choice.

## Troubleshooting

### A container isn't reachable on the machine's IP

Symptom: you published a container port (e.g. `-p 8080:80`) but
`http://<machine-ip>:8080` times out or refuses from another machine.

Cause: `harden.sh` sets the nftables input policy to drop; only SSH and any
ports you opened are allowed. With rootless Docker, a published port is a
userspace listener bound on the host, so it's subject to that input filter,
unlike rootful Docker, which inserts its own NAT rules that bypass it. The port
is simply not allowed in, so packets are dropped.

Fix (persistent, recommended): insert the accept rule into the input chain
before its `drop` in `/etc/nftables.conf`, then reload. No need to re-run the
whole hardener. `harden.sh` emits exactly one bare `drop` line (the input
chain's; the forward chain uses `policy drop;`), so a single `sed` targets it
safely:

```bash
sudo sed -i 's/^\([[:space:]]*\)drop$/\1tcp dport 8080 ct state new accept\n\1drop/' /etc/nftables.conf && sudo nft -f /etc/nftables.conf
```

For UDP, swap `tcp` for `udp`. For multiple ports, repeat the accept line
(e.g. `…\1tcp dport 8080 …\n\1tcp dport 8096 …\n\1drop`). Because the rule lands
in `/etc/nftables.conf`, it survives reloads and reboots. Re-running appends a
duplicate (harmless); to make it idempotent, guard with a grep:

```bash
grep -q 'tcp dport 8080 ct state new accept' /etc/nftables.conf || sudo sed -i 's/^\([[:space:]]*\)drop$/\1tcp dport 8080 ct state new accept\n\1drop/' /etc/nftables.conf; sudo nft -f /etc/nftables.conf
```

Fix (temporary, for a quick test): add the rule live. Use `insert`, not `add`.
The input chain ends in an explicit `drop`, and `add` appends after it (so the
rule is never reached), whereas `insert` prepends it above the `drop`:

```bash
sudo nft insert rule inet filter input tcp dport 8080 ct state new accept
sudo nft -a list chain inet filter input          # confirm it sits ABOVE the 'drop' line
```

> Temporary rules are lost on the next `nft -f` / `systemctl reload nftables`
> or reboot. Use the persistent `sed` one-liner above to make them stick.

Still not reachable? Check what the port is bound to:

```bash
ss -tlnp | grep ':8080'
```

- `0.0.0.0:8080` (or the machine IP): good; the firewall was the only blocker.
- `127.0.0.1:8080`: the container is published to loopback only. Change the
  compose mapping from `127.0.0.1:8080:80` to `8080:80`, then `docker compose up -d`.

Also verify the container itself works from the host (`curl http://127.0.0.1:8080`)
and that nothing upstream (cloud security group, router) is filtering the port.

### SSH works after hardening, then "Connection refused" on the new port after a reboot

Symptom: right after `harden.sh` you can SSH on the new port (e.g. `9907`), but
after rebooting the host you get `connect to host … port 9907: Connection
refused` (a refusal, not a timeout, so it's a missing listener, not the
firewall).

Cause: Debian 13 can socket-activate SSH via `ssh.socket`, whose listening port
comes from the socket unit (`ListenStream`, default 22), not from
`sshd_config`'s `Port`. A runtime restart can bind the new port, but on the next
boot only `ssh.socket` starts (the standalone `ssh.service` isn't enabled in
socket mode), so SSH reverts to :22 and the new port refuses.

Fix: current `harden.sh` detects this and masks `ssh.socket`, then enables
`ssh.service` so the port persists across reboots. To repair a host hardened by
an older version, get in on port 22 (still served by the socket) with
`ssh -p 22 user@host`, or via the Proxmox/VM console, then:

```bash
sudo systemctl disable --now ssh.socket
sudo systemctl mask ssh.socket
sudo systemctl enable --now ssh.service
sudo ss -ltnp | grep <port>          # confirm sshd is listening on the new port
```

## Requirements

- Debian 13 (Trixie); most steps also work on Debian 12 and 11
- root (`sudo`)
- outbound HTTPS, for Option 1 and for Docker installation
- bare metal, a VM, or an LXC container (tested on Proxmox VMs and LXC containers)

> VM vs LXC vs PVE host: `harden.sh` auto-detects whether it's running in an
> LXC container and skips host-managed steps that can't work inside one, most
> notably AppArmor and auditd, whose subsystems are owned by the Proxmox host
> kernel (enable and confirm them on the host, not in the container; auditd
> isn't even installed inside a container). On bare metal, full VMs and PVE
> hosts every step runs as normal, and `init.sh`'s `pve` environment adjusts
> the recommended defaults (see the setup-menu section) so hardening doesn't
> break the web UI, console, or cluster ssh. The optional `qemu-guest-agent`
> package (via `ancillary.sh`) is only useful inside a VM.
