# IPTV Multicast Integration Lab — Physical Testbed Manual Verification Guide

This document provides a comprehensive, step-by-step manual test execution guide for qualifying CPE Gateways (Broadcom/Linux-based router DUT) against operator multicast requirements (**R1 through R22**, consolidated into **7 standardized Test Cases**).

---

## 1. Testbed Architecture & Network Addressing

This guide is designed for a **Real Multi-Device Physical Testbed** (zero network namespaces required):

```text
       +-------------------------------------------------------------+
       |             IPTV Media Server (Latitude-E6540)             |
       |  - Physical Interface: eno1 (IP: 172.16.0.92, MTU: 1280)    |
       |  - FFmpeg MPEG-TS Multicast Transmitter (32 Channels)       |
       +-------------------------------------------------------------+
                                      |
                                      | Physical WAN Cable
                                      v
       +-------------------------------------------------------------+
       |                   CPE Gateway Router (DUT)                  |
       |  - WAN Port (eth1.1): 172.16.0.x (DHCP / Static)            |
       |  - Hardware Engine: PPE / Switch Fabric / Flow Cache        |
       |  - IGMP Service: IGMPv2 Proxy (RFC 4605) & Snooping (RFC 4541)|
       |  - LAN Bridge (br0): 192.168.1.1                            |
       +-------------------------------------------------------------+
                    |                 |                 |
     LAN Port 1     |  LAN Port 2     |  LAN Port 3     |
     (192.168.1.x)  |  (192.168.1.x)  |  (192.168.1.x)  |
                    v                 v                 v
             +------------+    +------------+    +------------+
             | Client PC1 |    | Client PC2 |    | Client PC3 |
             | (Live TV)  |    | (Live TV)  |    | (Zapper)   |
             +------------+    +------------+    +------------+
```

### Global Environment Parameters
| Node | Interface | IP Address | Subnet / Role |
| :--- | :--- | :--- | :--- |
| **Server Host** | `eno1` | `172.16.0.92` | Upstream WAN Headend Network |
| **DUT Router WAN** | `eth1.1` | `172.16.0.x` | CPE WAN Interface (Default Gateway to Server) |
| **DUT Router LAN** | `br0` | `192.168.1.1` | LAN Gateway, DHCP Server & IGMP Querier |
| **Client PC 1** | Physical LAN | `192.168.1.101` | Steady Receiver (LAN Port 1) |
| **Client PC 2** | Physical LAN | `192.168.1.102` | Steady Receiver (LAN Port 2) |
| **Client PC 3** | Physical LAN | `192.168.1.103` | Churner / Zapping STB (LAN Port 3) |

> [!IMPORTANT]
> **MTU & Packet Size Adaptation:**
> If `eno1` MTU is `1280`, ensure all streaming commands specify `pkt_size=1128` (6 MPEG-TS packets = 1,128 bytes + UDP/IP headers = 1,156 bytes $\le 1280$) to eliminate packet fragmentation. If MTU is `1500`, standard `pkt_size=1316` (7 MPEG-TS packets) is used.

---

## 2. Test Case Execution & Evidence Collection

---

### Test Case 1: Hardware Forwarding, Multi-STB Quality & Lossless Performance
* **Target Requirements:** `[R1, R2, R16, R17]`
* **Objective:** Verify multicast data packets are switched directly by hardware (PPE/Switch Fabric) without CPU SoftIRQ saturation under multi-STB load, achieving lossless transmission ($\le 10^{-9}$ packet loss).

#### Step-by-Step Procedure:
1. **Server Host (`172.16.0.92`):** Start high-rate multicast stream:
   ```bash
   cd /home/dddat/workspace/iptv_multicast_integration_lab
   ffmpeg -hide_banner -re -stream_loop -1 \
     -i media/sample_1080p_8mbps.ts -c copy -f mpegts \
     "udp://239.10.10.10:5000?pkt_size=1128&ttl=16&localaddr=172.16.0.92"
   ```
2. **Clients (PC 1, PC 2, PC 3):** Launch video playout simultaneously on all 3 clients:
   ```bash
   ffplay "udp://239.10.10.10:5000?buffer_size=4194304"
   ```
3. **Router DUT (SSH):** Check CPU utilization and SoftIRQ under full load:
   ```sh
   top -n 1
   ```
   *(Verify: `%si` is $< 1\%$ and `%idle` is $> 90\%$. On BusyBox routers, do NOT pipe to `head`).*
4. **Router DUT (SSH):** Verify CPU data-plane bypass:
   ```sh
   tcpdump -i br0 -n -c 10 "udp port 5000"
   ```
   *(Verify: `0 packets captured` on `br0`, while client screens show continuous smooth playback).*

#### Evidence Capture (`evidence_tc1.png`):
Capture a split-screen image displaying:
* **Left Window:** Playout windows on client PCs showing smooth 1080p playback without pixelation.
* **Right Window:** Router console executing `top -n 1` demonstrating `%si < 1%` and `tcpdump -i br0` capturing 0 packets.

---

### Test Case 2: Zapping Latency & Low-Delay Packet Processing ($\le 10\text{ ms}$)
* **Target Requirements:** `[R1, R12]`
* **Objective:** Measure the microsecond timestamp delta between receiving an IGMPv2 Join message on LAN and forwarding the first multicast data packet to LAN ($\le 10\text{ ms}$).

#### Step-by-Step Procedure:
1. **Client PC 1:** Start background packet capture:
   ```bash
   sudo tcpdump -i eth0 -n -s0 -w /tmp/zapping_test.pcap "igmp or (udp and port 5000)" &
   TCPDUMP_PID=$!
   ```
2. **Client PC 1:** Trigger a channel join:
   ```bash
   timeout 3 ffplay -nodisp -vn -an "udp://239.10.10.10:5000"
   kill -INT $TCPDUMP_PID 2>/dev/null || true
   ```
3. **Client PC 1:** Measure the precise timestamp delta with `tshark`:
   ```bash
   t0=$(tshark -r /tmp/zapping_test.pcap -Y "igmp.type == 0x16 && igmp.maddr == 239.10.10.10" -T fields -e frame.time_epoch | head -n1)
   t1=$(tshark -r /tmp/zapping_test.pcap -Y "udp.dstport == 5000 && ip.dst == 239.10.10.10" -T fields -e frame.time_epoch | head -n1)
   awk -v t0="$t0" -v t1="$t1" 'BEGIN { printf "Join-to-First-Data Latency: %.3f ms\n", (t1 - t0) * 1000 }'
   ```

#### Evidence Capture (`evidence_tc2.png`):
Screenshot of the Wireshark packet list or Tshark calculation output showing:
* Packet 1: `IGMPv2 Membership Report group 239.10.10.10`
* Packet 2: `MPEG-TS UDP Port 5000`
* Delta time clearly displayed: **$< 10.0\text{ ms}$** (typically `1.5 - 3.0 ms`).

---

### Test Case 3: IGMP Proxy, Snooping, Version Compliance & Header Rewriting
* **Target Requirements:** `[R1, R3, R4, R5, R7, R8, R19]`
* **Objective:** Verify Layer 2 snooping isolation, Layer 3 proxy upstream forwarding, Source IP/MAC rewriting (NAT/masquerading), and QoS DSCP marking (`0x88` / decimal `34` / `AF41`) with IP `DF=1`.

#### Step-by-Step Procedure:
1. **Server Host (`172.16.0.92`):** Capture upstream IGMP signaling from Router WAN:
   ```bash
   sudo tcpdump -i eno1 -n -c 5 -v "igmp"
   ```
2. **Client PC 1:** Start viewing channel `239.10.10.10`:
   ```bash
   ffplay "udp://239.10.10.10:5000"
   ```
3. **Inspect Server Capture Output:**
   Verify the captured IGMPv2 Report packet properties:
   * **Source IP:** Must match Router WAN IP (`172.16.0.x`), NOT Client private IP (`192.168.1.x`).
   * **Source MAC:** Must match Router WAN MAC.
   * **ToS / DSCP:** Must display `tos 0x88` (DSCP decimal 34, Class AF41).
   * **IP Flags:** Must display `flags [DF]` (Don't Fragment bit set).
4. **Router DUT (SSH):** Check hardware snooping port mapping:
   ```sh
   bridge mdb show
   ```
   *(Verify: Only the switch port connected to PC 1 is listed; other ports receive 0 packets).*

#### Evidence Capture (`evidence_tc3.png`):
Screenshot of the Server's `tcpdump -v` output highlighting `tos 0x88`, `flags [DF]`, and rewritten WAN IP address.

---

### Test Case 4: Multi-STB Tracking, Message Suppression & Fast Leave Isolation
* **Target Requirements:** `[R1, R10, R13]`
* **Objective:** Verify upstream Join suppression (RFC 4605), Explicit Source Tracking (per-host state), and Fast Leave isolation (leaving client does not interrupt concurrent viewers).

#### Step-by-Step Procedure:
1. **Client PC 1 & PC 2:** Open live stream on channel `239.10.10.10`:
   ```bash
   ffplay -v error "udp://239.10.10.10:5000?buffer_size=4194304"
   ```
2. **Client PC 3:** Execute 20 rapid Join/Leave cycles (100 ms interval):
   * *Option A (Using repo Python tool):*
     ```bash
     python3 tools/igmp_client.py --interface-ip 192.168.1.103 --groups 239.10.10.10 churn --cycles 20 --churn-interval-ms 100
     ```
   * *Option B (Using Bash loop):*
     ```bash
     for i in $(seq 1 20); do
       timeout 0.5 ffplay -nodisp "udp://239.10.10.10:5000" 2>/dev/null &
       PID=$!
       sleep 0.1
       kill -9 $PID 2>/dev/null || true
       sleep 0.1
     done
     ```
3. **Router DUT (SSH):** Monitor the snooping table during the churn:
   ```sh
   bridge mdb show
   ```
4. **Verification:** Confirm PC 1 and PC 2 video playback exhibits **zero stutter, zero frame drops, and zero error logs** during the entire 20 churn cycles.

#### Evidence Capture (`evidence_tc4.png`):
Screenshot of PC 1 and PC 2 video playback running cleanly while PC 3 terminal shows `CHURN_COMPLETE cycles=20`.

---

### Test Case 5: FTTH Topology Query Handling & Foreign Querier Protection
* **Target Requirements:** `[R6, R14]`
* **Objective:** Verify router handles upstream Group-Specific Queries with destination IP set to channel multicast address, and blocks rogue LAN Queriers to preserve router's Querier authority.

#### Step-by-Step Procedure:
1. **Router DUT (SSH):** Inspect IGMP interface roles:
   ```sh
   cat /proc/net/igmp
   ```
   *Verify:*
   * `eth1.1` (WAN): Displays `0A0A0AEF` (`239.10.10.10`) with `Reporter: 1` (IGMP Terminal role).
   * `br0` (LAN): Displays `Querier: V2` (IGMP Router / Querier role).
2. **Client PC (LAN):** Verify downstream Query source addressing:
   ```bash
   sudo tcpdump -i eth0 -n -v "igmp and ip[9] == 2"
   ```
   *Verify:* Outbound Queries on LAN carry Router LAN IP (`192.168.1.1`).
3. **Client PC (LAN):** Inject rogue Query with lower IP address (`192.168.1.254`):
   ```bash
   sudo python3 tools/igmp_query.py --interface eth0 --group 0.0.0.0 --src-ip 192.168.1.254
   ```
4. **Router DUT (SSH):** Re-check `cat /proc/net/igmp` to verify router did NOT yield its Querier status.

#### Evidence Capture (`evidence_tc5.png`):
Screenshot of router's `cat /proc/net/igmp` output highlighting `br0: Querier V2` and `eth1.1: 0A0A0AEF`.

---

### Test Case 6: Scale (32 Groups), 100ms Churn & Query Stress
* **Target Requirements:** `[R9, R11, R18]`
* **Objective:** Verify router maintains $\ge 32$ concurrent multicast group tables simultaneously, executes 100ms rapid churn without backlog, and withstands 250 qps WAN query flood.

#### Part 1: Stream 32 Multicast Groups on Server (Step 1)
On Server Host (`Latitude-E6540`), start 32 channels with a single, highly-optimized FFmpeg process:
```bash
cd /home/dddat/workspace/iptv_multicast_integration_lab

# Build 32-output argument list
OUTPUTS=""
for i in $(seq 1 32); do
    OUTPUTS="$OUTPUTS -c copy -f mpegts udp://239.100.1.$i:5000?pkt_size=1128&ttl=16&localaddr=172.16.0.92"
done

# Launch single-process 32-channel transmitter
ffmpeg -hide_banner -re -stream_loop -1 \
    -i media/sample_1080p_8mbps.ts \
    $OUTPUTS
```

#### Part 2: Connect Clients Across 3 Physical PCs (Step 2)
Distribute 32 groups across 3 physical PCs (each PC displays 1 live video window and joins remaining groups in background):

* **On Client PC 1 (LAN 1, IP `192.168.1.101`):**
  ```bash
  # 1 live display window:
  ffplay "udp://239.100.1.1:5000?buffer_size=4194304" &
  # 10 background groups (239.100.1.2 - 239.100.1.11):
  python3 tools/igmp_client.py --interface-ip 192.168.1.101 --groups 239.100.1.2-11 --hold-sec 600 &
  ```

* **On Client PC 2 (LAN 2, IP `192.168.1.102`):**
  ```bash
  # 1 live display window:
  ffplay "udp://239.100.1.12:5000?buffer_size=4194304" &
  # 10 background groups (239.100.1.13 - 239.100.1.22):
  python3 tools/igmp_client.py --interface-ip 192.168.1.102 --groups 239.100.1.13-22 --hold-sec 600 &
  ```

* **On Client PC 3 (LAN 3, IP `192.168.1.103`):**
  ```bash
  # 1 live display window:
  ffplay "udp://239.100.1.23:5000?buffer_size=4194304" &
  # 9 background groups (239.100.1.24 - 239.100.1.32):
  python3 tools/igmp_client.py --interface-ip 192.168.1.103 --groups 239.100.1.24-32 --hold-sec 600 &
  ```

#### Part 3: Inject 250 qps Query Stress from Server WAN
While 32 groups are active, inject 250 qps Specific Queries from Server (`eno1`) into Router WAN:
```bash
sudo python3 tools/igmp_query.py --interface eno1 --group 239.10.10.10 --rate-pps 250 --duration-sec 10
```

#### Part 4: Router Verification (SSH)
Check table capacity and CPU load on Router DUT:
```sh
# 1. Verify 32 entries in hardware bridge snooping database:
bridge mdb show

# 2. Verify 32 entries in kernel multicast forwarding cache:
cat /proc/net/ip_mr_mfc

# 3. Verify CPU load remains < 15%:
top -n 1
```

#### Evidence Capture (`evidence_tc6.png`):
Side-by-side screenshot showing:
* Terminal 1 (Server): `SENT 2500 queries at 250.0 pps over 10.0s (PASS)`
* Terminal 2 (Router): `bridge mdb show` listing all 32 distinct groups from `239.100.1.1` to `239.100.1.32` distributed across LAN ports.

---

### Test Case 7: 24-Hour Stability, Boot DHCP Concurrency & Wireless Media (Sling)
* **Target Requirements:** `[R15, R20, R21, R22]`
* **Objective:** Verify 24-hour continuous multicast forwarding without memory leaks or voice/data degradation, immediate DHCP IP lease allocation during router reboot under multicast traffic, and Sling wireless media toolchain readiness.

#### Step-by-Step Procedure:
1. **Boot DHCP Concurrency Test:**
   * Keep multicast streaming active on Server WAN (`eno1`).
   * Reboot Router DUT (or power cycle).
   * As router boots, verify all connected client STBs receive DHCP leases immediately:
     ```sh
     # On Router DUT:
     cat /tmp/dhcp.leases 2>/dev/null || cat /var/lib/misc/dnsmasq.leases 2>/dev/null
     ```
   * Confirm all client MAC addresses obtain valid `192.168.1.x` leases in $< 2.0$ seconds.
2. **Sling Server SDK & Cross-Toolchain Verification:**
   * Verify cross-compiler toolchain packaging on host:
     ```bash
     file tools/igmp_client.py
     ls -lh media/sample_1080p_8mbps.ts
     ```

#### Evidence Capture (`evidence_tc7.png`):
Screenshot of router's `dhcp.leases` table displaying active client leases granted during boot under multicast load.

---

## 3. Teardown & Post-Test Cleanup Commands

### On Client PCs:
Terminate background players and IGMP client sockets:
```bash
killall ffplay 2>/dev/null || true
killall python3 2>/dev/null || true
```

### On Server Host:
Stop the multi-channel FFmpeg transmitter:
```bash
killall ffmpeg 2>/dev/null || true
```

### On Router DUT:
Clear temporary packet filters or flush dynamic snooping records:
```sh
# Verify MDB returns to idle state:
bridge mdb show
```
