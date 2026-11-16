#Requires -Version 5.1
# 在背景接收 Telegram 指令：
#   打卡：/punch 立即打卡      /test 測試打卡流程（不實際送出）
#   預約：/in /off /am_off /pm_off 預約上班卡／下班卡   /cancel 取消預約
#   查詢：/status 系統狀態（網路、預約、睡眠）
#   睡眠：/sleepoff 今晚停用睡眠 /sleepon 今晚恢復睡眠（有開夜間睡眠才出現在選單）
#   更新：/update 更新至最新版本 /rollback 還原上一版本（有上一版本才出現在選單）
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
# 還沒到的預約：@{ 上班卡 = 時間或 $null; 下班卡 = ... }（過期的不算，那張是留給 punch-guard.ps1 判斷用的）
function Get-Bookings {
    $r = [ordered]@{}
    foreach ($p in @(@($TaskIn, '上班卡'), @($TaskOut, '下班卡'))) {
        $t  = Get-ScheduledTask -TaskName $p[0] -ErrorAction SilentlyContinue
        $at = if ($t) { [datetime]$t.Triggers[0].StartBoundary }
        $r[$p[1]] = if ($at -and $at -gt (Get-Date)) { $at } else { $null }
    }
    $r
}
function Get-BookingLines {
    $b = Get-Bookings
    ($b.Keys | ForEach-Object { "${_}：$(if ($b[$_]) { Format-PunchTime $b[$_] } else { '未預約' })" }) -join "`n"
}

function Get-NetLine {
    $online = try { (Invoke-WebRequest 'http://connectivitycheck.gstatic.com/generate_204' -UseBasicParsing -TimeoutSec 5).StatusCode -eq 204 } catch { $false }
    $wifi   = (netsh wlan show interfaces) -join "`n"
    $ssid   = if ($wifi -match '(?m)^\s*SSID\s+:\s+(.+)$') { $matches[1].Trim() } else { '未連接 WiFi' }
    "網路：$(if ($online) { '正常' } else { '中斷' })（$ssid）"
}

function Get-SleepLine {
    if (-not (Get-ScheduledTask -TaskName NightSleep -ErrorAction SilentlyContinue)) { return '' }
    $night = Get-NightOf
    $state = if (Test-OncallNight -Date $night) { '今晚值班，不進入睡眠' }
             elseif (Test-SkipSleep $night)     { '今晚不進入睡眠（/sleepon 恢復）' }
             else { $t = Get-SleepTimes; "$($t.Sleep) 後閒置休眠，$($t.Wake) 喚醒（/sleepoff 今晚停用）" }
    "`n睡眠：$state"
}

# 別名和中文指令都對到同一個動作（Telegram 選單只能放英文小寫，中文要自己打）
$Aliases = @{
    '/punch' = 'punch'; '/打卡' = 'punch'; '/checkin' = 'punch'; '/checkout' = 'punch'
    '/test' = 'test'; '/測試' = 'test'
    '/in' = 'in'; '/上班卡' = 'in'
    '/off' = 'off'; '/下班卡' = 'off'
    '/am_off' = 'am_off'; '/pm_off' = 'pm_off'
    '/status' = 'status'; '/狀態' = 'status'
    '/cancel' = 'cancel'; '/book_cancel' = 'cancel'; '/取消預約' = 'cancel'
    '/sleepoff' = 'sleepoff'; '/nosleep' = 'sleepoff'; '/不睡' = 'sleepoff'
    '/sleepon' = 'sleepon'; '/恢復睡眠' = 'sleepon'
    '/update' = 'update'; '/更新' = 'update'
    '/rollback' = 'rollback'; '/還原' = 'rollback'; '/退版' = 'rollback'
}
# 選單和說明依狀態變：沒開夜間睡眠就不列睡眠指令，沒有上一版就不列 /rollback。
# 藏起來的指令照樣能打，只是不佔選單。Telegram 選單不能分組，用排序＋每組的開頭符號區分
$BackupVer = "$PSScriptRoot\..\data\backup-version.txt"   # update.ps1 更新時留的上一版
function Get-MenuState {
    @{ Sleep = [bool](Get-ScheduledTask -TaskName NightSleep -ErrorAction SilentlyContinue)
       Rollback = (Test-Path $BackupVer) -and (Test-Path "$PSScriptRoot\..\data\backup") }
}
function Get-MenuCommands($State) {
    $c = @(
        @{ command = 'punch';  description = '⏰ 立即打卡' },
        @{ command = 'test';   description = '⏰ 測試打卡流程（不實際送出）' },
        @{ command = 'in';     description = '📅 預約上班卡' },
        @{ command = 'off';    description = '📅 預約下班卡' },
        @{ command = 'am_off'; description = '📅 預約值班隔日早上下班卡' },
        @{ command = 'pm_off'; description = '📅 預約值班隔日中午下班卡' },
        @{ command = 'cancel'; description = '📅 取消預約' },
        @{ command = 'status'; description = '🔍 查詢系統狀態' })
    if ($State.Sleep) {
        $c += @{ command = 'sleepoff'; description = '😴 今晚停用睡眠' }
        $c += @{ command = 'sleepon';  description = '😴 今晚恢復睡眠' }
    }
    $c += @{ command = 'update'; description = '🔄 更新至最新版本' }
    if ($State.Rollback) { $c += @{ command = 'rollback'; description = '🔄 還原上一版本' } }
    $c
}
function Get-HelpText {
    $st = Get-MenuState
    $t = "可用指令`n`n⏰ 打卡`n/punch 立即打卡`n/test 測試打卡流程（不實際送出）" +
         "`n`n📅 預約`n/in 上班卡`n/off 下班卡`n/am_off 值班隔日早上下班卡`n/pm_off 值班隔日中午下班卡`n/cancel 取消預約" +
         "`n`n🔍 查詢`n/status 系統狀態"
    if ($st.Sleep) { $t += "`n`n😴 睡眠`n/sleepoff 今晚停用睡眠`n/sleepon 今晚恢復睡眠" }
    $t += "`n`n🔄 更新`n/update 更新至最新版本"
    if ($st.Rollback) { $t += "`n/rollback 還原上一版本" }
    $t
}
# 狀態有變才重設選單（每輪收訊息約 50 秒檢查一次，平常不多打 API）
$script:MenuKey = ''
function Update-Menu {
    $st  = Get-MenuState
    $key = "$($st.Sleep)|$($st.Rollback)"
    if ($key -eq $script:MenuKey) { return }
    try {
        $cmds = ConvertTo-Json -Compress @(Get-MenuCommands $st)
        Invoke-RestMethod "$Api/setMyCommands" -Method POST -TimeoutSec 15 -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes("{`"commands`":$cmds}")) | Out-Null
        $script:MenuKey = $key   # 送成功才記，失敗下一輪再試
    } catch {}
}

Log "啟動"
$offset = 0
while ($true) {
    Update-Menu
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
                if ("$($m.text)" -like '/*') { Reply "⚠️ 已略過指令「$($m.text)」`n原因：傳送時電腦未連線（$([int]($age / 60)) 分鐘前）`n處理：如仍需要，請重新傳送" }
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
                    if ($busy) { Reply "⏳ 打卡作業進行中，完成後回報結果"; break }
                    Reply "⏳ 打卡作業已開始，約 1 分鐘後回報結果"
                    # 另開程序跑，打卡期間（失敗重試最多 6 分鐘）仍能收其他指令；結果和截圖由 scheduled-punch.ps1 自己傳
                    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `
                        "-ExecutionPolicy Bypass -NonInteractive -File `"$PSScriptRoot\scheduled-punch.ps1`" -Label 手動"
                }
                'test' {
                    $busy = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -match 'auto-checkin-v2\.ps1|scheduled-punch\.ps1' }
                    if ($busy) { Reply "⏳ 打卡作業進行中，請於完成後再測試"; break }
                    Reply "⏳ 打卡測試已開始（不實際送出），約 1 分鐘後回報結果"
                    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `
                        "-ExecutionPolicy Bypass -NonInteractive -File `"$PSScriptRoot\scheduled-punch.ps1`" -Label 測試 -DryRun"
                }
                { $_ -in 'in', 'off', 'am_off', 'pm_off' } {
                    try { Reply (Add-PunchBooking -Kind $action -Codes (Read-ShiftTable)) }
                    catch { Reply "❌ 預約失敗`n原因：$($_.Exception.Message)" }
                }
                'status' { Reply "🔍 系統狀態`n$(Get-NetLine)`n$(Get-BookingLines)$(Get-SleepLine)" }
                'cancel' {
                    $had = @((Get-Bookings).Values | Where-Object { $_ }).Count -gt 0
                    $TaskIn, $TaskOut | ForEach-Object {
                        $t = Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
                        # 只刪還沒到的：過期的那張 punch-guard.ps1 還要拿來判斷卡有沒有打成
                        if ($t -and [datetime]$t.Triggers[0].StartBoundary -gt (Get-Date)) {
                            Unregister-ScheduledTask -TaskName $_ -Confirm:$false
                        }
                    }
                    $auto = Get-ScheduledTask -TaskName NightlyBook -ErrorAction SilentlyContinue
                    if ($had) { Reply "✅ 已取消預約$(if ($auto) { "`n備註：每晚 21:00 仍會依班表預約隔日打卡" })" }
                    else { Reply "📅 目前無預約" }
                }
                'sleepoff' {
                    if (-not (Get-ScheduledTask -TaskName NightSleep -ErrorAction SilentlyContinue)) { Reply "⚠️ 夜間睡眠未啟用，無需設定"; break }
                    Set-Content $SkipSleepFlag (Get-NightOf).ToString('yyyy-MM-dd')
                    Reply "✅ 今晚停用睡眠，明晚自動恢復"
                }
                'sleepon' {
                    Remove-Item $SkipSleepFlag -ErrorAction SilentlyContinue
                    Reply "✅ 今晚恢復睡眠$(Get-SleepLine)"
                }
                { $_ -in 'update', 'rollback' } {
                    # 另開程序跑：更新完會把這支 bot 關掉重開，在這裡同步跑會把自己一起砍掉。結果由 update.ps1 自己傳
                    Reply $(if ($action -eq 'update') { "⏳ 更新作業已開始，完成後回報結果" } else { "⏳ 還原作業已開始，完成後回報結果" })
                    $flag = if ($action -eq 'update') { '-Apply' } else { '-Rollback' }
                    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `
                        "-ExecutionPolicy Bypass -NonInteractive -File `"$PSScriptRoot\..\update.ps1`" $flag"
                }
                default { Reply (Get-HelpText) }
            }
        }
    } catch {
        Log "錯誤：$($_.Exception.Message)"
        Start-Sleep -Seconds 10   # 斷網時別狂打 API
    }
}
