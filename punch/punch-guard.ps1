#Requires -Version 5.1
# 預約打卡的外部守門員：該打的卡沒打成就發 Telegram 叫人。
#
# 為什麼不寫在 scheduled-punch.ps1 裡：那支自己出不來的時候（2026-09-03 專案搬家，
# 排程還指著舊路徑，PowerShell 連檔案都找不到），它裡面的通知程式碼也跟著出不來，
# 結果是卡沒打、人也不知道。守門員刻意是另一個檔、另一張排程，不跟被監控的東西共存亡。
#
# 用法：
#   punch-guard.ps1            檢查一次（給排程跑，每 5 分鐘）
#   punch-guard.ps1 -DryRun    只印會做什麼，不送訊息也不動排程
#   punch-guard.ps1 -Install   註冊自己的排程（PunchGuard，每 5 分鐘）
param([switch]$DryRun, [switch]$Install)

$TaskName = 'PunchGuard'

if ($Install) {
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument "--headless powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -NonInteractive -File `"$PSCommandPath`""
    # 重複要掛在自己的時間觸發器上，而且不給 RepetitionDuration（不給就是無限）
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5)
    $trigger.Repetition.StopAtDurationEnd = $false
    Register-ScheduledTask -TaskName $TaskName -Force -ErrorAction Stop `
        -Trigger $trigger `
        -Principal (New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited) `
        -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -MultipleInstances IgnoreNew) `
        -Action $action | Out-Null
    Write-Host "已註冊 $TaskName，每 5 分鐘檢查一次。" -ForegroundColor Green
    return
}

. "$PSScriptRoot\..\shift-lib.ps1"   # Send-Telegram
$Png = Join-Path $PSScriptRoot 'checkin-screenshot.png'
$now = Get-Date

foreach ($name in 'PunchIn-Booked', 'PunchOut-Booked') {
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if (-not $t) { continue }

    $at    = [datetime]$t.Triggers[0].StartBoundary
    $label = if ($name -eq 'PunchIn-Booked') { '上班卡' } else { '下班卡' }
    # 連 WiFi、開瀏覽器、等網頁，整套跑完要好幾分鐘，太早看會冤枉它
    if ($now -lt $at.AddMinutes(15)) { continue }
    # 還在跑就別判：scheduled-punch.ps1 沒打成會等 5 分鐘重跑一次（10-22 起），整套可能超過 15 分鐘
    if ($t.State -eq 'Running') { continue }

    $ran  = (Get-ScheduledTaskInfo -TaskName $name).LastRunTime -ge $at
    # 打卡紀錄裡有一行 RESULT: OK、而且系統回的時間在預約之後，才算這次真的打成了
    # （截圖不算：按鈕點了但沒打成也照樣會截圖）。紀錄在 auto-checkin-v2.ps1 寫的 data/punch-logs/<年月>.log
    $log  = "$PSScriptRoot\..\data\punch-logs\$($at.ToString('yyyy-MM')).log"
    $ok   = [bool](Test-Path $log) -and [bool](Get-Content $log -Encoding UTF8 | Where-Object {
                $_ -match 'RESULT: OK (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})' -and [datetime]$matches[1] -ge $at.AddMinutes(-1) })
    $shot = (Test-Path $Png) -and ((Get-Item $Png).LastWriteTime -gt $at)
    $when = $at.ToString('MM/dd HH:mm')

    # $result 給 message-hook.ps1 分辨是哪一種情況
    if ($ran -and $ok) {
        $warn = $null; $result = 'ok'                    # 打成了，安靜收工
    } elseif ($ran -and $shot) {
        $warn = "⚠️ ${label}（$when）紀錄中未出現「打卡成功」，可能未打成。請確認並手動補打。"; $result = 'unverified'
    } elseif ($ran) {
        $warn = "⚠️ ${label}（$when）已到時間但未產生新截圖，可能未打成。請確認並手動補打。"; $result = 'no-shot'
    } elseif ($now -gt $at.AddMinutes(60)) {
        $warn = "⚠️ ${label}（$when）已到時間但排程未執行，請手動打卡並檢查排程。"; $result = 'not-run'
    } else {
        continue    # 還沒跑，但還在等 StartWhenAvailable 補跑（例如電腦剛開機），先別動它
    }
    $data = @{ Result = $result; Card = $label; When = $when }

    if ($DryRun) {
        $shown = if ($warn) { Use-MessageHook -Text $warn -Event guard -Data $data } else { '正常，不通知' }
        Write-Host "[$name] at=$when ran=$ran ok=$ok shot=$shot → $shown"
        continue
    }
    if ($warn) { Send-Telegram $warn -Topic schedule -Event guard -Data $data | Out-Null }   # 送不出去也不會讓守門員自己炸掉
    # 結案就清掉這張過期預約，免得每 5 分鐘重複唸同一件事
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
