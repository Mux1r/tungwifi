#Requires -Version 5.1
# WiFi 自動重連監控 — 事件驅動 (即時反應) + 定時保底
# 職責：監控連線、斷線重連。登入 Portal 委託 wifi-login.ps1 執行。
$SSID = "guest_tung"
$LoginScript  = "$PSScriptRoot\wifi-login.ps1"   # 登入邏輯集中在此
$PollInterval = 180
$EventSleep = 3
$DebounceSec = 15
$LogFile      = "$PSScriptRoot\wifi-monitor.log"
$MaxLogKB = 500

# 單一實例鎖：排程工作與 dashboard 同時啟動時，只留一份（兩份會同時 POST Portal 互相打架）
$script:Mutex = New-Object System.Threading.Mutex($false, "Global\WifiMonitor_guest_tung")
if (-not $script:Mutex.WaitOne(0)) {
    Write-Host "已有另一個 wifi-monitor 在執行，本實例結束。"
    exit
}

# ── 工具函式 ────────────────────────────────────────────────

function Write-Log {
    param([string]$Msg, [string]$Color = "White")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg"
    try {
        if ((Get-Item $LogFile -ErrorAction SilentlyContinue).Length / 1KB -gt $MaxLogKB) {
            $keep = Get-Content $LogFile -Tail 200
            Set-Content $LogFile $keep
        }
        Add-Content -Path $LogFile -Value $line
    } catch {}
    Write-Host $line -ForegroundColor $Color
}


function Test-Online {
    # generate_204 必須回傳 204（Portal 劫持後會變 200，視為未登入）
    try {
        $r = Invoke-WebRequest -Uri "http://connectivitycheck.gstatic.com/generate_204" `
             -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        if ($r.StatusCode -eq 204) { return $true }
    } catch {}

    # msftconnecttest 需驗證 body，Portal 回傳的是登入頁 HTML
    try {
        $r = Invoke-WebRequest -Uri "http://www.msftconnecttest.com/connecttest.txt" `
             -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        if ($r.StatusCode -eq 200 -and $r.Content -match "Microsoft Connect Test") { return $true }
    } catch {}

    return $false
}

function Connect-WiFiSSID {
    $out = netsh wlan connect name="$SSID"
    if ($out -notmatch "completed successfully") {
        Write-Log "netsh: $($out -join ' ')" "Red"
    }
    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -Seconds 2
        if ((Get-NetConnectionProfile -ErrorAction SilentlyContinue).Name -contains $SSID) {
            return $true
        }
    }
    return $false
}


function Get-WifiState {
    # 回傳 "on"（連著 $SSID）、"idle"（真的沒連任何網路）或 "busy"（連著別的網路，或正在切換中）
    $info = (netsh wlan show interfaces) -join "`n"
    $state = [regex]::Match($info, "(?m)^\s*State\s*:\s*(.+?)\s*$").Groups[1].Value
    $curSsid = [regex]::Match($info, "(?m)^\s*SSID\s*:\s*(.+?)\s*$").Groups[1].Value   # 不能叫 $ssid，PowerShell 變數不分大小寫會蓋掉 $SSID
    if ($state -eq "connected" -and $curSsid -eq $SSID) { return "on" }
    if ($state -eq "disconnected") { return "idle" }
    return "busy"
}

function Invoke-ReconnectFlow {
    param([string]$Reason)
    Write-Log "重連觸發 [$Reason]" "Yellow"

    # 斷線後先等 30s 再看：手動連熱點失敗時，使用者常在十幾秒內再試一次，不能趁這個空檔把他拉回 guest_tung。
    $st = Get-WifiState
    if ($st -eq "idle") { Start-Sleep -Seconds 30; $st = Get-WifiState }

    # 使用者連著別的網路、或正在切換（associating/authenticating），都不搶
    if ($st -eq "busy") {
        Write-Log "使用者正在用或正在切換到其他網路，略過自動重連 '$SSID'" "Cyan"
        return
    }

    if ($st -eq "idle") {
        Write-Log "重新連接 WiFi '$SSID'..." "Yellow"
        $connected = $false
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            # 每次重試前都再看一次，避免使用者在重試期間手動連別的網路又被踢掉
            if ($attempt -gt 1) {
                $st = Get-WifiState
                if ($st -eq "on") { $connected = $true; break }   # Windows 自己連回去了，直接往下做 Portal 登入
                if ($st -eq "busy") {
                    Write-Log "使用者正在用或正在切換到其他網路，停止重試" "Cyan"
                    return
                }
            }
            $visible = (netsh wlan show networks mode=bssid) -join "`n" | Select-String ([regex]::Escape($SSID))
            if (-not $visible) {
                Write-Log "掃描不到 '$SSID' (第 $attempt 次)，原因：AP 不可見或訊號太弱" "Red"
            } else {
                Write-Log "找到 '$SSID'，嘗試連接 (第 $attempt/5 次)..." "Yellow"
            }
            if (Connect-WiFiSSID) { $connected = $true; break }
            Write-Log "連接失敗，30s 後重試..." "Red"
            Start-Sleep -Seconds 30
        }
        if (-not $connected) {
            Write-Log "重試 5 次仍失敗，等待下次觸發" "Red"
            Add-FailStreak
            return
        }
        Write-Log "WiFi 已連接，等待 DHCP..." "Green"
        Start-Sleep -Seconds 5
    }

    # 剛換 IP 時 Portal 常瞬間拒連，失敗後隔 10s 再試一次（手動晚點按就成功 = 純時機問題）
    # 兩次都失敗就把 WiFi 斷開重連再試：Portal 有時卡在「Wi-Fi 連著、但登入頁不出來」，
    # 只有重新關聯才會放出登入頁（2026-10-23 手動開關 WiFi 才救回來）
    foreach ($try in 1..3) {
        if ($try -eq 3) {
            if ((Get-WifiState) -ne "on") { Write-Log "WiFi 已不在 '$SSID'，不重連" "Cyan"; break }
            Write-Log "登入兩次無效，斷開 WiFi 重新連接..." "Yellow"
            netsh wlan disconnect | Out-Null
            Start-Sleep -Seconds 3
            if (-not (Connect-WiFiSSID)) { Write-Log "重新連接 WiFi 失敗" "Red"; break }
            Start-Sleep -Seconds 5
        }
        Write-Log "送出 Captive Portal 登入 (wifi-login.ps1) 第 $try/3 次..." "Yellow"
        & powershell.exe -ExecutionPolicy Bypass -NonInteractive `
            -File $LoginScript -Silent 2>&1 | Out-Null
        Start-Sleep -Seconds 5

        if (Test-Online) {
            Write-Log "登入成功，網路已恢復!" "Green"
            $script:FailStreak = 0
            return
        }
        if ($try -eq 1) { Start-Sleep -Seconds 10 }
    }
    Write-Log "登入後仍無法上網，等待下次觸發" "Red"
    Add-FailStreak
}

function Add-FailStreak {
    # 最後手段：連續 3 輪（約 10 分鐘）都救不回來，就把 Wi-Fi 網卡整個關掉再打開，等同手動開關 WiFi
    $script:FailStreak++
    if ($script:FailStreak -ge 3) {
        $script:FailStreak = 0
        $nic = Get-NetAdapter | Where-Object NdisPhysicalMedium -eq 9 | Select-Object -First 1   # 9 = 802.11 無線網卡
        if ($nic) {
            Write-Log "連續 3 輪失敗，重啟 Wi-Fi 網卡 '$($nic.Name)'..." "Yellow"
            try { Restart-NetAdapter -Name $nic.Name -Confirm:$false -ErrorAction Stop }
            catch { Write-Log "重啟網卡失敗: $($_.Exception.Message)" "Red" }
        }
    }
}

# ── 訂閱 .NET 網路事件 ──────────────────────────────────────
# 不用 -Action，讓事件進入佇列，主迴圈統一取出處理

Unregister-Event -SourceIdentifier "WifiMon_Avail" -ErrorAction SilentlyContinue
Unregister-Event -SourceIdentifier "WifiMon_Addr"  -ErrorAction SilentlyContinue

Register-ObjectEvent `
    -InputObject  ([System.Net.NetworkInformation.NetworkChange]) `
    -EventName    NetworkAvailabilityChanged `
    -SourceIdentifier "WifiMon_Avail"

Register-ObjectEvent `
    -InputObject  ([System.Net.NetworkInformation.NetworkChange]) `
    -EventName    NetworkAddressChanged `
    -SourceIdentifier "WifiMon_Addr"

Write-Log "=== WiFi 監控啟動 (事件驅動 + ${PollInterval}s 保底) ===" "Cyan"

# ── 主迴圈 ──────────────────────────────────────────────────

$script:FailStreak = 0                # 連續登入失敗輪數，到 3 就重啟網卡
$lastAction  = [DateTime]::MinValue   # 上次執行重連的時間（防抖）
$lastPoll    = [DateTime]::Now        # 上次保底輪詢時間

while ($true) {
  # 任何意外錯誤都只記 log 不讓監控死掉；常駐程式停了就沒人顧網路
  try {
    $now      = [DateTime]::Now
    $cooldown = ($now - $lastAction).TotalSeconds -lt $DebounceSec

    # ── 1. 掃描事件佇列 ──────────────────────────────────
    $events = Get-Event -ErrorAction SilentlyContinue |
              Where-Object { $_.SourceIdentifier -like "WifiMon_*" }

    if ($events) {
        foreach ($evt in $events) {
            # NetworkAvailabilityChanged 攜帶 IsAvailable
            if ($evt.SourceIdentifier -eq "WifiMon_Avail") {
                $isAvail = try { $evt.SourceArgs[1].IsAvailable } catch { $null }
                $label   = if ($isAvail -eq $false) { "網路中斷事件" }
                           elseif ($isAvail -eq $true) { "網路恢復事件" }
                           else { "網路狀態事件" }
            } else {
                $label = "IP 位址變更事件"
            }
            Remove-Event -EventIdentifier $evt.EventIdentifier -ErrorAction SilentlyContinue

            if (-not $cooldown) {
                $lastAction = $now
                $cooldown   = $true
                # 若是「恢復事件」先等 IP 穩定，再確認是否需要 Portal 登入
                if ($label -eq "網路恢復事件") { Start-Sleep -Seconds 4 }
                if (-not (Test-Online)) {
                    Invoke-ReconnectFlow -Reason $label
                    $lastPoll = [DateTime]::Now
                }
            }
        }
    }

    # ── 2. 保底定時輪詢 ──────────────────────────────────
    if (($now - $lastPoll).TotalSeconds -ge $PollInterval) {
        $lastPoll = $now
        if (-not $cooldown -and -not (Test-Online)) {
            $lastAction = $now
            Invoke-ReconnectFlow -Reason "定時保底"
        }
    }
  } catch {
    Write-Log "主迴圈錯誤: $($_.Exception.Message)" "Red"
  }

    Start-Sleep -Seconds $EventSleep
}
