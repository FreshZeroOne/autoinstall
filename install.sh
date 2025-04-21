#!/bin/bash

set -e

echo "🛠  Starte RAM-VPN Auto-Installer für Ubuntu 22.04"

# IPv6 deaktivieren
echo "➡️  Deaktiviere IPv6..."
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
echo 'net.ipv6.conf.all.disable_ipv6 = 1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.default.disable_ipv6 = 1' >> /etc/sysctl.conf

# Abhängigkeiten installieren
echo "➡️  Installiere Abhängigkeiten..."
apt update && apt install -y docker.io docker-compose curl mysql-client iptables

# Arbeitsverzeichnis
mkdir -p /opt/ram-vpn && cd /opt/ram-vpn

# Benutzer nach Proxy fragen
read -p "🔐 Möchtest du einen Proxy verwenden? (y/n): " USE_PROXY

if [ "$USE_PROXY" == "y" ]; then
    read -p "Proxy IP: " PROXY_IP
    read -p "Proxy Port: " PROXY_PORT
    read -p "Proxy-Typ (socks5/http): " PROXY_TYPE
    read -p "Proxy Benutzername: " PROXY_USER
    read -p "Proxy Passwort: " PROXY_PASS

    echo "➡️  Erstelle redsocks.conf..."
    cat <<EOF > redsocks.conf
base {
 log_debug = on;
 log_info = on;
 log = "file:/var/log/redsocks.log";
 daemon = on;
 redirector = iptables;
}
redsocks {
 local_ip = 127.0.0.1;
 local_port = 12345;
 type = $PROXY_TYPE;
 ip = $PROXY_IP;
 port = $PROXY_PORT;
 login = "$PROXY_USER";
 password = "$PROXY_PASS";
}
EOF

    echo "➡️  Installiere redsocks..."
    apt install -y redsocks
    cp redsocks.conf /etc/redsocks.conf
    systemctl restart redsocks || nohup redsocks -c /etc/redsocks.conf &

    echo "➡️  Leite Traffic vom WireGuard über redsocks um..."
    iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner 65534 -j REDIRECT --to-ports 12345
fi

# Docker-Setup
echo "➡️  Erstelle docker-compose.yml..."
cat <<EOF > docker-compose.yml
version: '3'

services:
  wg-easy:
    image: weejewel/wg-easy
    container_name: wg-easy
    environment:
      - WG_HOST=auto
      - PASSWORD=changeme
      - WG_PORT=443
      - WG_MTU=1380
      - WG_IPV6=false
      - WG_DEFAULT_DNS=10.8.0.2
    ports:
      - "443:51820/udp"
      - "51821:51821/tcp"
    volumes:
      - ./wg-easy:/etc/wireguard
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=1
      - net.ipv6.conf.default.disable_ipv6=1
    restart: unless-stopped

  pihole:
    image: pihole/pihole
    container_name: pihole
    environment:
      - ServerIP=127.0.0.1
      - DNS1=1.1.1.1
      - DNS2=1.0.0.1
      - WEBPASSWORD=changeme
    volumes:
      - ./pihole/etc-pihole:/etc/pihole
      - ./pihole/etc-dnsmasq.d:/etc/dnsmasq.d
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80/tcp"
    restart: unless-stopped
EOF

echo "➡️  Starte Docker-Container..."
docker compose up -d

# Load Script
echo "➡️  Erstelle Load-Update-Script..."
cat <<'EOF' > update_load.sh
#!/bin/bash
LOAD=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d',' -f1 | xargs)
IP=$(curl -s ifconfig.me)
mysql -h85.215.238.89 -P3306 -uapi_user -pweilisso001 api_db -e "UPDATE servers SET load=${LOAD} WHERE domain='${IP}';"
EOF
chmod +x update_load.sh

# Cronjob hinzufügen
(crontab -l 2>/dev/null; echo "* * * * * /opt/ram-vpn/update_load.sh") | crontab -

echo "✅ Installation abgeschlossen! WireGuard & Pi-hole laufen nun."
