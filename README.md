# Nginx Subdomain Deployer

> One-command installer that sets up a FastAPI service + web UI to automate
> wildcard-TLS reverse-proxy configs for any subdomain on your VPS.

---

## Quick Start

```bash
sudo bash <(curl -s https://raw.githubusercontent.com/YOU/nginx-subdomain-deployer/main/install.sh)
```

You'll see an interactive menu:

```
  ╔══════════════════════════════════════════════════╗
  ║       Nginx Subdomain Deployer  v1.0.0           ║
  ║   Automate wildcard-SSL reverse-proxy setup      ║
  ╚══════════════════════════════════════════════════╝

  What would you like to do?

    [1]  Download source
    [2]  Set up everything
    [3]  Exit
```

### Option 1 – Download source only
Downloads all source files (`app.py`, frontend, configs) to a directory of your
choice — useful if you want to inspect/modify before installing.

### Option 2 – Set up everything
Full interactive wizard. It asks:

| Prompt | Example |
|---|---|
| Base domain | `example.com` |
| SSL cert directory | `/etc/letsencrypt/live/example.com` |
| Deployer API port | `9000` |
| System service user | `deployer` |
| Install directory | `/opt/nginx-subdomain-deployer` |

Then it automatically:

1. Installs `nginx`, `python3`, `pip`
2. Downloads source files
3. Patches your domain into `app.py`
4. Creates a Python venv and installs deps
5. Creates a locked-down `deployer` system user
6. Writes a narrow `sudoers` rule (nginx -t, nginx -s reload, ln -s only)
7. Installs & starts a `systemd` service
8. Creates an Nginx reverse-proxy so the UI is available at `https://deployer.yourdomain.com`

---

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04 (or Debian 11+)
- Root / sudo access
- A wildcard TLS cert already issued for `*.yourdomain.com`
  (e.g. via `certbot certonly --dns-cloudflare -d '*.example.com'`)
- Nginx installed (the script will install it if missing)

---

## After Installation

| Resource | URL |
|---|---|
| Web UI | `https://deployer.yourdomain.com` |
| Local API | `http://127.0.0.1:9000` |
| API docs | `http://127.0.0.1:9000/docs` |
| Health check | `http://127.0.0.1:9000/health` |

```bash
# View live logs
journalctl -u nginx-deployer -f

# Restart service
systemctl restart nginx-deployer
```

---

## How It Works

The deployer exposes a `POST /deploy` endpoint.  
Send `{ "subdomain_prefix": "api", "local_port": 3000 }` and it will:

1. Write an Nginx server block to `/etc/nginx/sites-available/api.yourdomain.com.conf`
2. Symlink it into `sites-enabled`
3. Run `nginx -t` to validate
4. Run `nginx -s reload` to apply
5. Your app is live at `https://api.yourdomain.com → 127.0.0.1:3000`

The web UI lets you do this from a browser form.

---

## Security Model

- Only `lowercase-alphanumeric + hyphen` subdomain names accepted (RFC-1123)
- Ports restricted to `1024–65535`
- `subprocess` calls use list arguments, never `shell=True`
- Service user has **no login shell** and owns only `/opt/nginx-subdomain-deployer`
- Sudo rights are the minimum possible (3 specific commands, no wildcards on args)

---

## Repository Layout

```
nginx-subdomain-deployer/
├── install.sh              ← entry point (curl | bash this)
├── README.md
└── source/
    ├── app.py              ← FastAPI backend
    ├── requirements.txt
    ├── sudoers.d/
    │   └── deployer        ← sudoers fragment
    └── static/
        └── index.html      ← web UI frontend
```

---

## Customisation

After install, the live config is in `/opt/nginx-subdomain-deployer/app.py`.  
Edit `BASE_DOMAIN`, `SITES_AVAILABLE`, `CERT_DIR` at the top and restart:

```bash
systemctl restart nginx-deployer
```
