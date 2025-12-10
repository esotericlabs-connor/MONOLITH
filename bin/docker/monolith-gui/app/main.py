from __future__ import annotations

import json
import socket
from pathlib import Path
from typing import Dict, Optional

from cryptography.fernet import Fernet
from fastapi import FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

APP_TITLE = "MONOLITH Portal"
DATA_DIR = Path("/data")
DATA_DIR.mkdir(parents=True, exist_ok=True)

CONFIG_PATHS: Dict[str, Path] = {
    "openvpn": DATA_DIR / "openvpn" / "client.ovpn",
    "wireguard": DATA_DIR / "wireguard" / "wg0.conf",
    "tor": DATA_DIR / "tor" / "torrc",
}

for path in CONFIG_PATHS.values():
    path.parent.mkdir(parents=True, exist_ok=True)

CREDENTIALS_PATH = DATA_DIR / "credentials.json"
STATE_PATH = DATA_DIR / "status.json"
SECRET_PATH = DATA_DIR / "secret.key"

app = FastAPI(title=APP_TITLE)
app.mount("/static", StaticFiles(directory=Path(__file__).parent / "static"), name="static")
templates = Jinja2Templates(directory=Path(__file__).parent / "templates")


def _load_or_create_secret() -> bytes:
    if SECRET_PATH.exists():
        return SECRET_PATH.read_bytes().strip()

    secret = Fernet.generate_key()
    SECRET_PATH.write_bytes(secret)
    return secret


def _fernet() -> Fernet:
    return Fernet(_load_or_create_secret())


def _load_credentials() -> Dict[str, Dict[str, str]]:
    if not CREDENTIALS_PATH.exists():
        return {}

    try:
        return json.loads(CREDENTIALS_PATH.read_text())
    except json.JSONDecodeError:
        return {}


def _save_credentials(data: Dict[str, Dict[str, str]]) -> None:
    CREDENTIALS_PATH.write_text(json.dumps(data, indent=2))


def _encrypt_value(value: str) -> str:
    if not value:
        return ""

    return _fernet().encrypt(value.encode()).decode()


def _decrypt_value(value: str) -> str:
    if not value:
        return ""

    return _fernet().decrypt(value.encode()).decode()


def _record_active_protocol(protocol: str) -> None:
    STATE_PATH.write_text(json.dumps({"active_protocol": protocol}))


def _read_state() -> Dict[str, str]:
    if not STATE_PATH.exists():
        return {}

    try:
        return json.loads(STATE_PATH.read_text())
    except json.JSONDecodeError:
        return {}


def _detect_tunnel_ip() -> Optional[str]:
    candidates = ["tun0", "wg0", "tor"]
    for candidate in candidates:
        try:
            addresses = socket.if_nameindex()
            if not any(name == candidate for _, name in addresses):
                continue

            with open(f"/sys/class/net/{candidate}/address", "r", encoding="utf-8") as handle:
                mac_address = handle.read().strip()
            return f"{candidate} ({mac_address})"
        except FileNotFoundError:
            continue
        except OSError:
            continue
    return None


def _config_status() -> Dict[str, bool]:
    return {name: path.exists() for name, path in CONFIG_PATHS.items()}


@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request) -> HTMLResponse:
    state = _read_state()
    credentials = _load_credentials()
    active_protocol = state.get("active_protocol", "Not set")
    tunnel_identity = _detect_tunnel_ip() or "Unavailable"

    return templates.TemplateResponse(
        "dashboard.html",
        {
            "request": request,
            "config_status": _config_status(),
            "active_protocol": active_protocol,
            "tunnel_identity": tunnel_identity,
            "has_credentials": {k: bool(v.get("username") or v.get("password")) for k, v in credentials.items()},
        },
    )


@app.post("/config/{protocol}")
async def update_config(
    protocol: str,
    config_text: str = Form(""),
    username: str = Form(""),
    password: str = Form(""),
    set_active: Optional[str] = Form(None),
) -> RedirectResponse:
    if protocol not in CONFIG_PATHS:
        raise HTTPException(status_code=404, detail="Unknown protocol")

    target_path = CONFIG_PATHS[protocol]
    if config_text.strip():
        target_path.write_text(config_text)

    credentials = _load_credentials()
    credentials.setdefault(protocol, {})
    if username:
        credentials[protocol]["username"] = username
    if password:
        credentials[protocol]["password"] = _encrypt_value(password)
    _save_credentials(credentials)

    if set_active:
        _record_active_protocol(protocol)

    return RedirectResponse(url="/", status_code=303)


@app.get("/health")
async def healthcheck() -> Dict[str, str]:
    return {"status": "ok"}


@app.post("/reset-state")
async def reset_state() -> RedirectResponse:
    if STATE_PATH.exists():
        STATE_PATH.unlink()
    return RedirectResponse(url="/", status_code=303)