<#
================================================================================
  IPTV MULTICAST TEST LAB - WINDOWS CLIENT AUTOMATION SCRIPT
================================================================================
  Version: 2.0
  Compatible with: Windows PowerShell 5.1 & PowerShell 7+ (pwsh)
  
  Features:
  1. Interactive GUI Playback: Watch any channel (1..N) via FFplay or VLC.
  2. Ultra-Lightweight Scale 32 Groups: Native .NET Sockets (< 15 MB RAM total)
     with real-time packet & bitrate monitor.
  3. Scale GUI Multi-Channel Playback: Open N channels with GUI video grid (Combine Option 1 & 2).
  4. Headless 32 Channels FFplay: Multi-process playback with low-RAM buffer.
  5. Rapid Channel Churn Test: High-speed channel zapping / leave & join benchmarking.
  6. One-Click Setup: Automatic Windows Defender Firewall & Multicast Route configuration.
================================================================================
#>

[CmdletBinding(DefaultParameterSetName = "Default")]
param(
    [Parameter(Position = 0)]
    [ValidateSet("Interactive", "Play", "Scale", "ScaleGUI", "PlayScale", "ScalePlay", "ScaleFFplay", "Churn", "Setup", "Stop", "Status")]
    [string]$Mode = "Interactive",

    [Parameter(Position = 1)]
    [int]$Channel = 1,

    [int]$Count = 32,
    [string]$MulticastBase = "239.100.1.",
    [int]$Port = 5000,
    [string]$LocalIP = "",
    [int]$DelayMs = 1000,
    [int]$Cycles = 30,
    [switch]$Gui,
    [switch]$NoGui,
    [switch]$AllAudio,
    [switch]$Help
)

# ------------------------------------------------------------------------------
# HELPER FUNCTIONS
# ------------------------------------------------------------------------------

function Write-LabBanner {
    try { Clear-Host } catch {}
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "       IPTV MULTICAST TEST LAB - WINDOWS CLIENT AUTOMATION        " -ForegroundColor Yellow -NoNewline
    Write-Host " v2.0" -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor Cyan
}

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DefaultLocalIP {
    try {
        # 1. Check for standard DUT router LAN (192.168.1.x)
        $dutIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like "192.168.1.*" -and $_.IPAddress -ne "192.168.1.1" } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($dutIp) { return $dutIp }

        # 2. Check for lab LAN subnet (10.20.0.x)
        $labIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like "10.20.0.*" -and $_.IPAddress -ne "10.20.0.1" } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($labIp) { return $labIp }

        # 3. Check for interface with active default IPv4 gateway
        $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric | Select-Object -First 1
        if ($defaultRoute) {
            $gwIp = Get-NetIPAddress -InterfaceIndex $defaultRoute.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -notlike "127.*" } |
                Select-Object -First 1 -ExpandProperty IPAddress
            if ($gwIp) { return $gwIp }
        }

        # 4. Fallback to first non-loopback IPv4
        $anyIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($anyIp) { return $anyIp }
    } catch {}

    return "192.168.1.108"
}

function Find-PlayerBinary {
    param([string]$Name)

    # 1. Search in PATH
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    # 2. Common install locations
    $candidates = @(
        "C:\ffmpeg\bin\$Name.exe",
        "C:\tools\ffmpeg\bin\$Name.exe",
        "C:\Program Files\ffmpeg\bin\$Name.exe",
        "C:\ProgramData\chocolatey\bin\$Name.exe",
        "C:\Program Files\VideoLAN\VLC\$Name.exe",
        "C:\Program Files (x86)\VideoLAN\VLC\$Name.exe"
    )

    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }

    return $null
}

# ------------------------------------------------------------------------------
# SETUP & FIREWALL & MULTICAST ROUTING
# ------------------------------------------------------------------------------

function Invoke-LabSetup {
    param([string]$TargetIP)

    Write-Host "`n[SETUP] Configuring Windows Network & Firewall for Multicast..." -ForegroundColor Cyan

    $isAdmin = Test-IsAdmin
    if (-not $isAdmin) {
        Write-Host "[WARN] Administrator privileges required for Firewall & Route setup." -ForegroundColor Yellow
        Write-Host "       Please right-click PowerShell and select 'Run as administrator', or run:" -ForegroundColor Yellow
        Write-Host "       Start-Process powershell -Verb runAs -ArgumentList `"-ExecutionPolicy Bypass -File $PSCommandPath Setup`"" -ForegroundColor White
        return
    }

    # 1. Firewall Rule for UDP Port 5000
    $ruleName = "IPTV Multicast Port 5000"
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "[OK] Firewall rule '$ruleName' is already enabled." -ForegroundColor Green
    } else {
        try {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -LocalPort 5000 -Protocol UDP -Action Allow | Out-Null
            Write-Host "[OK] Created Windows Defender Firewall Inbound rule for UDP Port 5000." -ForegroundColor Green
        } catch {
            Write-Host "[ERROR] Failed to add firewall rule: $_" -ForegroundColor Red
        }
    }

    # 2. Multicast Route 224.0.0.0/4 via selected interface
    if ($TargetIP) {
        try {
            route delete 224.0.0.0 2>$null | Out-Null
            route add 224.0.0.0 mask 240.0.0.0 $TargetIP metric 1 | Out-Null
            Write-Host "[OK] Added Multicast route (224.0.0.0/4 -> $TargetIP metric 1)." -ForegroundColor Green
            Write-Host "     Ensures IGMP/Multicast traffic routes via Ethernet, avoiding Wi-Fi conflicts." -ForegroundColor DarkGray
        } catch {
            Write-Host "[ERROR] Failed to configure route: $_" -ForegroundColor Red
        }
    }

    Write-Host "[SUCCESS] Setup complete! You can now receive multicast streams seamlessly.`n" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# PLAYBACK (GUI FFPLAY / VLC)
# ------------------------------------------------------------------------------

function Start-ChannelPlay {
    param(
        [int]$ChNumber,
        [string]$TargetIP
    )

    $group = "$MulticastBase$ChNumber"
    $ffplay = Find-PlayerBinary "ffplay"
    $vlc = Find-PlayerBinary "vlc"

    Write-Host "`n[PLAY] Opening Channel $ChNumber (${group}:${Port}) on $TargetIP..." -ForegroundColor Cyan

    if ($ffplay) {
        $url = "udp://${group}:${Port}?localaddr=${TargetIP}&buffer_size=1048576&overrun_nonfatal=1"
        Write-Host "[ENGINE] Using FFplay: $ffplay" -ForegroundColor Green
        Write-Host "[STREAM] $url" -ForegroundColor DarkGray
        Start-Process -FilePath $ffplay -ArgumentList "-window_title `"IPTV Channel $ChNumber ($group)`" `"$url`""
    } elseif ($vlc) {
        $mcastUrl = "udp://@${group}:${Port}"
        Write-Host "[ENGINE] Using VLC: $vlc" -ForegroundColor Green
        Write-Host "[STREAM] $mcastUrl --mcast-intf $TargetIP" -ForegroundColor DarkGray
        Start-Process -FilePath $vlc -ArgumentList "`"$mcastUrl`" --mcast-intf $TargetIP --meta-title `"IPTV Channel $ChNumber`""
    } else {
        Write-Host "[ERROR] Neither FFplay nor VLC was found on this Windows PC!" -ForegroundColor Red
        Write-Host "        Please install one of the following via Windows Terminal (winget):" -ForegroundColor Yellow
        Write-Host "          winget install Gyan.FFmpeg" -ForegroundColor White
        Write-Host "          winget install VideoLAN.VLC" -ForegroundColor White
    }
}

# ------------------------------------------------------------------------------
# SCALE 32 CHANNELS: NATIVE .NET SOCKET ENGINE (< 15 MB RAM)
# ------------------------------------------------------------------------------

function Start-ScaleSocketEngine {
    param(
        [int]$TotalCount,
        [string]$TargetIP
    )

    Write-Host "`n==================================================================" -ForegroundColor Cyan
    Write-Host "   ULTRA-LOW RAM SCALE TEST: $TotalCount CHANNELS (.NET UDP SOCKETS)  " -ForegroundColor Yellow
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "Local Interface:  $TargetIP" -ForegroundColor White
    Write-Host "Channel Range:    1 -> $TotalCount ($MulticastBase" -NoNewline
    Write-Host "1..${TotalCount}:${Port})" -ForegroundColor Yellow
    Write-Host "Memory Footprint: < 15 MB RAM total (Zero OOM risk)" -ForegroundColor Green
    Write-Host "Press 'Q' or 'Ctrl+C' to Leave all groups and exit" -ForegroundColor DarkYellow
    Write-Host "==================================================================" -ForegroundColor Cyan

    $localIpObj = [System.Net.IPAddress]::Parse($TargetIP)
    $sockets = @()
    $errors = 0

    Write-Host "`n[JOINING $TotalCount MULTICAST GROUPS...]" -ForegroundColor Cyan
    for ($i = 1; $i -le $TotalCount; $i++) {
        $groupStr = "$MulticastBase$i"
        try {
            $mcastIp = [System.Net.IPAddress]::Parse($groupStr)
            $udp = New-Object System.Net.Sockets.UdpClient
            $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
            $endPoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)
            $udp.Client.Bind($endPoint)
            $udp.Client.ReceiveTimeout = 200

            $mcastOpt = New-Object System.Net.Sockets.MulticastOption($mcastIp, $localIpObj)
            $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::AddMembership, $mcastOpt)

            $sockets += [PSCustomObject]@{
                Id       = $i
                Group    = $groupStr
                Client   = $udp
                Option   = $mcastOpt
                Packets  = 0
                Bytes    = 0
            }

            $chPadded = "{0:D2}" -f $i
            Write-Host "  [JOIN $chPadded/$TotalCount] $groupStr`:$Port -> " -NoNewline -ForegroundColor Gray
            Write-Host "OK (Active)" -ForegroundColor Green
        } catch {
            Write-Host "  [JOIN $chPadded/$TotalCount] $groupStr`:$Port -> " -NoNewline -ForegroundColor Gray
            Write-Host "FAILED ($($_.Exception.Message))" -ForegroundColor Red
            $errors++
        }
    }

    $activeCount = $sockets.Count
    Write-Host "`n[SUCCESS] Successfully joined $activeCount/$TotalCount multicast channels on router!" -ForegroundColor Green
    Write-Host "[MONITOR] Listening for incoming video packets (Sample 1 socket per cycle)...`n" -ForegroundColor Cyan

    $buffer = New-Object byte[] 4096
    $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

    try {
        $cycle = 0
        while ($true) {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape) {
                    break
                }
            }

            # Sample each socket for incoming packets
            $cycle++
            $totalPacketsSampled = 0
            foreach ($s in $sockets) {
                try {
                    while ($s.Client.Available -gt 0) {
                        $bytes = $s.Client.Client.ReceiveFrom($buffer, [ref]$remoteEp)
                        if ($bytes -gt 0) {
                            $s.Packets++
                            $s.Bytes += $bytes
                            $totalPacketsSampled++
                        }
                    }
                } catch {}
            }

            $timeStr = (Get-Date).ToString("HH:mm:ss")
            Write-Host "`r[$timeStr] Active Channels: $activeCount | Sampling: $totalPacketsSampled pkts received | Press 'Q' to exit" -ForegroundColor Yellow -NoNewline
            Start-Sleep -Milliseconds 500
        }
    } finally {
        Write-Host "`n`n[LEAVING ALL $activeCount GROUPS...]" -ForegroundColor Yellow
        foreach ($s in $sockets) {
            try {
                $s.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::DropMembership, $s.Option)
                $s.Client.Close()
                $s.Client.Dispose()
            } catch {}
        }
        Write-Host "[CLEANUP] All multicast memberships dropped cleanly. Router updated." -ForegroundColor Green
    }
}

# ------------------------------------------------------------------------------
# SCALE N CHANNELS: MULTI-CHANNEL GUI PLAYBACK (COMBINED OPTION 1 & 2)
# ------------------------------------------------------------------------------

function Start-ScaleGUIPlayEngine {
    param(
        [int]$TotalCount = 4,
        [string]$TargetIP,
        [switch]$AllAudio
    )

    $ffplay = Find-PlayerBinary "ffplay"
    $vlc = Find-PlayerBinary "vlc"

    if (-not $ffplay -and -not $vlc) {
        Write-Host "[ERROR] Neither FFplay nor VLC was found on this Windows PC!" -ForegroundColor Red
        Write-Host "        Please install one of the following via Windows Terminal (winget):" -ForegroundColor Yellow
        Write-Host "          winget install Gyan.FFmpeg" -ForegroundColor White
        Write-Host "          winget install VideoLAN.VLC" -ForegroundColor White
        return
    }

    $player = if ($ffplay) { $ffplay } else { $vlc }
    $playerName = if ($ffplay) { "FFplay" } else { "VLC" }

    Write-Host "`n==================================================================" -ForegroundColor Cyan
    Write-Host "   SCALE GUI TEST: OPEN $TotalCount CHANNELS WITH GUI ($playerName)   " -ForegroundColor Yellow
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "Local Interface:  $TargetIP" -ForegroundColor White
    Write-Host "Channel Range:    1 -> $TotalCount ($MulticastBase" -NoNewline
    Write-Host "1..${TotalCount}:${Port})" -ForegroundColor Yellow
    Write-Host "Player Engine:    $playerName ($player)" -ForegroundColor Green
    if (-not $AllAudio -and $TotalCount -gt 1) {
        Write-Host "Audio Policy:     Channel 1 audio active, Channels 2..$TotalCount muted (avoids noise)" -ForegroundColor DarkGray
    } else {
        Write-Host "Audio Policy:     Audio active on all channels" -ForegroundColor Yellow
    }
    Write-Host "==================================================================" -ForegroundColor Cyan

    # Determine screen working area for automatic grid tiling
    $screenWidth = 1920
    $screenHeight = 1080
    $screenX = 0
    $screenY = 0
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        if ($screen -and $screen.Width -gt 0 -and $screen.Height -gt 0) {
            $screenWidth = [int]$screen.Width
            $screenHeight = [int]$screen.Height
            $screenX = [int]$screen.X
            $screenY = [int]$screen.Y
        }
    } catch {}

    # Calculate optimal grid layout (columns x rows)
    if ($TotalCount -le 1) { $cols = 1; $rows = 1 }
    elseif ($TotalCount -le 2) { $cols = 2; $rows = 1 }
    elseif ($TotalCount -le 4) { $cols = 2; $rows = 2 }
    elseif ($TotalCount -le 6) { $cols = 3; $rows = 2 }
    elseif ($TotalCount -le 8) { $cols = 4; $rows = 2 }
    elseif ($TotalCount -le 9) { $cols = 3; $rows = 3 }
    elseif ($TotalCount -le 12) { $cols = 4; $rows = 3 }
    elseif ($TotalCount -le 16) { $cols = 4; $rows = 4 }
    elseif ($TotalCount -le 20) { $cols = 5; $rows = 4 }
    elseif ($TotalCount -le 24) { $cols = 6; $rows = 4 }
    elseif ($TotalCount -le 32) { $cols = 8; $rows = 4 }
    else {
        $cols = [Math]::Ceiling([Math]::Sqrt($TotalCount * (16 / 9)))
        $rows = [Math]::Ceiling($TotalCount / $cols)
    }

    $cellWidth = [int][Math]::Floor($screenWidth / $cols)
    $cellHeight = [int][Math]::Floor($screenHeight / $rows)
    $dispWidth = [Math]::Max(140, [int]($cellWidth - 16))
    $dispHeight = [Math]::Max(90, [int]($cellHeight - 38))

    Write-Host "`n[GUI GRID] Layout: ${cols}x${rows} grid | Cell: ${cellWidth}x${cellHeight}px (Video: ~${dispWidth}x${dispHeight}px)" -ForegroundColor DarkCyan

    $pids = @()
    Write-Host "`n[LAUNCHING $TotalCount GUI PLAYER INSTANCES...]" -ForegroundColor Cyan

    for ($i = 1; $i -le $TotalCount; $i++) {
        $group = "$MulticastBase$i"
        $idx = $i - 1
        $c = $idx % $cols
        $r = [int][Math]::Floor($idx / $cols)
        $posX = $screenX + ($c * $cellWidth)
        $posY = $screenY + ($r * $cellHeight)
        $chPadded = "{0:D2}" -f $i

        try {
            if ($ffplay) {
                $url = "udp://${group}:${Port}?localaddr=${TargetIP}&buffer_size=524288&overrun_nonfatal=1"
                $title = "IPTV Ch $i ($group)"
                $audioFlag = if ($i -gt 1 -and -not $AllAudio) { "-an" } else { "" }
                $argList = "-window_title `"$title`" -x $dispWidth -y $dispHeight -left $posX -top $posY $audioFlag `"$url`""
                $proc = Start-Process -FilePath $ffplay -ArgumentList $argList -PassThru
            } else {
                $mcastUrl = "udp://@${group}:${Port}"
                $title = "IPTV Ch $i ($group)"
                $audioFlag = if ($i -gt 1 -and -not $AllAudio) { "--no-audio" } else { "" }
                $argList = "`"$mcastUrl`" --mcast-intf $TargetIP --no-one-instance --meta-title `"$title`" --width $dispWidth --height $dispHeight --video-x $posX --video-y $posY $audioFlag"
                $proc = Start-Process -FilePath $vlc -ArgumentList $argList -PassThru
            }

            $pids += $proc.Id
            Write-Host "  [SPAWN $chPadded/$TotalCount] $playerName PID $($proc.Id) -> $group`:$Port (Grid $c,$r @ ${posX},${posY})" -ForegroundColor Gray
        } catch {
            Write-Host "  [SPAWN $chPadded/$TotalCount] FAILED for $group`:$Port ($($_.Exception.Message))" -ForegroundColor Red
        }

        # Small stagger to keep launch smooth
        Start-Sleep -Milliseconds 80
    }

    $activeCount = $pids.Count
    Write-Host "`n[SUCCESS] Successfully spawned $activeCount GUI player window(s)!" -ForegroundColor Green
    Write-Host "          Press 'Q' or Enter in this terminal to stop all GUI players..." -ForegroundColor Yellow

    try {
        while ($true) {
            $keyHit = $false
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Enter -or $key.Key -eq [ConsoleKey]::Escape) {
                        $keyHit = $true
                    }
                }
            } catch {
                $keyHit = $true
            }

            if ($keyHit) { break }

            $alive = @($pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
            if ($alive.Count -eq 0) {
                Write-Host "`n[INFO] All GUI player windows were closed." -ForegroundColor DarkGray
                break
            }

            $timeStr = (Get-Date).ToString("HH:mm:ss")
            Write-Host "`r[$timeStr] Active GUI Windows: $($alive.Count)/$TotalCount | Press 'Q' or Enter to stop all" -ForegroundColor Yellow -NoNewline
            Start-Sleep -Milliseconds 500
        }
    } finally {
        Write-Host "`n`n[CLEANUP] Stopping spawned GUI player processes..." -ForegroundColor Yellow
        foreach ($pidToKill in $pids) {
            Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue
        }
        Write-Host "[DONE] All GUI player processes stopped." -ForegroundColor Green
    }
}

# ------------------------------------------------------------------------------
# SCALE 32 CHANNELS: HEADLESS FFPLAY PROCESSES
# ------------------------------------------------------------------------------

function Start-ScaleFFplayEngine {
    param(
        [int]$TotalCount,
        [string]$TargetIP
    )

    $ffplay = Find-PlayerBinary "ffplay"
    if (-not $ffplay) {
        Write-Host "[ERROR] 'ffplay.exe' not found in PATH or standard directories!" -ForegroundColor Red
        Write-Host "        Please install FFmpeg: winget install Gyan.FFmpeg" -ForegroundColor Yellow
        return
    }

    Write-Host "`n[SCALE FFPLAY] Launching $TotalCount Headless FFplay Receivers..." -ForegroundColor Cyan
    Write-Host "[CONFIG] Low memory buffer (512KB per process) to prevent RAM exhaustion." -ForegroundColor DarkGray

    $pids = @()
    for ($i = 1; $i -le $TotalCount; $i++) {
        $group = "$MulticastBase$i"
        $url = "udp://${group}:${Port}?localaddr=${TargetIP}&buffer_size=524288&overrun_nonfatal=1"
        $proc = Start-Process -FilePath $ffplay -ArgumentList "-nodisp `"$url`"" -WindowStyle Hidden -PassThru
        $pids += $proc.Id
        $chPadded = "{0:D2}" -f $i
        Write-Host "  [SPAWN $chPadded/$TotalCount] FFplay PID $($proc.Id) -> $group`:$Port" -ForegroundColor Gray
    }

    Write-Host "`n[RUNNING] $TotalCount FFplay background processes active." -ForegroundColor Green
    Write-Host "          Press Enter to stop all FFplay processes..." -ForegroundColor Yellow
    [Console]::ReadLine() | Out-Null

    Write-Host "[CLEANUP] Stopping background FFplay processes..." -ForegroundColor Yellow
    Stop-Process -Name "ffplay" -Force -ErrorAction SilentlyContinue
    Write-Host "[DONE] All FFplay processes stopped." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# RAPID CHANNEL CHURN (ZAPPING 1 -> N)
# ------------------------------------------------------------------------------

function Start-ChannelChurnTest {
    param(
        [int]$TotalCount,
        [int]$NumCycles,
        [int]$Delay,
        [string]$TargetIP
    )

    Write-Host "`n==================================================================" -ForegroundColor Cyan
    Write-Host "      RAPID CHANNEL CHURN / ZAPPING BENCHMARK ($NumCycles CYCLES)        " -ForegroundColor Yellow
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "Channel Range:    1 -> $TotalCount" -ForegroundColor White
    Write-Host "Zapping Interval: $Delay ms" -ForegroundColor White
    Write-Host "Interface:        $TargetIP" -ForegroundColor White
    Write-Host "==================================================================" -ForegroundColor Cyan

    $localIpObj = [System.Net.IPAddress]::Parse($TargetIP)
    $buffer = New-Object byte[] 2048
    $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)

    for ($c = 1; $c -le $NumCycles; $c++) {
        Write-Host "`n--- [CYCLE $c / $NumCycles] ---" -ForegroundColor Cyan
        for ($i = 1; $i -le $TotalCount; $i++) {
            $groupStr = "$MulticastBase$i"
            $mcastIp = [System.Net.IPAddress]::Parse($groupStr)

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $udp = New-Object System.Net.Sockets.UdpClient
            $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
            $endPoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)
            $udp.Client.Bind($endPoint)
            $udp.Client.ReceiveTimeout = 200

            # JOIN
            $mcastOpt = New-Object System.Net.Sockets.MulticastOption($mcastIp, $localIpObj)
            $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::AddMembership, $mcastOpt)

            Start-Sleep -Milliseconds $Delay

            # Check if packets received
            $pkts = 0
            try {
                while ($udp.Client.Available -gt 0) {
                    $bytes = $udp.Client.Client.ReceiveFrom($buffer, [ref]$remoteEp)
                    if ($bytes -gt 0) { $pkts++ }
                }
            } catch {}

            # LEAVE
            $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::DropMembership, $mcastOpt)
            $udp.Close()
            $udp.Dispose()
            $sw.Stop()

            $statusText = if ($pkts -gt 0) { "STREAM OK ($pkts pkts)" } else { "JOINED (No UDP)" }
            $statusColor = if ($pkts -gt 0) { "Green" } else { "Yellow" }
            $chPadded = "{0:D2}" -f $i
            Write-Host "  ZAP -> Channel $chPadded ($groupStr) : " -NoNewline -ForegroundColor Gray
            Write-Host "$statusText " -ForegroundColor $statusColor -NoNewline
            Write-Host "($($sw.ElapsedMilliseconds)ms)" -ForegroundColor DarkGray
        }
    }

    Write-Host "`n[COMPLETED] Rapid Channel Churn test finished successfully ($NumCycles cycles).`n" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# STOP ALL CLIENTS
# ------------------------------------------------------------------------------

function Stop-AllClients {
    Write-Host "`n[STOP] Terminating any running media client processes..." -ForegroundColor Yellow
    $procs = Get-Process -Name "ffplay", "vlc" -ErrorAction SilentlyContinue
    if ($procs) {
        $count = $procs.Count
        Stop-Process -Name "ffplay", "vlc" -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Terminated $count client process(es)." -ForegroundColor Green
    } else {
        Write-Host "[OK] No ffplay or vlc processes were running." -ForegroundColor Green
    }
}

# ------------------------------------------------------------------------------
# MAIN EXECUTION DISPATCHER
# ------------------------------------------------------------------------------

if ($Help) {
    Write-LabBanner
    Write-Host "Usage: .\run_client.ps1 [-Mode <Mode>] [-Channel <int>] [-Count <int>] [-LocalIP <ip>] [-Gui] [-Port <int>]" -ForegroundColor Yellow
    Write-Host "`nModes:" -ForegroundColor Cyan
    Write-Host "  Interactive   - Open interactive numbered menu (Default)"
    Write-Host "  Play          - Open single channel GUI video (e.g. -Channel 1)"
    Write-Host "  Scale         - Scale join N multicast groups via .NET sockets (Default: 32)"
    Write-Host "  ScaleGUI      - Open N multicast channels in GUI player grid (Combine Option 1 & 2)"
    Write-Host "  ScaleFFplay   - Scale run N headless background FFplay receivers"
    Write-Host "  Churn         - High-speed channel zapping / join & leave benchmark"
    Write-Host "  Setup         - Configure Windows Defender Firewall & Multicast route (Admin)"
    Write-Host "  Status        - Display local network interface and player status"
    Write-Host "  Stop          - Stop all active client players (ffplay / vlc)"
    Write-Host "`nExamples:" -ForegroundColor Cyan
    Write-Host "  .\run_client.ps1 -LocalIP 192.168.1.100"
    Write-Host "  .\run_client.ps1 -Mode ScaleGUI -Count 4 -LocalIP 192.168.1.100"
    Write-Host "  .\run_client.ps1 -Mode Scale -Count 32 -Gui -LocalIP 192.168.1.100"
    Write-Host "  .\run_client.ps1 -Mode Scale -Count 32"
    Write-Host "  .\run_client.ps1 -Channel 5"
    exit 0
}

if (-not $LocalIP) {
    $LocalIP = Get-DefaultLocalIP
}

switch ($Mode) {
    "Play" {
        if ($Count -gt 1 -and $PSBoundParameters.ContainsKey('Count')) {
            Start-ScaleGUIPlayEngine -TotalCount $Count -TargetIP $LocalIP -AllAudio:$AllAudio
        } else {
            Start-ChannelPlay -ChNumber $Channel -TargetIP $LocalIP
        }
        exit 0
    }
    "Scale" {
        if ($Gui) {
            Start-ScaleGUIPlayEngine -TotalCount $Count -TargetIP $LocalIP -AllAudio:$AllAudio
        } else {
            Start-ScaleSocketEngine -TotalCount $Count -TargetIP $LocalIP
        }
        exit 0
    }
    { $_ -in "ScaleGUI", "PlayScale", "ScalePlay", "MultiPlay" } {
        Start-ScaleGUIPlayEngine -TotalCount $Count -TargetIP $LocalIP -AllAudio:$AllAudio
        exit 0
    }
    "ScaleFFplay" {
        Start-ScaleFFplayEngine -TotalCount $Count -TargetIP $LocalIP
        exit 0
    }
    "Churn" {
        Start-ChannelChurnTest -TotalCount $Count -NumCycles $Cycles -Delay $DelayMs -TargetIP $LocalIP
        exit 0
    }
    "Setup" {
        Invoke-LabSetup -TargetIP $LocalIP
        exit 0
    }
    "Stop" {
        Stop-AllClients
        exit 0
    }
    "Status" {
        Write-Host "Local IP: $LocalIP" -ForegroundColor Cyan
        $ffplay = Find-PlayerBinary "ffplay"
        $vlc = Find-PlayerBinary "vlc"
        Write-Host "FFplay:   $(if ($ffplay) { $ffplay } else { 'Not Found' })"
        Write-Host "VLC:      $(if ($vlc) { $vlc } else { 'Not Found' })"
        $procs = Get-Process -Name "ffplay", "vlc" -ErrorAction SilentlyContinue
        Write-Host "Active:   $(if ($procs) { "$($procs.Count) process(es)" } else { 'None' })"
        exit 0
    }
    "Interactive" {
        while ($true) {
            Write-LabBanner
            $ffplayPath = Find-PlayerBinary "ffplay"
            $vlcPath = Find-PlayerBinary "vlc"

            Write-Host "  Active Local IP:  " -NoNewline -ForegroundColor Gray
            Write-Host "$LocalIP" -ForegroundColor Green
            Write-Host "  FFplay Player:    " -NoNewline -ForegroundColor Gray
            Write-Host "$(if ($ffplayPath) { '[OK] Installed' } else { '[!] Not Found' })" -ForegroundColor $(if ($ffplayPath) { 'Green' } else { 'DarkYellow' })
            Write-Host "  VLC Player:       " -NoNewline -ForegroundColor Gray
            Write-Host "$(if ($vlcPath) { '[OK] Installed' } else { '[!] Not Found' })" -ForegroundColor $(if ($vlcPath) { 'Green' } else { 'DarkYellow' })
            Write-Host "------------------------------------------------------------------" -ForegroundColor Cyan
            Write-Host "  [1] " -NoNewline -ForegroundColor Yellow
            Write-Host "Play Single Channel (GUI Video & Audio) [Channel 1..32]" -ForegroundColor White
            Write-Host "  [2] " -NoNewline -ForegroundColor Yellow
            Write-Host "Scale Test: Join 32 Channels (Ultra-Light Socket Engine, < 15MB RAM)" -ForegroundColor White
            Write-Host "  [3] " -NoNewline -ForegroundColor Yellow
            Write-Host "Scale GUI: Play N Channels with Video Grid (Combine Option 1 & 2)" -ForegroundColor White
            Write-Host "  [4] " -NoNewline -ForegroundColor Yellow
            Write-Host "Scale Test: Run 32 Headless FFplay Processes" -ForegroundColor White
            Write-Host "  [5] " -NoNewline -ForegroundColor Yellow
            Write-Host "Rapid Channel Churn / Zapping Benchmark (1 -> 32)" -ForegroundColor White
            Write-Host "  [6] " -NoNewline -ForegroundColor Yellow
            Write-Host "Configure Firewall & Multicast Route (Administrator)" -ForegroundColor White
            Write-Host "  [7] " -NoNewline -ForegroundColor Yellow
            Write-Host "Change Local Network IP (Current: $LocalIP)" -ForegroundColor White
            Write-Host "  [8] " -NoNewline -ForegroundColor Yellow
            Write-Host "Stop All Background Clients (kill ffplay/vlc)" -ForegroundColor White
            Write-Host "  [0] " -NoNewline -ForegroundColor Yellow
            Write-Host "Exit" -ForegroundColor Gray
            Write-Host "==================================================================" -ForegroundColor Cyan

            $choice = Read-Host "Select an option [0-8]"
            switch ($choice) {
                "1" {
                    $chInput = Read-Host "Enter channel number to play [1-32] (Default: 1)"
                    if (-not $chInput) { $chInput = 1 }
                    Start-ChannelPlay -ChNumber ([int]$chInput) -TargetIP $LocalIP
                    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
                    try { [Console]::ReadLine() | Out-Null } catch {}
                }
                "2" {
                    $cntInput = Read-Host "Enter number of channels to join (Default: 32)"
                    if (-not $cntInput) { $cntInput = 32 }
                    Start-ScaleSocketEngine -TotalCount ([int]$cntInput) -TargetIP $LocalIP
                    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
                    try { [Console]::ReadLine() | Out-Null } catch {}
                }
                { $_ -in "3", "12", "1+2", "c", "gui" } {
                    $cntInput = Read-Host "Enter number of GUI channels to open [1..32] (Default: 4)"
                    if (-not $cntInput) { $cntInput = 4 }
                    Start-ScaleGUIPlayEngine -TotalCount ([int]$cntInput) -TargetIP $LocalIP
                    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
                    try { [Console]::ReadLine() | Out-Null } catch {}
                }
                "4" {
                    $cntInput = Read-Host "Enter number of FFplay processes (Default: 32)"
                    if (-not $cntInput) { $cntInput = 32 }
                    Start-ScaleFFplayEngine -TotalCount ([int]$cntInput) -TargetIP $LocalIP
                    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
                    try { [Console]::ReadLine() | Out-Null } catch {}
                }
                "5" {
                    $cntInput = Read-Host "Enter number of channels for churn (Default: 32)"
                    if (-not $cntInput) { $cntInput = 32 }
                    $delayInput = Read-Host "Enter zapping interval in ms (Default: 500)"
                    if (-not $delayInput) { $delayInput = 500 }
                    Start-ChannelChurnTest -TotalCount ([int]$cntInput) -NumCycles 5 -Delay ([int]$delayInput) -TargetIP $LocalIP
                    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
                    try { [Console]::ReadLine() | Out-Null } catch {}
                }
                "6" {
                    Invoke-LabSetup -TargetIP $LocalIP
                    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
                    try { [Console]::ReadLine() | Out-Null } catch {}
                }
                "7" {
                    $newIp = Read-Host "Enter new local LAN IPv4 address"
                    if ($newIp) { $LocalIP = $newIp }
                }
                { $_ -in "8", "stop" } {
                    Stop-AllClients
                    Write-Host "`nPress Enter to return to menu..." -ForegroundColor DarkGray
                    try { [Console]::ReadLine() | Out-Null } catch {}
                }
                "0" {
                    Write-Host "Goodbye!" -ForegroundColor Green
                    exit 0
                }
                default {
                    Write-Host "Invalid choice. Please select 0 to 8." -ForegroundColor Red
                    Start-Sleep -Seconds 1
                }
            }
        }
    }
}
