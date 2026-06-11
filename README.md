# 🏠 debian13-homelab-bootstrap

> Opinionated bootstrap scripts for a fresh **Debian 13 (Trixie)** homelab host.

`init.sh` is the entry point: it checks for root, then for each script asks
whether to run it — using a **local copy** if present, or **downloading it from
GitHub** if not. It asks **every question up front** (including which extra
packages, monitoring agents, and whether to install Docker), runs the chosen
scripts unattended, and ends with **one consolidated report** (a review of what
ran, plus a single next-steps list).

<br>

**Contents**

- [📦 What's in the box](#-whats-in-the-box)
- [🚀 Quick start](#-quick-start)
- [🧪 Dry run first](#-dry-run-first-recommended)
- [🐳 Docker & the `/opt/docker` layout](#-docker--the-optdocker-layout)
- [⚙️ Environment overrides](#️-environment-overrides)
- [🛟 Troubleshooting](#-troubleshooting)
- [✅ Requirements](#-requirements)

<br>

---

<br>

## 📦 What's in the box

<br>

| Script | Icon | What it does |
| --- | :---: | --- |
| **`init.sh`** | 🚀 | Orchestrator — root check, then runs the scripts below (local copy or download), one at a time, with a single consolidated review + next-steps report at the end. |
| **`bootstrap.sh`** | 👤 | **Runs first** — creates the admin user (or updates an existing one), adds it to `sudo`, and installs its SSH public key into `~/.ssh/authorized_keys`. Optional password for newly-created accounts (blank = SSH-key only). `harden.sh` relies on this account + key existing, since hardening disables password login. |
| **`harden.sh`** | 🔒 | System hardening — verifies the admin user(s) from `bootstrap.sh` (key + sudo), then SSH lockdown, nftables firewall (deny-by-default), fail2ban, unattended-upgrades, persistent journald, sysctl & kernel hardening, AppArmor, AIDE, auditd, plus extra fixes to clear common Lynis findings, then a Lynis audit. **Detects VM vs LXC** and skips host-managed steps (e.g. AppArmor, auditd) inside containers. |
| **`ancillary.sh`** | 🐟 | **Pick-and-install** extra packages — choose any of `btop`, `fish`, `rsync`, `qemu-guest-agent` — plus the **fish** shell set as the default shell for users `bootstrap.sh` created (or current users you pick). |
| **`monitoring.sh`** | 📈 | **Pick-and-install** monitoring agents from their vendor repos. **`zabbix-agent2`** adds Zabbix's official repo, installs the agent, and writes a custom config with this host's name and the Zabbix server address you provide — and when a **rootless Docker** daemon is detected, offers to set the agent up to monitor it (socket path + lingering + running the agent as that user). **`alloy`** adds Grafana's official repo and installs Grafana Alloy, a journal-first log shipper pointed at the Loki URL you provide — with an **optional prompt to also capture Docker container logs** (via Docker's `journald` log-driver, so it works for both rootful and rootless Docker). |
| **`docker.sh`** | 🐳 | Docker Engine + Compose + **rootless** Docker, plus the `/opt/docker` layout (always created) with an optional example app. Optionally sets Docker's **`journald` log-driver** so container logs flow to the journal (and on to Loki via Alloy) — works for rootful and rootless, and tags lines with the **Compose project/service** so you can group by stack in Loki. |
| **`motd.sh`** | 🖥️ | A cool **dynamic login banner** (MOTD) showing live host, IP, uptime, OS/kernel, load, memory, disk &amp; sessions — plus a link to your homelab documentation. |
| **`documentation.sh`** | 🔌 | Generates the **connection doc** (`docs/connect.html` by default) — server details plus how to SSH in on the hardened port, with a `fish` alias and `~/.ssh/config` recipe. Auto-detects host / IP / port / user, or takes `CONN_*` overrides. _Offered by `init.sh` as the optional **final step**, reusing the SSH port/user you configured — when run via `init.sh` the doc is always written to `/tmp/connect.html`._ |

<br>

✨ Every setup script is **idempotent**, has a **dry-run** preview, **prompts**
before changes, **backs up** files it edits, and prints a **recap** at the end.
(`documentation.sh` follows the same conventions but writes a doc rather than
changing the system, so it needs no root and backs nothing up.)

<br>

> ⚠️ **Run on a fresh host, VM, or LXC container.** `harden.sh` changes SSH and
> the firewall. **Keep your current session open** and test a new SSH login
> before disconnecting.

<br>

---

<br>

## 📥 Packages installed

<br>

Every third-party package these scripts pull in is listed below, grouped by the
script that installs it. Most come from **Debian's own repositories**; the ones
that come from an added third-party repo are flagged in the **Source** column.
Nothing here is installed without you selecting it — `harden.sh`'s core tools
install when you run hardening; everything in `ancillary.sh`, `monitoring.sh`
and `docker.sh` is opt-in.

<br>

### 🔒 `harden.sh` — core security tools

Installed when you run hardening (skipped individually if already present).

| Package | Source | What it is |
| --- | :---: | --- |
| `openssh-server` | Debian | OpenSSH server daemon — remote login. |
| `sudo` | Debian | Run commands as root / another user. |
| `vim` | Debian | Text editor. |
| `gnupg` | Debian | GnuPG — key handling and signature verification (e.g. apt repo keys). |
| `lsb-release` | Debian | Reports the distro / release version for other tooling. |
| `ca-certificates` | Debian | Trusted root CA certificates for TLS. |
| `nftables` | Debian | Linux kernel firewall — the deny-by-default backend. |
| `fail2ban` | Debian | Bans IPs after repeated failed logins (watches sshd). |
| `aide` | Debian | Advanced Intrusion Detection Environment — file-integrity database. |
| `apparmor` | Debian | Mandatory Access Control framework confining programs. |
| `apparmor-utils` | Debian | Tools to manage and audit AppArmor profiles. |
| `unattended-upgrades` | Debian | Applies security updates automatically. |
| `apt-listchanges` | Debian | Shows package changelogs at upgrade time. |
| `rsyslog` | Debian | System logging daemon. |
| `rsyslog-gnutls` | Debian | TLS transport for rsyslog (encrypted remote logging). |
| `logwatch` | Debian | Summarizes system logs into readable reports. |
| `lynis` | Debian | Security auditing / hardening scanner (run at the end). |
| `needrestart` | Debian | Flags services that need a restart after library upgrades. |
| `libpam-google-authenticator` | Debian | **Optional** — TOTP one-time-password PAM module; only installed when SSH 2FA is enabled. |

<br>

### 🐟 `ancillary.sh` — opt-in extras

Only the packages you tick in the picker are installed.

| Package | Source | What it is |
| --- | :---: | --- |
| `btop` | Debian | Resource monitor (htop-like). |
| `fish` | Debian | Friendly interactive shell (also settable as default shell). |
| `rsync` | Debian | Fast file copy / sync. |
| `qemu-guest-agent` | Debian | QEMU/KVM guest integration (VMs only). |

<br>

### 📈 `monitoring.sh` — opt-in monitoring agents

Each agent is installed from its vendor's official apt repo. Only the ones you
tick in the picker are installed.

| Package | Source | What it is |
| --- | :---: | --- |
| `zabbix-release` | **Zabbix repo** | `.deb` that registers Zabbix's official apt repository. |
| `zabbix-agent2` | **Zabbix repo** | Zabbix monitoring agent 2. |
| `inxi` | Debian | System-information CLI; backs the CPU-temperature monitoring item. Installed alongside `zabbix-agent2`. |
| `gnupg` | Debian | Ensured present to import the Grafana repo key (usually already installed by `harden.sh`). |
| `alloy` | **Grafana repo** | Grafana Alloy — journal-first log shipper to Loki. |

> 📦 If you opt into **Docker container logs**, Alloy captures them **via the
> journal** (no extra package, no Docker socket access): point Docker at the
> `journald` log-driver and the lines flow in like any other journal entry,
> tagged with `container` / `image` labels. This works for **both rootful and
> rootless** Docker. **You don't have to set the driver by hand:** if Docker is
> already installed, `monitoring.sh` detects it and offers to set the `journald`
> driver itself (rootful and/or rootless) when you enable Docker-log capture; and
> `docker.sh` sets it on fresh installs (its `DOCKER_JOURNALD_LOGS` step, auto-enabled
> when you opt into Alloy Docker logs via `init.sh`). To do it manually instead, put
> `{"log-driver":"journald"}` in `/etc/docker/daemon.json` (rootful) or
> `~/.config/docker/daemon.json` (rootless), restart Docker, and recreate your
> containers. Query them with
> `{host="<host>", container=~".+"}`, or **group by Compose stack/service** with
> `{compose_project="media"}` / `{compose_service="nginx"}` — `docker.sh` attaches
> those labels by default (`DOCKER_LOG_LABELS`) and Alloy promotes them. (The
> daemon's own logs already arrive via `docker.service`.)

<br>

### 🐳 `docker.sh` — Docker Engine + rootless

| Package | Source | What it is |
| --- | :---: | --- |
| `docker-ce` | **Docker repo** | Docker Engine (the daemon). |
| `docker-ce-cli` | **Docker repo** | Docker command-line client. |
| `containerd.io` | **Docker repo** | containerd container runtime. |
| `docker-buildx-plugin` | **Docker repo** | Buildx build plugin. |
| `docker-compose-plugin` | **Docker repo** | Compose v2 plugin (`docker compose`). |
| `docker-ce-rootless-extras` | **Docker repo** | Rootless-mode support files. |
| `uidmap` | Debian | `newuidmap`/`newgidmap` — user-namespace ID mapping for rootless. |
| `dbus-user-session` | Debian | Per-user D-Bus session, required for rootless systemd. |
| `slirp4netns` | Debian | User-mode networking for rootless containers. |

> 🧹 `docker.sh` also **removes** any conflicting legacy packages it finds
> (`docker.io`, `docker-doc`, `docker-compose`, `podman-docker`, `containerd`,
> `runc`) before installing the above.

<br>

### 🌐 Third-party apt repositories added

| Repo | URL | Added by | Signing key |
| --- | --- | :---: | --- |
| Docker | `https://download.docker.com/linux/debian` | `docker.sh` | `/etc/apt/keyrings/docker.asc` |
| Zabbix | `https://repo.zabbix.com` | `monitoring.sh` (via `zabbix-release`) | shipped in the `zabbix-release` package |
| Grafana | `https://apt.grafana.com` | `monitoring.sh` | `/etc/apt/keyrings/grafana.gpg` |

<br>

---

<br>

## 🚀 Quick start

<br>

### ⭐ Option 1 — Run `init.sh`

> Recommended · easiest · quickest. Downloads the other scripts for you — nothing
> to clone. Run as **root**.

<br>

```bash
# One-liner
curl -fsSL https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main/init.sh | bash
```

<br>

🔍 Prefer to review before running (safer than piping to a shell):

```bash
curl -fsSL https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main/init.sh -o init.sh
less init.sh        # review it first
bash init.sh
```

<br>

For each script, `init.sh` will:

1. ❓ &nbsp; ask **whether to run it** (`Set up the admin user + SSH key (bootstrap)?`, `Harden the system?`, `Install extra packages?`, `Install monitoring agents?`, `Install Docker…?` …) — and, for the **Extra packages** and **Monitoring** groups, let you **pick which ones** to install;
2. 🧭 &nbsp; gather **every answer up front**, then use the **local file** if present, otherwise download it from GitHub;
3. ▶️ &nbsp; run each chosen script **unattended** (no mid-run prompts), waiting for it to finish before the next;
4. 📋 &nbsp; finish with **one consolidated report** — a review of what ran and a single, merged next-steps list.

> 💡 `curl` is no longer installed by `init.sh`; it's assumed present (the
> one-liner above already uses it, and Debian ships it on all but the most
> minimal installs). The download fallback needs it too.

<br>

### 📥 Option 2 — `git clone` and run locally

> Skips downloading. Since the scripts sit next to `init.sh`, it uses the **local
> copies** and never hits the network for them.

<br>

```bash
git clone https://github.com/jordancannon88/debian13-homelab-bootstrap.git
cd debian13-homelab-bootstrap
sudo ./init.sh
```

<br>

🛠️ Or run the steps yourself, in order:

```bash
sudo ./bootstrap.sh   # 1️⃣  create/update the admin user + install the SSH key
sudo ./harden.sh      # 2️⃣  harden the system (relies on the user/key from 1️⃣)
sudo ./ancillary.sh   # 3️⃣  extra packages (btop, fish, rsync, qemu-guest-agent) + fish shell
sudo ./monitoring.sh  # 4️⃣  monitoring agents (zabbix-agent2, alloy)
sudo ./docker.sh      # 5️⃣  install Docker + Compose (rootless)
sudo ./motd.sh        # 6️⃣  install the dynamic login banner (MOTD)
./documentation.sh    # 7️⃣  generate docs/connect.html (no sudo needed)
```

<br>

---

<br>

## 🧪 Dry run first (recommended)

<br>

All setup scripts ask **Dry run vs Actual** on start and **default to a dry
run** that previews every action without changing anything. To force it:

<br>

```bash
sudo DRY_RUN=1 ./bootstrap.sh
sudo DRY_RUN=1 ./harden.sh
sudo DRY_RUN=1 ./ancillary.sh
sudo DRY_RUN=1 ./docker.sh
sudo DRY_RUN=1 ./motd.sh
DRY_RUN=1 ./documentation.sh # no sudo — just previews the generated HTML
```

<br>

---

<br>

## 🐳 Docker & the `/opt/docker` layout

<br>

`docker.sh` installs Docker Engine, the Compose plugin and (by default) sets up
**rootless** Docker for a chosen user. It then creates a tidy, predictable home
for your stacks under **`/opt/docker`** — one folder per app.

<br>

### 📂 Directory hierarchy

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

<br>

### 🧩 Conventions

- **One directory per app** under `/opt/docker/<app>/`.
- Each app has its own `docker-compose.yml`, `.env`, and `data/` directory.
- Persistent data lives in the app's `data/` folder (a relative bind mount), so a
  whole app is self-contained and easy to back up or move.
- **`shared/networks/`** is for networks you want multiple apps to join — create
  one (`docker network create proxy`) and mark it `external: true` in each app.

<br>

### 🔐 Ownership & permissions

| Mode | Owner | Notes |
| --- | --- | --- |
| **Rootless** (default) | `<docker-user>:<docker-user>` | the user runs Docker and owns the files |
| **Rootful** | `root:docker` | when you keep the system daemon |

`.env` files are `600` (sensitive), `docker-compose.yml` is `644`.

<br>

### 🚦 The example app

A minimal **`traefik/whoami`** service is dropped in at `/opt/docker/example-app/`
(published on host port **8080** by default). Start it:

```bash
cd /opt/docker/example-app
docker compose up -d
# then browse http://<host>:8080
```

<br>

### 📝 Good to know (rootless)

- Your shell gets `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` so `docker`
  talks to the rootless daemon.
- **Published ports bind on the host but are blocked by the deny-by-default
  firewall** — rootless port forwards are a userspace listener subject to the
  nftables input filter (unlike rootful, which bypasses it). Open each container
  port in `harden.sh`, e.g. `ALLOW_TCP_PORTS="8080 8096"` (or temporarily —
  note **`insert`**, since the chain ends in an explicit `drop`:
  `sudo nft insert rule inet filter input tcp dport 8080 ct state new accept`).
- Rootless containers run **without** the `docker-default` AppArmor profile
  (loading a profile needs root); isolation relies on user namespaces + seccomp.
- **The daemon waits for DNS at boot.** Lingering starts the user's
  `docker.service` seconds into boot — before the network is up — and user units
  can't order on the system's `network-online.target`. Containers brought up by
  restart policies would snapshot a not-yet-ready `resolv.conf` and keep broken
  DNS until manually recreated. A drop-in
  (`~/.config/systemd/user/docker.service.d/wait-online.conf`) makes `dockerd`
  poll until the host resolves names (fail-open after ~2 min) before starting.
- On Debian 13, `harden.sh` keeps AppArmor on; `docker.sh` grants **only**
  `rootlesskit` the `userns` permission so rootless still works (`USERNS_METHOD`).

<br>

➕ **Add a new app:** make `/opt/docker/<app>/`, drop a `docker-compose.yml`
(+ optional `.env` and `data/`) in it, then `docker compose up -d` from that folder.

<br>

---

<br>

## ⚙️ Environment overrides

<br>

<details open>
<summary>🚀 &nbsp;<strong><code>init.sh</code></strong></summary>

<br>

| Variable | Effect |
| --- | --- |
| `REPO_RAW_BASE=<url>` | Base raw URL to download scripts from (e.g. a fork/branch) |
| `ASSUME_YES=1` | Answer **yes** to every prompt (automation) |

</details>

<br>

<details open>
<summary>👤 &nbsp;<strong><code>bootstrap.sh</code></strong></summary>

<br>

| Variable | Effect |
| --- | --- |
| `ADMIN_USERS="jordan"` | Admin users to create/update (sudo + SSH key); skips the prompt |
| `PUBKEY=` / `PUBKEY_<user>=` | SSH public key(s) — `PUBKEY` is the primary (first) user |
| `ADMIN_PASSWORD=` / `PASSWORD_<user>=` | Password for a **newly-created** account (existing accounts are never changed; blank = SSH-key only) |
| `CREATE_<user>=1\|0` | Auto-answer the "create missing user?" prompt |

</details>

<br>

<details open>
<summary>🔒 &nbsp;<strong><code>harden.sh</code></strong></summary>

<br>

| Variable | Effect |
| --- | --- |
| `ADMIN_USERS="jordan"` | **Existing** admin users the hardening relies on (lockout checks, root locking); skips the prompt. Create them with `bootstrap.sh` first |
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
| `HARDEN_COMPILERS=0` | Do **not** restrict compilers to root (default: restricted) |
| `BACKUP_DNS="1.1.1.1 9.9.9.9"` | Fallback DNS servers |
| `REMOTE_SYSLOG="host:port"` | Forward logs to a remote syslog host (opt-in) |
| `GRUB_PASSWORD="…"` | Set a GRUB password; normal boot stays password-free (opt-in) |

</details>

<br>

<details open>
<summary>🐟 &nbsp;<strong><code>ancillary.sh</code></strong></summary>

<br>

| Variable | Effect |
| --- | --- |
| `ANCILLARY_PKGS="btop rsync"` | Install exactly these packages (any of `btop fish rsync qemu-guest-agent`), or `none` for nothing; **unset** installs the full default set |
| `FISH_USERS="u1 u2"` | Set fish as the default shell for exactly these users (skips prompts) |

</details>

<br>

<details open>
<summary>📈 &nbsp;<strong><code>monitoring.sh</code></strong></summary>

<br>

| Variable | Effect |
| --- | --- |
| `MONITORING_PKGS="zabbix-agent2 alloy"` | Install exactly these agents (any of `zabbix-agent2 alloy`), or `none` for nothing; **unset** installs the full default set |
| `ZABBIX_SERVER_ACTIVE="host[:port]"` | Zabbix server/proxy for active checks — **required** when `zabbix-agent2` is selected (asked interactively if unset). Written into `ServerActive=` in `/etc/zabbix/zabbix_agent2.conf` |
| `ZABBIX_MONITOR_ROOTLESS_DOCKER=1\|0` | Set the agent up to monitor a **rootless Docker** daemon. Empty = ask when a rootless daemon is detected (default no). Writes a Docker-plugin drop-in pointing `Plugins.Docker.Endpoint` at the user's `/run/user/<uid>/docker.sock`, enables lingering, and adds a systemd override running `zabbix-agent2` as that user so it can reach the socket. The override also sets `RuntimeDirectory`/`LogsDirectory` so `/run/zabbix` and `/var/log/zabbix` are re-owned by that user at every start (reboot-proof), and the logrotate `create` rule is repointed at that user so rotated logs stay writable |
| `ZABBIX_DOCKER_USER=<user>` | The rootless Docker owner to monitor (default: auto-detected from the running daemon; falls back to `$SUDO_USER`) |
| `LOKI_URL="scheme://host:port"` | Loki base URL for Alloy to push to — used when `alloy` is selected (asked interactively; defaults to `http://localhost:3100`). The `/loki/api/v1/push` path is appended automatically |
| `ALLOY_DOCKER_LOGS=1` | Also capture **Docker container** logs — used when `alloy` is selected (asked interactively; defaults to off). Keeps the journald relabel rules that promote `container`/`image`/`compose_project`/`compose_service` labels; relies on Docker using the `journald` log-driver (rootful **or** rootless). Container logs then ship via the journal under `{host="<host>", container=~".+"}` |
| `ALLOY_SET_DOCKER_DRIVER=1\|0` | When `ALLOY_DOCKER_LOGS=1` **and Docker is already installed here**, set Docker's `journald` log-driver from `monitoring.sh` itself (rootful via `/etc/docker/daemon.json`, rootless via the user's `~/.config/docker/daemon.json`) — so an existing Docker host needs no separate `docker.sh` run. Empty = ask; default yes |
| `DOCKER_LOG_LABELS=<csv>` | Container labels the journald driver attaches for grouping in Loki (default `com.docker.compose.project,com.docker.compose.service`, promoted to `compose_project`/`compose_service`). Empty = none |

</details>

<br>

<details open>
<summary>🐳 &nbsp;<strong><code>docker.sh</code></strong></summary>

<br>

| Variable | Effect |
| --- | --- |
| `DOCKER_USER=<name>` | User to set up rootless Docker for |
| `SETUP_ROOTLESS=1` · `DISABLE_ROOTFUL=1` | Rootless setup / disable the root daemon |
| `USERNS_METHOD=apparmor\|sysctl\|none` | How to allow unprivileged user namespaces |
| `CREATE_EXAMPLE_APP=1\|0` | Also drop an example app into the layout (the `/opt/docker` hierarchy is always created) |
| `EXAMPLE_APP=<name>` · `EXAMPLE_PORT=8080` | Example app name / host port |
| `DOCKER_JOURNALD_LOGS=1\|0` | Set Docker's `journald` log-driver so container logs flow to the systemd journal (and on to Loki via Alloy, no socket needed). Applies to the active daemon(s) — rootful (`/etc/docker/daemon.json`) and/or rootless (`~/.config/docker/daemon.json`). Else asks; default no. When run via `init.sh`, auto-enabled if you opted into Alloy Docker-log capture |
| `DOCKER_LOG_LABELS=<csv>` | Container labels the journald driver attaches to each line for grouping in Loki (default `com.docker.compose.project,com.docker.compose.service`, which Alloy promotes to `compose_project` / `compose_service` labels). Empty = attach none |

</details>

<br>

<details open>
<summary>🖥️ &nbsp;<strong><code>motd.sh</code></strong></summary>

<br>

| Variable | Effect |
| --- | --- |
| `DOC_URL=<url>` | Documentation link shown in the banner. **No default** — if unset you're prompted; leave it **blank to omit** the docs section entirely |
| `BLANK_STATIC_MOTD=1\|0` | Blank the stock `/etc/motd` so only the dynamic banner shows (default `1`; original is backed up to `/etc/motd.bootstrap-bak`) |

</details>

<br>

<details open>
<summary>🔌 &nbsp;<strong><code>documentation.sh</code></strong></summary>

<br>

Every field auto-detects from the host it runs on (or is prompted); set any
`CONN_*` override to pin it — handy for documenting a different box.

| Variable | Effect |
| --- | --- |
| `CONN_FQDN=<name>` | DNS hostname (default: `hostname -f`) |
| `CONN_IP=<addr>` | LAN address (default: primary route source IP) |
| `CONN_PORT=<port>` | SSH port (default: `Port` from `sshd_config`, else `22`) |
| `CONN_USER=<user>` | Login user (default: `SUDO_USER` / `logname`) |
| `CONN_ALIAS=<alias>` | `ssh` / `fish` alias (default: short hostname) |
| `CONN_KEY=<name>` | `IdentityFile` basename under `~/.ssh/` (default: `id_ed25519`) |
| `CONN_OS=<string>` | OS description (default: `PRETTY_NAME`) |
| `CONN_ROOT=<string>` | Root access note shown in the server table (default: detected — root SSH from `sshd_config`, password `su` from the root password-lock state) |
| `OUT_FILE=<path>` | Output file (default: `docs/connect.html`) |

</details>

<br>

> 🌐 Common to all: `DRY_RUN=1\|0`, `ASSUME_YES=1`.

<br>

---

<br>

## 🛟 Troubleshooting

<br>

### 🐳 A container isn't reachable on the machine's IP

<br>

**Symptom:** you published a container port (e.g. `-p 8080:80`) but
`http://<machine-ip>:8080` times out / refuses from another machine.

<br>

**Cause:** `harden.sh` sets the nftables **input policy to drop** (only SSH and
any ports you opened are allowed). With **rootless** Docker, a published port is
a userspace listener bound on the host, so it's subject to that input filter —
unlike rootful Docker, which inserts its own NAT rules that bypass it. The port
is simply not allowed in, so packets are dropped.

<br>

**Fix (persistent — recommended):** insert the accept rule into the input chain
**before** its `drop` in `/etc/nftables.conf`, then reload — no need to re-run the
whole hardener. harden.sh emits exactly one bare `drop` line (the input chain's;
the forward chain uses `policy drop;`), so a single `sed` targets it safely:

```bash
sudo sed -i 's/^\([[:space:]]*\)drop$/\1tcp dport 8080 ct state new accept\n\1drop/' /etc/nftables.conf && sudo nft -f /etc/nftables.conf
```

For **UDP**, swap `tcp` → `udp`. For **multiple ports**, repeat the accept line
(e.g. `…\1tcp dport 8080 …\n\1tcp dport 8096 …\n\1drop`). Because the rule lands
in `/etc/nftables.conf`, it survives reloads/reboots. Re-running appends a
duplicate (harmless); to make it idempotent, guard with a grep:

```bash
grep -q 'tcp dport 8080 ct state new accept' /etc/nftables.conf || sudo sed -i 's/^\([[:space:]]*\)drop$/\1tcp dport 8080 ct state new accept\n\1drop/' /etc/nftables.conf; sudo nft -f /etc/nftables.conf
```

<br>

**Fix (temporary — for a quick test):** add the rule live. Use **`insert`**, not
`add` — the input chain ends in an explicit `drop`, and `add` appends *after* it
(so the rule is never reached), whereas `insert` prepends it above the `drop`:

```bash
sudo nft insert rule inet filter input tcp dport 8080 ct state new accept
sudo nft -a list chain inet filter input          # confirm it sits ABOVE the 'drop' line
```

> ⚠️ Temporary rules are lost on the next `nft -f` / `systemctl reload nftables`
> or reboot — use the persistent `sed` one-liner above to make them stick.

<br>

**Still not reachable?** Check what the port is bound to:

```bash
ss -tlnp | grep ':8080'
```

- `0.0.0.0:8080` (or the machine IP) → good; the firewall was the only blocker.
- `127.0.0.1:8080` → the container is published to loopback only. Change the
  compose mapping from `127.0.0.1:8080:80` to `8080:80`, then `docker compose up -d`.

Also verify the container itself works from the host (`curl http://127.0.0.1:8080`)
and that nothing upstream (cloud security group, router) is filtering the port.

<br>

### 🔌 SSH works after hardening, then "Connection refused" on the new port after a reboot

<br>

**Symptom:** right after `harden.sh` you can SSH on the new port (e.g. `9907`),
but after rebooting the host you get `connect to host … port 9907: Connection
refused` (a *refusal*, not a timeout — so it's a missing listener, not the firewall).

<br>

**Cause:** Debian 13 can **socket-activate** SSH via `ssh.socket`, whose listening
port comes from the socket unit (`ListenStream`, default **22**) — not from
`sshd_config`'s `Port`. A runtime restart can bind the new port, but on the next
boot only `ssh.socket` starts (the standalone `ssh.service` isn't enabled in
socket mode), so SSH reverts to **:22** and the new port refuses.

<br>

**Fix:** current `harden.sh` detects this and **masks `ssh.socket`** + enables
`ssh.service` so the port persists across reboots. To repair a host hardened by an
older version, get in on port 22 (still served by the socket) — `ssh -p 22 user@host`
— or via the Proxmox/VM console, then:

```bash
sudo systemctl disable --now ssh.socket
sudo systemctl mask ssh.socket
sudo systemctl enable --now ssh.service
sudo ss -ltnp | grep <port>          # confirm sshd is listening on the new port
```

<br>

---

<br>

## ✅ Requirements

<br>

- 🐧 &nbsp; **Debian 13 (Trixie)** — also works on Debian 12 / 11 for most steps
- 👑 &nbsp; **Root** (`sudo`)
- 🌐 &nbsp; **Outbound HTTPS** — for Option 1 and for Docker installation
- 🖥️ &nbsp; **Bare metal, a VM, or an LXC container** — all supported (tested on Proxmox VMs and LXC containers)

<br>

> 🧱 **VM vs LXC.** `harden.sh` **auto-detects** whether it's running in an LXC
> container and **skips host-managed steps** that can't work inside one — most
> notably **AppArmor** and **auditd**, whose subsystems are owned by the Proxmox
> host kernel (enable/confirm them on the host, not in the container; auditd
> isn't even installed inside a container). On bare metal and full VMs every step
> runs as normal. The optional `qemu-guest-agent` package (via `ancillary.sh`)
> is only useful inside a VM.
