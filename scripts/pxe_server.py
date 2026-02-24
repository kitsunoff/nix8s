#!/usr/bin/env python3
"""nix8s PXE HTTP server with discovery API."""

import http.server
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

ASSETS_DIR = os.environ.get("ASSETS_DIR", ".")
NODES_DIR = os.environ.get("NODES_DIR", "./nix8s/nodes")


def mac_to_filename(mac: str) -> str:
    """Convert MAC address to valid filename: aa:bb:cc:dd:ee:ff -> aabbccddeeff.nix"""
    return re.sub(r"[:-]", "", mac.lower()) + ".nix"


def generate_node_nix(data: dict) -> str:
    """Generate Nix node file content with hardware info in comments."""
    mac = data.get("mac", "unknown")
    ip = data.get("ip", "unknown")
    cpu = data.get("cpu", {})
    memory_gb = data.get("memory_gb", 0)
    disks = data.get("disks", [])
    system = data.get("system", {})
    discovered_at = data.get("discovered_at", "unknown")

    # Format disks info
    disk_lines = []
    for disk in disks:
        name = disk.get("name", "?")
        size = disk.get("size", "?")
        model = disk.get("model", "").strip() if disk.get("model") else ""
        disk_lines.append(
            f"#   /dev/{name}: {size}" + (f" ({model})" if model else "")
        )

    disks_str = "\n".join(disk_lines) if disk_lines else "#   (no disks found)"
    first_disk = disks[0].get("name", "sda") if disks else "sda"
    node_name = mac_to_filename(mac)[:-4]

    return f'''# Discovered node: {mac}
# Discovered at: {discovered_at}
#
# Hardware:
#   CPU: {cpu.get("model", "unknown")} ({cpu.get("cores", "?")} cores)
#   Memory: {memory_gb} GB
#   System: {system.get("vendor", "")} {system.get("product", "")}
#   Serial: {system.get("serial", "")}
#
# Network:
#   MAC: {mac}
#   IP: {ip} (at discovery time)
#
# Disks:
{disks_str}
#
{{ ... }}:

{{
  nix8s.nodes."{node_name}" = {{
    network.mac = "{mac}";
    install.disk = "/dev/{first_disk}";
  }};
}}
'''


def list_discovered_nodes() -> dict:
    """List all discovered nodes from nix8s/nodes/*.nix files."""
    nodes = {}
    nodes_path = Path(NODES_DIR)
    if not nodes_path.exists():
        return nodes

    for nix_file in nodes_path.glob("*.nix"):
        # Skip non-MAC-address files (like standard.nix)
        if not re.match(r"^[0-9a-f]{12}\.nix$", nix_file.name):
            continue

        content = nix_file.read_text()
        # Extract MAC from comment
        mac_match = re.search(r"# Discovered node: ([0-9a-f:]+)", content)
        if mac_match:
            mac = mac_match.group(1)
            nodes[mac] = {"file": str(nix_file), "mac": mac}

    return nodes


class PXEHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP handler for PXE assets and discovery API."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ASSETS_DIR, **kwargs)

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/api/nodes":
            self.send_json(list_discovered_nodes())
        elif parsed.path.startswith("/api/nodes/"):
            mac = parsed.path.split("/")[-1].lower().replace("-", ":")
            nodes = list_discovered_nodes()
            if mac in nodes:
                self.send_json(nodes[mac])
            else:
                self.send_error(404, f"Node {mac} not found")
        else:
            super().do_GET()

    def do_POST(self):
        if self.path == "/api/discover":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length)
            try:
                data = json.loads(body)
                mac = data.get("mac", "").lower()
                if not mac:
                    self.send_error(400, "Missing MAC address")
                    return

                # Create nodes directory if needed
                nodes_path = Path(NODES_DIR)
                nodes_path.mkdir(parents=True, exist_ok=True)

                # Write node file
                filename = mac_to_filename(mac)
                filepath = nodes_path / filename
                nix_content = generate_node_nix(data)
                filepath.write_text(nix_content)

                print(f"\n{'='*50}")
                print(f"NEW NODE DISCOVERED: {mac}")
                print(f"IP: {data.get('ip', 'unknown')}")
                print(f"CPU: {data.get('cpu', {}).get('model', 'unknown')}")
                print(f"Memory: {data.get('memory_gb', 'unknown')} GB")
                print(f"Disks: {len(data.get('disks', []))}")
                print()
                print(f"Created: {filepath}")
                print(f"{'='*50}\n")

                self.send_json({"status": "ok", "mac": mac, "file": str(filepath)})
            except json.JSONDecodeError:
                self.send_error(400, "Invalid JSON")
        else:
            self.send_error(404, "Not found")

    def send_json(self, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    server = http.server.HTTPServer(("0.0.0.0", port), PXEHandler)
    print(f"PXE HTTP server listening on port {port}")
    print(f"Assets directory: {ASSETS_DIR}")
    print(f"Nodes directory: {NODES_DIR}")
    print()
    print("API endpoints:")
    print("  GET  /api/nodes         - List all discovered nodes")
    print("  GET  /api/nodes/<mac>   - Get specific node")
    print("  POST /api/discover      - Register discovered node")
    print()
    server.serve_forever()


if __name__ == "__main__":
    main()
