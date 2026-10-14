#!/bin/bash
# ==============================================================================
# VPN-Taga: Pure Native WireGuard Manager (без Docker)
# Ультралегковесное решение для управления сервером WireGuard и клиентами
# Потребление памяти: ~15 MB RAM (работает целиком в ядре Linux)
# ==============================================================================

set -euo pipefail

WG_DIR="/etc/wireguard"
WG_CONF="${WG_DIR}/wg0.conf"
CLIENTS_DIR="${WG_DIR}/clients"
PORT=51820
SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me || ip route get 1.1.1.1 | awk '{print $7}')

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo "Скрипт должен быть запущен с правами root!"
  exit 1
fi

init_server() {
  echo "=== Инициализация WireGuard сервера ==="
  apt-get update -y
  apt-get install -y wireguard qrencode iptables ufw curl

  # Включение IP forwarding
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
  sysctl -p /etc/sysctl.d/99-wireguard.conf

  mkdir -p "${WG_DIR}" "${CLIENTS_DIR}"
  chmod 700 "${WG_DIR}"

  # Определение основного сетевого интерфейса
  DEFAULT_NIC=$(ip route show default | awk '{print $5}' | head -n1)

  if [ ! -f "${WG_DIR}/server_private.key" ]; then
    wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
    chmod 600 "${WG_DIR}/server_private.key"
  fi

  SERVER_PRIV=$(cat "${WG_DIR}/server_private.key")
  SERVER_PUB=$(cat "${WG_DIR}/server_public.key")

  cat > "${WG_CONF}" << EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = ${PORT}
PrivateKey = ${SERVER_PRIV}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_NIC} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_NIC} -j MASQUERADE

# --- CLIENTS LIST ---
EOF

  chmod 600 "${WG_CONF}"

  # Настройка UFW
  ufw allow "${PORT}/udp" comment "WireGuard Port"
  ufw allow 22/tcp comment "SSH"
  echo "y" | ufw enable || true

  # Включение и запуск systemd службы
  systemctl enable wg-quick@wg0
  systemctl restart wg-quick@wg0

  echo "Сервер успешно настроен и запущен на порту ${PORT}/udp"
}

add_client() {
  local CLIENT_NAME="$1"
  if [ -z "$CLIENT_NAME" ]; then
    echo "Использование: $0 add <имя_клиента>"
    exit 1
  fi

  if [ -f "${CLIENTS_DIR}/${CLIENT_NAME}.conf" ]; then
    echo "Клиент с именем '${CLIENT_NAME}' уже существует!"
    exit 1
  fi

  # Поиск следующего свободного IP в подсети 10.8.0.0/24
  for i in {2..254}; do
    IP="10.8.0.$i"
    if ! grep -q "$IP" "${WG_CONF}"; then
      CLIENT_IP="$IP"
      break
    fi
  done

  if [ -z "${CLIENT_IP:-}" ]; then
    echo "Достигнут предел IP-адресов в подсети!"
    exit 1
  fi

  CLIENT_PRIV=$(wg genkey)
  CLIENT_PUB=$(echo "$CLIENT_PRIV" | wg pubkey)
  CLIENT_PSK=$(wg genpsk)
  SERVER_PUB=$(cat "${WG_DIR}/server_public.key")

  # Конфигурационный файл клиента
  cat > "${CLIENTS_DIR}/${CLIENT_NAME}.conf" << EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${CLIENT_IP}/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${SERVER_PUB}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${SERVER_IP}:${PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

  chmod 600 "${CLIENTS_DIR}/${CLIENT_NAME}.conf"

  # Добавление пира в конфиг сервера
  cat >> "${WG_CONF}" << EOF

# Client: ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${CLIENT_IP}/32
EOF

  # Применение изменений на лету без прерывания других клиентов
  wg syncconf wg0 <(wg-quick strip wg0)

  echo "=========================================================="
  echo "Клиент '${CLIENT_NAME}' успешно создан (IP: ${CLIENT_IP})!"
  echo "Конфигурационный файл: ${CLIENTS_DIR}/${CLIENT_NAME}.conf"
  echo "=========================================================="
  echo "QR-код для мобильного приложения WireGuard:"
  qrencode -t ansiutf8 < "${CLIENTS_DIR}/${CLIENT_NAME}.conf"
}

remove_client() {
  local CLIENT_NAME="$1"
  if [ -z "$CLIENT_NAME" ]; then
    echo "Использование: $0 remove <имя_клиента>"
    exit 1
  fi

  if [ ! -f "${CLIENTS_DIR}/${CLIENT_NAME}.conf" ]; then
    echo "Клиент '${CLIENT_NAME}' не найден!"
    exit 1
  fi

  # Извлекаем открытый ключ клиента
  CLIENT_PUB=$(grep -A 10 "Client: ${CLIENT_NAME}" "${WG_CONF}" | grep "PublicKey" | head -n1 | awk '{print $3}')

  if [ -n "$CLIENT_PUB" ]; then
    wg set wg0 peer "$CLIENT_PUB" remove
  fi

  # Удаляем блок клиента из wg0.conf
  sed -i "/# Client: ${CLIENT_NAME}/,+4d" "${WG_CONF}"
  rm -f "${CLIENTS_DIR}/${CLIENT_NAME}.conf" "${CLIENTS_DIR}/${CLIENT_NAME}_split.conf"

  echo "Клиент '${CLIENT_NAME}' успешно удален."
}

add_split_client() {
  local CLIENT_NAME="$1"
  if [ -z "$CLIENT_NAME" ]; then
    echo "Использование: $0 add-split <имя_клиента>"
    exit 1
  fi

  # Создаем обычного клиента, если еще не создан
  if [ ! -f "${CLIENTS_DIR}/${CLIENT_NAME}.conf" ]; then
    add_client "${CLIENT_NAME}"
  fi

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "${SCRIPT_DIR}/split_tunnel.py" ]; then
    python3 "${SCRIPT_DIR}/split_tunnel.py" "${CLIENTS_DIR}/${CLIENT_NAME}.conf"
  else
    echo "[ОШИБКА] Файл split_tunnel.py не найден в ${SCRIPT_DIR}!"
    exit 1
  fi
}

list_clients() {
  echo "=== Активные клиенты WireGuard ==="
  wg show wg0
}

case "${1:-}" in
  init)
    init_server
    ;;
  add)
    add_client "${2:-}"
    ;;
  add-split)
    add_split_client "${2:-}"
    ;;
  remove)
    remove_client "${2:-}"
    ;;
  list)
    list_clients
    ;;
  qr)
    CLIENT_NAME="${2:-}"
    if [ -f "${CLIENTS_DIR}/${CLIENT_NAME}.conf" ]; then
      qrencode -t ansiutf8 < "${CLIENTS_DIR}/${CLIENT_NAME}.conf"
    else
      echo "Клиент '${CLIENT_NAME}' не найден."
    fi
    ;;
  *)
    echo "Управление WireGuard:"
    echo "  $0 init              - Установить и настроить сервер с нуля"
    echo "  $0 add <имя>         - Добавить обычного клиента (0.0.0.0/0)"
    echo "  $0 add-split <имя>   - Добавить клиента со Split-Tunneling (Озон, ВБ, банки идут напрямую)"
    echo "  $0 remove <имя>      - Удалить клиента и отозвать доступ"
    echo "  $0 list              - Список пиров и статус передачи трафика"
    echo "  $0 qr <имя>          - Показать QR-код для существующего клиента"
    ;;
esac
