# Real IPTV Multicast Integration Lab

A production-grade, reproducible multicast test environment designed to validate **real-world IPTV streaming** through physical routers (DUT) or self-contained virtual simulations.

Unlike synthetic socket tests, this lab uses **real application/protocol stacks**:
* **Media Server**: **FFmpeg** streaming 1080p MPEG-TS over UDP Multicast (`239.10.10.10:5000`).
* **STB Clients**: **VLC (cvlc)** clients invoking native kernel `IP_ADD_MEMBERSHIP` socket options to generate standard IGMPv2 Report signaling.
* **Network Flexibility**: Supports full containerized test topology, WAN-only container topology, or direct standalone host streaming without Docker bridges.

---

## Deployment Modes Matrix

| Mode | Command | Bridges | Containers | Physical NICs | Typical Use Case |
|---|---|---|---|---|---|
| **Standalone WAN Server** *(Zero Topology)* | `sudo ./scripts/start_wan_server.sh run` | None | None | `WAN_IF` only | Linux PC acts as IPTV headend directly on Router WAN port; clients test on Router LAN/Wi-Fi |
| **WAN-Only Container** | `sudo ./scripts/setup.sh --wan-only` | `br-test-wan` | `mcast-server` | `WAN_IF` only | Containerized IPTV headend with isolated network namespace & DHCP |
| **Physical Server-Only** | `sudo ./scripts/setup.sh -p -s` | `br-test-wan`, `br-test-lan` | `mcast-server` | `WAN_IF` & `LAN_IF` | Router in the middle; external physical/Windows client on LAN bridge |
| **Full Physical DUT** | `sudo ./scripts/setup.sh --physical` | `br-test-wan`, `br-test-lan` | `mcast-server`, `mcast-client1,2` | `WAN_IF` & `LAN_IF` | Full automated physical qualification test with internal STB containers |
| **Virtual Simulation** | `sudo ./scripts/setup.sh --virtual` | `br-test-wan`, `br-test-lan` | `mcast-server`, `ns-dut`, clients | None | Local development, debugging, and headless CI pipelines |

---

## Architecture Topologies

### Topology 1: Full End-to-End Qualification Lab (Physical / Virtual)

```mermaid
flowchart TD
    subgraph WAN_Side["Upstream WAN Side (10.10.0.0/24)"]
        SRV["mcast-server (Docker)\nFFmpeg MPEG-TS Streamer\n10.10.0.2/24"]
        CTL["ns-wan (Control Netns)\nWAN DHCP Server (dnsmasq)\n10.10.0.254/24"]
        BR_WAN["br-test-wan (L2 Bridge)\nmcast_snooping=0"]
        SRV --- BR_WAN
        CTL --- BR_WAN
    end

    subgraph DUT["Device Under Test (DUT / Router)"]
        DUT_WAN["DUT WAN Port\n10.10.0.1/24 (DHCP/Static)\nFirewall & IGMP Proxy"]
        DUT_CORE["Multicast Forwarding Engine\nigmpproxy / kernel mroute\nHardware Flow Acceleration"]
        DUT_LAN["DUT LAN Switch / Bridge\n10.20.0.1/24\nIGMP Snooping Enabled"]
        DUT_WAN --- DUT_CORE --- DUT_LAN
    end

    subgraph LAN_Side["Downstream LAN Side (10.20.0.0/24)"]
        BR_LAN["br-test-lan (L2 Bridge)\nmcast_snooping=0"]
        C1["mcast-client1 (Docker)\nVLC STB: stb-living-room\n10.20.0.11/24"]
        C2["mcast-client2 (Docker)\nVLC STB: stb-bedroom\n10.20.0.12/24"]
        BR_LAN --- C1
        BR_LAN --- C2
    end

    BR_WAN ===|"USB-WAN (enxd46e...)"| DUT_WAN
    DUT_LAN ===|"USB-LAN (enx00e...)"| BR_LAN
```

### Topology 2: Standalone Zero-Topology WAN Server (Direct Host Headend)

```mermaid
flowchart LR
    subgraph Host_Linux["Linux PC (IPTV Headend)"]
        WAN_NIC["Physical Interface WAN_IF\n(e.g., enxd46e0e0c65e1)\nIP: 10.10.0.2/24"]
        DHCP["Direct DHCP Server (dnsmasq)\nInterface: WAN_IF, Port: 0 (No DNS conflict)\nLeases: 10.10.0.1 - 10.10.0.50"]
        FFMPEG["FFmpeg Streamer\nlocaladdr=10.10.0.2\n239.10.10.10:5000"]
        DHCP -.-> WAN_NIC
        FFMPEG ==>|"UDP Multicast"| WAN_NIC
    end

    subgraph Router["DUT (Router / Gateway)"]
        R_WAN["WAN Port\nGets 10.10.0.x via DHCP\nIGMP Proxy (Upstream)"]
        R_FWD["Multicast Routing\nigmpproxy / snooping"]
        R_LAN["LAN Ports & Wi-Fi\n192.168.1.1/24\nIGMP Snooping"]
        R_WAN --- R_FWD --- R_LAN
    end

    subgraph Clients["Client Devices (Downstream)"]
        WIN["Windows PC (VLC / FFplay)\n192.168.1.150"]
        STB["Physical IPTV STB / Smart TV"]
    end

    WAN_NIC ===|"Ethernet Cable"| R_WAN
    R_LAN ===|"Ethernet / Wi-Fi"| WIN
    R_LAN ===|"Ethernet"| STB
```

---

## Packet Flow & Protocol Sequence

```mermaid
sequenceDiagram
    autonumber
    actor Tester as Test Runner / CI
    participant Server as Media Server (FFmpeg)
    participant DUT as DUT Gateway (Router)
    participant Client1 as VLC Client 1 (STB 1)
    participant Client2 as VLC Client 2 (STB 2)

    Note over Server,DUT: Phase 1: Continuous Multicast Stream
    Server->>DUT: UDP MPEG-TS Stream (239.10.10.10:5000, 1316B, TTL 16)
    Note over DUT: DUT drops stream (no downstream LAN members yet)

    Note over Client1,DUT: Phase 2: First Client Joins (STB 1)
    Client1->>DUT: IGMPv2 Membership Report (239.10.10.10)
    Note over DUT: IGMP Snooping adds Client1 port to MDB
    DUT->>Server: Upstream IGMP Report (WAN Proxy)
    DUT->>Client1: Forwarded MPEG-TS Video Stream
    Note over Client1: VLC receives TS frames & starts decoding

    Note over Client2,DUT: Phase 3: Second Client Joins (STB 2)
    Client2->>DUT: IGMPv2 Membership Report (239.10.10.10)
    Note over DUT: DUT duplicates stream to Client2 port
    DUT->>Client1: Forwarded MPEG-TS Stream
    DUT->>Client2: Forwarded MPEG-TS Stream

    Note over Client1,DUT: Phase 4: Client 1 Leaves (Zapping)
    Client1->>DUT: IGMPv2 Leave Group (224.0.0.2)
    DUT->>Client1: Stop stream to Client 1
    DUT->>Client2: Stream continues uninterrupted to Client 2

    Note over Client2,DUT: Phase 5: Client 2 Leaves
    Client2->>DUT: IGMPv2 Leave Group (224.0.0.2)
    DUT->>Server: Stop forwarding (Flow deleted)
```

---

## Directory & Script Structure

```text
iptv_multicast_integration_lab/
├── config.env.example        # Reference configuration template
├── config.env                # Local host-specific configuration
├── Dockerfile.media          # Ubuntu 24.04 image with FFmpeg, VLC, iproute2
├── captures/                 # Timestamped PCAP evidence files (*.pcap)
├── logs/                     # Daemon logs (server.log, client_*.log, dnsmasq-*.log)
├── media/                    # MPEG-TS video assets (sample_1080p_8mbps.ts)
├── state/                    # Runtime state (PIDs, leases, topology_state.env)
├── docs/
│   ├── SHELL_STYLE.md        # Strict mode & safety guidelines
│   └── TEST_PLAN.md          # Test plan & compliance matrix
└── scripts/
    ├── lib/
    │   └── common.sh         # Core framework library (logging, docker, direct WAN, safety)
    ├── start_wan_server.sh   # Standalone WAN IPTV server (Zero Topology, host-direct)
    ├── start_server.sh       # Streamer manager (--direct host mode or --container mode)
    ├── setup.sh              # Topology setup (--physical, --virtual, --wan-only, --server-only)
    ├── cleanup.sh            # Idempotent cleanup of containers, veths, bridges, direct daemons
    ├── show_state.sh         # Displays runtime state, bridges, containers, groups, DHCP leases
    ├── capture.sh            # Packet capture manager (start | stop | status)
    ├── build_image.sh        # Builds multicast-media-tools:latest Docker image
    ├── generate_media.sh     # Generates deterministic 1080p 8Mbps MPEG-TS sample
    ├── diagnose.sh           # Non-destructive pre-flight check of host, NICs, tools
    ├── start_client.sh       # VLC STB client manager (run | start | stop | status)
    ├── scenario.sh           # Multi-phase automated smoke scenario
    ├── verify_capture.sh     # Automated PCAP verification & latency analysis
    └── view_stream_gui.sh    # Desktop GUI player (VLC/FFplay) on Ubuntu host with auto routing
```

---

## Prerequisites

Install host dependencies:

```bash
sudo apt update
sudo apt install -y docker.io iproute2 ethtool tshark tcpdump ffmpeg dnsmasq util-linux usbutils vlc
sudo systemctl enable --now docker
```

---

## Quick Start Guide

### Step 1: Configure Environment

Copy configuration and specify your physical Ethernet adapter(s):

```bash
cp config.env.example config.env
nano config.env
```

Set:
```bash
WAN_IF="enxd46e0e0c65e1"   # Connected to DUT WAN port
LAN_IF="enx00e04c88293c"   # Connected to DUT LAN port (only needed if using LAN bridge)
```

---

### Step 2: Build Image & Generate Media Asset

```bash
# 1. Build Docker image:
./scripts/build_image.sh

# 2. Generate 1080p 8Mbps MPEG-TS test video:
./scripts/generate_media.sh
```

---

### Step 3: Choose Your Running Mode

#### Mode 1: Standalone WAN IPTV Server (Zero Topology - Recommended for Router WAN Testing)
Use this when you only have **one cable** connecting the Linux PC's `WAN_IF` to the router's WAN port, and test clients (Windows PC, physical STBs, phones) are connected directly to the router's LAN ports or Wi-Fi:

```bash
# Foreground interactive streaming (displays live FFmpeg bitrate/fps stats):
sudo ./scripts/start_wan_server.sh run
# Or: sudo ./scripts/start_server.sh --direct run

# Or background daemon mode:
sudo ./scripts/start_wan_server.sh start
./scripts/start_wan_server.sh status
sudo ./scripts/start_wan_server.sh stop
```
* **No Docker bridges or containers needed.**
* Automatically unmanages `WAN_IF` from NetworkManager and assigns `10.10.0.2/24`.
* Automatically runs an isolated WAN DHCP server (`dnsmasq`) bound strictly to `WAN_IF` (`port=0`, no DNS listener conflict) to provide an IP to the router's WAN port.
* Directly streams FFmpeg MPEG-TS out `WAN_IF`.

#### Mode 2: WAN-Only Container Topology Mode
Use this if you prefer Docker container isolation for the media server, but only have `WAN_IF` connected (no `LAN_IF` or LAN bridge):

```bash
sudo ./scripts/setup.sh --wan-only
# Short syntax: sudo ./scripts/setup.sh -w
```
Deploys `br-test-wan`, `WAN_NS` (DHCP), and `mcast-server` container on `WAN_IF`, skipping all LAN bridges and client containers.

#### Mode 3: Server-Only Physical Topology Mode
```bash
sudo ./scripts/setup.sh --physical --server-only
# Short syntax: sudo ./scripts/setup.sh -p -s
```
Deploys both `br-test-wan` and `br-test-lan` and starts streaming, but skips client containers so you can connect external test devices to `LAN_IF`.

#### Mode 4: Full Physical DUT Mode (Automated End-to-End)
```bash
sudo ./scripts/setup.sh --physical
```
Deploys both bridges and launches internal STB client containers (`mcast-client1`, `mcast-client2`).

#### Mode 5: Virtual Simulation Mode (No Hardware Required)
```bash
sudo ./scripts/setup.sh --virtual
```

Verify state anytime with:
```bash
./scripts/show_state.sh
```

---

### Step 4: Testing with External Windows Client (VLC / FFplay)

When testing IPTV playback on a separate Windows PC connected to the router's LAN port:

1. **Start the IPTV Server on Linux**:
   ```bash
   sudo ./scripts/start_wan_server.sh start
   ```
2. **Connect Windows PC**:
   - Plug an Ethernet cable from the Windows PC into a LAN port on the Router (DUT).
   - Ensure Windows receives an IP in the router's LAN subnet (e.g. `192.168.1.150`).
3. **Configure Windows Defender Firewall (Required)**:
   Open **PowerShell as Administrator** on Windows and allow inbound UDP port 5000:
   ```powershell
   New-NetFirewallRule -DisplayName "IPTV Multicast Port 5000" -Direction Inbound -LocalPort 5000 -Protocol UDP -Action Allow
   ```
4. **Select Network Interface (Avoid Wi-Fi vs Ethernet Routing Conflicts)**:
   When Windows has both Wi-Fi and Ethernet active, Windows may route multicast/IGMP requests over Wi-Fi instead of the Ethernet adapter connected to the router. Use any of the following methods:

   * **Method A: Windows Multicast Route (Recommended - Universal for all apps)**:
     Open **Command Prompt as Administrator** on Windows:
     ```cmd
     route add 224.0.0.0 mask 240.0.0.0 192.168.1.150 metric 1
     ```
     *(This ensures all applications—VLC, FFplay, and browser players—send IGMP Joins and receive video via Ethernet. To remove later: `route delete 224.0.0.0`).*

     Then in VLC, simply open:
     ```text
     udp://@239.10.10.10:5000
     ```

   * **Method B: VLC Command-Line Flag (`--mcast-intf`)**:
     Open PowerShell or CMD on Windows:
     ```powershell
     & "C:\Program Files\VideoLAN\VLC\vlc.exe" udp://@239.10.10.10:5000 --mcast-intf 192.168.1.150
     ```

   * **Method C: VLC GUI Preferences**:
     1. In VLC, go to **Tools** -> **Preferences** (`Ctrl + P`).
     2. In the bottom-left corner, select **All** under **Show settings**.
     3. Navigate to **Input / Codecs** -> **Access modules** -> **UDP**.
     4. In **Multicast output interface**, enter: `192.168.1.150`.
     5. Click **Save** and restart VLC.
     6. Open URL: `udp://@239.10.10.10:5000`.

   * **Method D: Using FFplay (`localaddr`)**:
     ```powershell
     ffplay -i "udp://239.10.10.10:5000?localaddr=192.168.1.150"
     ```

---

### Step 5: Testing with Ubuntu Desktop GUI Player

To watch the live multicast video directly on the Ubuntu desktop:

```bash
# Watch stream forwarded through DUT Router on LAN side:
./scripts/view_stream_gui.sh lan

# Or watch stream directly from Media Server on WAN side (bypasses router):
./scripts/view_stream_gui.sh wan
```
* Automatically handles host multicast routing (`224.0.0.0/4`) and restores original tables upon exit.

---

### Step 6: Automated End-to-End Smoke Scenario

To run the complete automated qualification test (Join, stream validation, multi-client replication, Leave):

```bash
sudo ./scripts/scenario.sh
```

Inspect captured traffic and latency:
```bash
./scripts/verify_capture.sh full
```

Example report:
```text
==============================================================================
                 IPTV MULTICAST LAB - VERIFICATION REPORT                      
==============================================================================
Capture File:     captures/lan_20260904_125128.pcap
Multicast Group:  239.10.10.10 (UDP Port 5000)
------------------------------------------------------------------------------
  Metric / Check                      | Observed     | Result    
------------------------------------------------------------------------------
  IGMPv2 Membership Reports (Join)    | 4            | PASS      
  MPEG-TS Multicast Packets           | 9885         | PASS      
  Join-to-First-Data Latency          | 68.342 ms    | PASS      
  IGMPv2 Leave Messages               | 1            | PASS      
==============================================================================
OVERALL RESULT: PASS (Real video streaming and IGMP signaling verified)
```

---

### Step 7: Cleanup & Interface Restoration

To stop all streams, daemons, containers, and **automatically restore all physical interfaces (`WAN_IF`, `LAN_IF`) to UP state with DHCP**:

```bash
sudo ./scripts/cleanup.sh
# Explicit restore flag: sudo ./scripts/cleanup.sh --restore (or -r, --dhcp)
```
* Tears down test containers, bridges, veth pairs, and DHCP servers.
* Automatically detaches physical interfaces from test bridges and flushes test IPs (`10.10.0.x`).
* Brings physical links `UP`, restores NetworkManager management, and triggers DHCP to acquire IPs from whatever network they are connected to.

If you prefer to keep interfaces isolated and administratively `DOWN`:
```bash
sudo ./scripts/cleanup.sh --down
```

---

## DUT Router Configuration Requirements

To ensure the router forwards multicast from WAN to LAN:
1. **Firewall (WAN Zone)**:
   * Allow incoming IGMP: `proto igmp accept`
   * Allow incoming UDP Multicast: `ip daddr 224.0.0.0/4 udp dport 5000 accept`
   * Allow forwarding from WAN to LAN for `224.0.0.0/4`.
2. **IGMP Proxy (`/etc/igmpproxy.conf`)**:
   ```conf
   phyint eth1.1 upstream ratelimit 0 threshold 1
          altnet 10.10.0.0/24

   phyint br-lan downstream ratelimit 0 threshold 1
   ```
3. **IGMP Snooping on LAN Bridge**:
   * Enable snooping: `echo 1 > /sys/devices/virtual/net/br-lan/bridge/mcast_snooping`
   * Enable querier (optional): `echo 1 > /sys/devices/virtual/net/br-lan/bridge/multicast_querier`

---

## Wireshark / TShark Display Filters

```text
# All IGMP Control Messages
igmp

# IGMPv2 Membership Report (Join)
igmp.type == 0x16

# IGMPv2 Leave Group
igmp.type == 0x17

# Specific Group Traffic
igmp.maddr == 239.10.10.10

# MPEG-TS UDP Multicast Data Packets
ip.dst == 239.10.10.10 && udp.dstport == 5000
```

---

## Troubleshooting & FAQ

### 1. VLC on Windows connects but displays a black screen / buffers indefinitely
* **Windows Defender Firewall**: Windows blocks inbound UDP multicast packets by default. Run this in PowerShell (Admin):
  ```powershell
  New-NetFirewallRule -DisplayName "IPTV Multicast Port 5000" -Direction Inbound -LocalPort 5000 -Protocol UDP -Action Allow
  ```
* **Wi-Fi vs Ethernet Conflict**: If both Wi-Fi and Ethernet are connected, Windows routes IGMP out Wi-Fi. Add a static multicast route:
  ```cmd
  route add 224.0.0.0 mask 240.0.0.0 192.168.1.150 metric 1
  ```
* **Confirm URL syntax**: Ensure the URL begins with `udp://@` (the `@` symbol instructs VLC to listen on the local port and join the multicast group).

### 2. Router WAN does not obtain an IP address
* Ensure `ENABLE_WAN_DHCP="1"` in `config.env`.
* Run `./scripts/show_state.sh` or check active leases:
  - For standalone mode: `cat state/dnsmasq-direct.leases`
  - For container mode: `cat state/dnsmasq-wan.leases`
* Check the physical cable connection between `WAN_IF` and the router's WAN port.

### 3. VLC GUI on Ubuntu doesn't receive stream
* Ubuntu directs multicast packets to its default route (usually Wi-Fi `wlp3s0`). Always use the automated launcher:
  ```bash
  ./scripts/view_stream_gui.sh lan
  ```

### 4. How to generate video with different bitrates or resolutions?
* Modify `STREAM_BITRATE` or edit parameters in `scripts/generate_media.sh`:
  ```bash
  ./scripts/generate_media.sh
  ```
