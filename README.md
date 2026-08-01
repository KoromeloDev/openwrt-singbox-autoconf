# openwrt-singbox-autoconf
Автоматическая установка Sing-box с VLESS Reality и прозрачным прокси на OpenWrt.

## Установка

```sh
wget -O /tmp/install.sh https://raw.githubusercontent.com/KoromeloDev/openwrt-singbox-autoconf/main/install.sh && /tmp/install.sh
```

## Возможности
  - Поддержка подписки (base64/plain) с автоматическим обновлением
  - Ручной ввод параметров Reality
  - Исключение доменов (.ru и т.д.)
  - Прозрачный прокси через nftables (tproxy)
  
