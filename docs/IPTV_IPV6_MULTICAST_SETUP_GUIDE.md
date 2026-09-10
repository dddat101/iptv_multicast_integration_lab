# Comprehensive Guide: Setup & Stream IPTV Multicast with FFmpeg (IPv6 & Any Network Interface)

This document provides a comprehensive and detailed guide covering system architecture, core networking principles, step-by-step deployment for Server / DUT Router / Clients, and troubleshooting techniques for streaming **IPTV Multicast over IPv6/IPv4** using **FFmpeg** directly on a Linux host (without network namespaces) or across any arbitrary network interface (`eno1`, USB Ethernet `enx...`, `eth0`, etc.).

---

## 1. System Topology & Architecture

```
+-------------------------------------------------------------------------------+
|                        MEDIA SERVER (Linux Host / PC)                         |
|  Interface: $TARGET_IFACE (e.g., eno1 or USB Ethernet enx6c1ff76608e2)         |
|  - IPv4: 172.16.0.92/24 (or assigned IP)                                      |
|  - IPv6 Global: 2001:470:36:303::.../64                                       |
|  - Multicast Routing: Overridden in 'table local' pointing to $TARGET_IFACE    |
|  - Output Stream: udp://[ff15::10:10]:5000 (MPEG-TS, 1080p, H.264/AAC, 8Mbps) |
+-------------------------------------------------------------------------------+
                                        |
                                        | (WAN Ethernet Cable)
                                        v
+-------------------------------------------------------------------------------+
|                             DUT (Router / Gateway)                            |
|  - WAN Port: Receives multicast stream from Media Server                      |
|  - LAN Port: Supplies DHCP & IPv6 Router Advertisements (RA) to Clients       |
|  - MLD Proxy (IPv6): Upstream = WAN, Downstream = LAN                          |
|  - MLD Snooping: Enabled on LAN bridge to prevent broadcast storming          |
|  - WAN Firewall: Accepts ICMPv6 (MLD Query/Report) & UDP Port 5000 Multicast  |
+-------------------------------------------------------------------------------+
                                        |
                                        | (LAN Ethernet Cable)
                                        v
       +-------------------------------------------------+
       |                                                 |
       v                                                 v
+-------------------------------+         +-------------------------------+
|     CLIENT 1: WINDOWS 11      |         |     CLIENT 2: UBUNTU LINUX    |
|  - Interface: Ethernet 6      |         |  - Interface: eno1            |
|  - IPv6: SLAAC/RA from DUT    |         |  - IPv6: SLAAC/RA from DUT    |
|  - Route: ff15::/16 via iface |         |  - Tuning: Increased rmem     |
|  - Player: FFplay / VLC       |         |  - Player: FFplay / VLC       |
+-------------------------------+         +-------------------------------+
```

---

## 2. Core Principle: Why `table local` Must Be Used on Linux

When a Linux machine has **two or more active network interfaces** (e.g., Ethernet + Wi-Fi `wlp3s0`, or multiple USB Ethernet adapters):

1. **Linux IPv6 Routing Policy Rules (`ip -6 rule`):**
   ```text
   0:     from all lookup local
   32766: from all lookup main
   ```
   Linux always queries **`table local` first**. If a matching route is found, route evaluation **terminates immediately** and `table main` is never evaluated.

2. **The Problem with Standard Route Commands:**
   - The command `sudo ip -6 route replace ff15::/16 dev $IFACE` writes to `table main` by default.
   - Meanwhile, `table local` already contains default `multicast ff00::/8 dev ...` routes automatically generated for every interface that is brought `UP` (often prioritizing Wi-Fi `wlp3s0` or the first interface in the list).
   - **Result:** The Linux kernel routes multicast traffic out of Wi-Fi or the wrong interface, leading to **`0 packets captured`** on your intended target interface.

3. **The Correct Solution:**
   Append the **`table local`** flag to the route command. Because `/16` (or `/32`) is more specific than `/8` (**Longest Prefix Match - LPM**), the kernel will prioritize your designated interface within `table local`.

---

## 3. Server Setup & Streaming (On Any Arbitrary Interface)

### Step 1: Declare and Enable the Interface

```bash
# 1. Declare the target interface name (replace with your actual interface)
TARGET_IFACE="enx6c1ff76608e2"   # or eno1, eth0, etc.

# 2. Bring interface UP and enable MULTICAST flag
sudo ip link set dev "${TARGET_IFACE}" up multicast on
```

### Step 2: Configure Multicast Routing Directly in `table local`

```bash
# 1. Add route for ff15::/16 directly into table local
sudo ip -6 route replace ff15::/16 dev "${TARGET_IFACE}" table local

# 2. (Optional for IPv4 multicast testing):
sudo ip route replace 224.0.0.0/4 dev "${TARGET_IFACE}"

# 3. Clean up stale routes in table main (if previously added by mistake)
sudo ip -6 route del ff15::/16 dev "${TARGET_IFACE}" 2>/dev/null || true
sudo ip -6 route del ff00::/8 dev "${TARGET_IFACE}" 2>/dev/null || true
```

**Verify Kernel Route Lookup:**
```bash
ip -6 route get ff15::10:10
```
👉 **Expected Output:**
`multicast ff15::10:10 from :: dev <TARGET_IFACE> table local ...`

---

### Step 3: Run FFmpeg Media Server

Navigate to the project root directory:
```bash
cd /home/dddat/workspace/iptv_multicast_integration_lab
```

#### Option A: Interactive Foreground Mode (Best for Testing & Debugging)
```bash
# Automatically extract the Global IPv6 address of the interface
LOCAL_IP=$(ip -6 -o addr show dev "${TARGET_IFACE}" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)

ffmpeg -hide_banner -re -stream_loop -1 \
  -i "media/sample_1080p_8mbps.ts" \
  -c copy -f mpegts \
  "udp://[ff15::10:10]:5000?pkt_size=1316&ttl=16&localaddr=${LOCAL_IP}"
```

#### Option B: Background Daemon Mode (For Extended/Automated Testing)
```bash
mkdir -p logs state
LOCAL_IP=$(ip -6 -o addr show dev "${TARGET_IFACE}" scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)

nohup ffmpeg -hide_banner -re -stream_loop -1 \
  -i "media/sample_1080p_8mbps.ts" \
  -c copy -f mpegts \
  "udp://[ff15::10:10]:5000?pkt_size=1316&ttl=16&localaddr=${LOCAL_IP}" \
  > logs/server_${TARGET_IFACE}_ipv6.log 2>&1 &

echo $! > state/server_${TARGET_IFACE}_ipv6.pid
echo "Server IPv6 started [PID $(cat state/server_${TARGET_IFACE}_ipv6.pid)]"
```

**Monitor Realtime Logs:**
```bash
tail -f logs/server_${TARGET_IFACE}_ipv6.log
```

**Stop Daemon:**
```bash
if [ -f state/server_${TARGET_IFACE}_ipv6.pid ]; then
  kill $(cat state/server_${TARGET_IFACE}_ipv6.pid) && rm -f state/server_${TARGET_IFACE}_ipv6.pid
  echo "Stopped."
fi
# Or terminate by process matching:
pkill -f "udp://\[ff15::10:10\]:5000"
```

---

### Parameter Reference Table:

| Parameter | Technical Description |
| :--- | :--- |
| `-re` | **Mandatory**. Reads input at native frame rate (Real-time). Omitting this flag causes FFmpeg to blast data at maximum disk speed (hundreds of Mbps), overflowing router and client socket buffers and causing massive packet drops. |
| `-stream_loop -1` | Loops video playback infinitely when reaching EOF. |
| `-c copy` | Stream copies H.264/AAC elementary streams without transcoding (~0% CPU usage). |
| `-f mpegts` | Formats output into MPEG-TS container required by IPTV standards. |
| `pkt_size=1316` | Bundles exactly 7 TS packets (7 × 188B = 1316B). Total packet size = 1316 + 8 (UDP) + 40 (IPv6) = **1364 bytes**, perfectly fitting standard MTU 1500 without IP fragmentation. |
| `ttl=16` | Multicast Time-to-Live (allows traversal across up to 16 router hops). |
| `localaddr=...` | Binds outgoing socket to the exact source IPv6 address of the target interface. |

---

## 4. Client Configuration & Stream Reception

### 4.1. Windows 10 / 11 Client

> ⚠️ **Key Difference Between IPv4 and IPv6 on Windows:**
> - In IPv4, passing `localaddr=192.168.1.108` informs Winsock which NIC to bind to.
> - In IPv6, multicast sockets rely on `ipv6mr_interface` (an integer interface index), not an IP string.
> - Specifying `localaddr` with IPv6 on Windows causes Winsock `bind()` to fail or reject multicast packets. **Therefore, do NOT pass `localaddr` to FFplay on Windows.**

#### Step 1: Add IPv6 Multicast Route on Windows (Run Once)
Open **PowerShell (Run as Administrator)**:
```powershell
netsh interface ipv6 add route ff15::/16 "Ethernet 6" metric=1
```
*(Replace `"Ethernet 6"` with the exact network adapter name connected to the DUT LAN).*

#### Step 2: Play Stream using FFplay or VLC
- **Using FFplay (PowerShell / Git Bash):**
  ```powershell
  ffplay -window_title "IPTV IPv6 Windows" "udp://[ff15::10:10]:5000?buffer_size=1048576"
  ```
- **Using VLC Media Player:**
  Open VLC -> `Ctrl + N` -> Enter network URL:
  ```text
  udp://@[ff15::10:10]:5000
  ```
  *(Note: The `@` symbol instructs VLC to listen/join the multicast group).*

#### Step 3: Verify Group Membership on Windows
While `ffplay` or `vlc` is running, open another PowerShell window and run:
```powershell
netsh interface ipv6 show joins "Ethernet 6"
```
*You must see `Multicast Address : ff15::10:10` listed under the adapter.*

---

### 4.2. Ubuntu Linux Client (e.g., Laptop Latitude-E6520)

> ⚠️ **Packet Drop Symptoms on Ubuntu:**
> If `ifconfig` displays `RX dropped`, the Linux kernel default UDP receive buffer is too small, causing high-bitrate video bursts to be silently discarded, which manifests as `PES packet size mismatch` errors in player logs.

#### Step 1: Tune Kernel UDP Receive Buffer
Run the following commands on the Ubuntu client:
```bash
sudo sysctl -w net.core.rmem_max=16777216
sudo sysctl -w net.core.rmem_default=4194304
```

#### Step 2: Route Multicast Out Physical Interface (`eno1`)
```bash
sudo ip -6 route replace ff00::/8 dev eno1 metric 100
```

#### Step 3: Play Stream with FFplay (Increased Buffer + FIFO Protection)
```bash
ffplay -window_title "IPTV IPv6 Ubuntu" \
  "udp://[ff15::10:10]:5000?buffer_size=4194304&overrun_nonfatal=1&fifo_size=500000"
```

---

## 5. Intermediate Router (DUT) Requirements

For the DUT to forward IPv6 multicast streams from WAN to LAN:

1. **MLD Snooping:**
   Must be enabled on the DUT LAN bridge (e.g., `br-lan`).
2. **MLD Proxy (e.g., `mcproxy` or `mldproxy` daemon):**
   - **Upstream:** WAN interface (connected to the Media Server).
   - **Downstream:** LAN interface (connected to Windows/Ubuntu clients).
   - When a client issues an **MLD Report (ICMPv6 Type 143)** on LAN, the DUT proxies this registration upstream to the Server and activates multicast packet forwarding across the bridge.
3. **Firewall Rules on the DUT:**
   The WAN interface must permit (**ACCEPT**):
   - **ICMPv6** signaling (Type 130 = MLD Query, Type 143/131 = MLD Report).
   - **UDP destination port 5000** destined for multicast group `ff15::10:10`.

---

## 6. Comprehensive Troubleshooting Guide

### Issue 1: `tcpdump` on Server Shows `0 packets captured`
- **Cause:** Kernel is routing packets out of Wi-Fi or another interface due to default routes in `table local`.
- **Diagnostic:** Run `ip -6 route get ff15::10:10`. If it outputs an interface other than `$TARGET_IFACE`, the route is missing from `table local`.
- **Fix:** Add route explicitly to `table local`:
  ```bash
  sudo ip -6 route replace ff15::/16 dev "${TARGET_IFACE}" table local
  ```

---

### Issue 2: Windows Client Does Not Show `ff15::10:10` in `netsh show joins`
- **Cause 1:** Passing `localaddr=...` in the FFplay URL causes Winsock socket binding failure.
  - **Fix:** Remove `localaddr` parameter on the client.
- **Cause 2:** Windows defaults to Wi-Fi adapter due to missing multicast route.
  - **Fix:** Execute `netsh interface ipv6 add route ff15::/16 "Ethernet 6" metric=1`.

---

### Issue 3: FFplay Displays `PES packet size mismatch`, `cabac decode failed`, `concealing errors in P/B frame`
- **Case A (Normal Startup Sync):** Errors only occur for the **first 1–2 seconds** when launching FFplay because the player joins midway through a GOP. Once the server sends the next **IDR Keyframe (I-Frame with SPS/PPS)**, video renders smoothly.
- **Case B (Persistent Glitching/Artifacting):** Caused by **continuous UDP Packet Loss**:
  1. *Check Server:* Confirm `-re` flag is active to prevent bandwidth bursts.
  2. *Check MTU:* IPv6 intermediate routers cannot fragment packets. Test lowering packet size on Server to 6 TS packets (`pkt_size=1128`):
     ```bash
     ffmpeg -hide_banner -re -stream_loop -1 -i media/sample_1080p_8mbps.ts -c copy -f mpegts "udp://[ff15::10:10]:5000?pkt_size=1128&ttl=16"
     ```
  3. *Check Ubuntu Client:* Inspect socket drops via `netstat -su | grep -E "RcvbufErrors|receive errors"`. Apply sysctl `net.core.rmem_max=16777216` and append `buffer_size=4194304` to FFplay command.

---

## 7. Quick Testing & Packet Capture Cheatsheet

```bash
# Capture Multicast IPv6 on Server:
sudo tcpdump -nn -i "${TARGET_IFACE}" "ip6 and udp port 5000"

# Capture MLD Report / Query messages on Server or Client:
sudo tcpdump -nn -i "${TARGET_IFACE}" "icmp6 and (ip6[40] == 130 or ip6[40] == 131 or ip6[40] == 143)"

# Check IPv6 route resolution on Linux:
ip -6 route get ff15::10:10

# Show joined multicast groups on Linux:
ip maddr show dev "${TARGET_IFACE}"

# Show joined multicast groups on Windows:
netsh interface ipv6 show joins
```
