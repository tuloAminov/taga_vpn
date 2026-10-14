#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
==============================================================================
VPN-Taga: Быстрый генератор Split-Tunneling для WireGuard
==============================================================================
Режимы работы:
1. fast (по умолчанию): Оптимизированное исключение РФ (~2000 подсетей).
   Включение VPN за ~0.7-1 сек. Все зарубежные сервисы и мессенджеры (Telegram, WhatsApp,
   YouTube, Instagram и т.д.) в VPN, российские сайты (банки, Госуслуги, Ozon, WB) напрямую.
2. instant: Ультрабыстрый режим (~150 подсетей).
   Включение VPN мгновенно (< 0.2 сек). В VPN Telegram, YouTube, Instagram, X,
   Discord, ChatGPT и реестр блокировок. Сайты РФ и обычный трафик напрямую.
3. full: Точное математическое исключение (21 000 подсетей, включение ~5 сек).
==============================================================================
"""

import sys
import os
import argparse
import urllib.request
import ipaddress
import time
from pathlib import Path

# UTF-8 stdout
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# Пути к кэшу
if sys.platform == "win32":
    CACHE_DIR = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "vpn_taga"
else:
    CACHE_DIR = Path.home() / ".cache" / "vpn_taga"

RU_CACHE_FILE = CACHE_DIR / "ru_subnets.txt"
ANTIFILTER_CACHE_FILE = CACHE_DIR / "antifilter_subnets.txt"
CACHE_TTL = 7 * 86400  # 7 дней

RIPE_RU_URL = "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru/ipv4-aggregated.txt"
ANTIFILTER_URL = "https://antifilter.download/list/subnet.lst"

# Локальные и служебные диапазоны
PRIVATE_RANGES = [
    "0.0.0.0/8",       # "This" network
    "10.0.0.0/8",      # Локальная сеть
    "100.64.0.0/10",   # Провайдерский CGNAT
    "127.0.0.0/8",     # Loopback (localhost)
    "169.254.0.0/16",  # Link-local
    "172.16.0.0/12",   # Локальная сеть
    "192.0.0.0/24",    # IETF Protocol Assignments
    "192.168.0.0/16",  # Домашний Wi-Fi / роутер
    "198.18.0.0/15",   # Benchmark testing
    "224.0.0.0/4",     # Multicast
    "240.0.0.0/4",     # Reserved
    "255.255.255.255/32" # Broadcast
]

# Ключевые сервисы для instant-режима и принудительного направления в VPN
TELEGRAM_CIDRS = [
    # Telegram Messenger Network (AS44907, AS59930, AS62014, AS62041, AS211157)
    "91.108.4.0/22",     # DC2/DC4 (Europe)
    "91.108.8.0/21",     # DC1/DC3 (91.108.8.0/22 + 91.108.12.0/22)
    "91.108.16.0/21",    # DC4/DC5 (91.108.16.0/22 + 91.108.20.0/22)
    "91.108.56.0/22",    # DC5 (Singapore / Asia / Europe)
    "91.105.192.0/23",   # Telegram MTProxy & Services
    "149.154.160.0/20",  # Core Telegram ranges (DC2, DC4, Webogram: 149.154.160.0 - 149.154.175.255)
    "185.76.151.0/24",   # Telegram CDN
    "95.161.64.0/20",    # Webogram & Media
]

BLOCKED_SERVICES_CIDRS = [
    # Telegram
    *TELEGRAM_CIDRS,
    # Google & YouTube (AS15169 CDN/Video)
    "142.250.0.0/15", "172.217.0.0/16", "216.58.192.0/19", "173.194.0.0/16",
    "74.125.0.0/16", "209.85.128.0/17", "64.233.160.0/19", "66.102.0.0/20",
    "66.249.64.0/19", "108.177.0.0/17",
    # Meta / Instagram / WhatsApp / Facebook
    "31.13.24.0/21", "31.13.64.0/18", "31.13.208.0/24", "31.13.236.0/24",
    "157.240.0.0/16", "129.134.0.0/16", "185.60.216.0/22", "185.89.216.0/22",
    "57.144.0.0/14",
    # Twitter / X
    "104.244.42.0/24", "199.16.156.0/22", "199.59.148.0/22", "199.96.56.0/21",
    # Discord
    "162.158.0.0/15", "162.159.128.0/20", "66.22.196.0/22", "66.22.200.0/21",
    # OpenAI / ChatGPT
    "13.107.246.0/24", "20.150.0.0/17", "104.18.0.0/16", "172.64.0.0/13"
]

FORCE_VPN_CIDRS = list(BLOCKED_SERVICES_CIDRS)

def fetch_ru_subnets():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    if RU_CACHE_FILE.exists() and (time.time() - RU_CACHE_FILE.stat().st_mtime < CACHE_TTL):
        try:
            with open(RU_CACHE_FILE, "r", encoding="utf-8") as f:
                lines = [l.strip() for l in f if l.strip() and not l.startswith("#")]
            if len(lines) > 1000:
                return lines
        except Exception:
            pass

    print("[*] Загрузка официального реестра IP РФ (RIPE)...")
    try:
        req = urllib.request.Request(RIPE_RU_URL, headers={"User-Agent": "vpn-taga/1.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            content = resp.read().decode("utf-8")
        with open(RU_CACHE_FILE, "w", encoding="utf-8") as f:
            f.write(content)
        lines = [l.strip() for l in content.splitlines() if l.strip() and not l.startswith("#")]
        return lines
    except Exception as e:
        if RU_CACHE_FILE.exists():
            with open(RU_CACHE_FILE, "r", encoding="utf-8") as f:
                return [l.strip() for l in f if l.strip() and not l.startswith("#")]
        raise RuntimeError(f"Не удалось загрузить реестр IP РФ: {e}")

def fetch_antifilter_subnets():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    if ANTIFILTER_CACHE_FILE.exists() and (time.time() - ANTIFILTER_CACHE_FILE.stat().st_mtime < CACHE_TTL):
        try:
            with open(ANTIFILTER_CACHE_FILE, "r", encoding="utf-8") as f:
                return [l.strip() for l in f if l.strip()]
        except Exception:
            pass

    try:
        req = urllib.request.Request(ANTIFILTER_URL, headers={"User-Agent": "vpn-taga/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            content = resp.read().decode("utf-8")
        with open(ANTIFILTER_CACHE_FILE, "w", encoding="utf-8") as f:
            f.write(content)
        return [l.strip() for l in content.splitlines() if l.strip()]
    except Exception:
        if ANTIFILTER_CACHE_FILE.exists():
            with open(ANTIFILTER_CACHE_FILE, "r", encoding="utf-8") as f:
                return [l.strip() for l in f if l.strip()]
        return []

def range_to_cidrs(start, end):
    cidrs = []
    while start <= end:
        if start == 0:
            max_bits = 32
        else:
            max_bits = (start & -start).bit_length() - 1
            if max_bits > 32:
                max_bits = 32
        length = end - start + 1
        while max_bits > 0 and (1 << max_bits) > length:
            max_bits -= 1
        prefix = 32 - max_bits
        ip_str = str(ipaddress.IPv4Address(start))
        cidrs.append(f"{ip_str}/{prefix}")
        start += (1 << max_bits)
    return cidrs

def calculate_exclude_ru_cidrs(fast=True):
    ru_lines = fetch_ru_subnets()
    ru_nets = []
    for line in ru_lines:
        try:
            ru_nets.append(ipaddress.IPv4Network(line))
        except ValueError:
            continue

    if fast:
        # Агрегация подсетей РФ до маски /16.
        # Сокращает количество маршрутов с 21 000 до ~2 000 (в 10 раз быстрее включение VPN!)
        aggr = set()
        for net in ru_nets:
            if net.prefixlen > 16:
                aggr.add(net.supernet(new_prefix=16))
            else:
                aggr.add(net)
        ru_collapsed = list(ipaddress.collapse_addresses(list(aggr)))
    else:
        ru_collapsed = list(ipaddress.collapse_addresses(ru_nets))

    intervals = []
    for net in ru_collapsed:
        intervals.append((int(net.network_address), int(net.broadcast_address)))

    for pr in PRIVATE_RANGES:
        net = ipaddress.IPv4Network(pr)
        intervals.append((int(net.network_address), int(net.broadcast_address)))

    intervals.sort()

    # Слияние смежных интервалов
    merged = []
    for start, end in intervals:
        if not merged:
            merged.append([start, end])
        else:
            prev_start, prev_end = merged[-1]
            if start <= prev_end + 1:
                merged[-1][1] = max(prev_end, end)
            else:
                merged.append([start, end])

    # Вырезаем принудительно направляемые в VPN сервисы (Telegram, Meta и др.)
    # из списка исключаемых подсетей, чтобы они ВСЕГДА шли через VPN,
    # даже если агрегация до /16 захватила соседние с ними адреса.
    vpn_intervals = []
    for cidr in FORCE_VPN_CIDRS:
        net = ipaddress.IPv4Network(cidr)
        vpn_intervals.append((int(net.network_address), int(net.broadcast_address)))

    punched = []
    for s, e in merged:
        cur_parts = [(s, e)]
        for vs, ve in vpn_intervals:
            new_parts = []
            for cs, ce in cur_parts:
                if ve < cs or vs > ce:
                    new_parts.append((cs, ce))
                else:
                    if cs < vs:
                        new_parts.append((cs, vs - 1))
                    if ce > ve:
                        new_parts.append((ve + 1, ce))
            cur_parts = new_parts
        punched.extend(cur_parts)

    # Инверсия (0.0.0.0 - 255.255.255.255)
    allowed_intervals = []
    curr = 0
    for start, end in punched:
        if start > curr:
            allowed_intervals.append((curr, start - 1))
        curr = max(curr, end + 1)
        if curr > 0xFFFFFFFF:
            break
    if curr <= 0xFFFFFFFF:
        allowed_intervals.append((curr, 0xFFFFFFFF))

    allowed_cidrs = []
    for s, e in allowed_intervals:
        allowed_cidrs.extend(range_to_cidrs(s, e))

    return allowed_cidrs

def calculate_instant_cidrs():
    """Ультрабыстрый режим: ~100-200 подсетей ключевых заблокированных сервисов"""
    antifilter = fetch_antifilter_subnets()
    all_nets = []
    for item in antifilter + BLOCKED_SERVICES_CIDRS:
        try:
            all_nets.append(ipaddress.IPv4Network(item))
        except ValueError:
            continue
    collapsed = list(ipaddress.collapse_addresses(all_nets))
    return [str(net) for net in collapsed]

def generate_split_config(input_path, output_path=None, mode="fast"):
    in_file = Path(input_path)
    if not in_file.exists():
        print(f"[ОШИБКА] Файл '{input_path}' не найден!")
        sys.exit(1)

    suffix = "_split"
    if mode == "instant":
        suffix = "_instant"
    elif mode == "full":
        suffix = "_full"

    if output_path is None:
        output_path = in_file.parent / f"{in_file.stem}{suffix}.conf"
    else:
        output_path = Path(output_path)

    with open(in_file, "r", encoding="utf-8") as f:
        content = f.read()

    print(f"[*] Генерация маршрутов в режиме '{mode}'...")
    t0 = time.time()
    if mode == "instant":
        cidrs = calculate_instant_cidrs()
        desc = "Ультрабыстрый (Telegram, YouTube, Insta, X, Discord + РКН)"
    elif mode == "full":
        cidrs = calculate_exclude_ru_cidrs(fast=False)
        desc = "Полный список без агрегации (21 000 сетей)"
    else: # fast
        cidrs = calculate_exclude_ru_cidrs(fast=True)
        desc = "Оптимизированный (~2 100 сетей: Telegram, зарубежные сервисы в VPN, РФ напрямую)"

    elapsed = time.time() - t0
    print(f"[+] Рассчитано {len(cidrs)} подсетей ({desc}) за {elapsed:.2f} сек.")

    allowed_ips_str = ", ".join(cidrs)

    lines = content.splitlines()
    new_lines = []
    replaced = False

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("AllowedIPs") and "=" in stripped:
            new_lines.append(f"AllowedIPs = {allowed_ips_str}")
            replaced = True
        else:
            new_lines.append(line)

    if not replaced:
        peer_idx = -1
        for i, l in enumerate(new_lines):
            if l.strip() == "[Peer]":
                peer_idx = i
        if peer_idx != -1:
            new_lines.insert(peer_idx + 1, f"AllowedIPs = {allowed_ips_str}")
        else:
            new_lines.append(f"AllowedIPs = {allowed_ips_str}")

    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(new_lines) + "\n")

    print("\n" + "=" * 60)
    print("УСПЕХ: Конфигурационный файл создан!")
    print(f"Файл: {output_path.resolve()}")
    print(f"Количество маршрутов: {len(cidrs)} (скорость включения: < 1 сек)")
    print("=" * 60)
    print("\nИнструкция для родных:")
    print("1. Отправьте им созданный файл в Telegram / WhatsApp.")
    print("2. Родственник открывает файл -> 'Открыть в WireGuard' -> включает тумблер.")
    print("3. Включение теперь происходит быстро, а Ozon, WB и банки работают напрямую!\n")

def main():
    parser = argparse.ArgumentParser(
        description="VPN-Taga Split-Tunneling Generator: быстрый обход белого списка РФ"
    )
    parser.add_argument("config", help="Путь к исходному .conf файлу WireGuard")
    parser.add_argument("-o", "--output", help="Путь для сохранения результата", default=None)
    parser.add_argument(
        "-m", "--mode",
        choices=["fast", "instant", "full"],
        default="fast",
        help="Режим: fast (по умолчанию, ~2000 сетей, <1с коннект), instant (<0.2с коннект, ~100 сетей), full (21000 сетей)"
    )

    args = parser.parse_args()
    generate_split_config(args.config, args.output, mode=args.mode)

if __name__ == "__main__":
    main()
