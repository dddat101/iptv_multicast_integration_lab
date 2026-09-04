#!/usr/bin/env python3
"""UDP Multicast sequence tracking receiver for packet loss & stability measurement."""


import argparse
import ipaddress
import socket
import struct
import sys
import time

MAGIC_HEADER = 0x49505456  # "IPTV"


def parse_groups(value: str) -> list[str]:
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
        raise argparse.ArgumentTypeError("At least one group is required.")
    return groups


import os


def ensure_sysctl_memberships(needed: int) -> None:
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


def main() -> int:
    parser = argparse.ArgumentParser(description="UDP Multicast Receiver & Loss Analyzer")
    parser.add_argument("--interface-ip", required=True, help="Local interface IP to bind multicast membership")
    parser.add_argument("--groups", type=parse_groups, required=True,
                        help="Multicast group(s) to join, e.g. 239.10.10.10, or 239.100.1.1-12")
    parser.add_argument("--port", type=int, default=5000, help="UDP destination port")
    parser.add_argument("--duration-sec", type=int, default=10, help="Duration in seconds (0 = run forever)")

    args = parser.parse_args()

    ensure_sysctl_memberships(len(args.groups) + 16)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)

    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # Increase socket receive buffer to 4MB to prevent local kernel drops during high-rate tests
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    except OSError:
        pass

    sock.bind(("", args.port))
    sock.settimeout(0.5)

    memberships = []
    for grp in args.groups:
        mreq = socket.inet_aton(grp) + socket.inet_aton(args.interface_ip)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
        memberships.append(mreq)

    print(f"RECEIVER_ACTIVE joined_groups={len(args.groups)} port={args.port} duration={args.duration_sec}s", flush=True)

    has_duration = args.duration_sec > 0
    deadline = (time.monotonic() + args.duration_sec) if has_duration else 0

    total_received = 0
    total_out_of_order = 0
    total_missing = 0

    # Per-group tracking: group_idx -> dict(first_seq, last_seq, received, missing, ooo)
    grp_stats = {}

    try:
        while not has_duration or (time.monotonic() < deadline):
            try:
                data, _ = sock.recvfrom(65535)
            except socket.timeout:
                continue

            if len(data) < 16:
                continue

            magic = struct.unpack("!I", data[:4])[0]
            if magic == MAGIC_HEADER and len(data) >= 32:
                # 32-byte header: Magic(4B), GroupIdx(2B), Reserved(2B), GlobalSeq(8B), GroupSeq(8B), Timestamp(8B)
                _, grp_idx, _, global_seq, seq, _ = struct.unpack("!IHHIQQ", data[:32])
            else:
                # Fallback simple 16-byte header: Sequence(8B), Timestamp(8B)
                seq, _ = struct.unpack("!QQ", data[:16])
                grp_idx = 0

            total_received += 1
            if grp_idx not in grp_stats:
                grp_stats[grp_idx] = {
                    "first_seq": seq,
                    "last_seq": seq,
                    "received": 1,
                    "missing": 0,
                    "out_of_order": 0,
                }
            else:
                st = grp_stats[grp_idx]
                st["received"] += 1
                if seq <= st["last_seq"]:
                    st["out_of_order"] += 1
                    total_out_of_order += 1
                elif seq > st["last_seq"] + 1:
                    gap = seq - st["last_seq"] - 1
                    st["missing"] += gap
                    total_missing += gap
                st["last_seq"] = seq
    except KeyboardInterrupt:
        pass
    finally:
        for mreq in memberships:
            try:
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_DROP_MEMBERSHIP, mreq)
            except OSError:
                pass
        sock.close()

    total_expected = total_received + total_missing
    loss_ratio = (total_missing / total_expected) if total_expected > 0 else 0.0

    print(f"received_packets={total_received}")
    print(f"missing_packets={total_missing}")
    print(f"out_of_order_packets={total_out_of_order}")
    print(f"total_expected_packets={total_expected}")
    print(f"loss_ratio={loss_ratio:.2e}")
    print(f"loss_criteria_pass={'true' if total_received > 0 and loss_ratio <= 1e-9 else 'false'}")


    return 0 if total_received > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
