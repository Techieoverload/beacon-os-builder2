#!/bin/bash
# Beacon OS Custom Image Hook Script

Main() {
    export DEBIAN_FRONTEND=noninteractive

    echo "=== 1. PRE-CONFIGURING CREDENTIALS (BYPASS FIRST-BOOT WIZARD) ==="
    echo "root:beacon" | chpasswd
    rm -f /root/.not_logged_in_yet
    # Permit root login over SSH with password
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config || true

    echo "=== 2. INSTALLING SYSTEM PACKAGES ==="
    apt-get update -y
    apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        net-tools \
        ffmpeg \
        v4l-utils \
        python3-pip \
        python3-psutil

    echo "=== 3. INSTALLING PYTHON DEPENDENCIES & CORS ==="
    pip3 install --no-cache-dir flask flask-cors obsws-python psutil --break-system-packages

    echo "=== 4. CONFIGURING PERMISSIONS FOR PREBUILT GO-IRL ==="
    if [ -f /usr/local/bin/go-irl ]; then
        chmod +x /usr/local/bin/go-irl
    fi

    echo "=== 5. CREATING BEACON DASHBOARD SCRIPT ==="
    cat << 'EOFPYTHON' > /usr/local/bin/beacon_dashboard.py
from flask import Flask, jsonify, request
from flask_cors import CORS
import psutil, time, subprocess, threading

app = Flask(__name__)
CORS(app)

system_stats = {
    "cpu": 0.0,
    "ram": 0.0,
    "temp": 0.0,
    "uptime": 0,
    "srtla_active": False
}

def get_soc_temp():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
            return round(int(f.read().strip()) / 1000.0, 1)
    except Exception:
        return 0.0

def telemetry_worker():
    global system_stats
    while True:
        try:
            res = subprocess.run(["systemctl", "is-active", "beacon-srtla.service"], capture_output=True, text=True)
            srtla_up = (res.stdout.strip() == "active")
            system_stats = {
                "cpu": psutil.cpu_percent(interval=1.0),
                "ram": psutil.virtual_memory().percent,
                "temp": get_soc_temp(),
                "uptime": round(time.time() - psutil.boot_time()),
                "srtla_active": srtla_up
            }
        except Exception:
            time.sleep(1.0)

threading.Thread(target=telemetry_worker, daemon=True).start()

@app.route('/api/status')
def status():
    return jsonify(system_stats)

@app.route('/api/control/<action>', methods=['POST'])
def control_action(action):
    if action == "restart-parallel":
        subprocess.run(["systemctl", "restart", "beacon-srtla.service"])
        return jsonify({"status": "success", "message": "Engines restarted"})
    return jsonify({"status": "error"}), 400

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
EOFPYTHON
    chmod +x /usr/local/bin/beacon_dashboard.py

    echo "=== 6. CONFIGURING SYSTEMD SERVICES ==="
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

    systemctl enable beacon-dashboard.service

    echo "=== 7. INSTALLING TAILSCALE VPN ==="
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list
    apt-get update -y
    apt-get install -y --no-install-recommends tailscale
    systemctl enable tailscaled

    echo "=== BEACON OS BUILD COMPLETE ==="
}

Main "$@"
