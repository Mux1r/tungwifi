#Requires -Version 5.1
# 預約打卡的日期運算自我檢查：powershell -ExecutionPolicy Bypass -File test-punch-times.ps1
. "$PSScriptRoot\punch-lib.ps1"

function Assert($cond, $msg) { if (-not $cond) { throw "FAIL: $msg" }; Write-Host "  ok  $msg" }

# 跟 punch-lib.ps1 的 $Plans 同一組偏移量：上班提前 10–15 分，下班延後 5–10 分
$InOff  = @(-15, -10)
$OutOff = @(5, 10)

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

Write-Host "全部通過" -ForegroundColor Green
