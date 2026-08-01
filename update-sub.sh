#!/bin/sh
# Автообновление подписки и перегенерация конфига sing-box

. /etc/sing-box/install.conf

wget -q -O /tmp/sub_raw.txt "$SUB_URL" || exit 1
data=$(tr -d '\r\n' < /tmp/sub_raw.txt)

if echo "$data" | grep -qE '^(vless|ss|trojan)://'; then
    SUB_LINK="$data"
else
    decoded=$(echo "$data" | base64 -d 2>/dev/null)
    [ -z "$decoded" ] && { echo "$(date): ошибка base64" >> /var/log/sing-box-update.log; rm -f /tmp/sub_raw.txt; exit 1; }
    SUB_LINK=$(echo "$decoded" | grep -aoE 'vless://[^[:space:]]+')
fi
rm -f /tmp/sub_raw.txt
[ -z "$SUB_LINK" ] && { echo "$(date): ошибка парсинга" >> /var/log/sing-box-update.log; exit 1; }

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

sed -i "s/^SERVER=.*/SERVER=\"$SERVER\"/" /etc/sing-box/install.conf
sed -i "s/^PORT=.*/PORT=$PORT/" /etc/sing-box/install.conf
sed -i "s/^UUID=.*/UUID=\"$UUID\"/" /etc/sing-box/install.conf
sed -i "s/^FLOW=.*/FLOW=\"$FLOW\"/" /etc/sing-box/install.conf
sed -i "s/^PUBLIC_KEY=.*/PUBLIC_KEY=\"$PUBLIC_KEY\"/" /etc/sing-box/install.conf
sed -i "s/^SHORT_ID=.*/SHORT_ID=\"$SHORT_ID\"/" /etc/sing-box/install.conf
sed -i "s/^SERVER_NAME=.*/SERVER_NAME=\"$SERVER_NAME\"/" /etc/sing-box/install.conf
sed -i "s/^FINGERPRINT=.*/FINGERPRINT=\"$FINGERPRINT\"/" /etc/sing-box/install.conf

# Определяем IP сервера
PROXY_IP=$(nslookup "$SERVER" 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}' | head -1)
[ -z "$PROXY_IP" ] && PROXY_IP=$(ping -c1 "$SERVER" 2>/dev/null | grep "PING" | grep -oE '\([0-9.]*\)' | tr -d '()')
sed -i "s/^PROXY_IP=.*/PROXY_IP=\"$PROXY_IP\"/" /etc/sing-box/install.conf

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
      "sniff_override_destination": false
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
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "direct" },
      { "domain_suffix": [${EXCLUDE_JSON}], "outbound": "direct" }
    ],
    "final": "proxy"
  }
}
EOF

/etc/init.d/sing-box restart
echo "$(date): подписка обновлена" >> /var/log/sing-box-update.log
