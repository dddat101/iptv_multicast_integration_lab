# IPTV Multicast Lab - Troubleshooting & Diagnostic Runbook

This document provides technical diagnosis, root-cause analysis, and step-by-step remediation procedures for issues encountered when operating the Real IPTV Multicast Integration Lab.

---

## 1. NetworkManager Interference & Host Safety

### Symptom
Plugging in USB-to-Ethernet test adapters (`WAN_IF`, `LAN_IF`) causes NetworkManager to automatically request DHCP or assign link-local IP addresses (`169.254.x.x`), potentially overriding the host's default route (`0.0.0.0/0`).

### Impact
If the host default route switches to an unconfigured test interface, host internet access and SSH connections will immediately drop.

### Framework Solution & Fix
`scripts/lib/common.sh` implements `assert_safe_test_if()`:
1. Validates that the test interface does **not** carry the host default route.
2. Automatically sets the device to unmanaged in NetworkManager:
   ```bash
   nmcli device set <iface> managed no
   ip addr flush dev <iface>
   ```
3. To inspect interface status without root:
   ```bash
   ./scripts/diagnose.sh
   ```

---

## 2. MTU Mismatch & MPEG-TS Video Fragmentation

### Symptom
Clients (VLC or FFplay) report macroblocking, pixelation, or errors:
```text
[mpegts @ ...] Packet corrupt (stream = 0, dts = ...)
[h264 @ ...] non-existing PPS 0 referenced
[h264 @ ...] decode_slice_header error
```

### Root Cause
Standard MPEG-TS over UDP streams pack 7 TS packets ($7 \times 188\text{ bytes} = 1316\text{ bytes}$). Adding IP (20B) and UDP (8B) headers results in a 1344-byte frame. If the transmitting interface (e.g., `eno1` or a USB adapter) has an MTU $< 1344$ (e.g., `mtu 1280`), each video packet is fragmented into two IP fragments. Switches, hardware flow accelerators, or router NAT engines often drop fragment #2 (which has no UDP header), causing TS continuity counter mismatches.

### Remediation
1. **Set interface MTU to 1500**:
   ```bash
   sudo ip link set dev <iface> mtu 1500
   ```
2. **Automatic MTU adaptation in `start_server.sh`**:
   `scripts/start_server.sh` automatically detects interface MTU. If MTU $< 1344$, it reduces `pkt_size` to 1128 bytes (6 TS packets) to eliminate IP fragmentation.
3. **Increase client UDP receive buffer**:
   When using FFplay on a client machine:
   ```bash
   ffplay "udp://239.10.10.10:5000?buffer_size=4194304&overrun_nonfatal=1&fifo_size=500000"
   ```

---

## 3. Router / DUT Multicast Forwarding & Firewall Gotchas

### Symptom
Media server is transmitting (`start_server.sh status` is RUNNING), client sends IGMP Join, but no multicast UDP packets reach the LAN bridge.

### Root Cause & Checklist
1. **WAN Input Drop**: Commercial CPEs often drop incoming UDP multicast on the WAN interface by default:
   - Allow incoming IGMP:
     ```bash
     iptables -I INPUT -i eth-wan -p igmp -j ACCEPT
     ```
   - Allow incoming UDP multicast:
     ```bash
     iptables -I INPUT -i eth-wan -p udp -d 224.0.0.0/4 --dport 5000 -j ACCEPT
     iptables -I FORWARD -i eth-wan -o br-lan -d 224.0.0.0/4 -j ACCEPT
     ```
2. **IGMP Proxy Upstream/Downstream Interface Mapping**:
   Check `/etc/igmpproxy.conf` on the router:
   ```text
   phyint eth-wan upstream ratelimit 0 threshold 1
          altnet 10.10.0.0/24

   phyint br-lan downstream ratelimit 0 threshold 1
   ```
3. **Kernel Multicast Forwarding**:
   Ensure `mc_forwarding` is enabled on the router:
   ```bash
   cat /proc/sys/net/ipv4/conf/all/mc_forwarding
   # Must return 1. If 0:
   echo 1 > /proc/sys/net/ipv4/conf/all/mc_forwarding
   ```
4. **Collect Remote Router Diagnostics**:
   ```bash
   ./scripts/dut_collector.sh collect
   ```

---

## 4. Windows Client Issues (Black Screen & Indefinite Buffering)

### Symptom
VLC connects on a Windows laptop plugged into the router's LAN port, but shows a black screen and never displays video.

### Root Cause 1: Windows Defender Firewall
Windows Defender blocks incoming UDP multicast packets by default on private and public network profiles.
**Fix (Run in PowerShell as Administrator on Windows)**:
```powershell
New-NetFirewallRule -DisplayName "IPTV Multicast Port 5000" -Direction Inbound -LocalPort 5000 -Protocol UDP -Action Allow
```

### Root Cause 2: Wi-Fi vs Ethernet Routing Conflict
If the Windows PC is connected to both Wi-Fi (internet) and Ethernet (DUT LAN), Windows sends IGMP Membership Reports out the Wi-Fi interface due to metric priorities.
**Fix (Run in Command Prompt as Administrator on Windows)**:
```cmd
route add 224.0.0.0 mask 240.0.0.0 <Windows_LAN_IP> metric 1
```
*(To delete later: `route delete 224.0.0.0`)*.

### Root Cause 3: URL Format in VLC
Ensure the stream URL includes the `@` character to instruct VLC to bind to the local port:
```text
udp://@239.10.10.10:5000
```

---

## 5. Linux Multicast Routing for GUI Players

### Symptom
Running VLC or FFplay on Ubuntu host desktop (`./scripts/view_stream_gui.sh lan`) fails to receive stream packets.

### Root Cause
Linux routes multicast packets (`224.0.0.0/4`) to the interface carrying the default gateway (usually host Wi-Fi or primary LAN).
**Fix**:
Always use the automated GUI stream viewer script, which configures temporary routing to the test bridge and cleans up automatically upon exit:
```bash
./scripts/view_stream_gui.sh lan
```

---

## 6. Stale PID Files & Process Lifecycle Management

### Symptom
A script reports that a service is already running, but `ps aux` shows no active process.

### Root Cause
If a script was abruptly terminated with `kill -9` or a terminal crashed, `.pid` files in `state/` may remain abandoned.

### Framework Solution
`scripts/show_state.sh` automatically scans all registered `.pid` files and checks `kill -0 <pid>` and `/proc/<pid>`. It flags orphaned files with `[STALE PID FILE]`.
**Fix**:
```bash
# Inspect PID status:
./scripts/show_state.sh

# Stop and clean up stale state:
sudo ./scripts/cleanup.sh
```

---

## 7. SIGPIPE 141 in Bash Pipelines

### Symptom
A script terminates abruptly with exit code 141 without an obvious error message.

### Root Cause
Under `set -Eeuo pipefail`, if a downstream command terminates before the upstream command finishes writing (e.g., `tshark ... | head -n1`), the upstream command receives `SIGPIPE` (141), causing the entire pipeline to fail.

### Framework Fix
Wrap all early-terminating pipelines:
```bash
(tshark -r "${pcap_file}" ... 2>/dev/null || true) | head -n1
```

---

## 8. Packet Capture Verification Diagnostic Flow

```text
+-----------------------+
|  ./scripts/diagnose.sh |  Pre-flight check: adapters, tools, default routes
+-----------+-----------+
            |
            v
+-----------------------+
| sudo ./setup.sh --... |  Deploy topology (Virtual or Physical)
+-----------+-----------+
            |
            v
+-----------------------+
| sudo ./scenario.sh    |  Run multi-phase test sequence
+-----------+-----------+
            |
            v
+-------------------------------+
| ./verify_compliance.sh [pcap] |  Analyze PCAP evidence & packet timeline
+-------------------------------+
```
