#Requires -Version 5.1
# 排班表的讀法（punch/ 用它查「這天是什麼班」）和 Send-Telegram。
#
# 班表在 data/shifts.csv，一行一天「yyyy-MM-dd,班別代碼」，每月手動更新。
#
# 進階（一般安裝用不到）：settings.ps1 可以寫 $ShiftFile、$TopicsFile 指到別的地方，
# 給已經有自己一份班表、Telegram 話題設定的人共用同一份。只取這兩個變數，其他設定不帶出來。
$LibRoot = $PSScriptRoot
$ShiftFile, $TopicsFile = & {
    $ShiftFile  = Join-Path $LibRoot 'data\shifts.csv'
    $TopicsFile = Join-Path $LibRoot 'data\tg-topics.json'
    $f = Join-Path $LibRoot 'settings.ps1'
    if (Test-Path $f) { try { . $f } catch {} }
    $ShiftFile, $TopicsFile
}

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

# 夜間睡眠幾點睡、幾點醒：控制面板寫進 settings.ps1 的 $SleepAt / $WakeAt，沒設或寫壞就用 01:00 / 07:00
function Get-SleepTimes {
    $SleepAt = '01:00'; $WakeAt = '07:00'
    $f = Join-Path $LibRoot 'settings.ps1'   # $LibRoot 在下面定義；呼叫時已經有值
    $s = $SleepAt; $w = $WakeAt
    if (Test-Path $f) { try { . $f } catch {} }
    if ($SleepAt -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $SleepAt = $s }
    if ($WakeAt  -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $WakeAt  = $w }
    @{ Sleep = $SleepAt; Wake = $WakeAt }
}

# /sleepoff 寫進這個檔的是「哪一晚不睡」，過了那晚自動失效
$SkipSleepFlag = Join-Path $PSScriptRoot 'data\skip-sleep.flag'
function Test-SkipSleep {
    param([datetime]$Night = (Get-NightOf))
    (Test-Path $SkipSleepFlag) -and ((Get-Content $SkipSleepFlag -Raw).Trim() -eq $Night.ToString('yyyy-MM-dd'))
}

# 訊息掛鉤（進階，一般安裝用不到）：有 message-hook.ps1 就把通知交給它改寫，例如換成自己喜歡的語氣。
# 它收到 -Event（哪一種通知）、-Data（時間、哪張卡這些原始資料）、-Text（原本的訊息），印出來的字就是新訊息。
# 它是個人檔，不進 GitHub、更新也不會蓋掉；出錯或沒印東西就用原本的訊息，通知不能因為掛鉤壞掉而不見。
function Use-MessageHook {
    param([string]$Text, [string]$Event, [hashtable]$Data = @{})
    $hook = Join-Path $LibRoot 'message-hook.ps1'
    if (-not $Event -or -not (Test-Path $hook)) { return $Text }
    try { $t = (@(& $hook -Event $Event -Data $Data -Text $Text) -join "`n").Trim(); if ($t) { return $t } } catch {}
    $Text
}

# 送一則 Telegram。有話題設定（data/tg-topics.json）就送進指定話題，沒有就直接送聊天室。
# 話題讀不到或被刪了就改送沒分區的地方，訊息不能因此不見；整個送不出去也不丟錯，通知失敗不能害正事跟著失敗。
# 回傳實際送進的話題 id（scheduled-punch.ps1 的截圖要跟著送同一個話題）。
function Send-Telegram {
    param([Parameter(Mandatory)][string]$Text, [string]$Topic, [int]$TimeoutSec = 15,
          [string]$Event, [hashtable]$Data = @{})
    try {
        $Text = Use-MessageHook -Text $Text -Event $Event -Data $Data
        $cfg = Join-Path $LibRoot 'bot-config.ps1'   # $BotToken, $AuthChatId
        if (Test-Path $cfg) { . $cfg }
        if (-not $BotToken -or -not $AuthChatId) { return }   # 沒設定 Telegram 就不送
        $api  = "https://api.telegram.org/bot$BotToken/sendMessage"
        $body = @{ chat_id = $AuthChatId; text = $Text }
        if ($Topic) { try { $body.message_thread_id = (Get-Content $TopicsFile -Raw | ConvertFrom-Json).$Topic } catch {} }
        try { Invoke-RestMethod $api -Method POST -Body $body -TimeoutSec $TimeoutSec | Out-Null; return $body.message_thread_id }
        catch { $body.Remove('message_thread_id'); Invoke-RestMethod $api -Method POST -Body $body -TimeoutSec $TimeoutSec | Out-Null }
    } catch {}
}
