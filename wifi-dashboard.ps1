#Requires -Version 5.1
# WiFi 控制台 — 左側選單四頁：首頁（狀態、操作、日誌）、打卡記錄、功能開關、關於與更新
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
$script:UpdateScript  = Join-Path $script:Dir "update.ps1"
$script:LogFile       = Join-Path $script:Dir "wifi-monitor.log"
$script:SettingsFile  = Join-Path $script:Dir "settings.ps1"   # 個人設定，不進 GitHub、自動更新不會蓋掉
$script:PunchLogDir   = Join-Path $script:Dir "data\punch-logs"
$script:VersionFile   = Join-Path $script:Dir "data\version.txt"

$script:TaskSvc = New-Object -ComObject Schedule.Service
$script:TaskSvc.Connect()

$MonitorTask = "WiFi-AutoLogin-Monitor"
$PunchTasks  = "PunchIn-Booked", "PunchOut-Booked"   # nightly-book.ps1 每晚建的預約

# ══════════════════════════════════════════════════════════════
# 色票（dataviz 深色模式：頁面/卡片/墨色/狀態色）
# ══════════════════════════════════════════════════════════════

$C_PAGE = [System.Drawing.Color]::FromArgb(13, 13, 13)     # 頁面底
$C_SIDE = [System.Drawing.Color]::FromArgb(19, 19, 18)     # 側欄
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
$F_Nav   = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$F_Mono  = New-Object System.Drawing.Font("Consolas", 9)

$script:HairPen = New-Object System.Drawing.Pen $C_HAIR, 1

# ══════════════════════════════════════════════════════════════
# 參數讀寫
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

$script:SSID   = Read-Setting "SSID"
$script:Repo   = Read-Param $script:UpdateScript "Repo"     # 跟 update.ps1 用同一個來源，不另外寫死
$script:Branch = Read-Param $script:UpdateScript "Branch"

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

function Test-ProcRunning([string]$Pattern) {
    [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match $Pattern })
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

# 跑一支腳本並等它結束，等的時候視窗照樣能動（不然會顯示「沒有回應」）
function Invoke-ScriptUI([string]$File, [string[]]$Arguments, [int]$MaxSec = 300) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -NonInteractive -File `"$File`" $($Arguments -join ' ')"
    $p = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $argLine -PassThru
    $t0 = Get-Date
    while (-not $p.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt $MaxSec) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    return $p.HasExited
}

# 背景工作版本：給要回傳資料的（連網檢查、查 GitHub）
function Wait-JobUI($Job, [int]$MaxSec = 20) {
    $t0 = Get-Date
    while ($Job.State -eq 'Running' -and ((Get-Date) - $t0).TotalSeconds -lt $MaxSec) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    $out = if ($Job.State -eq 'Completed') { Receive-Job $Job } else { $null }
    Remove-Job $Job -Force -ErrorAction SilentlyContinue
    return $out
}

# ══════════════════════════════════════════════════════════════
# 打卡記錄：從 data\punch-logs\<年月>.log 拆出每一次打卡
# ══════════════════════════════════════════════════════════════

# 每次打卡是 auto-checkin-v2.ps1 的一段 transcript，開頭是「Start time: yyyyMMddHHmmss」，
# 結果看最後一行「RESULT: OK/FAIL/DRYRUN」；截圖檔名是截圖當下的時間，落在這段開始後 12 分鐘內就算這次的
function Get-PunchRuns([int]$Days = 60) {
    if (-not (Test-Path $script:PunchLogDir)) { return @() }
    $since = (Get-Date).AddDays(-$Days)
    $pngs  = @(Get-ChildItem "$script:PunchLogDir\*.png" -ErrorAction SilentlyContinue | ForEach-Object {
        $t = [datetime]::MinValue
        if ([datetime]::TryParseExact($_.BaseName, 'yyyyMMdd-HHmmss', $null, 'None', [ref]$t)) {
            [pscustomobject]@{ Time = $t; Path = $_.FullName }
        }
    })
    $runs = foreach ($f in (Get-ChildItem "$script:PunchLogDir\*.log" -ErrorAction SilentlyContinue |
                            Where-Object { $_.LastWriteTime -ge $since })) {
        $text  = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        $parts = [regex]::Split($text, '(?m)^Start time: (\d{14})\s*$')
        for ($i = 1; $i + 1 -lt $parts.Count; $i += 2) {
            $start = [datetime]::ParseExact($parts[$i], 'yyyyMMddHHmmss', $null)
            if ($start -lt $since) { continue }
            $body  = $parts[$i + 1]
            if ($body -notmatch '自動打卡系統') { continue }   # 不是打卡腳本留下的 transcript
            $lines = @($body -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\*{5,}|^(Username|RunAs User|Configuration Name|Machine|Host Application|Process ID|PSVersion|PSEdition|PSCompatibleVersions|BuildVersion|CLRVersion|WSManStackVersion|PSRemotingProtocolVersion|SerializationVersion|End time|Windows PowerShell transcript)' })
            $res   = @($lines | Where-Object { $_ -match 'RESULT: ' }) | Select-Object -Last 1
            $kind = 'unknown'; $info = '沒有跑完（中途被關掉或電腦睡著）'
            if ($res -match 'RESULT: OK (.+)$')     { $kind = 'ok';   $info = "系統記錄 $($matches[1].Trim())" }
            elseif ($res -match 'RESULT: DRYRUN')   { $kind = 'test'; $info = '測試模式，沒有送出打卡' }
            elseif ($res -match 'RESULT: FAIL (.+)$') {
                $kind = 'fail'
                $why  = $matches[1].Trim()
                $info = switch -Regex ($why) {
                    'login-expired' { '打卡網頁登入過期，要重新掃 QR Code'; break }
                    'no-wifi'       { '連不上 guest_tung'; break }
                    'no-chrome'     { '找不到 Chrome'; break }
                    'no-result'     { '沒拿到網頁回應'; break }
                    default {
                        $step = @($lines | Where-Object { $_ -match '✗ 步驟' }) | Select-Object -Last 1
                        if ($step) { $step.Trim() } else { $why }
                    }
                }
            }
            $png = $pngs | Where-Object { $_.Time -ge $start -and $_.Time -le $start.AddMinutes(12) } |
                   Sort-Object Time | Select-Object -Last 1
            [pscustomobject]@{ Start = $start; Kind = $kind; Info = $info; Shot = $png.Path; Detail = ($lines -join "`r`n") }
        }
    }
    @($runs | Sort-Object Start -Descending)
}

$KindText  = @{ ok = '成功'; fail = '失敗'; test = '測試'; unknown = '未完成' }
$KindColor = @{ ok = $C_GOOD; fail = $C_CRIT; test = $C_ACC; unknown = $C_WARN }

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

function New-Rtb([System.Windows.Forms.Control]$Parent, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $r = New-Object System.Windows.Forms.RichTextBox
    $r.Location    = New-Object System.Drawing.Point($X, $Y)
    $r.Size        = New-Object System.Drawing.Size($W, $H)
    $r.ReadOnly    = $true
    $r.BackColor   = $C_WELL
    $r.ForeColor   = $C_INK2
    $r.Font        = $F_Mono
    $r.BorderStyle = "None"
    $r.ScrollBars  = "Vertical"
    $Parent.Controls.Add($r)
    return $r
}

# 功能開關卡：標題、一行說明、右邊一顆按鈕
function New-ToggleCard([System.Windows.Forms.Control]$Parent, [int]$Y, [string]$Title) {
    $card = New-Card $Parent 16 $Y 688 66
    $null = New-Lbl $card $Title 12 8 300 18 $F_H $C_INK2
    $lbl  = New-Lbl $card "" 12 30 500 32 $F_Cap $C_MUTE
    $btn  = New-Btn $card "" 536 18 140 32 $B_GRAY
    return @{ Card = $card; Lbl = $lbl; Btn = $btn }
}
function Set-Toggle($T, [bool]$On, [string]$OnText, [string]$OffText, [string]$OnBtn, [string]$OffBtn) {
    $T.Lbl.Text      = if ($On) { $OnText } else { $OffText }
    $T.Lbl.ForeColor = if ($On) { $C_GOOD } else { $C_MUTE }
    $T.Btn.Text      = if ($On) { $OnBtn } else { $OffBtn }
}

# ══════════════════════════════════════════════════════════════
# 主視窗：左側選單 + 右邊四頁
# ══════════════════════════════════════════════════════════════

$form = New-Object System.Windows.Forms.Form
$form.Text            = "WiFi 控制台"
$form.ClientSize      = New-Object System.Drawing.Size(880, 640)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox     = $false
$form.StartPosition   = "CenterScreen"
$form.BackColor       = $C_PAGE
$form.ForeColor       = $C_INK
$form.Font            = $F_Body

$side = New-Object System.Windows.Forms.Panel
$side.Location  = New-Object System.Drawing.Point(0, 0)
$side.Size      = New-Object System.Drawing.Size(160, 640)
$side.BackColor = $C_SIDE
$form.Controls.Add($side)
$null = New-Lbl $side "WiFi 控制台" 16 16 140 26 $F_Title $C_INK
$lblVer = New-Lbl $side "" 16 606 140 20 $F_Cap $C_MUTE

$pages = @()
$navs  = @()
$names = '首頁', '打卡記錄', '功能開關', '關於與更新'
for ($i = 0; $i -lt $names.Count; $i++) {
    $pg = New-Object System.Windows.Forms.Panel
    $pg.Location  = New-Object System.Drawing.Point(160, 0)
    $pg.Size      = New-Object System.Drawing.Size(720, 640)
    $pg.BackColor = $C_PAGE
    $pg.Visible   = $false
    $form.Controls.Add($pg)
    $pages += $pg

    $nb = New-Btn $side "  $($names[$i])" 8 (60 + $i * 42) 144 36 $C_SIDE
    $nb.TextAlign = "MiddleLeft"
    $nb.Font      = $F_Nav
    $nb.Tag.Idx   = $i
    $nb.Add_Click({ Show-View $this.Tag.Idx })
    $navs += $nb
}
$pgHome, $pgLog, $pgFeat, $pgAbout = $pages

function Show-View([int]$Idx) {
    for ($i = 0; $i -lt $pages.Count; $i++) {
        $on = ($i -eq $Idx)
        $pages[$i].Visible = $on
        $bg = if ($on) { $C_CARD } else { $C_SIDE }
        $navs[$i].Tag.N     = $bg
        $navs[$i].BackColor = $bg
        $navs[$i].ForeColor = if ($on) { $C_INK } else { $C_MUTE }
    }
    switch ($Idx) {
        1 { Update-PunchList }
        2 { Update-FeatureCards }
        3 { Update-AboutPage }
    }
}

# ── 首頁：狀態列 ──────────────────────────────────────────────
$tileWifi    = New-Tile $pgHome "WIFI 連線"   16
$tileNet     = New-Tile $pgHome "網路連通"    188
$tileMonitor = New-Tile $pgHome "監控程序"    360
$tilePunch   = New-Tile $pgHome "下次打卡"    532
Set-Tile $tileNet "○ 未檢查" $C_MUTE

# ── 首頁：操作 ────────────────────────────────────────────────
$cardOp = New-Card $pgHome 16 84 688 114
$null = New-Lbl $cardOp "操作" 12 8 200 18 $F_H $C_INK2
$btnStart    = New-Btn $cardOp "▶  啟動監控" 12  34 158 32 $B_GREEN
$btnStop     = New-Btn $cardOp "■  停止監控" 178 34 158 32 $B_RED
$btnLogin    = New-Btn $cardOp "⚡ 立即登入"  344 34 158 32 $B_BLUE
$btnCheck    = New-Btn $cardOp "◎  立即檢查" 510 34 158 32 $B_GRAY
$btnPunch    = New-Btn $cardOp "◷  立即打卡" 12  74 656 32 $B_BLUE

# ── 首頁：上次打卡 ────────────────────────────────────────────
$cardLast = New-Card $pgHome 16 208 688 66
$null = New-Lbl $cardLast "上次打卡" 12 8 200 18 $F_H $C_INK2
$lblLast  = New-Lbl $cardLast "沒有紀錄" 12 32 500 24 $F_Val $C_MUTE
$btnLastShot = New-Btn $cardLast "看截圖" 536 17 140 32 $B_GRAY
$btnLastShot.Enabled = $false

# ── 首頁：日誌 ────────────────────────────────────────────────
$cardLog = New-Card $pgHome 16 284 688 340
$null = New-Lbl $cardLog "監控日誌（每 3 秒更新，最後 100 行）" 12 9 380 18 $F_H $C_INK2
$btnRefresh = New-Btn $cardLog "重新整理" 498 7 92 26 $B_GRAY
$btnClear   = New-Btn $cardLog "清除畫面" 596 7 80 26 $B_GRAY
$rtbLog = New-Rtb $cardLog 1 38 686 301
$rtbLog.WordWrap = $false

# ── 打卡記錄頁 ────────────────────────────────────────────────
$cardRuns = New-Card $pgLog 16 16 688 376
$null = New-Lbl $cardRuns "最近 60 天的打卡（點一筆看過程）" 12 9 400 18 $F_H $C_INK2
$btnRunsRefresh = New-Btn $cardRuns "重新整理" 584 7 92 26 $B_GRAY
$lvRuns = New-Object System.Windows.Forms.ListView
$lvRuns.Location      = New-Object System.Drawing.Point(1, 38)
$lvRuns.Size          = New-Object System.Drawing.Size(686, 337)
$lvRuns.View          = "Details"
$lvRuns.FullRowSelect = $true
$lvRuns.MultiSelect   = $false
$lvRuns.HeaderStyle   = "Nonclickable"
$lvRuns.BorderStyle   = "None"
$lvRuns.BackColor     = $C_WELL
$lvRuns.ForeColor     = $C_INK2
$lvRuns.Font          = $F_Body
[void]$lvRuns.Columns.Add("時間", 130)
[void]$lvRuns.Columns.Add("結果", 70)
[void]$lvRuns.Columns.Add("內容", 380)
[void]$lvRuns.Columns.Add("截圖", 80)
# 標題列預設是系統白底，跟深色介面不搭，自己畫；內容列照系統畫法（DrawDefault）
$lvRuns.OwnerDraw = $true
$lvRuns.Add_DrawColumnHeader({
    $_.Graphics.FillRectangle((New-Object System.Drawing.SolidBrush $C_CARD), $_.Bounds)
    $r = $_.Bounds; $r.X += 6
    [System.Windows.Forms.TextRenderer]::DrawText($_.Graphics, $_.Header.Text, $F_Cap, $r, $C_MUTE,
        [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left')
})
$lvRuns.Add_DrawItem({ $_.DrawDefault = $true })
$lvRuns.Add_DrawSubItem({ $_.DrawDefault = $true })
$cardRuns.Controls.Add($lvRuns)

$cardRunDetail = New-Card $pgLog 16 402 688 222
$null = New-Lbl $cardRunDetail "這次的過程" 12 9 300 18 $F_H $C_INK2
$btnRunShot = New-Btn $cardRunDetail "看截圖" 584 7 92 26 $B_GRAY
$btnRunShot.Enabled = $false
$rtbRun = New-Rtb $cardRunDetail 1 38 686 183

# ── 功能開關頁 ────────────────────────────────────────────────
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

$grpM = New-Card $pgFeat 16 16 688 244
$null = New-Lbl $grpM "WiFi 監控" 12 8 300 18 $F_H $C_INK2
$lblMonState = New-Lbl $grpM "" 120 9 400 18 $F_Cap $C_MUTE
$txSSID         = New-ParamRow $grpM 36  "SSID（WiFi 名稱）"  (Read-Setting "SSID")         "目標 WiFi 網路"
$txPollInterval = New-ParamRow $grpM 68  "PollInterval（秒）" (Read-Setting "PollInterval") "保底輪詢間隔，預設 180"
$txEventSleep   = New-ParamRow $grpM 100 "EventSleep（秒）"   (Read-Setting "EventSleep")   "事件掃描間隔，預設 3"
$txDebounceSec  = New-ParamRow $grpM 132 "DebounceSec（秒）"  (Read-Setting "DebounceSec")  "重複觸發冷卻，預設 15"
$txMaxLogKB     = New-ParamRow $grpM 164 "MaxLogKB（KB）"     (Read-Setting "MaxLogKB")     "日誌大小上限，預設 500"
# Portal 帳密不在這裡改：wifi-accounts.ps1 是好幾組輪流試的清單，要改直接編輯那個檔
$btnSave    = New-Btn $grpM "儲存參數" 12 200 120 32 $B_GREEN
$lblSaveMsg = New-Lbl $grpM "" 144 208 530 20 $F_Body $C_GOOD

$tgTele  = New-ToggleCard $pgFeat 270 "Telegram 指令"
$tgBook  = New-ToggleCard $pgFeat 344 "依班表自動打卡"
$btnShifts = New-Btn $tgBook.Card "編輯班表" 436 18 92 32 $B_GRAY
$tgBook.Lbl.Width = 416   # 讓出「編輯班表」的位置，不然說明文字會蓋在按鈕上
$tgSleep = New-ToggleCard $pgFeat 418 "夜間睡眠"
$tgUpd   = New-ToggleCard $pgFeat 492 "有新版時"

function Update-FeatureCards {
    $mRun = Test-MonitorRunning
    $lblMonState.Text      = if ($mRun) { "● 執行中（啟動／停止在首頁）" } else { "○ 未啟動（啟動／停止在首頁）" }
    $lblMonState.ForeColor = if ($mRun) { $C_GOOD } else { $C_MUTE }

    $hasBot = Test-Path (Join-Path $script:Dir 'bot-config.ps1')
    if (-not $hasBot) {
        $tgTele.Lbl.Text = "還沒設定 Telegram，設定好才能用 /punch 等指令和收打卡通知。"
        $tgTele.Lbl.ForeColor = $C_WARN
        $tgTele.Btn.Text = "設定 Telegram"
    } else {
        $on = [bool](Get-TaskRow 'TelegramCommands')
        $run = $on -and (Test-ProcRunning 'telegram-commands\.ps1')
        Set-Toggle $tgTele $on $(if ($run) { "已開啟，正在背景接收指令。" } else { "已開啟，但現在沒在跑（登入後或一小時內會自動啟動）。" }) `
            "已關閉：傳指令給 bot 不會有反應，預約的卡照樣會打。" "關閉" "開啟"
    }

    Set-Toggle $tgBook ([bool](Get-TaskRow 'NightlyBook')) `
        "已開啟：每晚 21:00 照 data\shifts.csv 預約隔天的卡。" "已關閉：要打卡就傳 /punch 或用 /in /off 預約。" "關閉" "開啟"

    Set-Toggle $tgSleep ([bool](Get-TaskRow 'NightSleep')) `
        "已開啟：每天 01:00 閒置 10 分鐘就睡，07:00 叫醒。`n值班夜、傳過 /sleepoff 的晚上不睡。" "已關閉：電腦不會自己睡。" "關閉" "開啟"

    $auto = (Read-Setting 'AutoUpdate') -eq '1'
    Set-Toggle $tgUpd $auto "每天 09:00 有新版就自動更新，更新完 Telegram 通知。" `
        "每天 09:00 有新版只傳 Telegram 通知，回 /update 才更新（預設）。" "改成只通知" "改成自動更新"
}

# ── 關於與更新頁 ──────────────────────────────────────────────
$cardVer = New-Card $pgAbout 16 16 688 110
$null = New-Lbl $cardVer "目前版本" 12 8 200 18 $F_H $C_INK2
$lblCurVer = New-Lbl $cardVer "" 12 32 664 24 $F_Val $C_INK
$btnChkUpd  = New-Btn $cardVer "檢查更新"   12  66 140 32 $B_GRAY
$btnApply   = New-Btn $cardVer "立即更新"   160 66 140 32 $B_GREEN
$btnRollbk  = New-Btn $cardVer "退回上一版" 308 66 140 32 $B_RED
$lblUpdMsg  = New-Lbl $cardVer "" 460 74 220 20 $F_Cap $C_MUTE
$btnApply.Enabled = $false

$cardNew = New-Card $pgAbout 16 136 688 230
$null = New-Lbl $cardNew "GitHub 上的新版內容" 12 9 400 18 $F_H $C_INK2
$rtbNew = New-Rtb $cardNew 1 38 686 191
$rtbNew.Text = "按「檢查更新」看看有沒有新版。"

$cardUpdLog = New-Card $pgAbout 16 376 688 248
$null = New-Lbl $cardUpdLog "更新紀錄（data\update.log）" 12 9 400 18 $F_H $C_INK2
$rtbUpdLog = New-Rtb $cardUpdLog 1 38 686 209

function Get-VersionLine {
    $v = @(Get-Content $script:VersionFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    if (-not $v) { return @{ Sha = ''; Label = '未知（還沒透過自動更新裝過）' } }
    $sha = "$($v[0])".Trim()
    $label = if ($v.Count -ge 2 -and $v[1]) { "$($v[1])（$($sha.Substring(0, [Math]::Min(7, $sha.Length))))" } else { $sha.Substring(0, [Math]::Min(7, $sha.Length)) }
    @{ Sha = $sha; Label = $label }
}

function Update-AboutPage {
    $ver = Get-VersionLine
    $lblCurVer.Text = $ver.Label
    $lblVer.Text    = "版本 $(if ($ver.Sha) { $ver.Sha.Substring(0, [Math]::Min(7, $ver.Sha.Length)) } else { '?' })"
    $btnRollbk.Enabled = (Test-Path (Join-Path $script:Dir 'data\backup')) -and (Test-Path (Join-Path $script:Dir 'data\backup-version.txt'))
    $log = Join-Path $script:Dir 'data\update.log'
    $rtbUpdLog.Text = if (Test-Path $log) { (Get-Content $log -Encoding UTF8 -Tail 30) -join "`r`n" } else { "還沒有更新紀錄。" }
    $rtbUpdLog.SelectionStart = $rtbUpdLog.TextLength; $rtbUpdLog.ScrollToCaret()
}

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

# 打卡記錄只在記錄檔有變時重讀（一個月的 log 有幾百 KB，每 3 秒重拆太浪費）
$script:Runs = @()
$script:RunsStamp = ''
function Update-Runs([bool]$Force = $false) {
    $files = @(Get-ChildItem "$script:PunchLogDir\*" -ErrorAction SilentlyContinue)
    $stamp = "$($files.Count) $(($files | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime.Ticks)"
    if (-not $Force -and $stamp -eq $script:RunsStamp) { return $false }
    $script:RunsStamp = $stamp
    $script:Runs = Get-PunchRuns
    $true
}

function Update-LastPunch {
    $last = $script:Runs | Where-Object { $_.Kind -ne 'test' } | Select-Object -First 1
    if (-not $last) { $lblLast.Text = "沒有紀錄"; $lblLast.ForeColor = $C_MUTE; $btnLastShot.Enabled = $false; return }
    $lblLast.Text      = "$($last.Start.ToString('MM/dd HH:mm'))　$($KindText[$last.Kind])　$($last.Info)"
    $lblLast.ForeColor = $KindColor[$last.Kind]
    $btnLastShot.Tag     = $last.Shot
    $btnLastShot.Enabled = [bool]$last.Shot
}

function Update-PunchList([bool]$Force = $false) {
    if (-not (Update-Runs $Force) -and $lvRuns.Items.Count) { return }
    $lvRuns.BeginUpdate()
    $lvRuns.Items.Clear()
    foreach ($r in $script:Runs) {
        $it = New-Object System.Windows.Forms.ListViewItem($r.Start.ToString('yyyy-MM-dd HH:mm'))
        $it.UseItemStyleForSubItems = $false
        $sub = $it.SubItems.Add($KindText[$r.Kind]); $sub.ForeColor = $KindColor[$r.Kind]
        [void]$it.SubItems.Add($r.Info)
        [void]$it.SubItems.Add($(if ($r.Shot) { '有' } else { '' }))
        $it.Tag = $r
        [void]$lvRuns.Items.Add($it)
    }
    $lvRuns.EndUpdate()
    $rtbRun.Text = if ($script:Runs) { "點上面任一筆看這次的過程。" } else { "還沒有打卡紀錄。" }
    $btnRunShot.Enabled = $false
    Update-LastPunch
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
    $online = Wait-JobUI $job 12
    if ($online) { Set-Tile $tileNet "● 正常" $C_GOOD }
    else         { Set-Tile $tileNet "● 無法連外" $C_CRIT }
    $btnCheck.Enabled = $true; $btnCheck.Text = "◎  立即檢查"
})

$btnRefresh.Add_Click({ Update-LogView $true })
$btnClear.Add_Click({ $rtbLog.Clear() })
$btnLastShot.Add_Click({ if ($this.Tag -and (Test-Path $this.Tag)) { Start-Process $this.Tag } })

$btnRunsRefresh.Add_Click({ Update-PunchList $true })
$lvRuns.Add_SelectedIndexChanged({
    if ($lvRuns.SelectedItems.Count -eq 0) { return }
    $r = $lvRuns.SelectedItems[0].Tag
    $rtbRun.Text = $r.Detail
    $btnRunShot.Tag     = $r.Shot
    $btnRunShot.Enabled = [bool]$r.Shot
})
$btnRunShot.Add_Click({ if ($this.Tag -and (Test-Path $this.Tag)) { Start-Process $this.Tag } })

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

# 開關都只是註冊／刪除自己帳號的排程，一般權限就夠
$tgTele.Btn.Add_Click({
    if (-not (Test-Path (Join-Path $script:Dir 'bot-config.ps1'))) {
        # 設定過程要在視窗裡貼金鑰，所以開看得到的視窗
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$(Join-Path $script:Dir 'setup-telegram.ps1')`""
        return
    }
    $this.Enabled = $false
    if (Get-TaskRow 'TelegramCommands') {
        try { Unregister-ScheduledTask -TaskName TelegramCommands -Confirm:$false -ErrorAction Stop } catch {}
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'telegram-commands\.ps1' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } else {
        [void](Invoke-ScriptUI (Join-Path $script:Dir 'punch\telegram-commands.ps1') @('-Install') 30)
        try { Start-ScheduledTask -TaskName TelegramCommands -ErrorAction Stop } catch {}
        Start-Sleep -Milliseconds 800
    }
    $this.Enabled = $true
    Update-FeatureCards
})

$tgBook.Btn.Add_Click({
    $this.Enabled = $false
    if (Get-TaskRow 'NightlyBook') {
        try { Unregister-ScheduledTask -TaskName NightlyBook -Confirm:$false -ErrorAction Stop } catch {}
    } else {
        [void](Invoke-ScriptUI (Join-Path $script:Dir 'punch\nightly-book.ps1') @('-Install') 30)
        $csv = Join-Path $script:Dir 'data\shifts.csv'
        if (-not (Get-Content $csv -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d{4}-' })) {
            [System.Windows.Forms.MessageBox]::Show(
                "已開啟，但 data\shifts.csv 還沒有班表，沒有班表就不會自動預約。`n按「編輯班表」填進去，一行一天，例如 2026-12-01,9076。", "還沒有班表") | Out-Null
        }
    }
    $this.Enabled = $true
    Update-FeatureCards
})
$btnShifts.Add_Click({
    $csv = Join-Path $script:Dir 'data\shifts.csv'
    if (-not (Test-Path $csv)) {
        New-Item -ItemType Directory -Force (Split-Path $csv) | Out-Null
        [IO.File]::WriteAllText($csv, "# 排班表：一行一天，格式「日期,班別代碼」，例如 2026-12-01,9076`r`n", (New-Object Text.UTF8Encoding $true))
    }
    Start-Process notepad.exe -ArgumentList "`"$csv`""
})

# 夜間睡眠開關：開＝註冊 NightSleep/MorningWake 排程，關＝刪掉（實際動作在 sleep.ps1）
$tgSleep.Btn.Add_Click({
    $this.Enabled = $false
    $arg = if (Get-TaskRow 'NightSleep') { '-Uninstall' } else { '-Install' }
    [void](Invoke-ScriptUI (Join-Path $script:Dir 'sleep.ps1') @($arg) 30)
    $this.Enabled = $true
    Update-FeatureCards
})

$tgUpd.Btn.Add_Click({
    $new = if ((Read-Setting 'AutoUpdate') -eq '1') { '0' } else { '1' }
    try { Write-Setting 'AutoUpdate' $new } catch {
        [System.Windows.Forms.MessageBox]::Show("存不進 settings.ps1：$($_.Exception.Message)", "儲存失敗") | Out-Null
    }
    Update-FeatureCards
})

# 檢查更新：直接問 GitHub，列出本機版本之後的每一筆改動（不經過 update.ps1，免得順手傳 Telegram）
$btnChkUpd.Add_Click({
    $btnChkUpd.Enabled = $false; $lblUpdMsg.Text = "檢查中..."; $lblUpdMsg.ForeColor = $C_MUTE
    $local = (Get-VersionLine).Sha
    $job = Start-Job -ArgumentList $script:Repo, $script:Branch, $local -ScriptBlock {
        param($Repo, $Branch, $Local)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            $c = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Branch" -TimeoutSec 15
            $list = @()
            if ($Local -and $Local -ne $c.sha) {
                try {
                    $cmp  = Invoke-RestMethod "https://api.github.com/repos/$Repo/compare/$Local...$($c.sha)" -TimeoutSec 15
                    $list = @($cmp.commits | ForEach-Object { "• $("$($_.commit.author.date)".Substring(0, 10))　$(($_.commit.message -split "`n")[0])" })
                } catch {}
            }
            if (-not $list) { $list = @("• $("$($c.commit.author.date)".Substring(0, 10))　$(($c.commit.message -split "`n")[0])") }
            [pscustomobject]@{ Ok = $true; Sha = $c.sha; List = $list }
        } catch { [pscustomobject]@{ Ok = $false; Err = $_.Exception.Message } }
    }
    $r = Wait-JobUI $job 40
    if (-not $r -or -not $r.Ok) {
        $lblUpdMsg.Text = "✕ 連不上 GitHub"; $lblUpdMsg.ForeColor = $C_CRIT
        $rtbNew.Text = "檢查失敗：$(if ($r) { $r.Err } else { '逾時' })"
        $btnApply.Enabled = $false
    } elseif ($r.Sha -eq $local) {
        $lblUpdMsg.Text = "✓ 已經是最新版"; $lblUpdMsg.ForeColor = $C_GOOD
        $rtbNew.Text = "目前就是 GitHub 上的最新版。"
        $btnApply.Enabled = $false
    } else {
        $lblUpdMsg.Text = "有新版"; $lblUpdMsg.ForeColor = $C_WARN
        $rtbNew.Text = "按「立即更新」會裝這些改動：`r`n`r`n" + ($r.List -join "`r`n")
        $btnApply.Enabled = $true
    }
    $btnChkUpd.Enabled = $true
})

$btnApply.Add_Click({
    $btnApply.Enabled = $false; $btnChkUpd.Enabled = $false; $btnRollbk.Enabled = $false
    $lblUpdMsg.Text = "更新中..."; $lblUpdMsg.ForeColor = $C_MUTE
    $done = Invoke-ScriptUI $script:UpdateScript @('-Apply') 900   # 打卡進行中會等最多 10 分鐘
    Update-AboutPage
    $lblUpdMsg.Text = if ($done) { "完成，重開控制面板才會看到新介面" } else { "還在跑，稍後看更新紀錄" }
    $lblUpdMsg.ForeColor = if ($done) { $C_GOOD } else { $C_WARN }
    $btnChkUpd.Enabled = $true
})

$btnRollbk.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "確定要退回上一版？退掉的這版之後不會再自動裝回來。", "退回上一版",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $btnRollbk.Enabled = $false; $btnApply.Enabled = $false
    $lblUpdMsg.Text = "退版中..."; $lblUpdMsg.ForeColor = $C_MUTE
    $done = Invoke-ScriptUI $script:UpdateScript @('-Rollback') 900
    Update-AboutPage
    $lblUpdMsg.Text = if ($done) { "已退回，重開控制面板才會看到舊介面" } else { "還在跑，稍後看更新紀錄" }
    $lblUpdMsg.ForeColor = if ($done) { $C_GOOD } else { $C_WARN }
})

# ══════════════════════════════════════════════════════════════
# 定時更新 + 啟動
# ══════════════════════════════════════════════════════════════

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    try { Update-Status } catch {}
    try { if ($pgHome.Visible) { Update-LogView } } catch {}
    try { if (Update-Runs) { Update-LastPunch; if ($pgLog.Visible) { Update-PunchList $true } } } catch {}
})
$timer.Start()

$form.Add_FormClosing({ $timer.Stop() })

Show-View 0
Update-Status
Update-LogView $true
[void](Update-Runs $true); Update-LastPunch
Update-AboutPage
[System.Windows.Forms.Application]::Run($form)
