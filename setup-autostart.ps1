#Requires -Version 5.1
#Requires -RunAsAdministrator
# 註冊 WiFi 監控的開機自啟。以系統管理員身分執行一次即可。
# 需要管理員是因為 netsh 連線 WiFi 要提權。

$TaskName      = "WiFi-AutoLogin-Monitor"
$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$MonitorScript = Join-Path $ScriptDir "wifi-monitor.ps1"

if (-not (Test-Path $MonitorScript)) {
    Write-Host "[錯誤] 找不到 $MonitorScript" -ForegroundColor Red
    exit 1
}

Write-Host "`n註冊 WiFi 監控: $TaskName" -ForegroundColor Cyan
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# ExecutionTimeLimit 用 0 = 不限時；原本設 365 天，2026-10-21 跑 19 天就被判超時砍掉
try {
    Register-ScheduledTask -TaskName $TaskName -Force -ErrorAction Stop `
        -Trigger   @(
                        (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
                        # 每小時補一次：監控若意外結束，最多一小時內復活（IgnoreNew + Mutex 保證不會跑兩份）
                        (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1))
                    ) `
        -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest) `
        -Settings  (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit ([TimeSpan]::Zero) `
                        -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 2) `
                        -MultipleInstances IgnoreNew) `
        -Action    (New-ScheduledTaskAction -Execute "powershell.exe" `
                        -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$MonitorScript`"") | Out-Null
    Write-Host "  完成，每次登入會自動在背景啟動。" -ForegroundColor Green
} catch {
    Write-Host "  [錯誤] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$start = Read-Host "`n是否立即啟動? (Y/N)"
if ($start -match '^[Yy]') {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "已在背景啟動，斷線時會自動重連並登入 Portal。" -ForegroundColor Green
}
