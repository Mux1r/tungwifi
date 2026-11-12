#Requires -Version 5.1
# 一鍵安裝：WiFi 監控開機自啟 + dashboard 捷徑 + 接收 Telegram 指令 + 每天 09:00 檢查更新；
# 依班表自動打卡會另外問，預設不開。
# 重跑沒關係，每一步都是覆蓋重建。
# 每個人裝在自己的電腦、用自己的帳號，排程就裝給目前這個帳號（刻意不處理「借別人的管理員帳號」）

# 註冊 WiFi 監控要管理員；不是的話自己用管理員身分重開一次
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    exit
}

$Dir = $PSScriptRoot

# 同一台電腦上如果已經有排程指向別的資料夾，安裝會把它們改指到這裡，先問一聲
$old = 'WiFi-AutoLogin-Monitor', 'NightlyBook', 'PunchGuard', 'TelegramCommands', 'AutoUpdate' | ForEach-Object {
    $t = Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
    if ($t -and $t.Actions.Arguments -notmatch [regex]::Escape($Dir)) { "  $_ → $($t.Actions.Arguments)" }
}
if ($old) {
    Write-Host "這些排程目前指向別的資料夾，繼續的話會改成跑這裡的腳本：" -ForegroundColor Yellow
    $old | Write-Host
    if ((Read-Host "繼續? (Y/N)") -notmatch '^[Yy]') { exit }
}

New-Item -ItemType Directory -Force "$Dir\data\punch-logs" | Out-Null
$Utf8Bom = New-Object Text.UTF8Encoding $true   # PowerShell 5.1 要有 BOM 才讀得懂中文

# 訪客 WiFi 帳密只存在這台電腦（不進 GitHub），已經有就不再問
$AccountsFile = "$Dir\wifi-accounts.ps1"
if (-not (Test-Path $AccountsFile)) {
    Write-Host "`n請輸入醫院訪客 WiFi（guest_tung）登入頁的帳號密碼，只會存在這台電腦。" -ForegroundColor Cyan
    do { $users = @((Read-Host "帳號（好幾組就用逗號隔開，例如 PGY001,PGY002）") -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    until ($users -and -not ($users -match '["`$]'))
    # 刻意假設每組密碼都一樣（目前的訪客帳號就是這樣）；不一樣的話直接編輯 wifi-accounts.ps1
    do { $pass = (Read-Host "密碼（每組都一樣，輸入一次）").Trim() } until ($pass -and $pass -notmatch '["`$]')
    $lines = $users | ForEach-Object { "    @{ User = `"$_`"; Pass = `"$pass`" }" }
    [IO.File]::WriteAllText($AccountsFile,
        "# 醫院訪客 WiFi（Captive Portal）帳密，由 install.ps1 產生。只存在這台電腦，不進 GitHub，自動更新也不會蓋掉。`r`n" +
        "# 依序嘗試，前面失敗就換下一組。`r`n`$Credentials = @(`r`n$($lines -join "`r`n")`r`n)`r`n", $Utf8Bom)
}

# 班表也是個人的，不進 GitHub；沒有就建一份只有說明的空白檔
if (-not (Test-Path "$Dir\data\shifts.csv")) {
    [IO.File]::WriteAllText("$Dir\data\shifts.csv",
        "# 排班表：一行一天，格式「日期,班別代碼」，例如 2026-12-01,9076`r`n" +
        "# 代碼意義：9076=全天班（隔天是 906/908 就代表當天值班）、908=值班隔天中午下班、`r`n" +
        "#           906=值班隔天早上下班、100/102=不用打卡。`r`n" +
        "# 以 # 開頭的行會被略過。只有開啟「依班表自動打卡」才會用到。`r`n", $Utf8Bom)
}

$steps = @(
    @{ Name = 'WiFi 監控開機自啟'; File = "$Dir\setup-autostart.ps1"; Args = @{} },
    @{ Name = 'dashboard 捷徑';    File = "$Dir\make-shortcut.ps1";   Args = @{} },
    @{ Name = '接收 Telegram 指令'; File = "$Dir\punch\telegram-commands.ps1"; Args = @{ Install = $true } },
    @{ Name = '每天 09:00 檢查更新'; File = "$Dir\update.ps1"; Args = @{ Install = $true } },
    # 手動 /in /off 預約的卡也要有人檢查有沒有打成，所以不管有沒有開依班表自動打卡都裝
    @{ Name = '每 5 分鐘檢查預約的卡有沒有打成'; File = "$Dir\punch\punch-guard.ps1"; Args = @{ Install = $true } }
)
# 依班表自動打卡：大多數人是自己傳 /punch 打卡，預設不開。重跑安裝選 N 就是關掉
Write-Host "`n依班表自動打卡：每晚 21:00 照 data\shifts.csv 預約隔天的卡，時間到自動打。" -ForegroundColor Cyan
Write-Host "只想自己用 /punch 或控制面板打卡的話，選 N 就好。"
$auto = (Read-Host "開啟依班表自動打卡? (Y/N，預設 N)") -match '^[Yy]'
if ($auto) {
    $steps += @{ Name = '每晚 21:00 預約打卡'; File = "$Dir\punch\nightly-book.ps1"; Args = @{ Install = $true } }
} else {
    Unregister-ScheduledTask -TaskName NightlyBook -Confirm:$false -ErrorAction SilentlyContinue
}

# 夜間睡眠安裝時不問也不開：有人回報睡著後早上叫不醒、打不了卡。真的要用再從控制面板「睡眠與電源」頁開
$failed = @()
foreach ($s in $steps) {
    Write-Host "`n== $($s.Name)" -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    try {
        # 一定要用 hashtable splatting：陣列 @('-Install') 傳給 .ps1 在 PowerShell 5.1 不會綁到 [switch]$Install，
        # 子腳本會跑成主程式（telegram-commands 會在前景常駐、安裝卡死）
        $a = $s.Args
        & $s.File @a
        if ($LASTEXITCODE) { $failed += $s.Name }   # 子腳本用 exit 1 回報失敗
    } catch {
        Write-Host "  [錯誤] $($_.Exception.Message)" -ForegroundColor Red
        $failed += $s.Name
    }
}

if (Test-Path "$Dir\bot-config.ps1") { . "$Dir\bot-config.ps1" }   # setup-telegram.ps1 產生，不進 GitHub
if (-not $BotToken -and (Read-Host "`n還沒設定 Telegram 通知，現在設定? (Y/N)") -match '^[Yy]') {
    & "$Dir\setup-telegram.ps1"
} elseif ($BotToken) {
    try { Start-ScheduledTask -TaskName TelegramCommands -ErrorAction Stop } catch {}
}

Write-Host ""
if ($failed) { Write-Host "沒裝成的：$($failed -join '、')" -ForegroundColor Red }
else { Write-Host "全部裝好了。" -ForegroundColor Green }

if ($auto -and -not (Get-Content "$Dir\data\shifts.csv" -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d{4}-' })) {
    Write-Host "提醒：data\shifts.csv 還沒有班表，沒有班表就不會自動預約打卡。" -ForegroundColor Yellow
}
