#Requires -Version 5.1
# 預約打卡的排程進入點：跑 auto-checkin-v2.ps1，完成後把截圖回傳 Telegram
# 由 nightly-book.ps1 註冊成一次性排程任務（PunchIn-Booked / PunchOut-Booked）
param([string]$Label = "預約打卡", [switch]$DryRun)

$cfg = "$PSScriptRoot\..\bot-config.ps1"   # $BotToken, $AuthChatId；setup-telegram.ps1 產生，不進 GitHub
if (Test-Path $cfg) { . $cfg }
$ChatId   = $AuthChatId
$ApiBase  = "https://api.telegram.org/bot$BotToken"
$Png      = Join-Path $PSScriptRoot 'checkin-screenshot.png'

$psArgs = @('-ExecutionPolicy','Bypass','-NonInteractive','-File',"$PSScriptRoot\auto-checkin-v2.ps1",'-Silent')
if ($DryRun) { $psArgs += '-DryRun' }
# 過程由 auto-checkin-v2.ps1 自己錄進 data/punch-logs/，這裡只拿兩樣：退出碼和系統回的打卡時間
# 沒驗到打卡成功就等 5 分鐘整套再跑一次（2026-10-22：醫院回應慢，三輪重試擠在 3 分鐘內全失敗，7 分鐘後手動就打成了）。
# 登入過期、連不上 guest_tung（電腦不在醫院）重跑也沒用，不等。只重跑一次：兩次都不行多半是真的壞了，要趕快通知本人手動補打
for ($run = 1; $run -le 2; $run++) {
    $out = & powershell.exe @psArgs 2>&1 | ForEach-Object { "$_" }
    $verified = $LASTEXITCODE -eq 0
    if ($verified -or $run -eq 2 -or ($out -match 'RESULT: FAIL (login-expired|no-wifi)')) { break }
    Start-Sleep -Seconds 300
}
$retried = $run -eq 2
$sysTime = ($out | Select-String 'RESULT: OK (.+)$' | Select-Object -First 1).Matches.Groups[1].Value

# 只認 5 分鐘內產生的截圖，否則就是這次打卡沒跑完（別把上次的截圖當這次的憑證）
$fresh = (Test-Path $Png) -and (((Get-Date) - (Get-Item $Png).LastWriteTime).TotalMinutes -lt 5)
. "$PSScriptRoot\..\shift-lib.ps1"     # Send-Telegram
$card = $Label -replace '^預約', ''     # 「預約上班卡」→「上班卡」
# 驗證過＝打卡網頁上真的出現「打卡成功」和剛剛的時間；按鈕都點了但沒看到這句，一樣當沒打成
$twice = if ($retried) { '間隔 5 分鐘試了兩次，' } else { '' }
$text = if ($verified) {
    "✅ ${card}打卡成功（系統記錄 $sysTime）$(if ($retried) { '，第一次失敗，5 分鐘後重試成功' })"
} elseif ($out -match 'RESULT: FAIL login-expired') {   # 2026-10-19：網頁停在掃 QR Code 登入的頁面
    "⚠️ ${card}打卡失敗（$(Get-Date -Format 'MM/dd HH:mm')）：打卡網頁登入已過期，需重新掃 QR Code 登入。請先手動補打。"
} elseif ($out -match 'RESULT: FAIL no-wifi') {
    "⚠️ ${card}打卡失敗（$(Get-Date -Format 'MM/dd HH:mm')）：電腦連不上 guest_tung（不在醫院或訊號太弱），只有 guest_tung 能打卡。請手動打卡。"
} elseif ($fresh) {
    "⚠️ ${card}可能未打成（$(Get-Date -Format 'MM/dd HH:mm')）：${twice}畫面上未出現「打卡成功」，截圖附於下方。請確認，未打到需手動補打。"
} else {
    "⚠️ ${card}可能未打成（$(Get-Date -Format 'MM/dd HH:mm')）：${twice}未產生新截圖。請確認，未打到需手動補打。"
}
# 上班卡打完附上下班卡的預約時間，沒有預約就提醒。
# 刻意不用 punch-lib 的 Get-PunchBooking：那支會順手 Unregister 過期的預約，而 punch-guard.ps1
# 正是靠那張過期排程判斷「該打的卡打成了沒」，先刪掉它守門員就瞎了。
if ($Label -like "*上班*") {
    . "$PSScriptRoot\punch-lib.ps1"   # 只借 $TaskOut 和 Format-PunchTime，不動任何排程
    $outTask  = Get-ScheduledTask -TaskName $TaskOut -ErrorAction SilentlyContinue
    $bookedAt = if ($outTask) { [datetime]$outTask.Triggers[0].StartBoundary } else { $null }
    if ($bookedAt -and $bookedAt -gt (Get-Date)) {
        $text += "`n🕔 下班卡已預約：$(Format-PunchTime $bookedAt)"
    } else {
        $text += "`n🕔 下班卡還沒預約，點一下就能約：`n/off（17:35 左右）`n/am_off（值班隔天 08:05 左右）`n/pm_off（值班隔天 11:35 左右）"
    }
}

# 通知失敗不影響打卡本身
try {
    $thread = Send-Telegram $text -Topic schedule
    # 截圖走 curl.exe：PS 5.1 手搓 multipart 太囉嗦，而中文不傳給原生 exe（caption 已在上面那則）
    # 跟著上面那則：文字有進話題，截圖就送同一個話題
    $tid = if ($thread) { @('-F', "message_thread_id=$thread") } else { @() }
    # --max-time：網路卡住時 curl 預設會一直等，這支不結束，bot 就一直以為「打卡進行中」而擋掉之後的 /punch
    if ($fresh) { curl.exe -s --max-time 30 -F "chat_id=$ChatId" @tid -F "photo=@$Png" "$ApiBase/sendPhoto" | Out-Null }
} catch {}
