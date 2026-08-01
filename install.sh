#!/bin/sh
# openwrt-singbox-autoconf install.sh
# Полная установка Sing-box с прозрачным прокси и встроенным парсером подписок

set -e

[ "$(id -u)" -ne 0 ] && { echo "Ошибка: скрипт нужно запускать от root"; exit 1; }

REPO_RAW="https://raw.githubusercontent.com/KoromeloDev/openwrt-singbox-autoconf/main"

# ---------- Пакетный менеджер ----------
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    UPDATE_CMD="apk update"
    INSTALL_CMD="apk add"
else
    PKG_MGR="opkg"
    UPDATE_CMD="opkg update"
    INSTALL_CMD="opkg install"
fi

# ---------- 1. Очистка старых правил ----------
echo ">>> Очистка старых правил..."
nft delete table inet podkop 2>/dev/null || true
nft delete table inet singbox 2>/dev/null || true
iptables -t nat -F PREROUTING 2>/dev/null || true
ip rule del fwmark 1 table 100 2>/dev/null || true
ip route del local default dev lo table 100 2>/dev/null || true

# ---------- 2. Установка sing-box ----------
echo ">>> Обновление списков пакетов..."
$UPDATE_CMD

if ! command -v sing-box >/dev/null 2>&1; then
    echo ">>> Установка sing-box..."
    $INSTALL_CMD sing-box
else
    echo ">>> sing-box уже установлен: $(sing-box version | head -1)"
fi

# ---------- 3. Проверка и установка рабочего base64 ----------
if ! echo "dGVzdA==" | base64 -d >/dev/null 2>&1; then
    echo ">>> Установка coreutils-base64..."
    $INSTALL_CMD coreutils-base64
    if ! echo "dGVzdA==" | base64 -d >/dev/null 2>&1; then
        echo "Ошибка: не удалось запустить base64 даже после установки пакета"
        exit 1
    fi
fi

# ---------- 4. Функция парсинга подписки ----------
parse_subscription() {
    local url="$1"
    local tmpfile="/tmp/sub_raw.txt"
    echo "    Скачивание подписки..."
    wget -q -O "$tmpfile" "$url" || { echo "Ошибка загрузки подписки"; return 1; }

    local data=$(tr -d '\r\n' < "$tmpfile")

    if echo "$data" | grep -qE '^(vless|ss|trojan)://'; then
        SUB_LINK="$data"
    else
        echo "    Подписка закодирована в base64, декодируем..."
        local decoded
        decoded=$(echo "$data" | base64 -d 2>/dev/null)
        [ -z "$decoded" ] && { echo "Ошибка: не удалось декодировать base64"; rm -f "$tmpfile"; return 1; }
        SUB_LINK=$(echo "$decoded" | grep -aoE 'vless://[^[:space:]]+')
        [ -z "$SUB_LINK" ] && { echo "Ошибка: не найдена vless:// ссылка после декодирования"; rm -f "$tmpfile"; return 1; }
    fi

    echo "    Получена ссылка: $SUB_LINK"

    if echo "$SUB_LINK" | grep -q '^vless://'; then
        UUID=$(echo "$SUB_LINK" | sed -n 's|vless://\([^@]*\)@.*|\1|p')
        SERVER=$(echo "$SUB_LINK" | sed -n 's|.*@\([^:]*\):.*|\1|p')
        PORT=$(echo "$SUB_LINK" | sed -n 's|.*:\([0-9]*\)[?/].*|\1|p' | head -1)
        PARAMS=$(echo "$SUB_LINK" | sed -n 's|.*?\(.*\)#.*|\1|p')
        FLOW=$(echo "$PARAMS" | sed -n 's|.*flow=\([^&]*\).*|\1|p')
        [ -z "$FLOW" ] && FLOW="xtls-rprx-vision"
        PUBLIC_KEY=$(echo "$PARAMS" | sed -n 's|.*pbk=\([^&]*\).*|\1|p')
        SHORT_ID=$(echo "$PARAMS" | sed -n 's|.*sid=\([^&]*\).*|\1|p')
        SERVER_NAME=$(echo "$PARAMS" | sed -n 's|.*sni=\([^&]*\).*|\1|p')
        FINGERPRINT=$(echo "$PARAMS" | sed -n 's|.*fp=\([^&]*\).*|\1|p')
        [ -z "$FINGERPRINT" ] && FINGERPRINT="firefox"
    else
        echo "Ошибка: поддерживается только vless://"
        rm -f "$tmpfile"
        return 1
    fi

    rm -f "$tmpfile"
    [ -z "$SERVER" ] || [ -z "$PORT" ] || [ -z "$UUID" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ] || [ -z "$SERVER_NAME" ] && {
        echo "Ошибка: не все параметры извлечены из подписки"
        return 1
    }
    return 0
}

# ---------- 5. Выбор режима ----------
echo ""
echo "=============================================="
echo " Как настроить прокси?"
echo " 1) Использовать готовую подписку (vless://...)"
echo " 2) Ввести параметры вручную (VLESS Reality)"
echo "=============================================="
read -r -p "Ваш выбор (1 или 2): " METHOD

case "$METHOD" in
    1)
        read -r -p "Введите URL подписки: " SUB_URL
        [ -z "$SUB_URL" ] && { echo "Ошибка: URL не может быть пустым"; exit 1; }
        if ! parse_subscription "$SUB_URL"; then
            echo "Не удалось обработать подписку. Проверьте URL."
            exit 1
        fi
        USE_SUB=1
        ;;
    2)
        echo "Введите параметры VLESS+Reality:"
        read -r -p "Сервер (IP или домен): " SERVER
        read -r -p "Порт: " PORT
        read -r -p "UUID: " UUID
        read -r -p "Flow [xtls-rprx-vision]: " FLOW
        FLOW="${FLOW:-xtls-rprx-vision}"
        read -r -p "Public Key: " PUBLIC_KEY
        read -r -p "Short ID: " SHORT_ID
        read -r -p "Server Name (SNI): " SERVER_NAME
        read -r -p "Fingerprint [firefox]: " FINGERPRINT
        FINGERPRINT="${FINGERPRINT:-firefox}"
        [ -z "$SERVER" ] || [ -z "$PORT" ] || [ -z "$UUID" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$SHORT_ID" ] || [ -z "$SERVER_NAME" ] \
            && { echo "Ошибка: все поля обязательны"; exit 1; }
        USE_SUB=0
        ;;
    *)
        echo "Неверный выбор, выход"
        exit 1
        ;;
esac

# ---------- 6. Домены-исключения ----------
echo ""
echo "=============================================="
echo " Введите домены, которые пойдут напрямую (через запятую)."
echo " По умолчанию: .ru, yandex.net, yastatic.net, .xn--p1ai (.рф)"
echo " (нажмите Enter, чтобы оставить по умолчанию)"
echo "=============================================="
read -r -p "Домены: " EXCLUDE_INPUT
[ -z "$EXCLUDE_INPUT" ] && EXCLUDE_DOMAINS=".ru,yandex.net,yastatic.net,.xn--p1ai" || EXCLUDE_DOMAINS="$EXCLUDE_INPUT"
EXCLUDE_JSON=$(echo "$EXCLUDE_DOMAINS" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')

# ---------- 7. Определение IP сервера ----------
echo ">>> Определение IP сервера $SERVER..."
PROXY_IP=$(nslookup "$SERVER" 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}' | head -1)
if [ -z "$PROXY_IP" ]; then
    PROXY_IP=$(ping -c1 "$SERVER" 2>/dev/null | grep "PING" | grep -oE '\([0-9.]*\)' | tr -d '()')
fi
if [ -z "$PROXY_IP" ]; then
    echo "    Не удалось определить IP сервера. Продолжаем без исключения IP."
    PROXY_IP=""
else
    echo "    IP сервера: $PROXY_IP"
fi

# ---------- 8. Сохранение параметров ----------
mkdir -p /etc/sing-box
cat > /etc/sing-box/install.conf <<EOF
USE_SUB=$USE_SUB
EXCLUDE_JSON='${EXCLUDE_JSON}'
SUB_URL="${SUB_URL}"
SERVER="$SERVER"
PORT="$PORT"
UUID="$UUID"
FLOW="$FLOW"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
SERVER_NAME="$SERVER_NAME"
FINGERPRINT="$FINGERPRINT"
PROXY_IP="$PROXY_IP"
EOF

# ---------- 9. Генерация конфига ----------
generate_config() {
    . /etc/sing-box/install.conf

    cat > /etc/sing-box/config.json <<EOF
{
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "127.0.0.1",
      "listen_port": 12345,
      "sniff": true,
      "sniff_override_destination": true
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$SERVER",
      "server_port": $PORT,
      "uuid": "$UUID",
      "flow": "$FLOW",
      "tls": {
        "enabled": true,
        "server_name": "$SERVER_NAME",
        "utls": {
          "enabled": true,
          "fingerprint": "$FINGERPRINT"
        },
        "reality": {
          "enabled": true,
          "public_key": "$PUBLIC_KEY",
          "short_id": "$SHORT_ID"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "dns": {
    "servers": []
  },
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "direct" },
      { "protocol": "dns", "outbound": "direct" },
      { "domain_suffix": [${EXCLUDE_JSON}], "outbound": "direct" }
    ],
    "final": "proxy"
  }
}
EOF
}

generate_config
echo ">>> Конфиг сохранён в /etc/sing-box/config.json"

# ---------- 10. Создание правил nftables ----------
echo ">>> Создание правил nftables..."
cat > /etc/sing-box/firewall.nft <<NFTEOF
#!/bin/sh
nft delete table inet singbox 2>/dev/null || true
nft add table inet singbox
nft add chain inet singbox prerouting { type filter hook prerouting priority mangle \; }

# Правило: всё из LAN (кроме исключений) помечаем меткой 1 и отправляем в TProxy
NFTEOF

if [ -n "$PROXY_IP" ]; then
    echo "nft add rule inet singbox prerouting iifname \"br-lan\" ip daddr != $PROXY_IP tcp dport != { 22, 53, 123 } meta mark set 1 tproxy ip to 127.0.0.1:12345" >> /etc/sing-box/firewall.nft
else
    echo "nft add rule inet singbox prerouting iifname \"br-lan\" tcp dport != { 22, 53, 123 } meta mark set 1 tproxy ip to 127.0.0.1:12345" >> /etc/sing-box/firewall.nft
fi

chmod +x /etc/sing-box/firewall.nft
/etc/sing-box/firewall.nft

ip rule add fwmark 1 table 100 2>/dev/null || true
ip route add local default dev lo table 100 2>/dev/null || true

# Убедимся, что rc.local существует и исполняемый
touch /etc/rc.local
chmod +x /etc/rc.local

# Добавляем правила, если их ещё нет
if ! grep -q "fwmark 1 table 100" /etc/rc.local 2>/dev/null; then
    echo "ip rule add fwmark 1 table 100" >> /etc/rc.local
    echo "ip route add local default dev lo table 100" >> /etc/rc.local
    echo "/etc/sing-box/firewall.nft" >> /etc/rc.local
fi

echo ">>> Правила nftables и маршрутизация настроены"

# ---------- 11. Автозапуск ----------
if [ -x /etc/init.d/sing-box ]; then
    /etc/init.d/sing-box enable
    /etc/init.d/sing-box restart
else
    cat > /etc/init.d/sing-box <<'INITEOF'
#!/bin/sh /etc/rc.common
START=90
USE_PROCD=1
PROG=/usr/bin/sing-box
CONF=/etc/sing-box/config.json

start_service() {
    procd_open_instance
    procd_set_param command "$PROG" run -c "$CONF"
    procd_set_param respawn
    procd_close_instance
}
INITEOF
    chmod +x /etc/init.d/sing-box
    /etc/init.d/sing-box enable
    /etc/init.d/sing-box restart
fi

echo ">>> Сервис sing-box запущен и добавлен в автозагрузку"

# ---------- 12. Автообновление подписки ----------
if [ "$USE_SUB" -eq 1 ]; then
    echo ">>> Загрузка update-sub.sh..."
    mkdir -p /usr/local/bin
    wget -q -O /usr/local/bin/update-sub.sh "${REPO_RAW}/update-sub.sh" || { echo "Ошибка загрузки update-sub.sh"; exit 1; }
    chmod +x /usr/local/bin/update-sub.sh

    if ! grep -q "update-sub.sh" /etc/crontabs/root 2>/dev/null; then
        echo "0 */6 * * * /usr/local/bin/update-sub.sh" >> /etc/crontabs/root
        /etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null
    fi
    echo ">>> Автообновление подписки настроено (каждые 6 часов)"
fi

echo ""
echo "=============================================="
echo " Установка завершена!"
echo " Проверьте работу:"
echo " curl http://ip-api.com/json"
echo "=============================================="
