#!/usr/bin/env bash
set -e
trap 'echo "Error on line $LINENO"; exit 1' ERR

# — ensure root
if [[ $EUID -ne 0 ]]; then
    echo "Please run with sudo"
    exit 1
fi

# — check ethernet link
if ! ip link show eth0 | grep -qq "state UP"; then
    echo "Ethernet (eth0) is not up. Please connect via Ethernet." >&2
    exit 1
fi

# — initialize flags
FULL=false
GPSD=false
AIRCRACK=false
KISMET=false
REPEATER=false
APP=false

usage() {
    cat <<EOF
Usage: $0 [--full|-f] [--gpsd|-g] [--aircrack|-a] [--kismet|-k] [--repeater|-r] [--app|-p]
  --full,      -f   full install (all modules)
  --gpsd,      -g   gpsd
  --aircrack,  -a   aircrack-ng
  --kismet,    -k   kismet
  --repeater,  -r   repeater + captive-portal
  --app,       -p   wifi_audit_tool application
  --help,      -h   show this help message
EOF
    exit 1
}

# — parse short and long options via getopt
PARSED=$(getopt --options fgakrph --long full,gpsd,aircrack,kismet,repeater,app,help --name "$0" -- "$@")
if [[ $? -ne 0 ]]; then
    usage
fi
eval set -- "$PARSED"

while true; do
    case "$1" in
        -f|--full)
            FULL=true; shift ;;
        -g|--gpsd)
            GPSD=true; shift ;;
        -a|--aircrack)
            AIRCRACK=true; shift ;;
        -k|--kismet)
            KISMET=true; shift ;;
        -r|--repeater)
            REPEATER=true; shift ;;
        -p|--app)
            APP=true; shift ;;
		-h|--help)
            usage ;;
        --)
            shift; break ;;
        *)
            usage ;;
    esac
done

if $FULL; then
    GPSD=true
    AIRCRACK=true
    KISMET=true
    REPEATER=true
    APP=true
fi

if ! $GPSD && ! $AIRCRACK && ! $KISMET && ! $REPEATER && ! $APP; then
    usage
fi

# — prompt for credentials
if $KISMET || $FULL || $REPEATER || $APP; then
    read -p "Enter username for app user: " USER_GLOBAL
    read -s -p "Enter password for app user: " PASS_GLOBAL
    echo
fi

if $REPEATER || $FULL; then
    read -p "Enter custom AP SSID: " AP_SSID
    read -s -p "Enter custom AP WPA passphrase: " AP_PASS
    echo
    read -p "Enter external Wi-Fi SSID to join: " EXT_SSID
    read -s -p "Enter external Wi-Fi passphrase: " EXT_PASS
    echo
fi

echo "Updating package lists..."
apt update -y -qq
apt upgrade -y -qq
apt autoremove -y -qq

# —— MODULE: GPSD
if $GPSD; then
    echo "Installing GPSD..."
    apt install -y -qq gpsd

    # auto-detect device
    if [[ -e /dev/ttyACM0 ]]; then
        DEV="/dev/ttyACM0"
    elif [[ -e /dev/ttyACM1 ]]; then
        DEV="/dev/ttyACM1"
    else
        echo "No GPS device (/dev/ttyACM0 or /dev/ttyACM1) found." >&2
        exit 1
    fi

    cat > /etc/default/gpsd <<EOF
DEVICES="$DEV"
GPSD_OPTIONS="-n -G -b"
USBAUTO="true"
EOF

    echo "GPSD configured for $DEV"
fi

# —— MODULE: Aircrack-ng
 if $AIRCRACK; then
    echo "Installing aircrack-ng..."
    apt install -qq -y aircrack-ng
    echo "Downloading rockyou.txt wordlist (zip)..."
    apt install -qq -y unzip
    mkdir -p /usr/share/wordlists
    if [[ ! -f /usr/share/wordlists/rockyou.txt ]]; then
        wget -qO /tmp/rockyou.zip https://github.com/kkrypt0nn/wordlists/raw/refs/heads/main/wordlists/famous/rockyou.zip
        unzip -p /tmp/rockyou.zip rockyou.txt > /usr/share/wordlists/rockyou.txt
        rm /tmp/rockyou.zip
    fi
 fi

# —— MODULE: Kismet
if $KISMET; then
    echo "Installing Kismet dependencies..."
    apt install -y -qq build-essential git libwebsockets-dev pkg-config \
        zlib1g-dev libnl-3-dev libnl-genl-3-dev libcap-dev libpcap-dev \
        libnm-dev libdw-dev libsqlite3-dev libprotobuf-dev libprotobuf-c-dev \
        protobuf-compiler protobuf-c-compiler libsensors4-dev libusb-1.0-0-dev \
        python3 python3-setuptools python3-protobuf python3-requests \
        python3-numpy python3-serial python3-usb python3-dev python3-websockets \
        librtlsdr0 libubertooth-dev libbtbb-dev libmosquitto-dev librtlsdr-dev

    BASE="/opt/kismet"
    GITDIR="$BASE/kismet_github"
    INSTDIR="$BASE/kismet_install"
    mkdir -p "$BASE"

    if [[ ! -d "$GITDIR" ]]; then
        echo "Cloning Kismet..."
        git clone --recursive https://github.com/kismetwireless/kismet.git "$GITDIR"
    else
        echo "Updating Kismet repo..."
        cd "$GITDIR" && git pull
    fi

    rm -rf "$INSTDIR"
    cp -r "$GITDIR" "$INSTDIR"
    cd "$INSTDIR"

    echo "Configuring Kismet..."
    ./configure

    # compile with up to 4 cores
    PROC=$(nproc --ignore=1)
    (( PROC<1 )) && PROC=1
    (( PROC>4 )) && PROC=4
    echo "Building Kismet (-j$PROC)"
    make -j"$PROC" --silent

    echo "Installing Kismet (suid)..."
    make suidinstall

    usermod -aG kismet "${SUDO_USER:-$USER}"

    # configure confs if gpsd is running
    if pgrep -x gpsd &>/dev/null; then
        echo "Writing Kismet GPS site config..."
        cat > /usr/local/etc/kismet_site.conf <<EOF
gps=gpsd:host=localhost,port=2947
EOF
        chmod 644 /usr/local/etc/kismet_site.conf

        echo "Appending Kismet logging prefs..."
        {
            echo "kis_log_data_packets=false"
            echo "kis_log_duplicate_packets=false"
        } >> /usr/local/etc/kismet_logging.conf

        echo "Appending Kismet HTTPd credentials..."
        {
            echo "httpd_username=$USER_GLOBAL"
            echo "httpd_password=$PASS_GLOBAL"
        } >> /usr/local/etc/kismet_httpd.conf
    else
        echo "gpsd not running; skipping Kismet GPS config"
    fi
fi

# —— MODULE: Repeater + Captive-Portal
if $REPEATER; then
    echo "Removing classic networking stacks..."
    systemctl daemon-reload
    systemctl disable --now ifupdown dhcpcd dhcpcd5 isc-dhcp-client isc-dhcp-common rsyslog
    apt --autoremove -y purge ifupdown dhcpcd dhcpcd5 isc-dhcp-client isc-dhcp-common rsyslog
    rm -rf /etc/network /etc/dhcp
    apt remove --purge -y network-manager

    echo "Enabling systemd-networkd + resolved..."
    systemctl disable --now avahi-daemon libnss-mdns
    apt --autoremove -y purge avahi-daemon
    apt install -y -qq libnss-resolve
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    apt-mark hold avahi-daemon dhcpcd dhcpcd5 ifupdown isc-dhcp-client isc-dhcp-common libnss-mdns openresolv raspberrypi-net-mods rsyslog
    systemctl enable systemd-networkd.service systemd-resolved.service

    echo "Installing hostapd..."
    apt install -y -qq hostapd

    cat > /etc/hostapd/hostapd.conf <<EOF
driver=nl80211
ssid=$AP_SSID
country_code=SK
hw_mode=g
channel=1
auth_algs=1
wpa=2
wpa_passphrase=$AP_PASS
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF
    chmod 600 /etc/hostapd/hostapd.conf

    echo "Creating accesspoint@.service..."
    cat > /etc/systemd/system/accesspoint@.service <<EOF
[Unit]
Description=accesspoint with hostapd (interface-specific version)
Wants=wpa_supplicant@%i.service

[Service]
ExecStartPre=/sbin/iw dev %i interface add ap@%i type __ap
ExecStart=/usr/sbin/hostapd -i ap@%i /etc/hostapd/hostapd.conf
ExecStopPost=-/sbin/iw dev ap@%i del

[Install]
WantedBy=sys-subsystem-net-devices-%i.device
EOF

    systemctl daemon-reload
    systemctl enable --now accesspoint@wlan0.service

    echo "Configuring wpa_supplicant for external Wi-Fi..."
    cat > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf <<EOF
country=SK
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="$EXT_SSID"
    psk="$EXT_PASS"
    key_mgmt=WPA-PSK
}
EOF
    chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
    systemctl disable wpa_supplicant.service

    mkdir -p /etc/systemd/system/wpa_supplicant@wlan0.service.d
    cat > /etc/systemd/system/wpa_supplicant@wlan0.service.d/override.conf <<EOF
[Unit]
BindsTo=accesspoint@%i.service
After=accesspoint@%i.service
EOF
    systemctl daemon-reload
    systemctl enable --now wpa_supplicant@wlan0.service

    echo "Writing systemd-networkd .network files..."
    cat > /etc/systemd/network/08-wifi.network <<EOF
[Match]
Name=wlan*
[Network]
LLMNR=no
MulticastDNS=yes
DHCP=yes
EOF

    cat > /etc/systemd/network/12-ap.network <<EOF
[Match]
Name=ap@*
[Network]
LLMNR=no
MulticastDNS=yes
IPMasquerade=yes
Address=192.168.4.1/24
DHCPServer=yes
[DHCPServer]
DNS=8.8.8.8 1.1.1.1
EOF

    cat > /etc/systemd/network/eth0.network <<EOF
[Match]
Name=eth0

[Network]
DHCP=yes
EOF
    systemctl daemon-reload

    echo "Installing Nodogsplash (captive portal)..."
    apt install -y git libmicrohttpd-dev build-essential
    mkdir -p /opt/nodogsplash
    cd /opt/nodogsplash

    if [[ ! -d nodogsplash ]]; then
        git clone https://github.com/nodogsplash/nodogsplash.git
    fi

    cd nodogsplash
    make && make install

    cat > /etc/nodogsplash/nodogsplash.conf <<EOF
GatewayInterface ap@wlan0
FirewallRuleSet authenticated-users {
}
FirewallRuleSet preauthenticated-users {
}
FirewallRuleSet users-to-router {
}
GatewayAddress 192.168.4.1
MaxClients 250
AuthIdleTimeout 480
RedirectURL http://192.168.4.1
BinAuth /usr/bin/nds-binauth.sh

EmptyRuleSetPolicy authenticated-users allow
EmptyRuleSetPolicy preauthenticated-users allow
EmptyRuleSetPolicy users-to-router allow
EmptyRuleSetPolicy trusted-users allow
EmptyRuleSetPolicy trusted-users-to-router allow
EOF

    cat > /usr/bin/nds-binauth.sh <<'EOF'
#!/bin/bash
EVENT="$1"
CLIENT_MAC="$2"
ENTERED_SSID="$3"
ENTERED_PASSWORD="$4"

if [ "$EVENT" = "auth_client" ]; then
    if [ "$ENTERED_SSID" = "skip_wifi_change" ]; then
        echo 0 0 0
        exit 0
    else
        cat <<EOCONF > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
country=SK
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="$ENTERED_SSID"
    psk="$ENTERED_PASSWORD"
    key_mgmt=WPA-PSK
}
EOCONF
        echo 0 0 0
        systemctl restart accesspoint@wlan0.service
        systemctl restart wpa_supplicant@wlan0.service
        exit 0
    fi
fi
EOF
    chmod +x /usr/bin/nds-binauth.sh
    mkdir -p /etc/nodogsplash/htdocs
    cat > /etc/nodogsplash/htdocs/splash.html <<EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Set Wi-Fi</title>
</head>
<body>
    <h2>Enter Wi-Fi Credentials</h2>
    <form method="GET" action='$authaction'>
        <input type='hidden' name='tok' value='$tok'>
        <input type='hidden' name='redir' value='$redir'>
        <label>SSID:</label>
        <input type="text" name="username" placeholder="SSID" /><br><br>
        <label>Wi-Fi Password:</label>
        <input type="password" name="password" placeholder="Password" /><br><br>
        <input type="submit" value="Connect" />
    </form>
    <form method="GET" action='$authaction'>
        <input type='hidden' name='tok' value='$tok'>
        <input type='hidden' name='redir' value='$redir'>
        <input type="hidden" name="username" value="skip_wifi_change">
        <input type="submit" value="Connect without wifi change" />
    </form>
</body>
</html>
EOF

    cat > /etc/systemd/system/nodogsplash.service <<EOF
[Unit]
Description=Nodogsplash Captive Portal
After=network.target

[Service]
ExecStart=/usr/bin/nodogsplash -f
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now nodogsplash.service

    cat > /etc/rc.local <<EOF
#!/bin/bash
iwconfig wlan0 power off
iwconfig wlan1 power off
iwconfig wlan2 power off
rfkill unblock all
exit 0
EOF
    chmod +x /etc/rc.local
fi

# —— MODULE: wifi_audit_tool Application
if $APP; then
    # assume script is run from inside app directory
    APP_DIR="$(cd "$(dirname "$0")" && pwd)"

    # preinstall Python and venv
    echo "Installing Python prerequisites..."
    apt install -y python3 python3-pip python3-venv

    # set up virtual environment
    echo "Creating virtual environment..."
    python3 -m venv "$APP_DIR/venv"
    "$APP_DIR/venv/bin/pip" install --upgrade pip

    # install required Python packages
    echo "Installing Python packages..."
    "$APP_DIR/venv/bin/pip" install aiohttp certifi colorama cryptography docutils geographiclib \
        geopy haversine IPython jinja2 keyring numba numpy pandas Pillow psutil pytest python-nmap \
        pytz redis requests requests-oauthlib scipy setuptools tqdm urllib3 wheel wmi yarl python-dotenv \
        flask flask-terminal

    # write .env
    cat > "$APP_DIR/.env" <<EOF
USERS=$USER_GLOBAL:$PASS_GLOBAL
KISMET_USER=$USER_GLOBAL
KISMET_PASS=$PASS_GLOBAL
EOF

    # install and enable systemd service
    cat > /etc/systemd/system/wifi_audit_tool.service <<EOF
[Unit]
Description=Wifi Audit Tool Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python app.py
ExecStop=/bin/kill -SIGINT \$MAINPID
Restart=on-failure
TimeoutStopSec=10
StandardOutput=append:/var/log/wifi_audit_tool.log
StandardError=append:/var/log/wifi_audit_tool.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now wifi_audit_tool.service
fi

# change ownership of app directory
chown -R "$SUDO_USER:$SUDO_USER" "$APP_DIR"
chmod -R 755 "$APP_DIR"

# update system - some packages may missing after installation
echo "Updating system packages..."
apt update -y -qq
apt upgrade -y -qq
apt autoremove -y -qq

read -p "Reboot required. Do you want to reboot now? (y/n): " REBOOT
if [[ $REBOOT =~ ^[Yy]$ ]]; then
    echo "Rebooting..."
    reboot
else
    echo "Installation complete. Please reboot the system to apply changes."
fi