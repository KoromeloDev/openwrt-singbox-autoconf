#!/bin/sh
# Очистка правил nftables и маршрутизации sing-box

echo ">>> Удаление правил nftables sing-box..."
nft delete table inet singbox 2>/dev/null || true

echo ">>> Удаление правил маршрутизации..."
ip rule del fwmark 1 table 100 2>/dev/null || true
ip route del local default dev lo table 100 2>/dev/null || true

echo ">>> Готово. Интернет работает напрямую."
