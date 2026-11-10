#Requires -Version 5.1
# 夜間睡眠（選用，預設關閉）：每天到了設定的時間（預設 01:00）等電腦閒置滿 10 分鐘就讓它睡，起床時間（預設 07:00）自動叫醒。
# 時間在控制面板「睡眠與電源」頁改，存在 settings.ps1 的 $SleepAt / $WakeAt。
# 以下情況不睡：
#   - 當晚傳過 /sleepoff（隔天自動恢復）
#   - 值班夜（班表上當天 9076、隔天 906/908），可能半夜要遠端連回來
#   - Parsec 遠端連線中（遠端操作不算本機的鍵盤滑鼠，會被誤判成閒置）
#   - 離起床不到兩小時還沒閒置下來：睡沒多久就要被叫醒，不值得
# 預約打卡的排程本來就有 WakeToRun，睡著也會醒來打卡。
#
# 用法：
#   sleep.ps1              到睡覺時間由排程跑
#   sleep.ps1 -Install     開啟（註冊 NightSleep、MorningWake 兩張排程，順便打開「允許喚醒計時器」）
#   sleep.ps1 -Uninstall   關閉
#   sleep.ps1 -DryRun      只印判斷結果，不等閒置也不睡；-Now 可假裝任何時間
param([switch]$Install, [switch]$Uninstall, [switch]$DryRun, [datetime]$Now = (Get-Date))

. "$PSScriptRoot\shift-lib.ps1"   # Get-SleepTimes、Test-OncallNight、Get-NightOf、Test-SkipSleep
$times   = Get-SleepTimes
$SleepAt = $times.Sleep; $WakeAt = $times.Wake
$Tasks   = 'NightSleep', 'MorningWake'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $Tasks -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "已關閉夜間睡眠。" -ForegroundColor Green
    return
}

if ($Install) {
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    # 睡眠這張刻意不開 StartWhenAvailable：整晚關機的話，早上開機會把錯過的「睡」補跑，剛開機又被睡掉
    Register-ScheduledTask -TaskName NightSleep -Force -ErrorAction Stop -Principal $principal `
        -Trigger (New-ScheduledTaskTrigger -Daily -At $SleepAt) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew) `
        -Action (New-ScheduledTaskAction -Execute 'conhost.exe' `
                    -Argument "--headless powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$PSCommandPath`"") | Out-Null
    # 叫醒的排程本身什麼都不做，重點是 WakeToRun
    Register-ScheduledTask -TaskName MorningWake -Force -ErrorAction Stop -Principal $principal `
        -Trigger (New-ScheduledTaskTrigger -Daily -At $WakeAt) `
        -Settings (New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries) `
        -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit') | Out-Null
    # 「允許喚醒計時器」關著的話 WakeToRun 叫不醒電腦（插電、用電池都打開）。
    # 這要管理員才改得動：從 install.cmd 開會成功，從控制面板開可能沒權限，那就維持原本的電源設定
    powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 2>$null | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 2>$null | Out-Null
    powercfg /setactive SCHEME_CURRENT 2>$null | Out-Null
    $global:LASTEXITCODE = 0   # powercfg 沒權限失敗不算安裝失敗
    Write-Host "已開啟夜間睡眠：$SleepAt 閒置就睡，$WakeAt 叫醒。" -ForegroundColor Green
    return
}

$night  = Get-NightOf $Now
$skip   = Test-SkipSleep $night
$oncall = Test-OncallNight -Date $night
if ($skip -or $oncall) { if ($DryRun) { Write-Host "不睡：/sleepoff=$skip 值班夜=$oncall" }; exit }
# 保險：只在「睡覺時間前 15 分鐘」到「起床前 2 小時」之間真的睡（可以跨午夜，例如 23:00 睡 07:00 醒）。
# 有人白天手動觸發這張排程也不准把電腦弄睡；離起床不到兩小時也不睡了
function Test-SleepWindow([datetime]$At) {
    $span = ((([TimeSpan]$WakeAt) - ([TimeSpan]$SleepAt)).TotalMinutes + 1440) % 1440
    $el   = (($At.TimeOfDay - [TimeSpan]$SleepAt).TotalMinutes + 1440 + 15) % 1440 - 15
    $el -ge -15 -and $el -le $span - 120
}
if (-not (Test-SleepWindow $Now)) {
    if ($DryRun) { Write-Host "不在 $SleepAt 前 15 分鐘到 $WakeAt 前 2 小時之間，不睡" }; exit
}
if ($DryRun) { Write-Host "會等閒置滿 10 分鐘、沒有 Parsec 連線後睡覺"; exit }

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Idle {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint MinutesIdle() {
        var i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(i);
        GetLastInputInfo(ref i);
        return ((uint)Environment.TickCount - i.dwTime) / 60000;
    }
}
'@
# 讀 Parsec log 最後一筆 connected/disconnected：connected 表示有人遠端連著。沒裝 Parsec 就當沒連
function Test-ParsecActive {
    $log = "$env:APPDATA\Parsec\log.txt"
    if (-not (Test-Path $log)) { return $false }
    $last = Select-String -Path $log -Pattern ' (connected|disconnected)\.$' | Select-Object -Last 1
    return [bool]($last -and $last.Line.TrimEnd().EndsWith(' connected.'))
}
while ([Idle]::MinutesIdle() -lt 10 -or (Test-ParsecActive)) {
    if (-not (Test-SleepWindow (Get-Date))) { exit }
    if (Test-SkipSleep $night) { exit }   # 等的時候才傳 /sleepoff 也要算數
    Start-Sleep -Seconds 60
}
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) | Out-Null
