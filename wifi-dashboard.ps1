#Requires -Version 5.1
# WiFi 控制台 — 狀態、操作、日誌、參數設定
# 深色介面色票取自已驗證的 dataviz 狀態色盤（深色底對比 ≥3:1）

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# PS1 用 $PSScriptRoot；EXE 用執行檔所在目錄
$script:Dir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    [System.IO.Path]::GetDirectoryName(
        [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    )
}
$script:MonitorScript = Join-Path $script:Dir "wifi-monitor.ps1"
$script:LoginScript   = Join-Path $script:Dir "wifi-login.ps1"
$script:CheckinScript = Join-Path $script:Dir "punch\auto-checkin-v2.ps1"
$script:LogFile       = Join-Path $script:Dir "wifi-monitor.log"
$script:SettingsFile  = Join-Path $script:Dir "settings.ps1"   # 個人設定，不進 GitHub、自動更新不會蓋掉

$script:TaskSvc = New-Object -ComObject Schedule.Service
$script:TaskSvc.Connect()

$MonitorTask = "WiFi-AutoLogin-Monitor"
$PunchTasks  = "PunchIn-Booked", "PunchOut-Booked"   # nightly-book.ps1 每晚建的預約

# ══════════════════════════════════════════════════════════════
# 色票（dataviz 深色模式：頁面/卡片/墨色/狀態色）
# ══════════════════════════════════════════════════════════════

$C_PAGE = [System.Drawing.Color]::FromArgb(13, 13, 13)     # 頁面底
$C_CARD = [System.Drawing.Color]::FromArgb(26, 26, 25)     # 卡片面
$C_WELL = [System.Drawing.Color]::FromArgb(19, 19, 18)     # 內凹區（日誌）
$C_INK  = [System.Drawing.Color]::FromArgb(255, 255, 255)  # 主要文字
$C_INK2 = [System.Drawing.Color]::FromArgb(195, 194, 183)  # 次要文字
$C_MUTE = [System.Drawing.Color]::FromArgb(137, 135, 129)  # 弱化文字
$C_HAIR = [System.Drawing.Color]::FromArgb(44, 44, 42)     # 髮絲線
$C_GOOD = [System.Drawing.Color]::FromArgb(12, 163, 12)    # 狀態：正常
$C_WARN = [System.Drawing.Color]::FromArgb(250, 178, 25)   # 狀態：警告
$C_CRIT = [System.Drawing.Color]::FromArgb(208, 59, 59)    # 狀態：異常
$C_ACC  = [System.Drawing.Color]::FromArgb(57, 135, 229)   # 強調藍

$B_GREEN = [System.Drawing.Color]::FromArgb(23, 99, 46)
$B_RED   = [System.Drawing.Color]::FromArgb(126, 47, 47)
$B_BLUE  = [System.Drawing.Color]::FromArgb(36, 86, 127)
$B_GRAY  = [System.Drawing.Color]::FromArgb(38, 38, 43)

$F_Title = New-Object System.Drawing.Font("Segoe UI Semibold", 13)
$F_H     = New-Object System.Drawing.Font("Segoe UI Semibold", 9.75)
$F_Body  = New-Object System.Drawing.Font("Segoe UI", 9.5)
$F_Cap   = New-Object System.Drawing.Font("Segoe UI", 8)
$F_Val   = New-Object System.Drawing.Font("Segoe UI Semibold", 10.5)
$F_Btn   = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
$F_Mono  = New-Object System.Drawing.Font("Consolas", 9)

$script:HairPen = New-Object System.Drawing.Pen $C_HAIR, 1

# ══════════════════════════════════════════════════════════════
# 參數讀寫（沿用原邏輯）
# ══════════════════════════════════════════════════════════════

function Read-Param([string]$File, [string]$VarName) {
    foreach ($line in (Get-Content $File -ErrorAction SilentlyContinue)) {
        $p = '^\s*\$' + [regex]::Escape($VarName) + '\s*=\s*(.+)$'
        if ($line -match $p) {
            $v = $Matches[1] -replace '\s*#.*$', ''
            return $v.Trim().Trim('"').Trim("'").Trim()
        }
    }
    return ""
}

function Write-Param([string]$File, [string]$VarName, [string]$Value) {
    $content = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
    $repl    = if ($Value -match '^\d+$') { "`$$VarName = $Value" }
               else                        { "`$$VarName = `"$Value`"" }
    $pattern    = '(?m)^\s*\$' + [regex]::Escape($VarName) + '\s*=\s*[^\r\n]+'
    $newContent = [regex]::Replace($content, $pattern, $repl)
    [System.IO.File]::WriteAllText($File, $newContent, [System.Text.Encoding]::UTF8)
}

# 個人設定優先，沒設過就用 wifi-monitor.ps1 裡的預設值
function Read-Setting([string]$Name) {
    $v = Read-Param $script:SettingsFile $Name
    if ($v -eq '') { $v = Read-Param $script:MonitorScript $Name }
    $v
}
# 只寫進 settings.ps1：有這一行就改，沒有就加在最後
function Write-Setting([string]$Name, [string]$Value) {
    if (-not (Test-Path $script:SettingsFile)) {
        [IO.File]::WriteAllText($script:SettingsFile,
            "# 個人設定（控制面板寫入）。只存在這台電腦，不進 GitHub，自動更新也不會蓋掉。`r`n", (New-Object Text.UTF8Encoding $true))
    }
    if ((Get-Content $script:SettingsFile -Encoding UTF8) -match ('^\s*\$' + [regex]::Escape($Name) + '\s*=')) {
        Write-Param $script:SettingsFile $Name $Value
    } else {
        $line = if ($Value -match '^\d+$') { "`$$Name = $Value" } else { "`$$Name = `"$Value`"" }
        [IO.File]::AppendAllText($script:SettingsFile, "$line`r`n", (New-Object Text.UTF8Encoding $false))
    }
}

$script:SSID = Read-Setting "SSID"

# ══════════════════════════════════════════════════════════════
# 狀態偵測（不靠 CommandLine，提權程序也偵測得到）
# ══════════════════════════════════════════════════════════════

function Test-MonitorRunning {
    # 監控腳本啟動時會持有此 mutex；開得到就代表在跑（無論權限）
    try {
        $m = [System.Threading.Mutex]::OpenExisting("Global\WifiMonitor_guest_tung")
        $m.Dispose(); return $true
    } catch { return $false }
}

function Get-WifiConnected {
    # ponytail: Get-NetConnectionProfile 不需定位權限；netsh 需要
    return (Get-NetConnectionProfile -ErrorAction SilentlyContinue).Name -contains $script:SSID
}

function Get-TaskRow([string]$Name) {
    # 用 COM 查：Get-ScheduledTask + Get-ScheduledTaskInfo 一張要 1.5 秒，而且跑在畫面執行緒上會卡住視窗
    try { $t = $script:TaskSvc.GetFolder("\").GetTask($Name) } catch { return $null }
    $next = $t.NextRunTime
    if ($next.Year -lt 2000) { $next = $null }   # 沒有下次執行時 COM 回 1899-12-30
    return [pscustomobject]@{ Enabled = $t.Enabled; Next = $next }
}

# ══════════════════════════════════════════════════════════════
# 啟動 / 停止（優先走排程工作，權限由工作排程器處理）
# ══════════════════════════════════════════════════════════════

function Start-MonitorNow {
    try { Start-ScheduledTask -TaskName $MonitorTask -ErrorAction Stop }
    catch {
        Start-Process powershell.exe -WindowStyle Hidden `
            -ArgumentList "-ExecutionPolicy Bypass -NonInteractive -File `"$script:MonitorScript`""
    }
}

function Stop-MonitorNow {
    try { Stop-ScheduledTask -TaskName $MonitorTask -ErrorAction SilentlyContinue } catch {}
    # 非排程啟動、與本面板同權限的實例
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'wifi-monitor\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ══════════════════════════════════════════════════════════════
# UI 輔助
# ══════════════════════════════════════════════════════════════

function New-Card([System.Windows.Forms.Control]$Parent, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location  = New-Object System.Drawing.Point($X, $Y)
    $p.Size      = New-Object System.Drawing.Size($W, $H)
    $p.BackColor = $C_CARD
    $p.Add_Paint({ $_.Graphics.DrawRectangle($script:HairPen, 0, 0, $this.Width - 1, $this.Height - 1) })
    $Parent.Controls.Add($p)
    return $p
}

function New-Lbl([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
                 [System.Drawing.Font]$Font, [System.Drawing.Color]$Color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $Text
    $l.Location  = New-Object System.Drawing.Point($X, $Y)
    $l.Size      = New-Object System.Drawing.Size($W, $H)
    $l.Font      = $Font
    $l.ForeColor = $Color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $Parent.Controls.Add($l)
    return $l
}

function New-Btn([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
                 [System.Drawing.Color]$BG) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text      = $Text
    $b.Location  = New-Object System.Drawing.Point($X, $Y)
    $b.Size      = New-Object System.Drawing.Size($W, $H)
    $b.BackColor = $BG
    $b.ForeColor = $C_INK
    $b.Font      = $F_Btn
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 0
    $b.Cursor    = "Hand"
    $hov = [System.Drawing.Color]::FromArgb(
        [Math]::Min(255, $BG.R + 24), [Math]::Min(255, $BG.G + 24), [Math]::Min(255, $BG.B + 24))
    $b.Tag = @{ N = $BG; H = $hov }
    $b.Add_MouseEnter({ $this.BackColor = $this.Tag.H })
    $b.Add_MouseLeave({ $this.BackColor = $this.Tag.N })
    $Parent.Controls.Add($b)
    return $b
}

function New-Tile([System.Windows.Forms.Control]$Parent, [string]$Caption, [int]$X) {
    $card = New-Card $Parent $X 8 166 66
    $null = New-Lbl $card $Caption 12 9 140 15 $F_Cap $C_MUTE
    return (New-Lbl $card "○ 檢查中..." 12 28 148 24 $F_Val $C_MUTE)
}

function Set-Tile([System.Windows.Forms.Label]$Lbl, [string]$Text, [System.Drawing.Color]$Color) {
    $Lbl.Text = $Text; $Lbl.ForeColor = $Color
}

# ══════════════════════════════════════════════════════════════
# 主視窗
# ══════════════════════════════════════════════════════════════

$form = New-Object System.Windows.Forms.Form
$form.Text            = "WiFi 控制台"
$form.ClientSize      = New-Object System.Drawing.Size(720, 666)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox     = $false
$form.StartPosition   = "CenterScreen"
$form.BackColor       = $C_PAGE
$form.ForeColor       = $C_INK
$form.Font            = $F_Body

# ── 頂欄 + 導覽 ───────────────────────────────────────────────
$null = New-Lbl $form "WiFi 控制台" 16 11 220 26 $F_Title $C_INK
$navDash = New-Btn $form "儀表板" 520 9 88 30 $B_GRAY
$navSet  = New-Btn $form "設定"   616 9 88 30 $B_GRAY

$dash = New-Object System.Windows.Forms.Panel
$dash.Location = New-Object System.Drawing.Point(0, 48)
$dash.Size     = New-Object System.Drawing.Size(720, 618)
$dash.BackColor = $C_PAGE
$setv = New-Object System.Windows.Forms.Panel
$setv.Location = $dash.Location
$setv.Size     = $dash.Size
$setv.BackColor = $C_PAGE
$setv.Visible  = $false
$form.Controls.AddRange(@($dash, $setv))

function Show-View([int]$Idx) {
    $dash.Visible = ($Idx -eq 0)
    $setv.Visible = ($Idx -eq 1)
    foreach ($pair in @(@($navDash, 0), @($navSet, 1))) {
        $b = $pair[0]
        $on = ($pair[1] -eq $Idx)
        $bg = if ($on) { $C_CARD } else { $C_PAGE }
        $b.Tag = @{ N = $bg; H = $b.Tag.H }
        $b.BackColor = $bg
        $b.ForeColor = if ($on) { $C_INK } else { $C_MUTE }
    }
}
$navDash.Add_Click({ Show-View 0 })
$navSet.Add_Click({ Show-View 1 })

# ── 儀表板：狀態列 ────────────────────────────────────────────
$tileWifi    = New-Tile $dash "WIFI 連線"   16
$tileNet     = New-Tile $dash "網路連通"    188
$tileMonitor = New-Tile $dash "監控程序"    360
$tilePunch   = New-Tile $dash "下次打卡"    532
Set-Tile $tileNet "○ 未檢查" $C_MUTE

# ── 儀表板：操作 ──────────────────────────────────────────────
$cardOp = New-Card $dash 16 84 688 114
$null = New-Lbl $cardOp "操作" 12 8 200 18 $F_H $C_INK2
$btnStart    = New-Btn $cardOp "▶  啟動監控" 12  34 158 32 $B_GREEN
$btnStop     = New-Btn $cardOp "■  停止監控" 178 34 158 32 $B_RED
$btnLogin    = New-Btn $cardOp "⚡ 立即登入"  344 34 158 32 $B_BLUE
$btnCheck    = New-Btn $cardOp "◎  立即檢查" 510 34 158 32 $B_GRAY
$btnPunch    = New-Btn $cardOp "◷  立即打卡" 12  74 656 32 $B_BLUE

# ── 儀表板：日誌 ──────────────────────────────────────────────
$cardLog = New-Card $dash 16 208 688 400
$null = New-Lbl $cardLog "監控日誌（每 3 秒更新，最後 100 行）" 12 9 380 18 $F_H $C_INK2
$btnRefresh = New-Btn $cardLog "重新整理" 498 7 92 26 $B_GRAY
$btnClear   = New-Btn $cardLog "清除畫面" 596 7 80 26 $B_GRAY

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location    = New-Object System.Drawing.Point(1, 38)
$rtbLog.Size        = New-Object System.Drawing.Size(686, 361)
$rtbLog.ReadOnly    = $true
$rtbLog.BackColor   = $C_WELL
$rtbLog.ForeColor   = $C_INK2
$rtbLog.Font        = $F_Mono
$rtbLog.BorderStyle = "None"
$rtbLog.ScrollBars  = "Vertical"
$rtbLog.WordWrap    = $false
$cardLog.Controls.Add($rtbLog)

# ── 設定頁 ────────────────────────────────────────────────────
function New-ParamRow([System.Windows.Forms.Control]$Parent, [int]$Y,
                      [string]$Label, [string]$Value, [string]$Hint) {
    $null = New-Lbl $Parent $Label 12 ($Y + 3) 180 20 $F_Body $C_INK2
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text        = $Value
    $t.Location    = New-Object System.Drawing.Point(196, $Y)
    $t.Size        = New-Object System.Drawing.Size(150, 24)
    $t.BackColor   = [System.Drawing.Color]::FromArgb(36, 36, 40)
    $t.ForeColor   = $C_INK
    $t.BorderStyle = "FixedSingle"
    $Parent.Controls.Add($t)
    $null = New-Lbl $Parent $Hint 360 ($Y + 3) 310 20 $F_Cap $C_MUTE
    return $t
}

$grpM = New-Card $setv 16 8 688 206
$null = New-Lbl $grpM "wifi-monitor.ps1" 12 8 300 18 $F_H $C_INK2
$txSSID         = New-ParamRow $grpM 36  "SSID（WiFi 名稱）"  (Read-Setting "SSID")         "目標 WiFi 網路"
$txPollInterval = New-ParamRow $grpM 68  "PollInterval（秒）" (Read-Setting "PollInterval") "保底輪詢間隔，預設 180"
$txEventSleep   = New-ParamRow $grpM 100 "EventSleep（秒）"   (Read-Setting "EventSleep")   "事件掃描間隔，預設 3"
$txDebounceSec  = New-ParamRow $grpM 132 "DebounceSec（秒）"  (Read-Setting "DebounceSec")  "重複觸發冷卻，預設 15"
$txMaxLogKB     = New-ParamRow $grpM 164 "MaxLogKB（KB）"     (Read-Setting "MaxLogKB")     "日誌大小上限，預設 500"

# Portal 帳密不在這裡改：wifi-login.ps1 是好幾組輪流試的清單，要改直接編輯那個檔
$btnSave = New-Btn $setv "儲存設定" 16 222 140 34 $B_GREEN
$lblSaveMsg = New-Lbl $setv "" 168 230 520 20 $F_Body $C_GOOD

# 夜間睡眠開關：開＝註冊 NightSleep/MorningWake 排程，關＝刪掉（實際動作在 sleep.ps1）
$grpS = New-Card $setv 16 274 688 76
$null = New-Lbl $grpS "夜間睡眠" 12 8 300 18 $F_H $C_INK2
$lblSleep = New-Lbl $grpS "" 12 36 500 34 $F_Cap $C_MUTE
$btnSleep = New-Btn $grpS "" 536 26 140 32 $B_GRAY
function Update-SleepCard {
    $on = [bool](Get-TaskRow 'NightSleep')
    $lblSleep.Text = if ($on) { "已開啟：每天 01:00 閒置 10 分鐘就睡，07:00 叫醒。`n值班夜、傳過 /sleepoff 的晚上不睡。" }
                     else     { "已關閉：電腦不會自己睡。" }
    $lblSleep.ForeColor = if ($on) { $C_GOOD } else { $C_MUTE }
    $btnSleep.Text = if ($on) { "關閉夜間睡眠" } else { "開啟夜間睡眠" }
}
$btnSleep.Add_Click({
    $arg = if (Get-TaskRow 'NightSleep') { '-Uninstall' } else { '-Install' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Dir 'sleep.ps1') $arg | Out-Null
    Update-SleepCard
})
Update-SleepCard

# ══════════════════════════════════════════════════════════════
# 狀態更新
# ══════════════════════════════════════════════════════════════

function Update-Status {
    if (Get-WifiConnected) { Set-Tile $tileWifi "● $($script:SSID)" $C_GOOD }
    else                   { Set-Tile $tileWifi "● 未連線" $C_CRIT }

    $mRun = Test-MonitorRunning
    if ($mRun) { Set-Tile $tileMonitor "● 執行中" $C_GOOD }
    else       { Set-Tile $tileMonitor "○ 未啟動" $C_MUTE }
    $btnStart.Enabled = -not $mRun
    $btnStop.Enabled  = $mRun

    $next = $PunchTasks | ForEach-Object { Get-TaskRow $_ } |
        Where-Object { $_ -and $_.Enabled -and $_.Next } | ForEach-Object Next | Sort-Object | Select-Object -First 1
    if ($next) { Set-Tile $tilePunch "● $($next.ToString('MM/dd HH:mm'))" $C_GOOD }
    else       { Set-Tile $tilePunch "○ 沒有預約" $C_MUTE }
}

$script:LogStamp = [datetime]::MinValue
function Update-LogView([bool]$Force = $false) {
    if (-not (Test-Path $script:LogFile)) { return }
    $stamp = (Get-Item $script:LogFile).LastWriteTime
    if (-not $Force -and $stamp -eq $script:LogStamp) { return }
    $script:LogStamp = $stamp

    $lines = Get-Content $script:LogFile -Tail 100 -ErrorAction SilentlyContinue
    if ($null -eq $lines) { return }

    $rtbLog.SuspendLayout()
    $rtbLog.Clear()
    foreach ($line in $lines) {
        $color = $C_INK2
        if     ($line -match "登入成功|網路已恢復|\[OK\]")              { $color = $C_GOOD }
        elseif ($line -match "失敗|無法上網|\[FAIL\]|Error|connection") { $color = $C_CRIT }
        elseif ($line -match "重連觸發|定時保底|重新連接|送出")           { $color = $C_WARN }
        elseif ($line -match "===|監控啟動|WiFi 監控")                   { $color = $C_ACC  }
        $rtbLog.SelectionStart  = $rtbLog.TextLength
        $rtbLog.SelectionLength = 0
        $rtbLog.SelectionColor  = $color
        $rtbLog.AppendText("$line`n")
    }
    $rtbLog.ResumeLayout()
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.ScrollToCaret()
}

# ══════════════════════════════════════════════════════════════
# 事件
# ══════════════════════════════════════════════════════════════

$btnStart.Add_Click({ Start-MonitorNow; Start-Sleep -Milliseconds 600; Update-Status })
$btnStop.Add_Click({
    Stop-MonitorNow; Start-Sleep -Milliseconds 600; Update-Status
    if (Test-MonitorRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            "監控程序以較高權限執行，無法從這裡停止。`n請以系統管理員身分開啟本面板再試。", "無法停止") | Out-Null
    }
})

$btnLogin.Add_Click({
    Start-Process powershell.exe -WindowStyle Normal `
        -ArgumentList "-ExecutionPolicy Bypass -File `"$script:LoginScript`""
})

$btnPunch.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "確定要立即打卡？（會實際送出打卡）", "確認打卡",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Process powershell.exe -WindowStyle Normal `
            -ArgumentList "-ExecutionPolicy Bypass -File `"$script:CheckinScript`""
    }
})

$btnCheck.Add_Click({
    $btnCheck.Enabled = $false; $btnCheck.Text = "檢查中..."
    Set-Tile $tileNet "○ 檢查中..." $C_MUTE
    $job = Start-Job -ScriptBlock {
        foreach ($c in @(
            @{ Uri = "http://connectivitycheck.gstatic.com/generate_204"; Code = 204; Body = $null },
            @{ Uri = "http://www.msftconnecttest.com/connecttest.txt";    Code = 200; Body = "Microsoft Connect Test" }
        )) {
            try {
                $r = Invoke-WebRequest -Uri $c.Uri -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                if ($r.StatusCode -eq $c.Code -and (-not $c.Body -or $r.Content -match $c.Body)) { return $true }
            } catch {}
        }
        return $false
    }
    $t0 = Get-Date
    while ($job.State -eq 'Running' -and ((Get-Date) - $t0).TotalSeconds -lt 12) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    $online = ($job.State -eq 'Completed') -and (Receive-Job $job)
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($online) { Set-Tile $tileNet "● 正常" $C_GOOD }
    else         { Set-Tile $tileNet "● 無法連外" $C_CRIT }
    $btnCheck.Enabled = $true; $btnCheck.Text = "◎  立即檢查"
})

$btnRefresh.Add_Click({ Update-LogView $true })
$btnClear.Add_Click({ $rtbLog.Clear() })

$btnSave.Add_Click({
    # 寫壞了監控腳本會整個跑不起來，先擋掉空白和非數字
    $bad = @(@($txPollInterval, $txEventSleep, $txDebounceSec, $txMaxLogKB) | Where-Object { $_.Text -notmatch '^[1-9]\d*$' })
    if (-not $txSSID.Text.Trim() -or $txSSID.Text -match '"' -or $bad) {
        $lblSaveMsg.Text      = "✕ 沒有儲存：SSID 不可空白，秒數和 KB 要填正整數"
        $lblSaveMsg.ForeColor = $C_CRIT
        return
    }
    try {
        Write-Setting "SSID"         $txSSID.Text
        Write-Setting "PollInterval" $txPollInterval.Text
        Write-Setting "EventSleep"   $txEventSleep.Text
        Write-Setting "DebounceSec"  $txDebounceSec.Text
        Write-Setting "MaxLogKB"     $txMaxLogKB.Text
        $script:SSID = $txSSID.Text
        $lblSaveMsg.Text      = "✓ 已儲存 $(Get-Date -Format 'HH:mm:ss') — 監控幾秒內會自動套用"
        $lblSaveMsg.ForeColor = $C_GOOD
    } catch {
        $lblSaveMsg.Text      = "✕ 儲存失敗：$($_.Exception.Message)"
        $lblSaveMsg.ForeColor = $C_CRIT
    }
})

# ══════════════════════════════════════════════════════════════
# 定時更新 + 啟動
# ══════════════════════════════════════════════════════════════

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    try { Update-Status } catch {}
    try { if ($dash.Visible) { Update-LogView } } catch {}
})
$timer.Start()

$form.Add_FormClosing({ $timer.Stop() })

Show-View 0
Update-Status
Update-LogView $true
[System.Windows.Forms.Application]::Run($form)
