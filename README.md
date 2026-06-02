# 🏠 debian13-homelab-bootstrap

> Opinionated bootstrap scripts for a fresh **Debian 13 (Trixie)** homelab host.

`init.sh` is the entry point: it checks for root, installs `curl`, then for each
script asks whether to run it — using a **local copy** if present, or offering to
**download it from GitHub** if not.

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
| **`init.sh`** | 🚀 | Orchestrator — root check, installs `curl`, then runs the scripts below (local copy or download), one at a time, with a summary report. |
| **`harden.sh`** | 🔒 | System hardening — admin users + SSH keys, SSH lockdown, nftables firewall (deny-by-default), fail2ban, unattended-upgrades, persistent journald, sysctl & kernel hardening, AppArmor, AIDE, auditd, plus extra fixes to clear common Lynis findings, then a Lynis audit. |
| **`ancillary.sh`** | 🐟 | Extra packages (`btop`, `rsync`, `qemu-guest-agent`) + the **fish** shell, set as the default shell for users `harden.sh` created (or current users you pick). |
| **`docker.sh`** | 🐳 | Docker Engine + Compose + **rootless** Docker, plus a `/opt/docker` layout with an example app. |

<br>

✨ Every script is **idempotent**, has a **dry-run** preview, **prompts** before
changes, **backs up** files it edits, and prints a **recap** at the end.

<br>

> ⚠️ **Run on a fresh host / VM.** `harden.sh` changes SSH and the firewall.
> **Keep your current session open** and test a new SSH login before disconnecting.

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
curl -fsSL https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main/init.sh | sudo bash
```

<br>

🔍 Prefer to review before running (safer than piping to a shell):

```bash
curl -fsSL https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main/init.sh -o init.sh
less init.sh        # review it first
sudo bash init.sh
```

<br>

For each script, `init.sh` will:

1. ❓ &nbsp; ask **whether to run it** (`Run harden.sh?` …) — and show what it installs;
2. 📂 &nbsp; use the **local file** if present, otherwise show the full raw URL and ask to **download** it;
3. ▶️ &nbsp; run it, **wait** for it to finish, then move to the next;
4. 📋 &nbsp; print a **bootstrap report** with a one-line summary from each script.

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
sudo ./harden.sh     # 1️⃣  harden the system
sudo ./ancillary.sh  # 2️⃣  extra packages (btop, rsync, qemu-guest-agent) + fish shell
sudo ./docker.sh     # 3️⃣  install Docker + Compose (rootless)
```

<br>

---

<br>

## 🧪 Dry run first (recommended)

<br>

All three setup scripts ask **Dry run vs Actual** on start and **default to a dry
run** that previews every action without changing anything. To force it:

<br>

```bash
sudo DRY_RUN=1 ./harden.sh
sudo DRY_RUN=1 ./ancillary.sh
sudo DRY_RUN=1 ./docker.sh
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
<summary>🔒 &nbsp;<strong><code>harden.sh</code></strong></summary>

<br>

| Variable | Effect |
| --- | --- |
| `ADMIN_USERS="jordan"` | Admin users to create/harden (sudo + SSH key); skips the prompt |
| `PUBKEY=` / `PUBKEY_<user>=` | SSH public key(s) — `PUBKEY` is the primary user |
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
| `FISH_USERS="u1 u2"` | Set fish as the default shell for exactly these users (skips prompts) |

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

---

<br>

## ✅ Requirements

<br>

- 🐧 &nbsp; **Debian 13 (Trixie)** — also works on Debian 12 / 11 for most steps
- 👑 &nbsp; **Root** (`sudo`)
- 🌐 &nbsp; **Outbound HTTPS** — for Option 1 and for Docker installation
