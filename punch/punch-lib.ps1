#Requires -Version 5.1
# 打卡的共用函式庫。
# 這裡是「怎麼算打卡時間、怎麼註冊排程」這些邏輯，
# 由 nightly-book.ps1、scheduled-punch.ps1 和 test-punch-times.ps1 dot-source 使用。

$PunchWrapper = "$PSScriptRoot\scheduled-punch.ps1"
$TaskIn       = "PunchIn-Booked"
$TaskOut      = "PunchOut-Booked"

# ── 預約打卡 ────────────────────────────────────────────────
# 時間到由 Task Scheduler 跑 scheduled-punch.ps1，這裡只負責註冊/查詢/取消。
# 上班卡、下班卡各一格（PunchIn-Booked / PunchOut-Booked），彼此獨立，同格重複預約直接覆蓋。
# 一律排「下一個該時間點」，所以值班隔天的下班卡不必特別處理跨天。

# 官方時間 → 實際打卡時間，往前或往後抖一段隨機分鐘，別每天分秒不差。
# $Offset 是 @(最少, 最多) 分鐘、兩端都含：上班卡給負的（提前），下班卡給正的（延後）。
function Add-PunchJitter {
    param([datetime]$At, [Parameter(Mandatory)][int[]]$Offset)
    $At.AddMinutes((Get-Random -Minimum $Offset[0] -Maximum ($Offset[1] + 1)))
}

# 四種預約各自的官方時間（Hour/Minute）、落在哪個排程格、下班卡要不要往後錨一天（值班），
# 以及實際打卡的偏移量：上班卡提前 10–15 分，下班卡延後 5–10 分，留緩衝免得壓線。
$Plans = @{
    in     = @{ Slot = $TaskIn;  Label = '上班卡'; Hour = 8;  Minute = 0;  DayOffset = 0; Offset = @(-15, -10) }
    off    = @{ Slot = $TaskOut; Label = '下班卡'; Hour = 17; Minute = 30; DayOffset = 0; Offset = @(5, 10) }
    am_off = @{ Slot = $TaskOut; Label = '下班卡'; Hour = 8;  Minute = 0;  DayOffset = 1; Offset = @(5, 10) }
    pm_off = @{ Slot = $TaskOut; Label = '下班卡'; Hour = 11; Minute = 30; DayOffset = 1; Offset = @(5, 10) }
}

# 某一天要打哪幾張卡：看那天的班別代碼，值班日還得看隔天的代碼，才知道下班卡落在哪天。
# 回傳 @(@{ Kind = 'in'; Date = 那張卡要打的日期 }, ...)，休假日回空陣列。
# 代碼不認得就丟例外——寧可吵，也不要默默漏打一張卡。
function Get-ShiftPunches {
    param([Parameter(Mandatory)][datetime]$Date, [string]$Code, [string]$NextCode)
    switch ($Code) {
        '100'  { return @() }                                  # 上下班時間都是 0，不用打卡
        '102'  { return @() }
        '906'  { return @(@{ Kind = 'am_off'; Date = $Date }) } # 值班隔天早上，人是回家，只打下班卡
        '908'  { return @(@{ Kind = 'pm_off'; Date = $Date }) } # 值班隔天中午，同上
        '9076' {
            # 隔天是 906/908 就代表這天要值班：留院過夜，只打上班卡，下班卡落在隔天
            if ($NextCode -eq '906') { return @(@{ Kind = 'in'; Date = $Date }, @{ Kind = 'am_off'; Date = $Date.AddDays(1) }) }
            if ($NextCode -eq '908') { return @(@{ Kind = 'in'; Date = $Date }, @{ Kind = 'pm_off'; Date = $Date.AddDays(1) }) }
            return @(@{ Kind = 'in'; Date = $Date }, @{ Kind = 'off'; Date = $Date })
        }
    }
    throw "班別代碼「$Code」沒見過（$($Date.ToString('MM/dd'))），不敢亂猜要打哪張卡。"
}

# 把一張卡換算成實際要執行的時刻（官方時間 + 隨機緩衝）
function Get-PunchMoment {
    param([Parameter(Mandatory)]$Punch)
    $p = $Plans[$Punch.Kind]
    Add-PunchJitter -Offset $p.Offset -At $Punch.Date.Date.AddHours($p.Hour).AddMinutes($p.Minute)
}

function Register-PunchTask {
    param([string]$Name, [datetime]$At, [string]$Label)
    # conhost --headless：直接開 powershell.exe 的話 -WindowStyle Hidden 生效前視窗會閃一下
    $action = New-ScheduledTaskAction -Execute "conhost.exe" `
        -Argument "--headless powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$PunchWrapper`" -Label `"$Label`""
    # WakeToRun：電腦睡著時叫醒它打卡；StartWhenAvailable：關機錯過了，開機後補跑
    $settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
    # 不用 RunLevel Highest：打卡只需 netsh wlan ... user=current 和自己的 Chrome，
    # 不提權則非管理員身分也能註冊（Highest 會 Access denied）
    Register-ScheduledTask -TaskName $Name -Action $action -Settings $settings `
        -Trigger (New-ScheduledTaskTrigger -Once -At $At) `
        -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive) `
        -Force -ErrorAction Stop | Out-Null
}

# 前面標「今天／明天」：值班隔天的下班卡會跨天，要一眼看出是哪天執行
function Format-PunchTime {
    param([datetime]$At, [datetime]$Now = (Get-Date))
    $stamp = "$($At.ToString('MM/dd')) ($('日一二三四五六'[[int]$At.DayOfWeek])) $($At.ToString('HH:mm'))"
    switch (($At.Date - $Now.Date).Days) {
        0       { "今天 $stamp" }
        1       { "明天 $stamp" }
        2       { "後天 $stamp" }
        default { $stamp }
    }
}
