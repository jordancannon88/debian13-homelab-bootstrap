# 🏠 debian13-homelab-bootstrap

> Opinionated bootstrap scripts for a fresh **Debian 13 (Trixie)** homelab host.

`init.sh` is the entry point: it checks for root, installs `curl`, then for each
script asks whether to run it — using a **local copy** if present, or offering to
**download it from GitHub** if not.

---

## 📦 What's in the box

| Script | Icon | What it does |
| --- | :---: | --- |
| **`init.sh`** | 🚀 | Orchestrator — root check, installs `curl`, then runs the scripts below (local copy or download), one at a time. |
| **`harden.sh`** | 🔒 | System hardening — admin users + SSH keys, SSH lockdown, nftables firewall (deny-by-default), fail2ban, unattended-upgrades, persistent journald, sysctl hardening, AppArmor, AIDE, Lynis. |
| **`docker.sh`** | 🐳 | Docker Engine + Compose + **rootless** Docker, plus a `/opt/docker` layout with an example app. |
| **`ancillary.sh`** | 🐟 | Extra packages (`btop`, `qemu-guest-agent`) + the **fish** shell, set as default for users `harden.sh` created (or current users you pick). |

✨ Every script is **idempotent**, has a **dry-run** preview, **prompts** before
changes, **backs up** files it edits, and prints a **recap** at the end.

> ⚠️ **Run on a fresh host / VM.** `harden.sh` changes SSH and the firewall.
> **Keep your current session open** and test a new SSH login before disconnecting.

---

## 🚀 Quick start

### ⭐ Option 1 — Run `init.sh` (recommended · easiest · quickest)

Downloads the other scripts for you — nothing to clone. Run as **root**.

```bash
# One-liner
curl -fsSL https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main/init.sh | sudo bash
```

🔍 Prefer to review before running (safer than piping to a shell):

```bash
curl -fsSL https://raw.githubusercontent.com/jordancannon88/debian13-homelab-bootstrap/main/init.sh -o init.sh
less init.sh        # review it first
sudo bash init.sh
```

For each script, `init.sh` will:

1. ❓ ask **whether to run it** (`Run harden.sh?` …);
2. 📂 use the **local file** if present, otherwise show the full raw URL and ask to **download** it;
3. ▶️ run it and **wait** for it to finish before the next.

### 📥 Option 2 — `git clone` and run locally (skips downloading)

Run everything from local files. Since the scripts sit next to `init.sh`, it uses
the **local copies** and never hits the network for them.

```bash
git clone https://github.com/jordancannon88/debian13-homelab-bootstrap.git
cd debian13-homelab-bootstrap
sudo ./init.sh
```

🛠️ Or run the steps yourself, in order:

```bash
sudo ./harden.sh     # 1️⃣  harden the system
sudo ./ancillary.sh  # 2️⃣  extra packages (btop, qemu-guest-agent) + fish shell
sudo ./docker.sh     # 3️⃣  install Docker + Compose (rootless)
```

---

## 🧪 Dry run first (recommended)

All three setup scripts ask **Dry run vs Actual** on start and **default to a dry
run** that previews every action without changing anything. To force it:

```bash
sudo DRY_RUN=1 ./harden.sh
sudo DRY_RUN=1 ./docker.sh
sudo DRY_RUN=1 ./ancillary.sh
```

---

## ⚙️ Environment overrides

<details open>
<summary>🚀 <strong><code>init.sh</code></strong></summary>

| Variable | Effect |
| --- | --- |
| `REPO_RAW_BASE=<url>` | Base raw URL to download scripts from (e.g. a fork/branch) |
| `ASSUME_YES=1` | Answer **yes** to every prompt (automation) |

</details>

<details open>
<summary>🔒 <strong><code>harden.sh</code></strong></summary>

| Variable | Effect |
| --- | --- |
| `ADMIN_USERS="jordan"` | Admin users to create/harden (sudo + SSH key); skips the prompt |
| `PUBKEY=` / `PUBKEY_<user>=` | SSH public key(s) — `PUBKEY` is the primary user |
| `SSH_PORT=22` | SSH port |
| `ALLOW_SSH_CIDRS="1.2.3.4/32"` | Restrict SSH to source ranges |
| `ALLOW_HTTP=1` · `ALLOW_HTTPS=1` | Open 80 / 443 |
| `ENABLE_SSH_2FA=1` | Require TOTP 2FA |
| `SKIP_UPGRADE=1` | Skip the full `apt` upgrade |
| `DOCKER_COMPAT=1` | Docker-compatible firewall + sysctl |
| `DISABLE_ROOT_LOGIN=1` | Lock the root account password |

</details>

<details open>
<summary>🐳 <strong><code>docker.sh</code></strong></summary>

| Variable | Effect |
| --- | --- |
| `DOCKER_USER=<name>` | User to set up rootless Docker for |
| `SETUP_ROOTLESS=1` · `DISABLE_ROOTFUL=1` | Rootless setup / disable the root daemon |
| `USERNS_METHOD=apparmor\|sysctl\|none` | How to allow unprivileged user namespaces |
| `CREATE_OPT_DOCKER=1` | Create the `/opt/docker` layout + example app |
| `EXAMPLE_APP=<name>` · `EXAMPLE_PORT=8080` | Example app name / host port |

</details>

<details open>
<summary>🐟 <strong><code>ancillary.sh</code></strong></summary>

| Variable | Effect |
| --- | --- |
| `FISH_USERS="u1 u2"` | Set fish as the default shell for exactly these users (skips prompts) |

</details>

> 🌐 Common to all: `DRY_RUN=1\|0`, `ASSUME_YES=1`.

---

## ✅ Requirements

- 🐧 **Debian 13 (Trixie)** — also works on Debian 12 / 11 for most steps
- 👑 **Root** (`sudo`)
- 🌐 **Outbound HTTPS** — for Option 1 and for Docker installation
