#!/usr/bin/env python3
"""Send bounded IGMPv2 General or Group-Specific Queries using AF_PACKET raw sockets.

Supports:
- Group-Specific Queries addressed to multicast group IP
- High-rate query generation and stress testing
- Configurable IP ToS/DSCP and Don't Fragment (DF) bit
- Foreign LAN Querier injection with custom source IP/MAC
"""


import argparse
import fcntl
import ipaddress
import socket
import struct
import sys
import time

SIOCGIFADDR = 0x8915
SIOCGIFHWADDR = 0x8927
ETH_P_IP = 0x0800


def checksum(data: bytes) -> int:
    if len(data) % 2:
        data += b"\x00"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    total = (total & 0xFFFF) + (total >> 16)
    total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def ioctl_ifreq(sock: socket.socket, iface: str, request: int) -> bytes:
    ifname = iface.encode("ascii")[:15]
    ifreq = struct.pack("256s", ifname)
    return fcntl.ioctl(sock.fileno(), request, ifreq)


def get_interface_ipv4(iface: str) -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        result = ioctl_ifreq(sock, iface, SIOCGIFADDR)
        return socket.inet_ntoa(result[20:24])
    finally:
        sock.close()


def get_interface_mac(iface: str) -> bytes:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        result = ioctl_ifreq(sock, iface, SIOCGIFHWADDR)
        return result[18:24]
    finally:
        sock.close()


def multicast_mac(ip_text: str) -> bytes:
    ip_value = int(ipaddress.IPv4Address(ip_text))
    low23 = ip_value & 0x7FFFFF
    return bytes((0x01, 0x00, 0x5E, (low23 >> 16) & 0x7F, (low23 >> 8) & 0xFF, low23 & 0xFF))


def mac_str_to_bytes(mac_str: str) -> bytes:
    return bytes(int(b, 16) for b in mac_str.replace("-", ":").split(":"))


def build_query(
    src_ip: str,
    src_mac: bytes,
    group: str | None,
    max_resp_tenths: int,
    ident: int,
    eth_broadcast: bool,
    tos: int = 0xc0,
    df: bool = False,
) -> bytes:
    if group is None:
        dst_ip = "224.0.0.1"
        group_ip = "0.0.0.0"
    else:
        dst_ip = group
        group_ip = group

    # IGMP Membership Query payload (8 bytes)
    # Type (0x11), Max Resp Code, Checksum, Group Address
    igmp_wo_sum = struct.pack("!BBH4s", 0x11, max_resp_tenths, 0, socket.inet_aton(group_ip))
    igmp_sum = checksum(igmp_wo_sum)
    igmp = struct.pack("!BBH4s", 0x11, max_resp_tenths, igmp_sum, socket.inet_aton(group_ip))

    # IP Header with Router Alert Option (RFC 2113: 0x94 0x04 0x00 0x00) -> 24 bytes
    router_alert = b"\x94\x04\x00\x00"
    version_ihl = 0x46  # IPv4, IHL = 6 (24 bytes)
    total_length = 24 + len(igmp)
    flags_fragment = 0x4000 if df else 0  # 0x4000 = Don't Fragment (DF)
    ttl = 1

    ip_wo_sum = struct.pack(
        "!BBHHHBBH4s4s",
        version_ihl,
        tos,
        total_length,
        ident & 0xFFFF,
        flags_fragment,
        ttl,
        socket.IPPROTO_IGMP,
        0,
        socket.inet_aton(src_ip),
        socket.inet_aton(dst_ip),
    ) + router_alert

    ip_sum = checksum(ip_wo_sum)

    ip_header = struct.pack(
        "!BBHHHBBH4s4s",
        version_ihl,
        tos,
        total_length,
        ident & 0xFFFF,
        flags_fragment,
        ttl,
        socket.IPPROTO_IGMP,
        ip_sum,
        socket.inet_aton(src_ip),
        socket.inet_aton(dst_ip),
    ) + router_alert

    dst_mac = b"\xff\xff\xff\xff\xff\xff" if eth_broadcast else multicast_mac(dst_ip)
    eth = dst_mac + src_mac + struct.pack("!H", ETH_P_IP)
    return eth + ip_header + igmp


def main() -> int:
    parser = argparse.ArgumentParser(description="IGMP Query Generator Tool")
    parser.add_argument("--interface", required=True, help="Network interface to transmit raw queries")
    parser.add_argument("--group", default="", help="Multicast group for Group-Specific Query (empty for General Query)")
    parser.add_argument("--src-ip", default="", help="Override source IP (e.g. foreign querier IP)")
    parser.add_argument("--src-mac", default="", help="Override source MAC (format: aa:bb:cc:dd:ee:ff)")
    parser.add_argument("--rate-pps", type=int, default=1, help="Query transmission rate in packets per second")

    parser.add_argument("--duration-sec", type=int, default=1, help="Transmission duration in seconds")
    parser.add_argument("--max-response-tenths", type=int, default=10, help="Max response time in tenths of a second (10 = 1.0s)")
    parser.add_argument("--tos", type=lambda x: int(x, 0), default=0xc0, help="IPv4 Type of Service / DSCP byte (default: 0xc0)")
    parser.add_argument("--df", action="store_true", help="Set IPv4 Don't Fragment (DF) flag")
    parser.add_argument("--eth-broadcast", action="store_true", help="Use Ethernet broadcast MAC destination instead of multicast MAC")

    args = parser.parse_args()

    if not 1 <= args.rate_pps <= 10000:
        parser.error("Rate must be 1..10000 pps")
    if not 1 <= args.duration_sec <= 3600:
        parser.error("Duration must be 1..3600 seconds")
    if not 0 <= args.max_response_tenths <= 255:
        parser.error("Max response code must be 0..255")
    if not 0 <= args.tos <= 255:
        parser.error("ToS must be 0..255")

    group = args.group.strip() or None
    if group is not None:
        addr = ipaddress.IPv4Address(group)
        if not addr.is_multicast:
            parser.error("--group must be IPv4 multicast")

    src_ip = args.src_ip.strip() or get_interface_ipv4(args.interface)
    src_mac = mac_str_to_bytes(args.src_mac.strip()) if args.src_mac.strip() else get_interface_mac(args.interface)

    raw = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    raw.bind((args.interface, 0))

    interval = 1.0 / args.rate_pps
    deadline = time.monotonic() + args.duration_sec
    next_send = time.monotonic()
    count = 0

    try:
        while time.monotonic() < deadline:
            frame = build_query(
                src_ip=src_ip,
                src_mac=src_mac,
                group=group,
                max_resp_tenths=args.max_response_tenths,
                ident=count,
                eth_broadcast=args.eth_broadcast,
                tos=args.tos,
                df=args.df,
            )
            raw.send(frame)
            count += 1
            next_send += interval
            sleep_for = next_send - time.monotonic()
            if sleep_for > 0:
                time.sleep(sleep_for)
    finally:
        raw.close()

    query_type = f"group-specific ({group})" if group else "general"
    print(f"query_type={query_type}")
    print(f"sent_queries={count}")
    print(f"rate_pps={args.rate_pps}")
    print(f"src_ip={src_ip}")
    print(f"tos=0x{args.tos:02x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
