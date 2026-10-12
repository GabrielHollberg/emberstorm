"""The signing helper: hands releases waiting on this PC to EmberStorm Signer
on the developer's phone, over Tailscale only, and keeps the signatures that
come back (android/signer/README.md).

    py scripts\\signing-helper.py [FOLDER]

FOLDER (default: emberstorm-signing on the Desktop) holds a folder per
release waiting - its manifest.json (box/release.sh) or desktop.json
(scripts/desktop-release.sh). The phone reads it, the YubiKey signs those very
bytes, and the signature comes back as <file>.sig, as box/yubikey.py writes
it, kept only once it checks against the release keys (box/release.pub).

Only over Tailscale, the developer's own private network: it listens on this
PC's Tailscale address alone, refuses anything not from a Tailscale address,
and the Windows firewall rule for it (made once, by hand) admits port 8098 on
the Tailscale adapter only. Nothing on the internet or the home Wi-Fi can
reach it, the release never sits on the internet-facing EmberStorm server,
and Tailscale encrypts everything between the phone and the PC. It runs only
while there is something to sign: Ctrl-C, or it stops by itself once
everything waiting is signed.
"""
import base64
import ipaddress
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

PORT = 8098
HERE = os.path.dirname(os.path.abspath(__file__))
TAILNET = ipaddress.ip_network("100.64.0.0/10")
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
FILES = ("manifest.json", "desktop.json")


def release_keys():
    keys = []
    with open(os.path.join(HERE, "..", "box", "release.pub"), encoding="ascii") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                keys.append(Ed25519PublicKey.from_public_bytes(base64.b64decode(line)))
    if not keys:
        sys.exit("No release keys in box/release.pub.")
    return keys


def tailscale_ip():
    exe = os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "Tailscale", "tailscale.exe")
    try:
        out = subprocess.run([exe, "ip", "-4"], capture_output=True, text=True, timeout=10).stdout.split()
    except OSError:
        sys.exit("Tailscale is not installed on this PC.")
    for word in out:
        try:
            if ipaddress.ip_address(word) in TAILNET:
                return word
        except ValueError:
            pass
    sys.exit("Tailscale is not connected on this PC: turn it on, then run this again.")


def release_file(folder):
    for name in FILES:
        path = os.path.join(folder, name)
        if os.path.isfile(path) and os.path.getsize(path) <= 1 << 20:
            return name
    return None


def waiting(root):
    items = []
    for name in sorted(os.listdir(root)):
        folder = os.path.join(root, name)
        if not NAME.match(name) or not os.path.isdir(folder):
            continue
        file = release_file(folder)
        if not file or os.path.exists(os.path.join(folder, file + ".sig")):
            continue
        with open(os.path.join(folder, file), "rb") as f:
            items.append({"name": name, "file": file, "data": base64.b64encode(f.read()).decode()})
    return items


def make_handler(root, keys):
    class Handler(BaseHTTPRequestHandler):
        server_version = "EmberStormSigning"

        def answer(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def from_tailnet(self):
            try:
                return ipaddress.ip_address(self.client_address[0]) in TAILNET
            except ValueError:
                return False

        def do_GET(self):
            if not self.from_tailnet():
                return self.answer(403, {"error": "Only over Tailscale."})
            if self.path != "/api/signing":
                return self.answer(404, {"error": "not here"})
            self.answer(200, {"items": waiting(root)})

        def do_PUT(self):
            if not self.from_tailnet():
                return self.answer(403, {"error": "Only over Tailscale."})
            m = re.fullmatch(r"/api/signing/([A-Za-z0-9][A-Za-z0-9._-]{0,63})", self.path)
            if not m:
                return self.answer(404, {"error": "not here"})
            folder = os.path.join(root, m.group(1))
            file = release_file(folder) if os.path.isdir(folder) else None
            if not file:
                return self.answer(404, {"error": "No such release."})
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > 4096:
                return self.answer(400, {"error": "Expected a signature."})
            try:
                sig = base64.b64decode(json.loads(self.rfile.read(length))["signature"], validate=True)
            except (ValueError, KeyError, TypeError):
                return self.answer(400, {"error": "That is not a signature."})
            with open(os.path.join(folder, file), "rb") as f:
                data = f.read()
            for key in keys:
                try:
                    key.verify(sig, data)
                    break
                except InvalidSignature:
                    continue
            else:
                return self.answer(400, {"error": "The signature does not match EmberStorm's release keys - was it the right YubiKey?"})
            with open(os.path.join(folder, file + ".sig"), "w", encoding="ascii", newline="\n") as f:
                f.write(base64.b64encode(sig).decode() + "\n")
            print(f"Signed: {m.group(1)}/{file}", flush=True)
            self.answer(200, {"signed": True})
            if not waiting(root):
                print("Everything waiting is signed - stopping.", flush=True)
                self.server.shutdown_after = True

        def log_message(self, fmt, *args):
            print(f"{self.client_address[0]} {fmt % args}", flush=True)

    return Handler


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.expanduser("~"), "Desktop", "emberstorm-signing")
    os.makedirs(root, exist_ok=True)
    keys = release_keys()
    ip = tailscale_ip()
    items = waiting(root)
    if not items:
        sys.exit(f"Nothing waiting to be signed in {root}.")
    server = ThreadingHTTPServer((ip, PORT), make_handler(root, keys))
    server.shutdown_after = False
    print(f"Waiting for EmberStorm Signer on {ip}:{PORT} (Tailscale only): {', '.join(i['name'] for i in items)}", flush=True)
    try:
        while not server.shutdown_after:
            server.handle_request()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
