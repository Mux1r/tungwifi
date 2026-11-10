#Requires -Version 5.1
# 在背景接收 Telegram 指令：
#   /punch 立即打卡            /in /off /am_off /pm_off 預約上班卡／下班卡
#   /status 查預約和連線狀態   /cancel 取消預約
#   /sleepoff 今晚不睡         /sleepon 今晚照常睡（有開夜間睡眠才有用）
#   /update 更新到最新版       /rollback 退回上一版
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
. "$PSScriptRoot\punch-lib.ps1"       # Add-PunchBooking、Format-PunchTime、$TaskIn/$TaskOut
. "$PSScriptRoot\..\shift-lib.ps1"    # Read-ShiftTable、Test-OncallNight、Get-NightOf、$SkipSleepFlag
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Api = "https://api.telegram.org/bot$BotToken"
$LogFile = "$PSScriptRoot\..\data\telegram-commands.log"

function Reply([string]$Text) {
    try { Invoke-RestMethod "$Api/sendMessage" -Method POST -TimeoutSec 15 -Body @{ chat_id = $AuthChatId; text = $Text } | Out-Null } catch {}
}
function Log([string]$Msg) { try { Add-Content $LogFile "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg" } catch {} }

# 刻意不用「順手清掉過期預約」的寫法：過期的那張 punch-guard.ps1 還要拿來判斷卡有沒有打成
function Get-Booking {
    $lines = foreach ($p in @(@($TaskIn, '上班卡'), @($TaskOut, '下班卡'))) {
        $t = Get-ScheduledTask -TaskName $p[0] -ErrorAction SilentlyContinue
        if (-not $t) { continue }
        $at = [datetime]$t.Triggers[0].StartBoundary
        if ($at -gt (Get-Date)) { "$($p[1])　$(Format-PunchTime $at)" }
    }
    if ($lines) { "📅 已預約：`n$($lines -join "`n")" } else { "📅 目前沒有預約。" }
}

function Get-NetLine {
    $online = try { (Invoke-WebRequest 'http://connectivitycheck.gstatic.com/generate_204' -UseBasicParsing -TimeoutSec 5).StatusCode -eq 204 } catch { $false }
    $wifi   = (netsh wlan show interfaces) -join "`n"
    $ssid   = if ($wifi -match '(?m)^\s*SSID\s+:\s+(.+)$') { "WiFi：$($matches[1].Trim())" } else { '沒連 WiFi' }
    "$(if ($online) { '📶 連線正常' } else { '⚠️ 上不了網' })，$ssid"
}

function Get-SleepLine {
    if (-not (Get-ScheduledTask -TaskName NightSleep -ErrorAction SilentlyContinue)) { return '' }
    $night = Get-NightOf
    $state = if (Test-OncallNight -Date $night) { '今晚值班，不睡' }
             elseif (Test-SkipSleep $night)     { '今晚不睡（/sleepon 恢復）' }
             else { $t = Get-SleepTimes; "今晚 $($t.Sleep) 後閒置就睡，$($t.Wake) 醒（/sleepoff 今晚不睡）" }
    "`n😴 $state"
}

# 別名和中文指令都對到同一個動作（Telegram 選單只能放英文小寫，中文要自己打）
$Aliases = @{
    '/punch' = 'punch'; '/打卡' = 'punch'; '/checkin' = 'punch'; '/checkout' = 'punch'
    '/in' = 'in'; '/上班卡' = 'in'
    '/off' = 'off'; '/下班卡' = 'off'
    '/am_off' = 'am_off'; '/pm_off' = 'pm_off'
    '/status' = 'status'; '/狀態' = 'status'
    '/cancel' = 'cancel'; '/book_cancel' = 'cancel'; '/取消預約' = 'cancel'
    '/sleepoff' = 'sleepoff'; '/nosleep' = 'sleepoff'; '/不睡' = 'sleepoff'
    '/sleepon' = 'sleepon'; '/恢復睡眠' = 'sleepon'
    '/update' = 'update'; '/更新' = 'update'
    '/rollback' = 'rollback'; '/退版' = 'rollback'
}
$Help = "可用指令：`n/punch 立即打卡`n/in 預約上班卡（08:00 前）`n/off 預約下班卡（17:30 後）`n/am_off 值班隔天早上下班卡`n/pm_off 值班隔天中午下班卡`n/status 查看預約和連線`n/cancel 取消預約`n/sleepoff 今晚不睡　/sleepon 今晚照常睡`n/update 更新到最新版　/rollback 退回上一版"

# 讓 Telegram 輸入框的「/」選單列出這幾個指令
try {
    $cmds = ConvertTo-Json -Compress @(
        @{ command = 'punch';    description = '立即打卡' },
        @{ command = 'in';       description = '預約上班卡' },
        @{ command = 'off';      description = '預約下班卡（17:30 後）' },
        @{ command = 'am_off';   description = '預約值班隔天早上的下班卡' },
        @{ command = 'pm_off';   description = '預約值班隔天中午的下班卡' },
        @{ command = 'status';   description = '查看預約和連線狀態' },
        @{ command = 'cancel';   description = '取消已預約的打卡' },
        @{ command = 'sleepoff'; description = '今晚電腦不睡' },
        @{ command = 'sleepon';  description = '今晚電腦照常睡' },
        @{ command = 'update';   description = '更新到最新版' },
        @{ command = 'rollback'; description = '退回上一版（新版打卡有問題時）' })
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
            # 電腦關機或睡著時傳的舊指令，醒來才收到，不能照做（例如隔天早上突然打一張卡）；回一句讓本人知道被略過了
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $m.date
            if ($age -gt 120) {
                Log "略過 $([int]($age / 60)) 分鐘前的舊訊息：$($m.text)"
                if ("$($m.text)" -like '/*') { Reply "⏭ 電腦剛連上，$([int]($age / 60)) 分鐘前傳的「$($m.text)」已略過，需要的話請重傳。" }
                continue
            }

            $cmd    = ("$($m.text)" -split '[\s@]')[0].ToLower()
            $action = $Aliases[$cmd]
            Log "收到 $cmd"
            switch ($action) {
                'punch' {
                    # 預約的卡或控制面板的「立即打卡」正在跑，就別再開一個：兩個會搶同一個 Chrome 除錯埠
                    $busy = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -match 'auto-checkin-v2\.ps1|scheduled-punch\.ps1' }
                    if ($busy) { Reply "⏳ 已經有一次打卡在進行中，完成後會回報結果。"; break }
                    Reply "⏳ 開始打卡，約 1 分鐘後回報結果。"
                    # 另開程序跑，打卡期間（失敗重試最多 6 分鐘）仍能收其他指令；結果和截圖由 scheduled-punch.ps1 自己傳
                    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `
                        "-ExecutionPolicy Bypass -NonInteractive -File `"$PSScriptRoot\scheduled-punch.ps1`" -Label 手動"
                }
                { $_ -in 'in', 'off', 'am_off', 'pm_off' } {
                    try { Reply "$(Add-PunchBooking -Kind $action -Codes (Read-ShiftTable))`n$(Get-Booking)" }
                    catch { Reply "⚠️ 預約失敗：$($_.Exception.Message)" }
                }
                'status' { Reply "$(Get-NetLine)`n$(Get-Booking)$(Get-SleepLine)" }
                'cancel' {
                    $before = Get-Booking
                    $TaskIn, $TaskOut | ForEach-Object {
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
                'sleepoff' {
                    if (-not (Get-ScheduledTask -TaskName NightSleep -ErrorAction SilentlyContinue)) { Reply "😴 夜間睡眠沒有開啟，電腦本來就不會自己睡。"; break }
                    Set-Content $SkipSleepFlag (Get-NightOf).ToString('yyyy-MM-dd')
                    Reply "☕ 好，今晚電腦不睡，明晚自動恢復。"
                }
                'sleepon' {
                    Remove-Item $SkipSleepFlag -ErrorAction SilentlyContinue
                    Reply "😴 好，今晚照常睡。$(Get-SleepLine)"
                }
                { $_ -in 'update', 'rollback' } {
                    # 另開程序跑：更新完會把這支 bot 關掉重開，在這裡同步跑會把自己一起砍掉。結果由 update.ps1 自己傳
                    Reply $(if ($action -eq 'update') { "⏳ 開始更新，完成後回報。" } else { "⏳ 開始退回上一版，完成後回報。" })
                    $flag = if ($action -eq 'update') { '-Apply' } else { '-Rollback' }
                    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `
                        "-ExecutionPolicy Bypass -NonInteractive -File `"$PSScriptRoot\..\update.ps1`" $flag"
                }
                default { Reply $Help }
            }
        }
    } catch {
        Log "錯誤：$($_.Exception.Message)"
        Start-Sleep -Seconds 10   # 斷網時別狂打 API
    }
}
