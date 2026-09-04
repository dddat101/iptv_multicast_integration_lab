#!/usr/bin/env python3
"""Enhanced IGMP client supporting multi-group scale, rapid churn, and IGMPv3 SSM."""


import argparse
import ipaddress
import os
import signal
import socket
import struct
import sys
import time

# Linux socket options for multicast source filtering (SSM)
IP_ADD_SOURCE_MEMBERSHIP = 39
IP_DROP_SOURCE_MEMBERSHIP = 40
IP_BLOCK_SOURCE = 38
IP_UNBLOCK_SOURCE = 37


def parse_groups(value: str) -> list[str]:
    """Parse comma-separated list of IPs or range syntax like 239.100.1.1-32."""
    groups = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        if "-" in item:
            parts = item.split("-")
            base_ip = parts[0].strip()
            count_or_end = parts[1].strip()
            base_addr = ipaddress.IPv4Address(base_ip)
            if count_or_end.isdigit():
                num = int(count_or_end)
                if num > 256:
                    end_addr = ipaddress.IPv4Address(count_or_end)
                    start_int = int(base_addr)
                    end_int = int(end_addr)
                    for ip_int in range(start_int, end_int + 1):
                        groups.append(str(ipaddress.IPv4Address(ip_int)))
                else:
                    start_int = int(base_addr)
                    for i in range(num):
                        groups.append(str(ipaddress.IPv4Address(start_int + i)))
            else:
                end_addr = ipaddress.IPv4Address(count_or_end)
                start_int = int(base_addr)
                end_int = int(end_addr)
                for ip_int in range(start_int, end_int + 1):
                    groups.append(str(ipaddress.IPv4Address(ip_int)))
        else:
            groups.append(item)

    if not groups:
        raise argparse.ArgumentTypeError("At least one multicast group is required.")

    for g in groups:
        addr = ipaddress.IPv4Address(g)
        if not addr.is_multicast:
            raise argparse.ArgumentTypeError(f"Not an IPv4 multicast address: {g}")

    return groups


def membership_req(group: str, interface_ip: str) -> bytes:
    return socket.inet_aton(group) + socket.inet_aton(interface_ip)


def source_membership_req(group: str, interface_ip: str, source_ip: str) -> bytes:
    return socket.inet_aton(group) + socket.inet_aton(interface_ip) + socket.inet_aton(source_ip)


def new_mcast_socket() -> socket.socket:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    return sock


def ensure_sysctl_memberships(needed: int) -> None:
    """Attempt to increase kernel igmp_max_memberships if currently lower."""
    path = "/proc/sys/net/ipv4/igmp_max_memberships"
    try:
        if os.path.exists(path):
            with open(path, "r") as f:
                current = int(f.read().strip())
            if current < needed:
                target = max(needed + 32, 256)
                with open(path, "w") as f:
                    f.write(str(target))
    except (OSError, PermissionError, ValueError):
        pass


def hold_memberships(groups: list[str], interface_ip: str, sources: list[str], hold_sec: float) -> int:
    ensure_sysctl_memberships(len(groups) + 16)

    active_sockets: list[socket.socket] = []
    current_sock = new_mcast_socket()
    active_sockets.append(current_sock)

    # Track: list of (socket, group, is_ssm, source_ip)
    joined_records: list[tuple[socket.socket, str, bool, str | None]] = []
    joined_count = 0
    interrupted = False

    def sig_handler(sig, frame):
        nonlocal interrupted
        interrupted = True

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    try:
        for grp in groups:
            if sources:
                for src in sources:
                    mreq = source_membership_req(grp, interface_ip, src)
                    try:
                        current_sock.setsockopt(socket.IPPROTO_IP, IP_ADD_SOURCE_MEMBERSHIP, mreq)
                    except OSError as e:
                        if e.errno == 105:  # ENOBUFS (socket hit per-socket membership limit)
                            current_sock = new_mcast_socket()
                            active_sockets.append(current_sock)
                            current_sock.setsockopt(socket.IPPROTO_IP, IP_ADD_SOURCE_MEMBERSHIP, mreq)
                        else:
                            raise
                    joined_records.append((current_sock, grp, True, src))
            else:
                mreq = membership_req(grp, interface_ip)
                try:
                    current_sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
                except OSError as e:
                    if e.errno == 105:  # ENOBUFS
                        current_sock = new_mcast_socket()
                        active_sockets.append(current_sock)
                        current_sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
                    else:
                        raise
                joined_records.append((current_sock, grp, False, None))

            joined_count += 1
            print(f"JOIN {grp}", flush=True)

        print(f"HOLD_ACTIVE count={joined_count} sockets={len(active_sockets)} hold_sec={hold_sec}", flush=True)

        if hold_sec <= 0:
            while not interrupted:
                time.sleep(0.5)
        else:
            deadline = time.monotonic() + hold_sec
            while time.monotonic() < deadline and not interrupted:
                time.sleep(min(0.2, max(0.01, deadline - time.monotonic())))

        for sock, grp, is_ssm, src in reversed(joined_records):
            try:
                if is_ssm and src:
                    mreq = source_membership_req(grp, interface_ip, src)
                    sock.setsockopt(socket.IPPROTO_IP, IP_DROP_SOURCE_MEMBERSHIP, mreq)
                else:
                    mreq = membership_req(grp, interface_ip)
                    sock.setsockopt(socket.IPPROTO_IP, socket.IP_DROP_MEMBERSHIP, mreq)
                print(f"LEAVE {grp}", flush=True)
            except OSError:
                pass
    finally:
        for sock in active_sockets:
            try:
                sock.close()
            except OSError:
                pass

    print(f"HOLD_COMPLETE joined={joined_count}", flush=True)
    return 0


def cycle_memberships(groups: list[str], interface_ip: str, interval_ms: int, cycles: int) -> int:
    ensure_sysctl_memberships(len(groups) + 16)
    delay = interval_ms / 1000.0
    total_ops = 0

    for c in range(1, cycles + 1):
        active_sockets: list[socket.socket] = []
        current_sock = new_mcast_socket()
        active_sockets.append(current_sock)
        joined_records: list[tuple[socket.socket, str]] = []

        try:
            for grp in groups:
                mreq = membership_req(grp, interface_ip)
                try:
                    current_sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
                except OSError as e:
                    if e.errno == 105:
                        current_sock = new_mcast_socket()
                        active_sockets.append(current_sock)
                        current_sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
                    else:
                        raise
                joined_records.append((current_sock, grp))
                print(f"CYCLE {c}/{cycles} JOIN {grp}", flush=True)
                total_ops += 1

            time.sleep(delay)

            for sock, grp in reversed(joined_records):
                mreq = membership_req(grp, interface_ip)
                try:
                    sock.setsockopt(socket.IPPROTO_IP, socket.IP_DROP_MEMBERSHIP, mreq)
                except OSError:
                    pass
                print(f"CYCLE {c}/{cycles} LEAVE {grp}", flush=True)
                total_ops += 1

            if c < cycles:
                time.sleep(delay)
        finally:
            for sock in active_sockets:
                try:
                    sock.close()
                except OSError:
                    pass

    print(f"CHURN_COMPLETE cycles={cycles} interval_ms={interval_ms} total_ops={total_ops}", flush=True)
    return 0



def main() -> int:
    parser = argparse.ArgumentParser(description="IGMP Multicast Client Test Tool")
    parser.add_argument("--interface-ip", required=True, help="Local interface IPv4 address")
    parser.add_argument("--groups", type=parse_groups, required=True,
                        help="Multicast group(s), e.g. 239.10.10.10, or 239.100.1.1-32")
    parser.add_argument("--sources", default="", help="Optional comma-separated unicast sources for IGMPv3 SSM")
    parser.add_argument("--hold-sec", type=float, default=10.0,
                        help="Duration in seconds to maintain membership (0 = indefinite)")
    parser.add_argument("--interval-ms", type=int, default=0,
                        help="Rapid churn interval in milliseconds (e.g. 100)")

    parser.add_argument("--cycles", type=int, default=0,
                        help="Number of Join/Leave cycles to repeat")

    args = parser.parse_args()

    sources = [s.strip() for s in args.sources.split(",") if s.strip()]

    if args.cycles > 0:
        if args.interval_ms <= 0:
            parser.error("--cycles requires --interval-ms > 0")
        return cycle_memberships(args.groups, args.interface_ip, args.interval_ms, args.cycles)

    return hold_memberships(args.groups, args.interface_ip, sources, args.hold_sec)


if __name__ == "__main__":
    sys.exit(main())
