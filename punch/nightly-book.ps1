#Requires -Version 5.1
# 每晚 21:00 照排班表把明天的卡預約好，再把結果傳到 Telegram。
# 預約不對的話，手動刪掉排程 PunchIn-Booked / PunchOut-Booked。
#
# 班表為什麼是本機檔案：來源是 Google Drive 上的私有試算表，匿名抓會 401，
# 要一整套 OAuth 才拿得到，為了一天讀一次不值得。改成本機一份 data/shifts.csv，
# 每月手動更新；剩 5 天以內時通知裡會提醒。
#
# 用法：
#   nightly-book.ps1            跑一次（給排程用，每天 21:00）
#   nightly-book.ps1 -DryRun    只印會預約什麼，不動排程也不送訊息
#   nightly-book.ps1 -Install   註冊自己的排程（NightlyBook，每天 21:00）
#   nightly-book.ps1 -Now ...   假裝現在是某個時間，供 test-punch-times.ps1 驗算
param([switch]$DryRun, [switch]$Install, [datetime]$Now = (Get-Date))

$TaskName = 'NightlyBook'

if ($Install) {
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument "--headless powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$PSCommandPath`""
    # WakeToRun + StartWhenAvailable：睡眠會叫醒；關機錯過 21:00 就開機後補跑（補跑時預約的是當天，見下面 $day）
    Register-ScheduledTask -TaskName $TaskName -Force -ErrorAction Stop `
        -Trigger (New-ScheduledTaskTrigger -Daily -At '21:00') `
        -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited) `
        -Settings (New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable `
                        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew) `
        -Action $action | Out-Null
    Write-Host "已註冊 $TaskName，每天 21:00 幫明天的卡預約。" -ForegroundColor Green
    return
}

. "$PSScriptRoot\punch-lib.ps1"          # $Plans, Get-ShiftPunches, Get-PunchMoment, Register-PunchTask
. "$PSScriptRoot\..\shift-lib.ps1"       # Read-ShiftTable、Send-Telegram

function Send-Note {
    param([string]$Text)
    if ($DryRun) { Write-Host $Text; return }
    Send-Telegram $Text -Topic schedule | Out-Null   # 送不出去也不影響，預約本身已經做完了
}

# ── 讀班表 ──────────────────────────────────────────────
$codes = Read-ShiftTable
if ($codes.Count -eq 0) {
    Send-Note "⚠️ 班表是空的或找不到（data\shifts.csv），卡未預約。請更新班表。"
    return
}

# 正常是 21:00 跑、預約明天。中午前才跑代表昨晚關機錯過了，開機補跑時要預約的是今天剩下的卡
$dayWord = if ($Now.Hour -lt 12) { '今天' } else { '明天' }
$day  = if ($Now.Hour -lt 12) { $Now.Date } else { $Now.Date.AddDays(1) }
$key  = $day.ToString('yyyy-MM-dd')
$wk   = '日一二三四五六'[[int]$day.DayOfWeek]
$when = "$($day.ToString('MM/dd'))（$wk）"

if (-not $codes.ContainsKey($key)) {
    Send-Note "📅 班表上沒有${dayWord} ${when}的資料，${dayWord}的卡未預約。請更新班表。"
    return
}

# ── 算出這天要打哪幾張卡 ─────────────────────────────────
$code = $codes[$key]
$next = $codes[$day.AddDays(1).ToString('yyyy-MM-dd')]
try {
    $punches = @(Get-ShiftPunches -Date $day -Code $code -NextCode $next)
} catch {
    Send-Note "⚠️ ${dayWord} ${when}的班別代碼「$code」無法辨識，未預約。請自行打卡。"
    return
}

# 這天是不是值班（只打上班卡、下班卡落在隔天）
$isOncall = ($code -eq '9076') -and ($punches.Count -eq 2) -and ($punches[1].Date -ne $day)
$intro = switch ($code) {
    '906'  { "${dayWord} ${when}：值班隔天早上，只打下班卡" }
    '908'  { "${dayWord} ${when}：值班隔天中午，只打下班卡" }
    '9076' { if ($isOncall) { "${dayWord} ${when}：值班，只打上班卡，下班卡排在隔天" }
             else { "${dayWord} ${when}：全天班，上下班都打" } }
    default { "${dayWord} ${when}：休假" }
}

if ($punches.Count -eq 0) {
    Send-Note "📅 ${intro}，不需打卡。"
    return
}

# ── 預約 ────────────────────────────────────────────────
$lines = @()
foreach ($p in $punches) {
    $plan = $Plans[$p.Kind]
    $at   = Get-PunchMoment -Punch $p
    if ($at -le $Now) {
        $lines += "⚠️ $($plan.Label)　$(Format-PunchTime $at -Now $Now) 已經過了，沒排"
        continue
    }
    if (-not $DryRun) { Register-PunchTask -Name $plan.Slot -At $at -Label "預約$($plan.Label)" }
    $icon = if ($p.Kind -eq 'in') { '🌅' } else { '🌆' }
    $lines += "$icon $($plan.Label)　$(Format-PunchTime $at -Now $Now)"
}

$text = "📅 ${intro}`n`n已預約：`n$($lines -join "`n")"

# 班表快用完就提前提醒，免得月底那幾天沒排到
$left = @($codes.Keys | Where-Object { $_ -ge $key }).Count
if ($left -le 5) {
    $text += "`n`n📖 班表剩 $left 天，請更新 data\shifts.csv。"
}

Send-Note $text
