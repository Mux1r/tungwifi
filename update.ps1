#Requires -Version 5.1
# 從 GitHub 抓最新版覆蓋到這個資料夾。
# 只蓋程式檔：bot-config.ps1、wifi-accounts.ps1、settings.ps1、message-hook.ps1 和 data\ 底下（班表、紀錄）是每個人自己的，一律不碰。
# 新版裡只要有一支腳本語法錯誤就整批不更新，免得一次壞掉大家的打卡。
#
# 用法：
#   update.ps1            檢查一次（給排程跑）。預設只用 Telegram 通知有新版，回 /update 才裝；
#                         settings.ps1 裡 $AutoUpdate = 1 就直接裝
#   update.ps1 -Apply     立即更新到最新版（Telegram /update、控制面板按鈕）
#   update.ps1 -Rollback  退回更新前的版本，並跳過這一版（Telegram /rollback）
#   update.ps1 -Install   註冊自己的排程（AutoUpdate，每天 09:00，電腦沒醒就醒來補跑）
param([switch]$Install, [switch]$Apply, [switch]$Rollback)

$Repo     = 'Mux1r/tungwifi'
$Branch   = 'main'
$TaskName = 'AutoUpdate'
$Dir      = $PSScriptRoot

if ($Install) {
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument "--headless powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$PSCommandPath`""
    # 09:00：早上的上班卡大多已經打完，更新壞了離下班卡還有時間處理；06:00 電腦常常還在睡
    Register-ScheduledTask -TaskName $TaskName -Force -ErrorAction Stop `
        -Trigger (New-ScheduledTaskTrigger -Daily -At '09:00') `
        -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited) `
        -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew) `
        -Action $action | Out-Null
    Write-Host "已註冊 $TaskName，每天 09:00 檢查 GitHub 有沒有新版。" -ForegroundColor Green
    return
}

New-Item -ItemType Directory -Force "$Dir\data" | Out-Null
$LogFile     = "$Dir\data\update.log"
$VersionFile = "$Dir\data\version.txt"          # 第一行 sha，第二行「日期 說明」給控制面板顯示
$NotifiedFile = "$Dir\data\update-notified.txt" # 已經通知過的新版 sha，同一版不天天吵
$SkipFile    = "$Dir\data\update-skip.txt"      # 退回過的版本，不再自動裝回來
$BackupDir   = "$Dir\data\backup"               # 只留更新前那一版（刻意只留一版，退兩版要從 GitHub 重下）
$BackupVer   = "$Dir\data\backup-version.txt"   # 備份那一版的 version.txt（不放進 backup\，不然退版時會被當程式檔搬出來）
function Log([string]$Msg) { try { Add-Content $LogFile "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg" -Encoding UTF8 } catch {} }
. "$Dir\shift-lib.ps1"   # Send-Telegram

# 這幾個是個人檔，就算哪天不小心進了 repo 也不能蓋掉本機那份
$Personal = 'bot-config.ps1', 'wifi-accounts.ps1', 'settings.ps1', 'message-hook.ps1'
$AutoUpdate = 0
if (Test-Path "$Dir\settings.ps1") { try { . "$Dir\settings.ps1" } catch {} }   # $AutoUpdate（控制面板寫入）

function Get-LocalSha { if (Test-Path $VersionFile) { "$(Get-Content $VersionFile -TotalCount 1)".Trim() } else { '' } }
# 給人看的版本說明；舊版的 version.txt 只有 sha 一行，就顯示 sha 前 7 碼
function Get-VersionLabel {
    $v = @(Get-Content $VersionFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($v.Count -ge 2 -and $v[1]) { $v[1] } elseif ($v) { "$($v[0])".Substring(0, [Math]::Min(7, "$($v[0])".Length)) } else { '未知版本' }
}

# 程式檔清單：資料夾裡除了 data\ 和個人檔以外的檔案
function Get-ProgramFiles([string]$Root) {
    Get-ChildItem $Root -Recurse -File | Where-Object {
        $rel = $_.FullName.Substring($Root.Length + 1)
        $rel -notlike 'data\*' -and $rel -notlike '.git\*' -and $_.Name -notin $Personal -and
        $_.Extension -notin '.log', '.lnk', '.png'
    }
}
function Copy-Program([string]$From, [string]$To) {
    foreach ($f in (Get-ProgramFiles $From)) {
        $dest = Join-Path $To $f.FullName.Substring($From.Length + 1)
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item $f.FullName $dest -Force
    }
}

# 打卡正在跑就別換檔：換到一半的腳本可能讓這張卡打不成
function Test-PunchBusy {
    [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'auto-checkin-v2\.ps1|scheduled-punch\.ps1' })
}
function Wait-PunchIdle {
    for ($i = 0; $i -lt 20 -and (Test-PunchBusy); $i++) { Start-Sleep -Seconds 30 }   # 最多等 10 分鐘
    -not (Test-PunchBusy)
}

# 收 Telegram 指令的程式是常駐的，重開才會用到新版。
# WiFi 監控不用管：它發現自己的程式檔變了會自己重開（它是管理員權限，這裡也停不掉）
function Restart-Bot {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'telegram-commands\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    try { Start-ScheduledTask -TaskName TelegramCommands -ErrorAction Stop } catch {}
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── 退回上一版 ─────────────────────────────────────────────
if ($Rollback) {
    $bakSha = if ((Test-Path $BackupVer) -and (Test-Path $BackupDir)) { "$(Get-Content $BackupVer -TotalCount 1)".Trim() } else { '' }
    if (-not $bakSha) { Send-Telegram "⚠️ 沒有可以退回的版本（還沒透過新版更新過，或已經退回過了）。" | Out-Null; return }
    if (-not (Wait-PunchIdle)) { Send-Telegram "⚠️ 打卡一直在進行中，這次沒有退版，等打卡結束再傳一次 /rollback。" | Out-Null; return }
    $badSha = Get-LocalSha
    try {
        Copy-Program $BackupDir $Dir
        Copy-Item $BackupVer $VersionFile -Force
        Set-Content $SkipFile $badSha   # 自動更新模式下，明天別又把這版裝回來
        Remove-Item $BackupDir, $BackupVer -Recurse -Force   # 退過就沒有「上一版」了，避免連按兩次來回跳
        Log "退回到 $($bakSha.Substring(0, 7))，跳過 $badSha"
        Send-Telegram "⏪ 已退回上一版（$(Get-VersionLabel)）。`n這次退掉的版本不會再自動裝回來，之後有更新的版本才會再通知。" | Out-Null
    } catch {
        Log "退版失敗：$($_.Exception.Message)"
        Send-Telegram "⚠️ 退版失敗：$($_.Exception.Message)" | Out-Null
    }
    Restart-Bot
    return
}

# ── 檢查／更新 ─────────────────────────────────────────────
$tmp = Join-Path $env:TEMP "tungwifi-update-$PID"
try {
    $commit = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Branch" -TimeoutSec 30
    $sha    = $commit.sha
    $local  = Get-LocalSha
    if ($sha -eq $local) {
        if ($Apply) { Send-Telegram "✅ 已經是最新版了。" | Out-Null }
        return
    }
    $skipped = (Test-Path $SkipFile) -and ("$(Get-Content $SkipFile -TotalCount 1)".Trim() -eq $sha)
    if ($skipped -and -not $Apply) { return }   # 退回過的版本，手動 /update 才裝

    # 這次更新包含哪些改動（本機版本之後的每一筆）。第一次跑沒有本機版本就不列
    $changes = @()
    if ($local) {
        try {
            $cmp = Invoke-RestMethod "https://api.github.com/repos/$Repo/compare/$local...$sha" -TimeoutSec 30
            $changes = @($cmp.commits | ForEach-Object { '• ' + ($_.commit.message -split "`n")[0] })
        } catch {}
        if (-not $changes) { $changes = @('• ' + ($commit.commit.message -split "`n")[0]) }
    }
    $changeText = ($changes | Select-Object -Last 10) -join "`n"

    # 預設只通知；第一次跑（剛安裝）直接裝，只是把版本對齊
    if ($local -and -not $Apply -and "$AutoUpdate" -ne '1') {
        if (-not (Test-Path $NotifiedFile) -or "$(Get-Content $NotifiedFile -TotalCount 1)".Trim() -ne $sha) {
            Send-Telegram "🆕 有新版可以更新：`n$changeText`n`n要更新就回 /update" | Out-Null
            Set-Content $NotifiedFile $sha
            Log "通知新版 $($sha.Substring(0, 7))"
        }
        return
    }

    if (-not (Wait-PunchIdle)) {
        Log "打卡進行中，這次不更新"
        if ($Apply) { Send-Telegram "⚠️ 打卡一直在進行中，這次沒有更新，等打卡結束再傳一次 /update。" | Out-Null }
        return
    }

    New-Item -ItemType Directory -Force $tmp | Out-Null
    Invoke-WebRequest "https://codeload.github.com/$Repo/zip/$sha" -OutFile "$tmp\src.zip" -UseBasicParsing -TimeoutSec 120
    Expand-Archive "$tmp\src.zip" "$tmp\src" -Force
    $src = (Get-ChildItem "$tmp\src" -Directory | Select-Object -First 1).FullName   # zip 裡多包一層 tungwifi-<sha>

    # 新版每支腳本都要能解析，有一支壞就整批不更新
    $broken = Get-ChildItem $src -Recurse -Filter *.ps1 | Where-Object {
        $err = $null
        [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$err)
        $err
    }
    if ($broken) { throw "新版有語法錯誤，不更新：$($broken.Name -join ', ')" }

    # 先備份目前這版，壞了可以 /rollback 退回來
    if ($local) {
        Remove-Item $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $BackupDir | Out-Null
        Copy-Program $Dir $BackupDir
        Copy-Item $VersionFile $BackupVer -Force
    }
    Copy-Program $src $Dir
    $msg = ($commit.commit.message -split "`n")[0]
    Set-Content $VersionFile @($sha, "$(Get-Date -Format 'yyyy-MM-dd') $msg") -Encoding UTF8
    Remove-Item $SkipFile, $NotifiedFile -ErrorAction SilentlyContinue
    Log "更新到 $($sha.Substring(0, 7))：$msg"
    Restart-Bot
    # 已經存在的控制面板捷徑換成新圖示（只改現有的，使用者刪掉的不會被加回來）
    if (Test-Path "$Dir\app.ico") {
        try {
            $ws = New-Object -ComObject WScript.Shell
            foreach ($lnk in "$Dir\WiFi 控制面板.lnk", (Join-Path ([Environment]::GetFolderPath('Desktop')) 'WiFi 控制面板.lnk')) {
                if (Test-Path $lnk) { $sc = $ws.CreateShortcut($lnk); $sc.IconLocation = "$Dir\app.ico,0"; $sc.Save() }
            }
        } catch {}
    }

    if ($local) {   # 第一次跑只是記下版本，不用通知
        Send-Telegram "🔄 已更新到最新版：`n$changeText`n`n打卡有問題的話回 /rollback 退回上一版" | Out-Null
    }
} catch {
    Log "更新失敗：$($_.Exception.Message)"
    if ($Apply) { Send-Telegram "⚠️ 更新失敗：$($_.Exception.Message)" | Out-Null }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# 舊版裝的排程是 06:00，順手改成 09:00（排程是自己帳號的，不用管理員）
try {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if ($t.Triggers[0].StartBoundary -notmatch 'T09:00') { & $PSCommandPath -Install | Out-Null; Log "排程改到 09:00" }
} catch {}
