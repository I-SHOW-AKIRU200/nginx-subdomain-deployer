"""
VPS Nginx Deployment Backend - FastAPI Service
===============================================
This service automates Nginx reverse-proxy configuration for subdomains
under killersharmabot.online using a wildcard TLS certificate.

Security model:
  - Input sanitization: only alphanumeric subdomain names, port 1024-65535.
  - Subprocess calls use explicit list arguments (never shell=True with
    untrusted input) to prevent shell injection.
  - Nginx operations require elevated privileges; the process user is
    granted narrow sudo rules (see SETUP.md) covering only the three
    commands needed: nginx -t, nginx -s reload, and ln -s for the
    specific sites-available/sites-enabled paths.
  - Config files are written by this process (run as a service user that
    owns /etc/nginx/sites-available) so no sudo is required for file I/O.

Run:
  uvicorn main:app --host 127.0.0.1 --port 9000
"""

import re
import os
import subprocess
import logging
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from pydantic import BaseModel, field_validator, model_validator

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("deployer")

# ---------------------------------------------------------------------------
# Constants – adjust paths here if your layout differs
# ---------------------------------------------------------------------------
BASE_DOMAIN = "killersharmabot.online"
SITES_AVAILABLE = Path("/etc/nginx/sites-available")
SITES_ENABLED = Path("/etc/nginx/sites-enabled")
CERT_DIR = Path(f"/etc/letsencrypt/live/{BASE_DOMAIN}")

# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------
app = FastAPI(title="VPS Deployer", version="1.0.0")

# Allow requests from the same origin (the static UI served on port 9000).
# Tighten this list in production if the UI is on a different origin.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["POST", "GET"],
    allow_headers=["*"],
)

# Serve the frontend from the same process for convenience.
app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/")
async def root():
    return FileResponse("static/index.html")


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------

class DeployRequest(BaseModel):
    subdomain_prefix: str
    local_port: int

    @field_validator("subdomain_prefix")
    @classmethod
    def sanitize_subdomain(cls, v: str) -> str:
        """
        Accept only lowercase alphanumeric strings (and hyphens, which are
        valid in DNS labels).  Reject anything else to prevent path traversal
        or shell metacharacters reaching file-system or subprocess calls.
        """
        v = v.strip().lower()
        if not v:
            raise ValueError("subdomain_prefix must not be empty")
        if len(v) > 63:
            raise ValueError("subdomain_prefix must be 63 characters or fewer (DNS label limit)")
        # RFC-1123: letters, digits, hyphens; must not start or end with hyphen
        if not re.fullmatch(r"[a-z0-9]([a-z0-9\-]*[a-z0-9])?|[a-z0-9]", v):
            raise ValueError(
                "subdomain_prefix may only contain lowercase letters, digits, and hyphens, "
                "and must not start or end with a hyphen"
            )
        return v

    @field_validator("local_port")
    @classmethod
    def validate_port(cls, v: int) -> int:
        """
        Ports 0-1023 are privileged/reserved.
        65535 is the highest valid TCP port.
        """
        if not (1024 <= v <= 65535):
            raise ValueError("local_port must be between 1024 and 65535")
        return v


class StepLog(BaseModel):
    step: str
    status: str          # "ok" | "error" | "info"
    message: str


class DeployResponse(BaseModel):
    success: bool
    steps: list[StepLog]
    fqdn: str | None = None


# ---------------------------------------------------------------------------
# Nginx config template
# ---------------------------------------------------------------------------

def _render_nginx_config(subdomain: str, port: int) -> str:
    """
    Render a minimal but production-ready Nginx server block.
    The HTTP block simply redirects to HTTPS; the HTTPS block terminates
    TLS with the existing wildcard certificate and reverse-proxies to the
    local application.
    """
    fqdn = f"{subdomain}.{BASE_DOMAIN}"
    return f"""# Auto-generated by VPS Deployer — do not edit manually
server {{
    listen 80;
    listen [::]:80;
    server_name {fqdn};

    # Redirect all plain-HTTP traffic to HTTPS
    return 301 https://$host$request_uri;
}}

server {{
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name {fqdn};

    # Wildcard certificate for *.{BASE_DOMAIN}
    ssl_certificate     {CERT_DIR}/fullchain.pem;
    ssl_certificate_key {CERT_DIR}/privkey.pem;

    # Modern TLS settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;

    # Reverse proxy to the local application
    location / {{
        proxy_pass         http://127.0.0.1:{port};
        proxy_http_version 1.1;

        # WebSocket support
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";

        # Forward real client information
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 86400;
    }}
}}
"""


# ---------------------------------------------------------------------------
# Helper: run a subprocess with sudo, capture output
# ---------------------------------------------------------------------------

def _run(cmd: list[str], steps: list[StepLog], step_name: str) -> tuple[bool, str]:
    """
    Execute *cmd* via subprocess (no shell=True).  Prepend 'sudo' so the
    service user can run the narrow set of whitelisted commands defined in
    the sudoers file.

    Returns (success: bool, combined_output: str).
    """
    full_cmd = ["sudo"] + cmd
    log.info("Running: %s", " ".join(full_cmd))
    try:
        result = subprocess.run(
            full_cmd,
            capture_output=True,
            text=True,
            timeout=30,          # safety net – nginx -t should be instant
        )
        output = (result.stdout + result.stderr).strip()
        if result.returncode != 0:
            log.error("Command failed (rc=%d): %s", result.returncode, output)
            steps.append(StepLog(step=step_name, status="error", message=output or "Command returned non-zero exit code"))
            return False, output
        log.info("Command succeeded: %s", output[:200])
        return True, output
    except subprocess.TimeoutExpired:
        msg = "Command timed out after 30 seconds"
        log.error(msg)
        steps.append(StepLog(step=step_name, status="error", message=msg))
        return False, msg
    except FileNotFoundError:
        msg = f"Executable not found: {full_cmd[1]}"
        log.error(msg)
        steps.append(StepLog(step=step_name, status="error", message=msg))
        return False, msg


# ---------------------------------------------------------------------------
# Deployment endpoint
# ---------------------------------------------------------------------------

@app.post("/deploy", response_model=DeployResponse)
async def deploy(req: DeployRequest):
    """
    Orchestrate the full deployment sequence:
      1. Validate inputs (handled by Pydantic validators above).
      2. Check for an existing configuration.
      3. Write the Nginx config to sites-available.
      4. Symlink into sites-enabled.
      5. Validate with nginx -t.
      6. Reload Nginx with nginx -s reload.
    """
    steps: list[StepLog] = []
    fqdn = f"{req.subdomain_prefix}.{BASE_DOMAIN}"
    conf_name = f"{fqdn}.conf"
    available_path = SITES_AVAILABLE / conf_name
    enabled_path = SITES_ENABLED / conf_name

    # ------------------------------------------------------------------
    # Step 1: Check for existing configuration
    # ------------------------------------------------------------------
    if enabled_path.exists() or available_path.exists():
        steps.append(StepLog(
            step="existence_check",
            status="error",
            message=f"{fqdn} is already configured. Remove the existing config first if you want to reconfigure it.",
        ))
        return DeployResponse(success=False, steps=steps, fqdn=fqdn)

    steps.append(StepLog(
        step="existence_check",
        status="ok",
        message=f"No existing configuration found for {fqdn}. Proceeding.",
    ))

    # ------------------------------------------------------------------
    # Step 2: Write Nginx configuration to sites-available
    # The service user must own (or have write access to) sites-available.
    # ------------------------------------------------------------------
    config_content = _render_nginx_config(req.subdomain_prefix, req.local_port)
    try:
        available_path.write_text(config_content, encoding="utf-8")
        log.info("Wrote config: %s", available_path)
        steps.append(StepLog(
            step="write_config",
            status="ok",
            message=f"Configuration file written to {available_path}",
        ))
    except PermissionError as exc:
        steps.append(StepLog(
            step="write_config",
            status="error",
            message=f"Permission denied writing to {available_path}: {exc}",
        ))
        return DeployResponse(success=False, steps=steps)
    except OSError as exc:
        steps.append(StepLog(
            step="write_config",
            status="error",
            message=f"OS error writing config: {exc}",
        ))
        return DeployResponse(success=False, steps=steps)

    # ------------------------------------------------------------------
    # Step 3: Create symbolic link in sites-enabled
    # We call 'sudo ln -s' so the service user doesn't need write access
    # to /etc/nginx/sites-enabled directly.
    # ------------------------------------------------------------------
    ok, out = _run(
        ["ln", "-s", str(available_path), str(enabled_path)],
        steps,
        "create_symlink",
    )
    if not ok:
        # Clean up the config file we just wrote
        _cleanup(available_path, None, steps)
        return DeployResponse(success=False, steps=steps)

    steps.append(StepLog(
        step="create_symlink",
        status="ok",
        message=f"Symlink created: {enabled_path} -> {available_path}",
    ))

    # ------------------------------------------------------------------
    # Step 4: Validate the new Nginx configuration
    # ------------------------------------------------------------------
    ok, out = _run(["nginx", "-t"], steps, "nginx_test")
    if not ok:
        # Roll back: remove symlink and config file
        _cleanup(available_path, enabled_path, steps)
        return DeployResponse(success=False, steps=steps)

    steps.append(StepLog(
        step="nginx_test",
        status="ok",
        message="Nginx configuration syntax is valid.",
    ))

    # ------------------------------------------------------------------
    # Step 5: Reload Nginx to apply the new config
    # ------------------------------------------------------------------
    ok, out = _run(["nginx", "-s", "reload"], steps, "nginx_reload")
    if not ok:
        _cleanup(available_path, enabled_path, steps)
        return DeployResponse(success=False, steps=steps)

    steps.append(StepLog(
        step="nginx_reload",
        status="ok",
        message="Nginx reloaded successfully. Your app is now live.",
    ))

    log.info("Deployment complete: https://%s -> 127.0.0.1:%d", fqdn, req.local_port)
    return DeployResponse(success=True, steps=steps, fqdn=fqdn)


# ---------------------------------------------------------------------------
# Rollback helper
# ---------------------------------------------------------------------------

def _cleanup(available: Path | None, enabled: Path | None, steps: list[StepLog]):
    """
    Attempt to remove a partially-created config and its symlink.
    Logs warnings but never raises so the caller can still return a
    clean error response.
    """
    for path in (enabled, available):
        if path is None:
            continue
        try:
            if path.exists() or path.is_symlink():
                path.unlink()
                log.info("Cleaned up: %s", path)
                steps.append(StepLog(
                    step="rollback",
                    status="info",
                    message=f"Rolled back: removed {path}",
                ))
        except OSError as exc:
            log.warning("Could not remove %s during rollback: %s", path, exc)
            steps.append(StepLog(
                step="rollback",
                status="error",
                message=f"Could not remove {path}: {exc}",
            ))


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.get("/health")
async def health():
    return {"status": "ok"}
