#Requires -Version 5.1
# 排班表的讀法（punch/ 用它查「這天是什麼班」）和 Send-Telegram。
#
# 班表在 data/shifts.csv，一行一天「yyyy-MM-dd,班別代碼」，每月手動更新。

$ShiftFile = Join-Path $PSScriptRoot 'data\shifts.csv'

# 讀成 @{ 'yyyy-MM-dd' = '班別代碼' }。認不出格式的行（註解、空行、寫壞的行）直接跳過。
# 代碼不准含逗號：不然「2026-09-07,9076,多打一欄」會被當成代碼「9076,多打一欄」收進來。
# 檔案不存在就回空表，讓呼叫端自己決定要吵還是安靜略過。
function Read-ShiftTable {
    param([string]$Path = $ShiftFile)
    $codes = @{}
    if (-not (Test-Path $Path)) { return $codes }
    foreach ($line in (Get-Content $Path -Encoding UTF8)) {
        if ($line -match '^\s*(\d{4}-\d{2}-\d{2})\s*,\s*([^,\s]+)\s*$') { $codes[$matches[1]] = $matches[2] }
    }
    $codes
}

# 那天晚上要不要值班（＝留在醫院過夜，可能半夜要遠端連回家裡的電腦，夜間睡眠就別睡）。
# 判斷方式跟打卡那邊同一條：當天是全天班 9076，而且隔天是 906／908。查不到那天就回 $false（照常睡）。
function Test-OncallNight {
    param([Parameter(Mandatory)][datetime]$Date, [hashtable]$Codes = (Read-ShiftTable))
    ($Codes[$Date.ToString('yyyy-MM-dd')] -eq '9076') -and
    ($Codes[$Date.AddDays(1).ToString('yyyy-MM-dd')] -in '906', '908')
}

# 「這一晚」是哪天：往前推 6 小時。電腦 01:00 才睡，00:30 傳的 /sleepoff 要算前一晚，不然 01:00 認不得照睡
function Get-NightOf { param([datetime]$At = (Get-Date)) $At.AddHours(-6).Date }

# /sleepoff 寫進這個檔的是「哪一晚不睡」，過了那晚自動失效
$SkipSleepFlag = Join-Path $PSScriptRoot 'data\skip-sleep.flag'
function Test-SkipSleep {
    param([datetime]$Night = (Get-NightOf))
    (Test-Path $SkipSleepFlag) -and ((Get-Content $SkipSleepFlag -Raw).Trim() -eq $Night.ToString('yyyy-MM-dd'))
}

# 送一則 Telegram。有 data/tg-topics.json 就送進指定話題，沒有就直接送聊天室。
# 話題讀不到或被刪了就改送沒分區的地方，訊息不能因此不見；整個送不出去也不丟錯，通知失敗不能害正事跟著失敗。
# 回傳實際送進的話題 id（scheduled-punch.ps1 的截圖要跟著送同一個話題）。
$LibRoot = $PSScriptRoot
function Send-Telegram {
    param([Parameter(Mandatory)][string]$Text, [string]$Topic, [int]$TimeoutSec = 15)
    try {
        $cfg = Join-Path $LibRoot 'bot-config.ps1'   # $BotToken, $AuthChatId
        if (Test-Path $cfg) { . $cfg }
        if (-not $BotToken -or -not $AuthChatId) { return }   # 沒設定 Telegram 就不送
        $api  = "https://api.telegram.org/bot$BotToken/sendMessage"
        $body = @{ chat_id = $AuthChatId; text = $Text }
        if ($Topic) { try { $body.message_thread_id = (Get-Content (Join-Path $LibRoot 'data/tg-topics.json') -Raw | ConvertFrom-Json).$Topic } catch {} }
        try { Invoke-RestMethod $api -Method POST -Body $body -TimeoutSec $TimeoutSec | Out-Null; return $body.message_thread_id }
        catch { $body.Remove('message_thread_id'); Invoke-RestMethod $api -Method POST -Body $body -TimeoutSec $TimeoutSec | Out-Null }
    } catch {}
}
