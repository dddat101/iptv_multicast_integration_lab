#!/usr/bin/env python3
"""High-precision UDP multicast sender for IPTV & multicast performance testing.

Supports:
- Multi-group round-robin (e.g. 239.100.1.1-12)
- Configurable UDP payload sizing
- Precise per-group and global sequence tagging
- Configurable ToS / DSCP marking
"""


import argparse
import ipaddress
import socket
import struct
import sys
import time

MAGIC_HEADER = 0x49505456  # "IPTV" in ASCII


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
        raise argparse.ArgumentTypeError("At least one multicast group is required.")

    for g in groups:
        addr = ipaddress.IPv4Address(g)
        if not addr.is_multicast:
            raise argparse.ArgumentTypeError(f"Not multicast: {g}")

    return groups


def main() -> int:
    parser = argparse.ArgumentParser(description="UDP Multicast Sequence Stream Generator")
    parser.add_argument("--interface-ip", required=True, help="Local interface IPv4 to bind/transmit")
    parser.add_argument("--groups", type=parse_groups, required=True,
                        help="Multicast group(s), e.g. 239.10.10.10, or 239.100.1.1-12")
    parser.add_argument("--port", type=int, default=5000, help="UDP destination port")
    parser.add_argument("--ttl", type=int, default=16, help="Multicast TTL")
    parser.add_argument("--payload-bytes", type=int, default=1200, help="Total UDP payload size in bytes")

    parser.add_argument("--rate-pps", type=int, default=1000, help="Overall packet transmission rate in packets/sec")
    parser.add_argument("--duration-sec", type=int, default=10, help="Transmission duration in seconds (0 = run forever)")
    parser.add_argument("--tos", type=lambda x: int(x, 0), default=0, help="IPv4 Type of Service / DSCP byte")

    args = parser.parse_args()

    if not 1 <= args.port <= 65535:
        parser.error("Invalid UDP port")
    if not 1 <= args.ttl <= 255:
        parser.error("Invalid TTL")
    if not 32 <= args.payload_bytes <= 65000:
        parser.error("Payload size must be 32..65000 bytes")
    if not 1 <= args.rate_pps <= 50000:
        parser.error("Rate must be 1..50000 pps")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, args.ttl)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(args.interface_ip))
    if args.tos > 0:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_TOS, args.tos)

    groups = args.groups
    num_groups = len(groups)
    group_seq = [0] * num_groups
    global_seq = 0

    filler = b"X" * (args.payload_bytes - 32)
    interval = 1.0 / args.rate_pps
    has_duration = args.duration_sec > 0
    deadline = (time.monotonic() + args.duration_sec) if has_duration else 0
    next_send = time.monotonic()

    print(f"START_STREAM groups={num_groups} payload={args.payload_bytes}B rate={args.rate_pps}pps duration={args.duration_sec}s", flush=True)

    try:
        while not has_duration or (time.monotonic() < deadline):
            grp_idx = global_seq % num_groups
            grp = groups[grp_idx]
            g_seq = group_seq[grp_idx]

            # Header (32 bytes): Magic (4B), GroupIdx (2B), Reserved (2B), GlobalSeq (8B), GroupSeq (8B), Timestamp_ns (8B)
            header = struct.pack("!IHHQQQ", MAGIC_HEADER, grp_idx, 0, global_seq, g_seq, time.time_ns())
            packet = header + filler

            sock.sendto(packet, (grp, args.port))

            group_seq[grp_idx] += 1
            global_seq += 1
            next_send += interval

            sleep_for = next_send - time.monotonic()
            if sleep_for > 0:
                time.sleep(sleep_for)
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()

    print(f"sent_packets={global_seq}")
    print(f"groups_count={num_groups}")
    for idx, grp in enumerate(groups):
        print(f"group_{grp}_sent={group_seq[idx]}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
