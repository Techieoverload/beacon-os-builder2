#!/bin/bash
# Beacon OS Custom Image Hook Script

Main() {
    export DEBIAN_FRONTEND=noninteractive
    
    echo "=== INSTALLING BEACON OS PACKAGES ==="
    apt-get update -y
    apt-get install -y --no-install-recommends \
        python3-pip python3-psutil ffmpeg v4l-utils golang git curl net-tools ca-certificates gnupg

    pip3 install --no-cache-dir flask obsws-python psutil --break-system-packages

    echo "=== BUILDING GO-IRL SRTLA ENGINE ==="
    export GOPATH=/tmp/gopath
    export GOCACHE=/tmp/gocache
    git clone https://github.com/e04/go-irl.git /tmp/go-irl
    cd /tmp/go-irl && go build -o /usr/local/bin/go-irl
    rm -rf /tmp/go-irl /tmp/gopath /tmp/gocache

    echo "=== CREATING BEACON DASHBOARD SCRIPT ==="
    cat << 'EOFPYTHON' > /usr/local/bin/beacon_dashboard.py
from flask import Flask, jsonify, request
import psutil, time, subprocess, threading

app = Flask(__name__)
system_stats = {"cpu": 0.0, "ram": 0.0, "temp": 35.0, "freq": 1200, "uptime": 0, "srtla_active": False}

def telemetry_worker():
    global system_stats
    while True:
        try:
            res = subprocess.run(["systemctl", "is-active", "beacon-srtla.service"], capture_output=True, text=True)
            srtla_up = (res.stdout.strip() == "active")
            system_stats = {
                "cpu": psutil.cpu_percent(interval=1.0),
                "ram": psutil.virtual_memory().percent,
                "temp": 45.0,
                "uptime": round(time.time() - psutil.boot_time()),
                "srtla_active": srtla_up
            }
        except: time.sleep(1.0)

threading.Thread(target=telemetry_worker, daemon=True).start()

@app.route('/api/status')
def status(): return jsonify(system_stats)

@app.route('/api/control/<action>', methods=['POST'])
def control_action(action):
    if action == "restart-parallel":
        subprocess.run(["sudo", "systemctl", "restart", "beacon-srtla.service"])
        return jsonify({"status": "success", "message": "Engines restarted"})
    return jsonify({"status": "error"}), 400

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOFPYTHON
    chmod +x /usr/local/bin/beacon_dashboard.py

    echo "=== CONFIGURING SYSTEMD SERVICES ==="
    cat << 'EOF' > /etc/systemd/system/beacon-srtla.service
[Unit]
Description=BeaconOS SRTLA Bonding Engine
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/go-irl -srtla-port 5000 -udp-port 5002 -srt-port 5001
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    cat << 'EOF' > /etc/systemd/system/beacon-dashboard.service
[Unit]
Description=BeaconOS Core Dashboard Engine
After=network.target beacon-srtla.service

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/beacon_dashboard.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable beacon-srtla.service beacon-dashboard.service

    echo "=== INSTALLING TAILSCALE VPN ==="
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list
    apt-get update -y
    apt-get install -y tailscale

    echo "=== BEACON OS BUILD COMPLETE ==="
}

Main "$@"
