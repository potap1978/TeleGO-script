#!/bin/bash

# TeleGO Management Script
# Author: Based on TeleGO documentation
# Version: 1.0

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration paths
TELEGO_BIN="/usr/local/bin/telego"
TELEGO_CONFIG="/etc/telego/config.toml"
TELEGO_SERVICE="/etc/systemd/system/telego.service"
TELEGO_DATA_DIR="/var/lib/telego"
TELEGO_LOG_DIR="/var/log/telego"

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_header() {
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   $1${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root!"
        exit 1
    fi
}

# Check if TeleGO is installed
is_installed() {
    [[ -f "$TELEGO_BIN" ]]
}

# Get server IP
get_server_ip() {
    local ip=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || curl -s -4 ipinfo.io/ip)
    echo "$ip"
}

# Generate secret for a user
generate_secret() {
    local sni="$1"
    local secret_output=$(telego generate "$sni" 2>/dev/null)
    local secret=$(echo "$secret_output" | grep -oP 'secret=\K[0-9a-f]+' | head -1)
    local link=$(echo "$secret_output" | grep -oP 'link=\K.*' | head -1)
    echo "$secret|$link"
}

# Stop TeleGO service
stop_service() {
    if systemctl is-active --quiet telego; then
        systemctl stop telego
        print_status "TeleGO service stopped"
    fi
}

# Start TeleGO service
start_service() {
    systemctl start telego
    print_status "TeleGO service started"
}

# Restart TeleGO service
restart_service() {
    systemctl restart telego
    print_status "TeleGO service restarted"
}

# Install TeleGO
install_telego() {
    print_header "Installing TeleGO"
    
    if is_installed; then
        print_warning "TeleGO is already installed"
        read -p "Do you want to reinstall? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
        remove_telego
    fi
    
    print_status "Installing dependencies..."
    apt-get update -qq
    apt-get install -y -qq wget curl make git build-essential
    
    print_status "Downloading latest TeleGO..."
    cd /tmp
    LATEST_VERSION=$(curl -s https://api.github.com/repos/Scratch-net/telego/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
    wget -q "https://github.com/Scratch-net/telego/releases/download/${LATEST_VERSION}/telego_${LATEST_VERSION}_linux_amd64.tar.gz"
    tar -xzf "telego_${LATEST_VERSION}_linux_amd64.tar.gz"
    mv telego "$TELEGO_BIN"
    chmod +x "$TELEGO_BIN"
    
    print_status "Creating directories..."
    mkdir -p "$(dirname "$TELEGO_CONFIG")" "$TELEGO_DATA_DIR" "$TELEGO_LOG_DIR"
    
    print_status "Creating systemd service..."
    cat > "$TELEGO_SERVICE" <<EOF
[Unit]
Description=TeleGO MTProxy Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$TELEGO_BIN run -c $TELEGO_CONFIG
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    
    print_success "TeleGO installed successfully"
}

# Remove TeleGO completely
remove_telego() {
    print_header "Removing TeleGO"
    
    if is_installed; then
        print_status "Stopping service..."
        systemctl stop telego 2>/dev/null || true
        systemctl disable telego 2>/dev/null || true
        
        print_status "Removing files..."
        rm -f "$TELEGO_BIN"
        rm -f "$TELEGO_SERVICE"
        rm -rf "$(dirname "$TELEGO_CONFIG")"
        rm -rf "$TELEGO_DATA_DIR"
        rm -rf "$TELEGO_LOG_DIR"
        
        systemctl daemon-reload
        
        print_success "TeleGO removed completely"
    else
        print_warning "TeleGO is not installed"
    fi
}

# Create configuration
create_config() {
    local port="$1"
    local mask_host="$2"
    
    print_status "Creating configuration..."
    
    cat > "$TELEGO_CONFIG" <<EOF
[general]
bind-to = "0.0.0.0:$port"
log-level = "info"

[tls-fronting]
mask-host = "$mask_host"
mask-port = 443

[performance]
idle-timeout = "5m"
num-event-loops = 0

[metrics]
# bind-to = "127.0.0.1:9090"  # Uncomment to enable metrics
EOF
    
    print_success "Configuration created at $TELEGO_CONFIG"
}

# Add user to config
add_user() {
    local username="$1"
    local secret="$2"
    
    if ! is_installed; then
        print_error "TeleGO is not installed. Please install first."
        return 1
    fi
    
    print_header "Adding User: $username"
    
    # Get SNI from user
    read -p "Enter SNI (domain for TLS fronting, e.g., www.google.com): " sni
    if [[ -z "$sni" ]]; then
        sni="www.google.com"
    fi
    
    print_status "Generating secret for $sni..."
    local result=$(generate_secret "$sni")
    local secret=$(echo "$result" | cut -d'|' -f1)
    local link=$(echo "$result" | cut -d'|' -f2)
    
    if [[ -z "$secret" ]]; then
        print_error "Failed to generate secret"
        return 1
    fi
    
    # Add to config
    if grep -q "^\[secrets\]" "$TELEGO_CONFIG"; then
        sed -i "/^\[secrets\]/a $username = \"$secret\"" "$TELEGO_CONFIG"
    else
        echo -e "\n[secrets]" >> "$TELEGO_CONFIG"
        echo "$username = \"$secret\"" >> "$TELEGO_CONFIG"
    fi
    
    # Get server IP and port
    local server_ip=$(get_server_ip)
    local port=$(grep "bind-to" "$TELEGO_CONFIG" | grep -oP ':\K[0-9]+')
    
    # Create Telegram link
    local tg_link="tg://proxy?server=$server_ip&port=$port&secret=${secret}"
    
    print_success "User $username added successfully!"
    echo
    echo -e "${GREEN}User Details:${NC}"
    echo "  Username: $username"
    echo "  Secret: $secret"
    echo "  SNI: $sni"
    echo "  Port: $port"
    echo "  Server: $server_ip"
    echo
    echo -e "${GREEN}Telegram Proxy Link:${NC}"
    echo "  $tg_link"
    echo
    
    # Save link to file
    echo "$tg_link" >> "$TELEGO_DATA_DIR/${username}.link"
    
    restart_service
}

# Remove user from config
remove_user() {
    if ! is_installed; then
        print_error "TeleGO is not installed"
        return 1
    fi
    
    print_header "Remove User"
    
    # List existing users
    if grep -q "^\[secrets\]" "$TELEGO_CONFIG"; then
        echo -e "${GREEN}Existing users:${NC}"
        grep -A 100 "^\[secrets\]" "$TELEGO_CONFIG" | grep -v "^\[" | grep "=" | while read line; do
            echo "  - $(echo "$line" | cut -d'=' -f1 | xargs)"
        done
        echo
    else
        print_error "No users found"
        return 1
    fi
    
    read -p "Enter username to remove: " username
    if [[ -z "$username" ]]; then
        print_error "Username cannot be empty"
        return 1
    fi
    
    # Remove user from config
    sed -i "/^$username = /d" "$TELEGO_CONFIG"
    
    # Remove link file
    rm -f "$TELEGO_DATA_DIR/${username}.link"
    
    print_success "User $username removed"
    
    restart_service
}

# Change port
change_port() {
    if ! is_installed; then
        print_error "TeleGO is not installed"
        return 1
    fi
    
    print_header "Change Port"
    
    current_port=$(grep "bind-to" "$TELEGO_CONFIG" | grep -oP ':\K[0-9]+')
    echo -e "Current port: ${GREEN}$current_port${NC}"
    
    read -p "Enter new port (1-65535): " new_port
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1 ]] || [[ "$new_port" -gt 65535 ]]; then
        print_error "Invalid port number"
        return 1
    fi
    
    # Update config
    sed -i "s/bind-to = \".*:${current_port}\"/bind-to = \"0.0.0.0:${new_port}\"/" "$TELEGO_CONFIG"
    
    print_success "Port changed from $current_port to $new_port"
    
    restart_service
    
    # Show updated links
    if grep -q "^\[secrets\]" "$TELEGO_CONFIG"; then
        echo
        echo -e "${GREEN}Updated proxy links:${NC}"
        local server_ip=$(get_server_ip)
        grep -A 100 "^\[secrets\]" "$TELEGO_CONFIG" | grep -v "^\[" | grep "=" | while read line; do
            username=$(echo "$line" | cut -d'=' -f1 | xargs)
            secret=$(echo "$line" | cut -d'=' -f2 | xargs | tr -d '"')
            echo "  tg://proxy?server=$server_ip&port=$new_port&secret=$secret"
        done
    fi
}

# Change SNI (mask host)
change_sni() {
    if ! is_installed; then
        print_error "TeleGO is not installed"
        return 1
    fi
    
    print_header "Change SNI (TLS Fronting Host)"
    
    current_sni=$(grep "mask-host" "$TELEGO_CONFIG" | cut -d'"' -f2)
    echo -e "Current SNI: ${GREEN}$current_sni${NC}"
    
    read -p "Enter new SNI domain (e.g., www.cloudflare.com): " new_sni
    if [[ -z "$new_sni" ]]; then
        print_error "SNI cannot be empty"
        return 1
    fi
    
    # Update config
    sed -i "s/mask-host = \".*\"/mask-host = \"$new_sni\"/" "$TELEGO_CONFIG"
    
    print_warning "Note: Changing SNI will invalidate existing proxy links!"
    read -p "Do you want to regenerate secrets for all users? (y/n): " regenerate
    
    if [[ "$regenerate" =~ ^[Yy]$ ]]; then
        print_status "Regenerating secrets..."
        local temp_config="/tmp/config.toml"
        cp "$TELEGO_CONFIG" "$temp_config"
        
        # Remove existing secrets section
        sed -i '/^\[secrets\]/,/^$/d' "$TELEGO_CONFIG"
        
        # Regenerate secrets
        grep "^\[secrets\]" -A 100 "$temp_config" | grep -v "^\[" | grep "=" | while read line; do
            username=$(echo "$line" | cut -d'=' -f1 | xargs)
            local result=$(generate_secret "$new_sni")
            local new_secret=$(echo "$result" | cut -d'|' -f1)
            
            if ! grep -q "^\[secrets\]" "$TELEGO_CONFIG"; then
                echo -e "\n[secrets]" >> "$TELEGO_CONFIG"
            fi
            echo "$username = \"$new_secret\"" >> "$TELEGO_CONFIG"
        done
    fi
    
    print_success "SNI changed to $new_sni"
    
    restart_service
    
    # Show updated links
    if [[ "$regenerate" =~ ^[Yy]$ ]] && grep -q "^\[secrets\]" "$TELEGO_CONFIG"; then
        echo
        echo -e "${GREEN}New proxy links:${NC}"
        local server_ip=$(get_server_ip)
        local port=$(grep "bind-to" "$TELEGO_CONFIG" | grep -oP ':\K[0-9]+')
        grep -A 100 "^\[secrets\]" "$TELEGO_CONFIG" | grep -v "^\[" | grep "=" | while read line; do
            username=$(echo "$line" | cut -d'=' -f1 | xargs)
            secret=$(echo "$line" | cut -d'=' -f2 | xargs | tr -d '"')
            echo "  $username: tg://proxy?server=$server_ip&port=$port&secret=$secret"
        done
    fi
}

# Show status and users
show_status() {
    print_header "TeleGO Status"
    
    if ! is_installed; then
        print_error "TeleGO is not installed"
        return
    fi
    
    # Service status
    if systemctl is-active --quiet telego; then
        echo -e "Service Status: ${GREEN}Running${NC}"
    else
        echo -e "Service Status: ${RED}Stopped${NC}"
    fi
    
    # Port
    port=$(grep "bind-to" "$TELEGO_CONFIG" | grep -oP ':\K[0-9]+' 2>/dev/null || echo "N/A")
    echo "Listen Port: $port"
    
    # SNI
    sni=$(grep "mask-host" "$TELEGO_CONFIG" | cut -d'"' -f2 2>/dev/null || echo "N/A")
    echo "TLS Fronting Host: $sni"
    
    # Users
    echo
    echo -e "${GREEN}Users:${NC}"
    if grep -q "^\[secrets\]" "$TELEGO_CONFIG"; then
        local server_ip=$(get_server_ip)
        local count=0
        grep -A 100 "^\[secrets\]" "$TELEGO_CONFIG" | grep -v "^\[" | grep "=" | while read line; do
            username=$(echo "$line" | cut -d'=' -f1 | xargs)
            secret=$(echo "$line" | cut -d'=' -f2 | xargs | tr -d '"')
            echo "  • $username"
            echo "    Link: tg://proxy?server=$server_ip&port=$port&secret=$secret"
            ((count++))
        done
        if [[ $count -eq 0 ]]; then
            echo "  No users configured"
        fi
    else
        echo "  No users configured"
    fi
    
    # Logs
    echo
    echo -e "${GREEN}Recent logs:${NC}"
    journalctl -u telego -n 5 --no-pager
}

# Main menu
show_menu() {
    clear
    print_header "TeleGO Management Script"
    echo "1. Install TeleGO"
    echo "2. Add User"
    echo "3. Remove User"
    echo "4. Change Port"
    echo "5. Change SNI (TLS Fronting)"
    echo "6. Show Status & Users"
    echo "7. Restart Service"
    echo "8. Uninstall TeleGO (Complete Removal)"
    echo "0. Exit"
    echo
    read -p "Select option: " choice
    
    case $choice in
        1)
            install_telego
            if is_installed; then
                read -p "Enter port (default 443): " port
                port=${port:-443}
                read -p "Enter SNI (default www.google.com): " sni
                sni=${sni:-www.google.com}
                create_config "$port" "$sni"
                systemctl enable telego
                start_service
            fi
            ;;
        2)
            if ! is_installed; then
                print_error "Please install TeleGO first (option 1)"
            else
                read -p "Enter username: " username
                add_user "$username" ""
            fi
            ;;
        3)
            remove_user
            ;;
        4)
            change_port
            ;;
        5)
            change_sni
            ;;
        6)
            show_status
            ;;
        7)
            restart_service
            ;;
        8)
            remove_telego
            ;;
        0)
            print_status "Exiting..."
            exit 0
            ;;
        *)
            print_error "Invalid option"
            ;;
    esac
    
    echo
    read -p "Press Enter to continue..."
    show_menu
}

# Initial check
check_root

# Check for required commands
for cmd in curl wget systemctl; do
    if ! command -v $cmd &> /dev/null; then
        print_error "$cmd is required but not installed"
        exit 1
    fi
done

# Start menu
show_menu
