#Requires -Version 5.1
# 預約打卡的日期運算自我檢查：powershell -ExecutionPolicy Bypass -File test-punch-times.ps1
. "$PSScriptRoot\punch-lib.ps1"

function Assert($cond, $msg) { if (-not $cond) { throw "FAIL: $msg" }; Write-Host "  ok  $msg" }

# 跟 punch-lib.ps1 的 $Plans 同一組偏移量：上班提前 10–15 分，下班延後 5–10 分
$InOff  = @(-15, -10)
$OutOff = @(5, 10)

# 官方 08:00 的上班卡，之前下指令 → 排今天，落在 07:45–07:50
$t = Get-NextPunchTime -Hour 8 -Minute 0 -Offset $InOff -Now ([datetime]'2026-07-27 06:00')
Assert (($t -ge [datetime]'2026-07-27 07:45') -and ($t -le [datetime]'2026-07-27 07:50')) "06:00 下指令 → 今天 07:45–07:50"
# 邊界：07:52 時官方 08:00 還沒到，但抖動是往前的，不可以排出今天那個已經過去的時間
$t = Get-NextPunchTime -Hour 8 -Minute 0 -Offset $InOff -Now ([datetime]'2026-07-27 07:52')
Assert ($t.Date -eq [datetime]'2026-07-28') "07:52 下指令 → 排到明天"
$t = Get-NextPunchTime -Hour 8 -Minute 0 -Offset $InOff -Now ([datetime]'2026-07-31 23:30')
Assert ($t.Date -eq [datetime]'2026-08-01') "月底 23:30 → 隔月 1 號"

# 標示今天/明天，跨天才不會看錯
$today = (Get-Date).Date.AddHours(8).AddMinutes(8)
Assert ((Format-PunchTime $today) -like "今天 * (*) 08:08") "今天標示"
Assert ((Format-PunchTime $today.AddDays(1)) -like "明天 * (*) 08:08") "明天標示"
Assert ((Format-PunchTime $today.AddDays(3)) -notlike "*今天*") "3 天後不標今天/明天"
Assert ((Format-PunchTime $today.AddDays(2)) -like "後天 *") "後天標示"
Assert ((Format-PunchTime ([datetime]'2026-07-27 07:48')) -like "*07/27 (一) 07:48") "格式化含星期"

# 下班卡跟著上班卡的日期算：/in 明天 → /pm_off（官方 11:30）要排到後天
$inAt = (Get-Date).Date.AddDays(1).AddHours(7).AddMinutes(48)
$pm = Add-PunchJitter -At $inAt.Date.AddDays(1).AddHours(11).AddMinutes(30) -Offset $OutOff
Assert ($pm.Date -eq (Get-Date).Date.AddDays(2)) "上班卡明天 → pm_off 後天"
Assert (($pm -ge (Get-Date).Date.AddDays(2).AddHours(11).AddMinutes(35)) -and
        ($pm -le (Get-Date).Date.AddDays(2).AddHours(11).AddMinutes(40))) "pm_off 落在 11:35–11:40"
$offAt = Add-PunchJitter -At $inAt.Date.AddHours(17).AddMinutes(30) -Offset $OutOff
Assert ($offAt.Date -eq (Get-Date).Date.AddDays(1)) "上班卡明天 → off 明天"
Assert (($offAt -ge (Get-Date).Date.AddDays(1).AddHours(17).AddMinutes(35)) -and
        ($offAt -le (Get-Date).Date.AddDays(1).AddHours(17).AddMinutes(40))) "off 落在 17:35–17:40"

# 隨機偏移：跑 200 次都要落在區間內，且最少出現 3 種不同結果（確認真的有隨機）
$base = [datetime]'2026-07-27 08:00'
$seen = 1..200 | ForEach-Object { Add-PunchJitter -At $base -Offset $InOff } | Sort-Object -Unique
Assert (($seen[0] -ge $base.AddMinutes(-15)) -and ($seen[-1] -le $base.AddMinutes(-10))) "上班抖動落在提前 10–15 分內"
Assert ($seen.Count -ge 3) "上班真的有隨機（200 次出現 $($seen.Count) 種時間）"

$seen = 1..200 | ForEach-Object { Add-PunchJitter -At $base -Offset $OutOff } | Sort-Object -Unique
Assert (($seen[0] -ge $base.AddMinutes(5)) -and ($seen[-1] -le $base.AddMinutes(10))) "下班抖動落在延後 5–10 分內"
Assert ($seen.Count -ge 3) "下班真的有隨機（200 次出現 $($seen.Count) 種時間）"

# ── 班別代碼 → 要打哪幾張卡 ─────────────────────────────
$d = [datetime]'2026-09-05'

# 值班日：代碼是全天班，但隔天是 906/908 → 只打上班卡，下班卡落在隔天
$r = @(Get-ShiftPunches -Date $d -Code '9076' -NextCode '906')
Assert ($r.Count -eq 2) "值班日出兩張卡"
Assert ($r[0].Kind -eq 'in' -and $r[0].Date -eq $d) "值班日上班卡在當天"
Assert ($r[1].Kind -eq 'am_off' -and $r[1].Date -eq $d.AddDays(1)) "值班日下班卡落在隔天早上"
$r = @(Get-ShiftPunches -Date $d -Code '9076' -NextCode '908')
Assert ($r[1].Kind -eq 'pm_off' -and $r[1].Date -eq $d.AddDays(1)) "隔天是 908 → 下班卡是 pm_off"

# 一般全天班：兩張都在當天
$r = @(Get-ShiftPunches -Date $d -Code '9076' -NextCode '9076')
Assert ($r[0].Kind -eq 'in' -and $r[1].Kind -eq 'off') "一般全天班出上班卡+下班卡"
Assert ($r[1].Date -eq $d) "一般全天班的下班卡在當天"
$r = @(Get-ShiftPunches -Date $d -Code '9076' -NextCode '102')
Assert ($r[1].Kind -eq 'off') "隔天休假 → 還是一般全天班，不是值班"

# 值班隔天：只有下班卡
$r = @(Get-ShiftPunches -Date $d -Code '906' -NextCode '9076')
Assert ($r.Count -eq 1 -and $r[0].Kind -eq 'am_off') "906 只打下班卡"
$r = @(Get-ShiftPunches -Date $d -Code '908' -NextCode '9076')
Assert ($r.Count -eq 1 -and $r[0].Kind -eq 'pm_off') "908 只打下班卡"

# 休假日：一張都不打
Assert (@(Get-ShiftPunches -Date $d -Code '100' -NextCode '9076').Count -eq 0) "100 不用打卡"
Assert (@(Get-ShiftPunches -Date $d -Code '102' -NextCode '9076').Count -eq 0) "102 不用打卡"

# 沒見過的代碼要吵，不可以默默當成休假漏打
$threw = $false
try { Get-ShiftPunches -Date $d -Code '777' -NextCode '9076' } catch { $threw = $true }
Assert $threw "沒見過的代碼會丟例外"

# 卡 → 實際執行時刻（官方時間 + 緩衝）
$m = Get-PunchMoment -Punch @{ Kind = 'in'; Date = $d }
Assert (($m -ge $d.AddHours(7).AddMinutes(45)) -and ($m -le $d.AddHours(7).AddMinutes(50))) "上班卡落在 07:45–07:50"
$m = Get-PunchMoment -Punch @{ Kind = 'am_off'; Date = $d }
Assert (($m -ge $d.AddHours(8).AddMinutes(5)) -and ($m -le $d.AddHours(8).AddMinutes(10))) "am_off 落在 08:05–08:10"


# ── 班表怎麼讀 ─────────────────────────────
. "$PSScriptRoot\..\shift-lib.ps1"

# 讀班表：只認 yyyy-MM-dd,代碼，註解／空行／寫壞的行一律跳過，不要瞎猜
$tmp = Join-Path $env:TEMP "shift-test-$PID.csv"
@'
# 這是註解

2026-09-05,9076
  2026-09-06 , 906
2026-09-07,9076,多一欄
壞掉的行
'@ | Set-Content $tmp -Encoding UTF8
$c = Read-ShiftTable -Path $tmp
Assert ($c.Count -eq 2) "只讀進格式正確的 2 行（實際 $($c.Count)）"
Assert ($c['2026-09-05'] -eq '9076') "讀得到代碼"
Assert ($c['2026-09-06'] -eq '906') "前後空白會被修掉"
Assert (-not $c.ContainsKey('2026-09-07')) "多一欄的行不採用"
Remove-Item $tmp -Force
Assert ((Read-ShiftTable -Path (Join-Path $env:TEMP 'nope-does-not-exist.csv')).Count -eq 0) "檔案不在就回空表，不炸掉"

# 值班夜＝當天 9076 且隔天是 906/908
$codes = @{ '2026-09-03' = '9076'; '2026-09-04' = '9076'; '2026-09-05' = '9076'
            '2026-09-06' = '906';  '2026-09-07' = '9076'; '2026-09-08' = '102' }
Assert (Test-OncallNight -Date ([datetime]'2026-09-05') -Codes $codes) "9/5 隔天是 906 → 值班夜"
Assert (-not (Test-OncallNight -Date ([datetime]'2026-09-04') -Codes $codes)) "9/4 隔天還是全天班 → 不是值班夜"
Assert (-not (Test-OncallNight -Date ([datetime]'2026-09-07') -Codes $codes)) "9/7 隔天休假 → 不是值班夜"
Assert (-not (Test-OncallNight -Date ([datetime]'2026-12-25') -Codes $codes)) "班表查不到那天 → 照常睡"

# 「這一晚」往前推 6 小時：凌晨 00:30 還算前一晚
Assert ((Get-NightOf ([datetime]'2026-09-06 00:30')) -eq [datetime]'2026-09-05') "00:30 算前一晚"
Assert ((Get-NightOf ([datetime]'2026-09-05 23:00')) -eq [datetime]'2026-09-05') "23:00 算當晚"

# 手動預約照班表排：9/17 值班（隔天 908）、9/19–20 休假、9/21 值班（隔天 906）
$codes = @{ '2026-09-17' = '9076'; '2026-09-18' = '908'; '2026-09-19' = '100'; '2026-09-20' = '102'
            '2026-09-21' = '9076'; '2026-09-22' = '906' }
$now = [datetime]'2026-09-17 07:56'
Assert ((Find-ShiftPunchTime -Kind 'pm_off' -Codes $codes -Now $now).Date -eq [datetime]'2026-09-18') "值班日早上按 pm_off → 隔天中午"
Assert ((Find-ShiftPunchTime -Kind 'in' -Codes $codes -Now $now).Date -eq [datetime]'2026-09-21') "07:56 按 in → 跳過 908 和休假，排到 9/21"
Assert ((Find-ShiftPunchTime -Kind 'am_off' -Codes $codes -Now $now).Date -eq [datetime]'2026-09-22') "按 am_off → 下一個 906 那天"
Assert ($null -eq (Find-ShiftPunchTime -Kind 'pm_off' -Codes @{ '2026-09-17' = '9076' } -Now $now)) "隔天查不到 → 不亂排下班卡"

# 預約回覆（DryRun 不動排程）：照班表的不加註，沒班表的要講明是照時間排
$r = Add-PunchBooking -Kind 'pm_off' -Codes $codes -Now $now -DryRun
Assert ($r -like '*下班卡約好了*' -and $r -notlike '*找不到*') "有班表 → 照班表約"
$r = Add-PunchBooking -Kind 'off' -Codes @{} -Now ([datetime]'2026-09-17 09:00') -DryRun
Assert ($r -like '*找不到這張卡*' -and $r -match '17:(3[5-9]|40)') "沒班表 → 照時間排 17:35–17:40 並註明"

# 夜間睡眠的安全時段（sleep.ps1 的 Test-SleepWindow）：睡覺前 15 分鐘到起床前 2 小時，可以跨午夜
$sleepAst = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\sleep.ps1", [ref]$null, [ref]$null)
$sleepAst.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Test-SleepWindow' }, $true) |
    ForEach-Object { Invoke-Expression $_.Extent.Text }
$SleepAt = '01:00'; $WakeAt = '07:00'
Assert (-not (Test-SleepWindow ([datetime]'2026-11-10 00:44'))) "01:00 睡：00:44 還不睡"
Assert (Test-SleepWindow ([datetime]'2026-11-10 05:00')) "01:00 睡 07:00 醒：05:00 還可以睡"
Assert (-not (Test-SleepWindow ([datetime]'2026-11-10 05:01'))) "01:00 睡 07:00 醒：05:01 離起床不到 2 小時，不睡"
$SleepAt = '23:00'; $WakeAt = '07:00'
Assert (Test-SleepWindow ([datetime]'2026-11-10 23:59')) "23:00 睡：跨午夜前可以睡"
Assert (Test-SleepWindow ([datetime]'2026-11-10 03:30')) "23:00 睡：跨午夜後可以睡"
Assert (-not (Test-SleepWindow ([datetime]'2026-11-10 20:00'))) "23:00 睡：20:00 不睡"

Write-Host "全部通過" -ForegroundColor Green
