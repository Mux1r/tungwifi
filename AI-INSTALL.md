# 給 AI 的安裝說明

你是在使用者自己的 Windows 電腦上幫使用者安裝 tungwifi。使用者沒有程式背景，每一步用白話說明，需要他動手時講清楚要按哪裡。

## 前提

- Windows 10/11，Windows PowerShell 5.1（內建的 `powershell.exe`，不是 pwsh 7）。
- 電腦要能看到 `guest_tung` 這個 WiFi（醫院內）。
- 要裝好 Chrome。打卡用的是獨立的 Chrome 設定檔（`%LOCALAPPDATA%\tungwifi-punch\chrome`），新電腦第一次打卡時要在裡面掃 QR Code 登入打卡網頁一次。
- 腳本檔有中文，PowerShell 5.1 需要 UTF-8 BOM 才讀得懂。不要用會拿掉 BOM 的方式改檔。

## 步驟

### 1. 先確認是不是已經裝過

```powershell
Get-ScheduledTask WiFi-AutoLogin-Monitor -ErrorAction SilentlyContinue | ForEach-Object { $_.Actions.Arguments }
```

有結果就代表裝過了，路徑裡就是原本的資料夾。這時不要重新下載，請使用者在 Telegram 回 `/update`，或在原本的資料夾跑 `powershell.exe -ExecutionPolicy Bypass -File "<原本的資料夾>\update.ps1" -Apply`，就完成了。

使用者堅持要裝到新資料夾的話，先把舊資料夾的個人檔複製過去（`bot-config.ps1`、`wifi-accounts.ps1`、`settings.ps1`、整個 `data\`），再繼續下面的步驟，裝好確認沒問題後，問過使用者才刪舊資料夾。

### 2. 下載

裝到 `%USERPROFILE%\Documents\tungwifi`（之後不能搬，排程記的是絕對路徑）：

```powershell
$dest = "$env:USERPROFILE\Documents\tungwifi"
$tmp  = Join-Path $env:TEMP "tungwifi-dl"
Invoke-WebRequest https://codeload.github.com/Mux1r/tungwifi/zip/main -OutFile "$tmp.zip" -UseBasicParsing
Expand-Archive "$tmp.zip" $tmp -Force
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item "$tmp\tungwifi-main\*" $dest -Recurse -Force
Remove-Item "$tmp.zip", $tmp -Recurse -Force
```

### 3. 執行安裝

```powershell
Start-Process "$env:USERPROFILE\Documents\tungwifi\install.cmd"
```

`install.ps1` 會自己要求系統管理員權限，開一個新的視窗，問題都要使用者在那個視窗裡回答（你看不到也打不進去）。先跟使用者說會跳出管理員確認要按「是」，再照順序告訴他每題怎麼答：

1. 訪客 WiFi 帳號密碼：`guest_tung` 登入頁用的帳密，好幾組用逗號隔開，密碼只輸入一次。
2. 開啟依班表自動打卡？大多數人按 `N`（只用 `/punch` 打卡）。
3. 開啟夜間睡眠？想讓電腦半夜睡、早上自己醒就 `Y`。
4. 是否立即啟動？`Y`。
5. 現在設定 Telegram？`Y`，然後陪使用者建 bot：Telegram 搜尋 @BotFather（藍勾勾）→ 按開始 → 傳 `/newbot` → 取顯示名稱 → 取以 `bot` 結尾的帳號 → 把 BotFather 回的金鑰整串複製、貼回視窗 → 到 Telegram 搜尋自己的 bot 按「開始」→ 視窗顯示「設定完成」並收到測試訊息。
6. 看到「全部裝好了」就完成。

最後提醒使用者：在控制面板按一次「立即打卡」，打卡網頁要登入就用手機掃 QR Code。金鑰等於 bot 的密碼，不要傳給別人。

### 4. 驗證

```powershell
$d = "$env:USERPROFILE\Documents\tungwifi"

# 排程都在、路徑指向這個資料夾（沒開的選用功能找不到排程是正常的）
Get-ScheduledTask WiFi-AutoLogin-Monitor, TelegramCommands, AutoUpdate, PunchGuard, NightlyBook, NightSleep -ErrorAction SilentlyContinue | ForEach-Object { "$($_.TaskName): $($_.Actions.Arguments)" }

# 監控有在跑：log 有「=== WiFi 監控啟動」，之後持續有新紀錄
Get-Content "$d\wifi-monitor.log" -Tail 5

# 打卡時間、預約、值班夜邏輯的自我檢查，結尾要是「全部通過」
powershell.exe -ExecutionPolicy Bypass -File "$d\punch\test-punch-times.ps1"

# 打卡檢查能跑：LastTaskResult 要是 0
Start-ScheduledTask PunchGuard; (Get-ScheduledTaskInfo PunchGuard).LastTaskResult
```

## 安裝會建出什麼

`install.ps1`：沒有 `wifi-accounts.ps1` 就問訪客 WiFi 帳密並產生；沒有 `data\shifts.csv` 就建一份空白的；問要不要開「依班表自動打卡」（選 N 會刪掉 `NightlyBook`）和「夜間睡眠」；依序裝下表的排程；最後若還沒設定 Telegram，問要不要執行 `setup-telegram.ps1`。排程一律裝給目前登入的帳號（不支援借別人的管理員帳號安裝）。若發現同名排程指向別的資料夾，會先列出來問要不要覆蓋。每一件也可以單獨跑：

| 步驟 | 指令 | 建出的排程 / 檔案 |
| --- | --- | --- |
| WiFi 監控開機自啟 | `setup-autostart.ps1`（要管理員，結尾會 `Read-Host` 問要不要立即啟動） | 排程 `WiFi-AutoLogin-Monitor`：登入時啟動＋每小時補一次，RunLevel Highest |
| 控制面板捷徑 | `make-shortcut.ps1` | 資料夾內和桌面各一個 `WiFi 控制面板.lnk`，圖示是 `app.ico`（Lucide 的 calendar-clock；更新時會順手把現有捷徑換成這個圖示） |
| Telegram 指令 | `punch\telegram-commands.ps1 -Install` | 排程 `TelegramCommands`：登入時啟動＋每小時補一次，常駐接收指令，啟動時用 `setMyCommands` 登記指令選單；沒設定 Telegram 時啟動即結束 |
| 每天檢查更新 | `update.ps1 -Install` | 排程 `AutoUpdate`：每天 09:00（電腦沒醒就醒來補跑）比對 GitHub `main` 最新 commit。預設只傳 Telegram 通知（同一版只通知一次），`settings.ps1` 設 `$AutoUpdate = 1` 才直接更新。更新時下載 zip 覆蓋程式檔，新版有任何 `.ps1` 語法錯誤就整批不更新；打卡進行中會等它結束（最多 10 分鐘）。覆蓋前把目前這版備份到 `data\backup\`，`update.ps1 -Rollback` 退回並把退掉的版本記進 `data\update-skip.txt`，不再自動裝。紀錄在 `data\update.log` |
| 打卡檢查 | `punch\punch-guard.ps1 -Install` | 排程 `PunchGuard`：每 5 分鐘檢查預約的卡（手動 `/in`、`/off` 或依班表）有沒有打成，沒有就發 Telegram |
| 每晚預約打卡（選用） | `punch\nightly-book.ps1 -Install` | 排程 `NightlyBook`：每天 21:00 照 `data\shifts.csv` 註冊隔天的 `PunchIn-Booked` / `PunchOut-Booked` |
| 夜間睡眠（選用） | `sleep.ps1 -Install`／`-Uninstall` | 排程 `NightSleep`（預設 01:00，等閒置 10 分鐘就睡，不補跑）和 `MorningWake`（預設 07:00，WakeToRun 叫醒），時間存在 `settings.ps1` 的 `$SleepAt`／`$WakeAt`；只在睡覺前 15 分鐘到起床前 2 小時之間真的睡；並用 `powercfg` 打開「允許喚醒計時器」（要管理員，從控制面板開可能改不到） |

其他試算工具（不動排程也不發訊息）：

```powershell
powershell.exe -ExecutionPolicy Bypass -File "$d\punch\nightly-book.ps1" -DryRun                      # 只印出會預約什麼
powershell.exe -ExecutionPolicy Bypass -File "$d\sleep.ps1" -DryRun -Now "2026-12-01 01:00"          # 只印今晚睡不睡
```

## 要知道的事

- **個人檔不進 GitHub、自動更新也不會蓋**（見 `.gitignore`）：`wifi-accounts.ps1`（訪客 WiFi 帳密，`install.ps1` 產生）、`bot-config.ps1`（`setup-telegram.ps1` 產生）、`settings.ps1`（控制面板改過的參數）、`data\`（班表、紀錄、目前版本、`/sleepoff` 的旗標）。打卡的身分不在腳本裡，是打卡網頁在 Chrome 設定檔裡記住的登入狀態。
- **參數**：`wifi-monitor.ps1` 開頭的 `$SSID`、`$PollInterval` 等是預設值；控制面板存檔只寫進 `settings.ps1`，監控程式啟動時讀它覆蓋預設值。
- **自動更新與重開**：`update.ps1` 更新完會重開 `TelegramCommands`。WiFi 監控每 3 秒檢查自己的程式檔和 `settings.ps1`，有變就自己重開（它是管理員權限，一般權限的更新程式停不掉它）。手動更新就跑 `update.ps1 -Apply`。推新版前先跑 `test-punch-times.ps1`，推上去當天 09:00 所有人都會收到通知。
- **依班表自動打卡預設關閉**：班表 `data\shifts.csv` 一行一天，格式 `yyyy-MM-dd,班別代碼`；手動預約也會參考它。剩 5 天以內時預約通知裡會提醒。21:00 那次若因關機錯過，開機後補跑時預約的是當天剩下的卡。
- **夜間睡眠**：「這一晚」是往前推 6 小時算的，所以 00:30 傳的 `/sleepoff` 還算前一晚。睡覺那張排程刻意不補跑，免得整晚關機後一開機就被睡掉。Parsec 連線中不睡（遠端操作不算本機閒置）。
- **取消預約**：Telegram 傳 `/cancel`，或刪掉排程 `PunchIn-Booked` / `PunchOut-Booked`。
- **Telegram**：只聽 `$AuthChatId` 本人的訊息，紀錄在 `data\telegram-commands.log`。同一個 bot 同時只能有一支程式讀訊息，`setup-telegram.ps1` 執行時會先停掉 `TelegramCommands`、設定完再啟動。想把通知送進群組的某個話題，可另建 `data\tg-topics.json`（`{"schedule": <話題 id>}`），沒有這個檔就直接送到聊天室。不想收通知就把 `$BotToken` 清空，打卡照常。
- **排程沒有視窗**：打卡排程用 `conhost.exe --headless` 啟動，出錯畫面上看不到，要看 `data\punch-logs\` 和 Telegram。
- **解除安裝**：`Unregister-ScheduledTask -TaskName WiFi-AutoLogin-Monitor, NightlyBook, PunchGuard, TelegramCommands, AutoUpdate, NightSleep, MorningWake, PunchIn-Booked, PunchOut-Booked -Confirm:$false`，再刪掉資料夾和桌面捷徑。
