#!/bin/bash
# Beacon OS image hook (runs inside the target chroot during the Armbian build)
set -euo pipefail

Main() {
    export DEBIAN_FRONTEND=noninteractive

    # go-irl binary + licence files placed here by the workflow via userpatches/overlay
    cp -a /tmp/overlay/. /
    chmod +x /usr/local/bin/go-irl

    echo "=== INSTALLING PACKAGES ==="
    apt-get update -y
    apt-get install -y --no-install-recommends \
        python3-pip python3-flask python3-waitress python3-psutil sudo openssl \
        ffmpeg v4l-utils git curl net-tools ca-certificates gnupg
    pip3 install --no-cache-dir obsws-python --break-system-packages

    echo "=== DASHBOARD USER + PERMISSIONS ==="
    id beacon >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin beacon
    mkdir -p /etc/beacon
    chown root:beacon /etc/beacon
    chmod 0750 /etc/beacon
    # beacon may restart exactly one service, nothing else
    echo 'beacon ALL=(root) NOPASSWD: /usr/bin/systemctl restart beacon-srtla.service' > /etc/sudoers.d/beacon
    chmod 0440 /etc/sudoers.d/beacon
    visudo -cf /etc/sudoers.d/beacon

    # Per-device token, created on first boot (never baked into the image)
    cat << 'EOFTOKEN' > /usr/local/bin/beacon-init-token.sh
#!/bin/bash
set -e
F=/etc/beacon/dashboard.token
if [ ! -s "$F" ]; then
    umask 027
    openssl rand -hex 24 > "$F"
fi
chown root:beacon "$F"
chmod 0640 "$F"
EOFTOKEN
    chmod +x /usr/local/bin/beacon-init-token.sh

    echo "=== DASHBOARD ==="
    cat << 'EOFPYTHON' > /usr/local/bin/beacon_dashboard.py
from flask import Flask, jsonify, request
import psutil, time, subprocess, threading, hmac, os

app = Flask(__name__)
TOKEN_FILE = "/etc/beacon/dashboard.token"
system_stats = {"cpu": 0.0, "ram": 0.0, "temp": None, "uptime": 0, "srtla_active": False}

def authed():
    try:
        tok = open(TOKEN_FILE).read().strip()
    except OSError:
        return False
    given = request.headers.get("Authorization", "")
    return bool(tok) and hmac.compare_digest(given, "Bearer " + tok)

def read_temp():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return int(f.read().strip()) / 1000.0
    except Exception:
        return None

def telemetry_worker():
    global system_stats
    while True:
        try:
            res = subprocess.run(["systemctl", "is-active", "beacon-srtla.service"],
                                 capture_output=True, text=True)
            system_stats = {
                "cpu": psutil.cpu_percent(interval=1.0),
                "ram": psutil.virtual_memory().percent,
                "temp": read_temp(),
                "uptime": round(time.time() - psutil.boot_time()),
                "srtla_active": res.stdout.strip() == "active",
            }
        except Exception:
            time.sleep(1.0)

threading.Thread(target=telemetry_worker, daemon=True).start()

@app.route('/api/status')
def status():
    return jsonify(system_stats)

@app.route('/api/control/<action>', methods=['POST'])
def control_action(action):
    if not authed():
        return jsonify({"status": "unauthorized"}), 401
    if action == "restart-parallel":
        subprocess.run(["sudo", "-n", "/usr/bin/systemctl", "restart", "beacon-srtla.service"])
        return jsonify({"status": "success", "message": "Engines restarted"})
    return jsonify({"status": "error"}), 400

if __name__ == '__main__':
    from waitress import serve
    # Set BEACON_BIND=127.0.0.1 (or a Tailscale IP) to restrict where it listens
    serve(app, host=os.environ.get("BEACON_BIND", "0.0.0.0"), port=5000)
EOFPYTHON
    chmod +x /usr/local/bin/beacon_dashboard.py

    echo "=== SYSTEMD SERVICES ==="
    cat << 'EOF' > /etc/systemd/system/beacon-srtla.service
[Unit]
Description=BeaconOS SRTLA Bonding Engine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=beacon
Group=beacon
NoNewPrivileges=yes
ExecStart=/usr/local/bin/go-irl -srtla-port 5000 -udp-port 5002 -srt-port 5001
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    cat << 'EOF' > /etc/systemd/system/beacon-dashboard.service
[Unit]
Description=BeaconOS Dashboard
After=network.target beacon-srtla.service

[Service]
Type=simple
User=beacon
Group=beacon
ExecStartPre=+/usr/local/bin/beacon-init-token.sh
ExecStart=/usr/bin/python3 /usr/local/bin/beacon_dashboard.py
Restart=always
RestartSec=3
# sudo needs to gain privileges, so NoNewPrivileges must stay off
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable beacon-srtla.service beacon-dashboard.service

    echo "=== TAILSCALE ==="
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list
    apt-get update -y
    apt-get install -y tailscale

    apt-get clean
    rm -rf /var/lib/apt/lists/*
    echo "=== BEACON OS BUILD COMPLETE ==="
}

Main "$@"
