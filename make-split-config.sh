#!/bin/bash
# ==============================================================================
# VPN-Taga: Конвертер конфигураций в Split-Tunneling (Раздельный туннель)
# Исключает российские сервисы (Ozon, WB, VK, банки) из VPN туннеля,
# чтобы они работали без отключения VPN и капчи у ваших родных и друзей.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/split_tunnel.py"

# Проверка Python 3
if ! command -v python3 &> /dev/null; then
    echo "[!] Установка python3..."
    apt-get update -y && apt-get install -y python3
fi

TARGET="${1:-}"
MODE="${2:-fast}"

if [ -z "$TARGET" ]; then
    echo "=================================================================="
    echo "  VPN-TAGA: Генерация Split-Tunneling профилей для родных        "
    echo "=================================================================="
    echo "Использование:"
    echo "  $0 <имя_клиента> [режим]        - для клиента из native-wg или wg-easy"
    echo "  $0 <путь_к_файлу.conf> [режим]  - для произвольного файла конфигурации"
    echo "  $0 all [режим]                  - сконвертировать всех существующих клиентов"
    echo ""
    echo "Режимы:"
    echo "  fast    - Оптимизированный (~2100 сетей: Telegram, зарубеж в VPN, РФ напрямую)"
    echo "  instant - Ультрабыстрый (~150 сетей, коннект < 0.2 сек: Telegram, YouTube, Insta, X, Discord)"
    echo "  full    - Полный (21000 сетей, коннект ~5 сек)"
    echo ""
    echo "Примеры:"
    echo "  $0 mama"
    echo "  $0 mama instant"
    echo "  $0 all fast"
    echo "=================================================================="
    exit 1
fi

find_conf_file() {
    local NAME="$1"
    # 1. Точный путь
    if [ -f "$NAME" ]; then
        echo "$NAME"
        return 0
    fi
    # 2. Имя с расширением .conf
    if [ -f "${NAME}.conf" ]; then
        echo "${NAME}.conf"
        return 0
    fi
    # 3. native-wg путь
    if [ -f "/etc/wireguard/clients/${NAME}.conf" ]; then
        echo "/etc/wireguard/clients/${NAME}.conf"
        return 0
    fi
    # 4. wg-easy путь в ./data
    if [ -f "${SCRIPT_DIR}/data/${NAME}.conf" ]; then
        echo "${SCRIPT_DIR}/data/${NAME}.conf"
        return 0
    fi
    return 1
}

if [ "$TARGET" = "all" ]; then
    echo "[*] Поиск всех файлов конфигураций клиентов..."
    FOUND=0
    for DIR in "${SCRIPT_DIR}/data" "/etc/wireguard/clients" "${SCRIPT_DIR}"; do
        if [ -d "$DIR" ]; then
            for CONF in "$DIR"/*.conf; do
                if [ -f "$CONF" ] && [[ "$CONF" != *"_split"* ]] && [[ "$CONF" != *"_instant"* ]] && [[ "$CONF" != *"_full"* ]]; then
                    echo "--> Обработка: $CONF"
                    python3 "${PYTHON_SCRIPT}" "$CONF" -m "$MODE"
                    FOUND=$((FOUND + 1))
                fi
            done
        fi
    done
    if [ "$FOUND" -eq 0 ]; then
        echo "[!] Конфигурационные файлы .conf не найдены."
    else
        echo "[+] Успешно сконвертировано $FOUND файлов."
    fi
    exit 0
fi

RESOLVED_CONF=$(find_conf_file "$TARGET" || true)

if [ -z "$RESOLVED_CONF" ]; then
    echo "[ОШИБКА] Не удалось найти файл конфигурации для '$TARGET'!"
    echo "Убедитесь, что клиент создан в панели wg-easy или через native-wg.sh"
    exit 1
fi

python3 "${PYTHON_SCRIPT}" "$RESOLVED_CONF" -m "$MODE"
