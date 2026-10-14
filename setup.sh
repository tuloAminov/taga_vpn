#!/bin/bash
# ==============================================================================
# VPN-Taga: Автоматизированный развертыватель WireGuard VPN с Web UI (wg-easy)
# Поддерживаемые ОС: Debian 11/12, Ubuntu 20.04/22.04/24.04
# Минимальные требования: 1 CPU / 1 GB RAM / 10 GB SSD
# ==============================================================================

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}====================================================${NC}"
echo -e "${GREEN}    VPN-TAGA: Развертывание персонального VPN        ${NC}"
echo -e "${BLUE}====================================================${NC}"

# 1. Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ОШИБКА] Этот скрипт должен быть запущен от имени root!${NC}"
  echo "Выполните: sudo bash $0"
  exit 1
fi

# 2. Определение публичного IP сервера
echo -e "\n${YELLOW}[1/7] Определение внешнего IP-адреса...${NC}"
DETECTED_IP=$(curl -s4 --max-time 5 ifconfig.me || curl -s4 --max-time 5 api.ipify.org || ip route get 1.1.1.1 | awk '{print $7}')
echo -e "Обнаружен IP: ${GREEN}${DETECTED_IP}${NC}"

read -r -p "Использовать этот IP для клиентов VPN? [Y/n]: " CONFIRM_IP
CONFIRM_IP=${CONFIRM_IP:-Y}
if [[ "$CONFIRM_IP" =~ ^[Nn]$ ]]; then
  read -r -p "Введите публичный IP или домен вручную: " DETECTED_IP
fi

# 3. Запрос пароля администратора для Web UI
echo -e "\n${YELLOW}[2/7] Настройка пароля панели администратора...${NC}"
RANDOM_PASS=$(tr -dc A-Za-z0-9_ < /dev/urandom | head -c 16)
read -r -p "Введите пароль для веб-панели (Enter для генерации: $RANDOM_PASS): " ADMIN_PASS
ADMIN_PASS=${ADMIN_PASS:-$RANDOM_PASS}

# 4. Проверка и настройка Swap (с учетом размера диска и ОЗУ)
echo -e "\n${YELLOW}[3/7] Проверка оперативной памяти и Swap...${NC}"
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_EXISTS=$(swapon --show | wc -l)

if [ "$SWAP_EXISTS" -le 1 ]; then
  if [ "$TOTAL_RAM_MB" -ge 3500 ]; then
    echo -e "${GREEN}Обнаружено ${TOTAL_RAM_MB} MB ОЗУ. Для 4 GB RAM подкачка на диске 10 GB не требуется (экономим место на NVMe).${NC}"
  else
    echo "Создание Swap-файла размером 1 GB для стабильности системы..."
    fallocate -l 1024M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    sysctl vm.swappiness=10
    echo 'vm.swappiness=10' >> /etc/sysctl.d/99-swap.conf
    echo -e "${GREEN}Swap успешно настроен!${NC}"
  fi
else
  echo -e "${GREEN}Файл подкачки уже активен.${NC}"
fi

# 5. Включение IP Forwarding и BBR
echo -e "\n${YELLOW}[4/7] Включение сетевой маршрутизации (IP Forwarding & BBR)...${NC}"
cat > /etc/sysctl.d/99-wireguard.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system > /dev/null 2>&1

# 6. Обновление пакетов и установка зависимостей
echo -e "\n${YELLOW}[5/7] Обновление системы и установка Docker...${NC}"
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release ufw

# Установка Docker и Docker Compose V2, если не установлены
if ! command -v docker &> /dev/null; then
  echo "Установка официального Docker Engine..."
  install -m 0755 -d /etc/apt/keyrings
  DISTRO_ID=$(. /etc/os-release && echo "$ID")
  CODENAME=$(lsb_release -cs)

  # Обработка Debian 13 (Trixie/testing): Docker пока не имеет отдельного репозитория trixie, используем bookworm
  if [ "$CODENAME" = "trixie" ] || [ "$CODENAME" = "testing" ] || [ "$CODENAME" = "sid" ]; then
    echo -e "${YELLOW}Обнаружен Debian 13 ($CODENAME). Используем проверенный репозиторий Bookworm для Docker.${NC}"
    CODENAME="bookworm"
  fi

  curl -fsSL https://download.docker.com/linux/${DISTRO_ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  chmod a+r /etc/apt/keyrings/docker.gpg
  
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} \
    ${CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl start docker
  echo -e "${GREEN}Docker успешно установлен!${NC}"
else
  echo -e "${GREEN}Docker уже установлен.${NC}"
fi

# 7. Настройка UFW (Firewall)
echo -e "\n${YELLOW}[6/7] Настройка UFW файрвола...${NC}"
ufw --force reset > /dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing

# Разрешаем текущий SSH порт
SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config | awk '{print $2}' || echo "22")
SSH_PORT=${SSH_PORT:-22}
ufw allow "${SSH_PORT}/tcp" comment "SSH Port"

# Разрешаем порт WireGuard (UDP)
ufw allow 51820/udp comment "WireGuard VPN Port"

# Разрешаем порт Web UI (TCP)
ufw allow 51821/tcp comment "WireGuard Web UI"

# Включаем UFW
echo "y" | ufw enable
echo -e "${GREEN}Файрвол настроен: открыты только порты ${SSH_PORT} (SSH), 51820 (WireGuard UDP) и 51821 (Web UI TCP).${NC}"

# 8. Развертывание стека через Docker Compose
echo -e "\n${YELLOW}[7/7] Запуск сервиса wg-easy...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Формируем .env файл
cat > .env << EOF
SERVER_IP=${DETECTED_IP}
ADMIN_PASSWORD=${ADMIN_PASS}
EOF

# Загружаем модуль ядра wireguard
modprobe wireguard || true

# Запуск контейнера
docker compose down > /dev/null 2>&1 || true
docker compose up -d

# Итоговый отчет
echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}       УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                 ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Адрес панели управления:  ${YELLOW}http://${DETECTED_IP}:51821${NC}"
echo -e "Пароль администратора:    ${YELLOW}${ADMIN_PASS}${NC}"
echo -e "Порт подключения VPN:     ${YELLOW}51820 UDP${NC}"
echo -e "\n${BLUE}Как добавить пользователей:${NC}"
echo "1. Откройте в браузере: http://${DETECTED_IP}:51821"
echo "2. Введите пароль."
echo "3. Нажмите кнопку '+ New Client', введите имя (например: 'mama-iphone')."
echo "4. Для телефона: нажмите на иконку QR-кода и отсканируйте камерой в приложении WireGuard."
echo "5. Для ПК/Mac: нажмите 'Download', отправьте файл .conf и импортируйте в приложение WireGuard."
echo -e "\n${RED}Внимание: Сохраните пароль в надежном месте!${NC}\n"
