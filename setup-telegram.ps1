#Requires -Version 5.1
# Telegram 通知設定精靈：貼上自己 bot 的金鑰，傳一句話給 bot，自動抓到聊天室 id 寫進 bot-config.ps1。
# 重跑就是重設。

$ConfigFile = Join-Path $PSScriptRoot 'bot-config.ps1'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12   # PS 5.1 預設可能不是 TLS 1.2，Telegram 會拒連

Write-Host @"

== 第 1 步：建立自己的 bot ==
1. 在 Telegram 搜尋 @BotFather（有藍色勾勾的那個），按「開始」。
2. 傳送 /newbot
3. 依提示輸入 bot 的顯示名稱（隨意，例如「我的打卡通知」）。
4. 再輸入 bot 的帳號，必須以 bot 結尾，例如 xxx_punch_bot。
5. BotFather 會回一串像 123456789:ABCdef... 的金鑰（token），整串複製下來。
   金鑰等於這個 bot 的密碼，不要給別人。

"@ -ForegroundColor Cyan

do {
    $token = (Read-Host "貼上金鑰後按 Enter").Trim()
    $ok = $token -match '^\d+:[\w-]{30,}$'
    if (-not $ok) { Write-Host "格式不對，金鑰長得像 123456789:ABCdef...，請重新複製。" -ForegroundColor Yellow; continue }
    try {
        $me = (Invoke-RestMethod "https://api.telegram.org/bot$token/getMe" -TimeoutSec 15).result
    } catch {
        Write-Host "Telegram 不認得這個金鑰（或網路不通），請確認後再貼一次。" -ForegroundColor Yellow
        $ok = $false
    }
} until ($ok)

Write-Host @"

== 第 2 步：讓 bot 認得你 ==
在 Telegram 搜尋 @$($me.username)，打開後按「開始」，或隨便傳一句話給它。
（等候中，最多 3 分鐘…）
"@ -ForegroundColor Cyan

# 收指令的程式也在讀同一個 bot 的訊息，兩邊同時讀 Telegram 會拒絕，先停掉它
Stop-ScheduledTask -TaskName TelegramCommands -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'telegram-commands\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$chatId = $null
$deadline = (Get-Date).AddMinutes(3)
while (-not $chatId -and (Get-Date) -lt $deadline) {
    try {
        # timeout=20：長輪詢，有訊息就立刻回，沒有就等 20 秒再回空的
        $upd = (Invoke-RestMethod "https://api.telegram.org/bot$token/getUpdates?timeout=20" -TimeoutSec 30).result
        $msg = $upd | ForEach-Object { $_.message } | Where-Object { $_ } | Select-Object -Last 1
        if ($msg) { $chatId = $msg.chat.id; $who = $msg.from.first_name }
    } catch { Start-Sleep -Seconds 3 }
}
if (-not $chatId) {
    Write-Host "3 分鐘內沒收到訊息，設定沒有儲存。確認傳給的是 @$($me.username) 後重跑一次。" -ForegroundColor Red
    exit 1
}

$content = "# Telegram 通知設定，由 setup-telegram.ps1 填寫。留空就不發通知，打卡照常。`r`n`$BotToken   = `"$token`"`r`n`$AuthChatId = `"$chatId`"`r`n"
[IO.File]::WriteAllText($ConfigFile, $content, (New-Object Text.UTF8Encoding $true))

try {
    Invoke-RestMethod "https://api.telegram.org/bot$token/sendMessage" -Method POST -TimeoutSec 15 `
        -Body @{ chat_id = $chatId; text = "✅ 打卡通知設定完成，之後的預約和打卡結果會傳到這裡。`n可用指令：/punch 立即打卡、/status 查看預約、/cancel 取消預約" } | Out-Null
    Write-Host "`n設定完成（$who），Telegram 應該已收到一則測試訊息。" -ForegroundColor Green
} catch {
    Write-Host "`n設定已儲存，但測試訊息發送失敗：$($_.Exception.Message)" -ForegroundColor Yellow
}

# 開始收指令（排程還沒裝就略過，install.ps1 會裝）
try { Start-ScheduledTask -TaskName TelegramCommands -ErrorAction Stop } catch {}
