#!/bin/bash

# TeleGO Management Script (Russian Version)
# Скрипт управления TeleGO

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Пути конфигурации
TELEGO_BIN="/usr/local/bin/telego"
TELEGO_CONFIG="/etc/telego/config.toml"
TELEGO_SERVICE="/etc/systemd/system/telego.service"
TELEGO_DATA_DIR="/var/lib/telego"
TELEGO_LOG_DIR="/var/log/telego"

# Значения по умолчанию
DEFAULT_PORT="8800"
DEFAULT_SNI="github.com"

# Функции вывода
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error() { echo -e "${RED}[ОШИБКА]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} $1"; }
print_header() { echo -e "\n${GREEN}========================================${NC}\n${GREEN}   $1${NC}\n${GREEN}========================================${NC}\n"; }

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Скрипт должен запускаться от root!"
        exit 1
    fi
}

# Проверка установки
is_installed() { [[ -f "$TELEGO_BIN" ]]; }

# Автоустановка если не установлен
auto_install_if_needed() {
    if ! is_installed; then
        print_warning "TeleGO не установлен. Выполняется автоматическая установка..."
        install_telego
    fi
}

# Получение IP сервера
get_server_ip() {
    curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || curl -s -4 ipinfo.io/ip 2>/dev/null
}

# Генерация секрета
generate_secret() {
    local sni="$1"
    local secret_output=$(telego generate "$sni" 2>/dev/null)
    echo "$secret_output" | grep -oP 'secret=\K[0-9a-f]+' | head -1
}

# Управление сервисом
stop_service() { systemctl stop telego 2>/dev/null && print_status "Сервис TeleGO остановлен" || true; }
start_service() { systemctl start telego && print_status "Сервис TeleGO запущен"; }
restart_service() { systemctl restart telego && print_status "Сервис TeleGO перезапущен"; }

# Установка TeleGO
install_telego() {
    print_header "УСТАНОВКА TELEGO"
    
    if is_installed; then
        print_warning "TeleGO уже установлен"
        read -p "Переустановить? (y/n): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return
        remove_telego
    fi
    
    print_status "Установка зависимостей..."
    apt-get update -qq
    apt-get install -y -qq wget curl make git build-essential
    
    print_status "Загрузка TeleGO..."
    cd /tmp
    LATEST_VERSION=$(curl -s https://api.github.com/repos/Scratch-net/telego/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
    wget -q "https://github.com/Scratch-net/telego/releases/download/${LATEST_VERSION}/telego_${LATEST_VERSION}_linux_amd64.tar.gz"
    tar -xzf "telego_${LATEST_VERSION}_linux_amd64.tar.gz"
    mv telego "$TELEGO_BIN"
    chmod +x "$TELEGO_BIN"
    
    print_status "Создание директорий..."
    mkdir -p "$(dirname "$TELEGO_CONFIG")" "$TELEGO_DATA_DIR" "$TELEGO_LOG_DIR"
    
    print_status "Создание systemd сервиса..."
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
    
    # Запрос параметров с значениями по умолчанию
    echo
    echo -e "${YELLOW}Настройка TeleGO (Enter = значение по умолчанию)${NC}"
    read -p "Введите порт (по умолчанию $DEFAULT_PORT): " port
    port=${port:-$DEFAULT_PORT}
    read -p "Введите SNI домен (по умолчанию $DEFAULT_SNI): " sni
    sni=${sni:-$DEFAULT_SNI}
    
    create_config "$port" "$sni"
    systemctl enable telego
    start_service
    
    print_success "TeleGO успешно установлен на порт $port с SNI $sni!"
}

# Создание конфигурации
create_config() {
    cat > "$TELEGO_CONFIG" <<EOF
[general]
bind-to = "0.0.0.0:$1"
log-level = "info"

[tls-fronting]
mask-host = "$2"
mask-port = 443

[performance]
idle-timeout = "5m"
num-event-loops = 0
EOF
    print_success "Конфигурация создана"
}

# Добавление пользователя
add_user() {
    auto_install_if_needed
    
    print_header "ДОБАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ"
    
    read -p "Введите имя пользователя: " username
    [[ -z "$username" ]] && { print_error "Имя не может быть пустым"; return 1; }
    
    # Получаем текущий SNI из конфига
    current_sni=$(grep "mask-host" "$TELEGO_CONFIG" | cut -d'"' -f2)
    echo -e "Текущий SNI: ${GREEN}$current_sni${NC}"
    read -p "Использовать другой SNI? (оставьте пустым для текущего): " new_sni
    sni=${new_sni:-$current_sni}
    
    print_status "Генерация секрета для $sni..."
    secret=$(generate_secret "$sni")
    
    if [[ -z "$secret" ]]; then
        print_error "Не удалось сгенерировать секрет"
        return 1
    fi
    
    # Добавление в конфиг
    if ! grep -q "^\[secrets\]" "$TELEGO_CONFIG"; then
        echo -e "\n[secrets]" >> "$TELEGO_CONFIG"
    fi
    echo "$username = \"$secret\"" >> "$TELEGO_CONFIG"
    
    local server_ip=$(get_server_ip)
    local port=$(grep "bind-to" "$TELEGO_CONFIG" | grep -oP ':\K[0-9]+')
    local tg_link="tg://proxy?server=$server_ip&port=$port&secret=$secret"
    
    echo "$tg_link" > "$TELEGO_DATA_DIR/${username}.link"
    
    print_success "Пользователь $username добавлен!"
    echo
    echo -e "${GREEN}Ссылка для Telegram:${NC}"
    echo "  $tg_link"
    echo
    echo -e "${YELLOW}Секрет сохранен в: ${TELEGO_DATA_DIR}/${username}.link${NC}"
    
    restart_service
}

# Удаление пользователя
remove_user() {
    auto_install_if_needed
    
    print_header "УДАЛЕНИЕ ПОЛЬЗОВАТЕЛЯ"
    
    # Список пользователей
    if grep -q "^\[secrets\]" "$TELEGO_CONFIG"; then
        echo -e "${GREEN}Существующие пользователи:${NC}"
        grep -A 100 "^\[secrets\]" "$TELEGO_CONFIG" | grep -v "^\[" | grep "=" | while read line; do
            echo "  - $(echo "$line" | cut -d'=' -f1 | xargs)"
        done
        echo
    else
        print_error "Пользователи не найдены"
        return 1
    fi
    
    read -p "Введите имя пользователя для удаления: " username
    [[ -z "$username" ]] && { print_error "Имя не может быть пустым"; return 1; }
    
    sed -i "/^$username = /d" "$TELEGO_CONFIG"
    rm -f "$TELEGO_DATA_DIR/${username}.link"
    
    print_success "Пользователь $username удален"
    restart_service
}

# Смена порта
change_port() {
    auto_install_if_needed
    
    print_header "СМЕНА ПОРТА"
    
    current_port=$(grep "bind-to" "$TELEGO_CONFIG" | grep -oP ':\K[0-9]+')
    echo -e "Текущий порт: ${GREEN}$current_port${NC}"
    
    read -p "Введите новый порт (по умолчанию $DEFAULT_PORT): " new_port
    new_port=${new_port:-$DEFAULT_PORT}
    
    [[ ! "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1 ]] || [[ "$new_port" -gt 65535 ]] && { print_error "Неверный порт"; return 1; }
    
    sed -i "s/bind-to = \".*:${current_port}\"/bind-to = \"0.0.0.0:${new_port}\"/" "$TELEGO_CONFIG"
    
    print_success "Порт изменен с $current_port на $new_port"
    restart_service
}

# Смена SNI
change_sni() {
    auto_install_if_needed
    
    print_header "СМЕНА SNI (TLS FRONTING)"
    
    current_sni=$(grep "mask-host" "$TELEGO_CONFIG" | cut -d'"' -f2)
    echo -e "Текущий SNI: ${GREEN}$current_sni${NC}"
    
    read -p "Введите новый SNI домен (по умолчанию $DEFAULT_SNI): " new_sni
    new_sni=${new_sni:-$DEFAULT_SNI}
    [[ -z "$new_sni" ]] && { print_error "SNI не может быть пустым"; return 1; }
    
    sed -i "s/mask-host = \".*\"/mask-host = \"$new_sni\"/" "$TELEGO_CONFIG"
    
    print_warning "Внимание: Смена SNI делает старые ссылки недействительными!"
    read -p "Перегенерировать секреты для всех пользователей? (y/n): " regenerate
    
    if [[ "$regenerate" =~ ^[Yy]$ ]]; then
        print_status "Перегенерация секретов..."
        local temp_config="/tmp/config.toml"
        cp "$TELEGO_CONFIG" "$temp_config"
        sed -i '/^\[secrets\]/,/^$/d' "$TELEGO_CONFIG"
        
        grep -A 100 "^\[secrets\]" "$temp_config" 2>/dev/null | grep -v "^\[" | grep "=" | while read line; do
            username=$(echo "$line" | cut -d'=' -f1 | xargs)
            new_secret=$(generate_secret "$new_sni")
            if [[ -n "$new_secret" ]]; then
                if ! grep -q "^\[secrets\]" "$TELEGO_CONFIG"; then
                    echo -e "\n[secrets]" >> "$TELEGO_CONFIG"
                fi
                echo "$username = \"$new_secret\"" >> "$TELEGO_CONFIG"
            fi
        done
        print_success "Секреты перегенерированы"
    fi
    
    print_success "SNI изменен на $new_sni"
    restart_service
}

# Показать статус
show_status() {
    if ! is_installed; then
        print_error "TeleGO не установлен"
        return
    fi
    
    print_header "СТАТУС TELEGO"
    
    if systemctl is-active --quiet telego; then
        echo -e "Статус: ${GREEN}РАБОТАЕТ${NC}"
    else
        echo -e "Статус: ${RED}ОСТАНОВЛЕН${NC}"
    fi
    
    port=$(grep "bind-to" "$TELEGO_CONFIG" 2>/dev/null | grep -oP ':\K[0-9]+' || echo "N/A")
    sni=$(grep "mask-host" "$TELEGO_CONFIG" 2>/dev/null | cut -d'"' -f2 || echo "N/A")
    echo "Порт: $port"
    echo "SNI: $sni"
    
    echo
    echo -e "${GREEN}Пользователи:${NC}"
    if grep -q "^\[secrets\]" "$TELEGO_CONFIG" 2>/dev/null; then
        server_ip=$(get_server_ip)
        grep -A 100 "^\[secrets\]" "$TELEGO_CONFIG" | grep -v "^\[" | grep "=" | while read line; do
            username=$(echo "$line" | cut -d'=' -f1 | xargs)
            secret=$(echo "$line" | cut -d'=' -f2 | xargs | tr -d '"')
            echo "  • $username"
            echo "    tg://proxy?server=$server_ip&port=$port&secret=$secret"
        done
    else
        echo "  Нет пользователей"
    fi
    
    echo
    echo -e "${GREEN}Последние логи:${NC}"
    journalctl -u telego -n 5 --no-pager 2>/dev/null || echo "Логи недоступны"
}

# Перезапуск сервиса
restart_service_menu() {
    auto_install_if_needed
    restart_service
}

# Полное удаление
remove_telego() {
    print_header "ПОЛНОЕ УДАЛЕНИЕ TELEGO"
    
    if is_installed; then
        print_status "Остановка сервиса..."
        systemctl stop telego 2>/dev/null || true
        systemctl disable telego 2>/dev/null || true
        
        print_status "Удаление файлов..."
        rm -f "$TELEGO_BIN"
        rm -f "$TELEGO_SERVICE"
        rm -rf "$(dirname "$TELEGO_CONFIG")"
        rm -rf "$TELEGO_DATA_DIR"
        rm -rf "$TELEGO_LOG_DIR"
        
        systemctl daemon-reload
        print_success "TeleGO полностью удален"
    else
        print_warning "TeleGO не установлен"
    fi
}

# Главное меню
show_menu() {
    while true; do
        clear
        print_header "TELEGO - СКРИПТ УПРАВЛЕНИЯ"
        echo " 1. Установить TeleGO"
        echo " 2. Добавить пользователя"
        echo " 3. Удалить пользователя"
        echo " 4. Сменить порт"
        echo " 5. Сменить SNI (маскировку)"
        echo " 6. Показать статус и пользователей"
        echo " 7. Перезапустить сервис"
        echo " 8. Полное удаление TeleGO"
        echo " 0. Выход"
        echo
        echo -e "${YELLOW}Значения по умолчанию: порт $DEFAULT_PORT, SNI $DEFAULT_SNI${NC}"
        echo
        read -p "Выберите пункт меню: " choice
        echo
        
        case $choice in
            1) install_telego ;;
            2) add_user ;;
            3) remove_user ;;
            4) change_port ;;
            5) change_sni ;;
            6) show_status ;;
            7) restart_service_menu ;;
            8) remove_telego ;;
            0) print_status "Выход..."; exit 0 ;;
            *) print_error "Неверный пункт меню" ;;
        esac
        
        echo
        read -p "Нажмите Enter для продолжения..."
    done
}

# Запуск
check_root
show_menu
