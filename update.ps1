#Requires -Version 5.1
# 每天早上從 GitHub 抓最新版覆蓋到這個資料夾。
# 只蓋程式檔：bot-config.ps1、wifi-accounts.ps1、settings.ps1 和 data\ 底下（班表、紀錄）是每個人自己的，一律不碰。
# 新版裡只要有一支腳本語法錯誤就整批不更新，免得一次壞掉大家的打卡。
#
# 用法：
#   update.ps1            檢查一次，有新版就更新（給排程跑）
#   update.ps1 -Install   註冊自己的排程（AutoUpdate，每天 06:00，關機錯過就開機補跑）
param([switch]$Install)

$Repo     = 'Mux1r/tungwifi'
$Branch   = 'main'
$TaskName = 'AutoUpdate'
$Dir      = $PSScriptRoot

if ($Install) {
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument "--headless powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$PSCommandPath`""
    Register-ScheduledTask -TaskName $TaskName -Force -ErrorAction Stop `
        -Trigger (New-ScheduledTaskTrigger -Daily -At '06:00') `
        -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited) `
        -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew) `
        -Action $action | Out-Null
    Write-Host "已註冊 $TaskName，每天 06:00 檢查 GitHub 有沒有新版。" -ForegroundColor Green
    return
}

New-Item -ItemType Directory -Force "$Dir\data" | Out-Null
$LogFile     = "$Dir\data\update.log"
$VersionFile = "$Dir\data\version.txt"
function Log([string]$Msg) { try { Add-Content $LogFile "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg" -Encoding UTF8 } catch {} }

# 這幾個是個人檔，就算哪天不小心進了 repo 也不能蓋掉本機那份
$Personal = 'bot-config.ps1', 'wifi-accounts.ps1', 'settings.ps1'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tmp = Join-Path $env:TEMP "tungwifi-update-$PID"
try {
    $commit = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Branch" -TimeoutSec 30
    $sha    = $commit.sha
    $local  = if (Test-Path $VersionFile) { (Get-Content $VersionFile -Raw).Trim() } else { '' }
    if ($sha -eq $local) { return }   # 已是最新版

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

    $files = Get-ChildItem $src -Recurse -File | Where-Object {
        $rel = $_.FullName.Substring($src.Length + 1)
        $rel -notlike 'data\*' -and $_.Name -notin $Personal
    }
    foreach ($f in $files) {
        $dest = Join-Path $Dir $f.FullName.Substring($src.Length + 1)
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item $f.FullName $dest -Force
    }
    Set-Content $VersionFile $sha
    $msg = ($commit.commit.message -split "`n")[0]
    Log "更新到 $($sha.Substring(0, 7))：$msg"

    # 收 Telegram 指令的程式是常駐的，重開才會用到新版。
    # WiFi 監控不用管：它發現自己的程式檔變了會自己重開（它是管理員權限，這裡也停不掉）
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'telegram-commands\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    try { Start-ScheduledTask -TaskName TelegramCommands -ErrorAction Stop } catch {}

    if ($local) {   # 第一次跑只是記下版本，不用通知
        . "$Dir\shift-lib.ps1"
        Send-Telegram "🔄 已自動更新到最新版：$msg" | Out-Null
    }
} catch {
    Log "更新失敗：$($_.Exception.Message)"
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
