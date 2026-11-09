#Requires -Version 5.1
# 在背景接收 Telegram 指令：/punch 立即打卡、/status 查預約、/cancel 取消預約。
# 只聽 bot-config.ps1 裡 $AuthChatId 那個人的話，其他人傳來的一律不理。
#
# 用法：
#   telegram-commands.ps1            常駐收指令（給排程跑）
#   telegram-commands.ps1 -Install   註冊自己的排程（TelegramCommands，登入時啟動＋每小時補一次）
param([switch]$Install)

$TaskName = 'TelegramCommands'

if ($Install) {
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument "--headless powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$PSCommandPath`""
    # 每小時補一次：程式意外結束時最多一小時內復活（IgnoreNew + Mutex 保證不會跑兩份）
    $hourly = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $TaskName -Force -ErrorAction Stop `
        -Trigger @((New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME), $hourly) `
        -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew) `
        -Action $action | Out-Null
    Write-Host "已註冊 $TaskName，登入後在背景接收 Telegram 指令。" -ForegroundColor Green
    return
}

$mutex = New-Object System.Threading.Mutex($false, "Global\TungwifiTelegramCommands")
if (-not $mutex.WaitOne(0)) { exit }

$cfg = "$PSScriptRoot\..\bot-config.ps1"   # $BotToken, $AuthChatId；setup-telegram.ps1 產生，不進 GitHub
if (Test-Path $cfg) { . $cfg }
if (-not $BotToken -or -not $AuthChatId) { exit }   # 沒設定 Telegram 就不用跑
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Api = "https://api.telegram.org/bot$BotToken"
$LogFile = "$PSScriptRoot\..\data\telegram-commands.log"

function Reply([string]$Text) {
    try { Invoke-RestMethod "$Api/sendMessage" -Method POST -TimeoutSec 15 -Body @{ chat_id = $AuthChatId; text = $Text } | Out-Null } catch {}
}
function Log([string]$Msg) { try { Add-Content $LogFile "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg" } catch {} }

function Get-Booking {
    $lines = foreach ($p in @(@('PunchIn-Booked', '上班卡'), @('PunchOut-Booked', '下班卡'))) {
        $t = Get-ScheduledTask -TaskName $p[0] -ErrorAction SilentlyContinue
        if (-not $t) { continue }
        $at = [datetime]$t.Triggers[0].StartBoundary
        if ($at -gt (Get-Date)) { "$($p[1])　$($at.ToString('MM/dd HH:mm'))" }
    }
    if ($lines) { "📅 已預約：`n$($lines -join "`n")" } else { "📅 目前沒有預約。" }
}

# 讓 Telegram 輸入框的「/」選單列出這幾個指令
try {
    $cmds = ConvertTo-Json -Compress @(
        @{ command = 'punch';  description = '立即打卡' },
        @{ command = 'status'; description = '查看預約的打卡時間' },
        @{ command = 'cancel'; description = '取消已預約的打卡' })
    Invoke-RestMethod "$Api/setMyCommands" -Method POST -TimeoutSec 15 -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes("{`"commands`":$cmds}")) | Out-Null
} catch {}

Log "啟動"
$offset = 0
while ($true) {
    try {
        $updates = (Invoke-RestMethod "$Api/getUpdates?timeout=50&offset=$offset" -TimeoutSec 65).result
        foreach ($u in $updates) {
            $offset = $u.update_id + 1
            $m = $u.message
            if (-not $m -or "$($m.chat.id)" -ne "$AuthChatId") { continue }   # 不是本人就不理
            # 電腦關機時傳的舊指令，開機後才收到，不能照做（例如隔天早上突然打一張卡）
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $m.date
            if ($age -gt 120) { Log "略過 $([int]($age / 60)) 分鐘前的舊訊息：$($m.text)"; continue }

            $cmd = ("$($m.text)" -split '[\s@]')[0].ToLower()
            Log "收到 $cmd"
            switch ($cmd) {
                '/punch' {
                    # 預約的卡或控制面板的「立即打卡」正在跑，就別再開一個：兩個會搶同一個 Chrome 除錯埠
                    $busy = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -match 'auto-checkin-v2\.ps1|scheduled-punch\.ps1' }
                    if ($busy) { Reply "⏳ 已經有一次打卡在進行中，完成後會回報結果。"; continue }
                    Reply "⏳ 開始打卡，約 1 分鐘後回報結果。"
                    # 另開程序跑，打卡期間（失敗重試最多 6 分鐘）仍能收其他指令；結果和截圖由 scheduled-punch.ps1 自己傳
                    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `
                        "-ExecutionPolicy Bypass -NonInteractive -File `"$PSScriptRoot\scheduled-punch.ps1`" -Label 手動"
                }
                '/status' { Reply (Get-Booking) }
                '/cancel' {
                    $before = Get-Booking
                    'PunchIn-Booked', 'PunchOut-Booked' | ForEach-Object {
                        $t = Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
                        # 只刪還沒到的：過期的那張 punch-guard.ps1 還要拿來判斷卡有沒有打成
                        if ($t -and [datetime]$t.Triggers[0].StartBoundary -gt (Get-Date)) {
                            Unregister-ScheduledTask -TaskName $_ -Confirm:$false
                        }
                    }
                    $auto = Get-ScheduledTask -TaskName NightlyBook -ErrorAction SilentlyContinue
                    if ($before -match '已預約') { Reply "🗑 已取消預約。$(if ($auto) { '每晚 21:00 仍會依班表預約隔天的卡。' })" }
                    else { Reply "📅 目前沒有預約，不需取消。" }
                }
                default { Reply "可用指令：`n/punch 立即打卡`n/status 查看預約`n/cancel 取消預約" }
            }
        }
    } catch {
        Log "錯誤：$($_.Exception.Message)"
        Start-Sleep -Seconds 10   # 斷網時別狂打 API
    }
}
