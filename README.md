# tungwifi

維持 `guest_tung` WiFi 連線，用 Telegram 一個指令打卡、把結果和截圖傳回來。

- **WiFi 監控**（`wifi-monitor.ps1`）：開機常駐，斷線自動重連並登入 Captive Portal。
- **打卡**（`punch\`）：在 Telegram 傳 `/punch`，電腦自動開 Chrome 打卡，結果和截圖傳回 Telegram。也可以用 `/in`、`/off` 先預約，時間到自動打。
- **依班表自動打卡**（選用，預設關閉）：每晚 21:00 依 `data\shifts.csv` 預約隔天的卡，時間到自動打，沒打成會提醒。
- **夜間睡眠**（選用，預設關閉）：每天 01:00 電腦閒置就睡，07:00 自動叫醒；值班夜或傳過 `/sleepoff` 的晚上不睡。
- **控制面板**（`wifi-dashboard.ps1`）：查看連線狀態和下次打卡時間，手動啟停監控、登入 Portal、立即打卡、修改參數、開關夜間睡眠。
- **自動更新**（`update.ps1`）：每天早上 06:00 從 GitHub 抓最新版，有更新會傳 Telegram 通知。

## 懶人安裝

1. 打開 <https://github.com/Mux1r/tungwifi>，按綠色的「Code」→「Download ZIP」。
2. 解壓縮，把資料夾放到想要的位置，例如 `文件\tungwifi`（之後別再搬，排程記的是絕對路徑；搬了就再裝一次）。
3. 雙擊 `install.cmd`，跳出系統管理員確認時按「是」。每個人裝在自己的電腦上，用平常登入的帳號安裝。
4. 問訪客 WiFi 帳號密碼：輸入 `guest_tung` 登入頁用的帳密（問同事）。只會存在自己電腦，不會上傳。
5. 問「開啟依班表自動打卡?」：只想自己傳 `/punch` 打卡就按 `N`（大多數人選這個）。
6. 問「開啟夜間睡眠?」：想讓電腦半夜自己睡、早上自己醒就按 `Y`，不要就按 `N`。
7. 問「是否立即啟動?」按 `Y`。
8. 問「現在設定 Telegram?」按 `Y`，照下一節的步驟做。
9. 看到「全部裝好了」就完成。
10. 第一次打卡前，先在控制面板按「立即打卡」一次。打卡網頁若要求登入，用手機掃 QR Code 登入，之後就會記住。

裝好之後就不用再下載，每天早上會自動更新。自己的設定（Telegram 金鑰、WiFi 帳密、班表、控制面板改過的參數）都不會被更新蓋掉。

想改選項時：依班表自動打卡重跑一次 `install.cmd` 改答 `Y`/`N`；夜間睡眠可以在控制面板「設定」頁直接開關。有開依班表自動打卡的話，還要把自己的班表填進 `data\shifts.csv`（用記事本開，一行一天，例如 `2026-12-01,9076`）。

## 設定 Telegram 通知（用自己的 bot）

每個人用自己的 bot，通知只會傳給自己。安裝時沒設定，之後雙擊執行 `setup-telegram.ps1`（右鍵 →「用 PowerShell 執行」）也可以，重跑就是重設。

1. 手機或電腦打開 Telegram，搜尋 **@BotFather**（有藍色勾勾的那個），按「開始」。
2. 傳送 `/newbot`。
3. 它會問 bot 的顯示名稱，隨意取，例如「我的打卡通知」。
4. 再問 bot 的帳號，必須以 `bot` 結尾，例如 `wang_punch_bot`；被用過就換一個。
5. BotFather 回一段訊息，裡面有一串像 `123456789:ABCdef...` 的金鑰（token），整串複製。
6. 回到電腦上的設定視窗，貼上金鑰按 Enter。
7. 視窗會顯示你的 bot 帳號，到 Telegram 搜尋它、打開後按「開始」。
8. 幾秒內視窗顯示「設定完成」，Telegram 也會收到一則測試訊息，就好了。

設定好之後，在 Telegram 對自己的 bot 傳這些指令（輸入框打 `/` 會跳出選單）：

| 指令 | 作用 |
| --- | --- |
| `/punch`（或 `/打卡`） | 立即打卡，約 1 分鐘後回報結果並附截圖 |
| `/in`（或 `/上班卡`） | 預約上班卡，08:00 前 10–15 分鐘打 |
| `/off`（或 `/下班卡`） | 預約下班卡，17:30 後 5–10 分鐘打 |
| `/am_off` | 預約值班隔天早上的下班卡（08:05 左右） |
| `/pm_off` | 預約值班隔天中午的下班卡（11:35 左右） |
| `/status`（或 `/狀態`） | 查看連線、WiFi、已預約的卡和今晚睡不睡 |
| `/cancel`（或 `/取消預約`） | 取消還沒到的預約 |
| `/sleepoff`（或 `/不睡`） | 今晚電腦不睡，明晚自動恢復（有開夜間睡眠才有用） |
| `/sleepon`（或 `/恢復睡眠`） | 取消 `/sleepoff`，今晚照常睡 |

預約會先對照班表（有填的話）找下一張真的要打的卡，例如值班日傳 `/pm_off` 會排到隔天中午；沒填班表就照時間排最近的一個。上班卡打完，如果下班卡還沒約，通知裡會附上可以直接點的預約指令。預約的卡沒打成，5 分鐘內會傳提醒。

電腦要開著、連得上網才收得到指令，而且只有連上 `guest_tung` 才打得了卡；電腦不在醫院時傳 `/punch`，會回報「連不上 guest_tung」。電腦關機或睡著時傳的指令，醒來後不會補做（超過 2 分鐘的舊指令一律略過，並回一句提醒），以免隔天突然打一張卡。

金鑰等於這個 bot 的密碼，不要傳給別人。設定存在 `bot-config.ps1`，所以裝好的資料夾不要整包轉給別人，請對方自己從 GitHub 下載。

## 給 AI 的安裝說明

你是在一台新的 Windows 電腦上幫使用者安裝這套東西。使用者沒有程式背景，每一步用白話說明。

### 前提

- Windows 10/11，Windows PowerShell 5.1（內建的 `powershell.exe`，不是 pwsh 7）。
- 電腦要能看到 `guest_tung` 這個 WiFi（醫院內）。
- 要裝好 Chrome。打卡用的是獨立的 Chrome 設定檔（`%LOCALAPPDATA%\tungwifi-punch\chrome`），新電腦第一次執行時要在裡面掃 QR Code 登入打卡網頁一次。
- 腳本檔有中文，PowerShell 5.1 需要 UTF-8 BOM 才讀得懂。不要用會拿掉 BOM 的方式改檔。

### 安裝

以系統管理員身分執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File "<資料夾>\install.ps1"
```

它會：沒有 `wifi-accounts.ps1` 就問訪客 WiFi 帳密並產生；沒有 `data\shifts.csv` 就建一份空白的；問要不要開「依班表自動打卡」（預設 N，選 N 會刪掉 `NightlyBook`）和「夜間睡眠」（預設 N）；依序裝下表的排程；最後若還沒設定 Telegram，會問要不要執行 `setup-telegram.ps1`（互動式：要使用者自己去 @BotFather 建 bot、貼金鑰、傳訊息給 bot，請陪使用者一步步做）。排程一律裝給目前登入的帳號（每個人裝在自己電腦，不支援借別人的管理員帳號安裝）。每一件也可以單獨跑：

| 步驟 | 指令 | 建出的排程 / 檔案 |
| --- | --- | --- |
| WiFi 監控開機自啟 | `setup-autostart.ps1`（要管理員，結尾會 `Read-Host` 問要不要立即啟動） | 排程 `WiFi-AutoLogin-Monitor`：登入時啟動＋每小時補一次，RunLevel Highest |
| 控制面板捷徑 | `make-shortcut.ps1` | 資料夾內和桌面各一個 `WiFi 控制面板.lnk` |
| Telegram 指令 | `punch\telegram-commands.ps1 -Install` | 排程 `TelegramCommands`：登入時啟動＋每小時補一次，常駐接收上面那些指令；沒設定 Telegram 時啟動即結束 |
| 每天自動更新 | `update.ps1 -Install` | 排程 `AutoUpdate`：每天 06:00（錯過就開機補跑）比對 GitHub `main` 最新 commit，不同就下載 zip 覆蓋程式檔；新版有任何 `.ps1` 語法錯誤就整批不更新；紀錄在 `data\update.log` |
| 打卡檢查 | `punch\punch-guard.ps1 -Install` | 排程 `PunchGuard`：每 5 分鐘檢查預約的卡（手動 `/in`、`/off` 或依班表）有沒有打成，沒有就發 Telegram |
| 每晚預約打卡（選用） | `punch\nightly-book.ps1 -Install` | 排程 `NightlyBook`：每天 21:00 照 `data\shifts.csv` 註冊隔天的 `PunchIn-Booked` / `PunchOut-Booked` |
| 夜間睡眠（選用） | `sleep.ps1 -Install`／`-Uninstall` | 排程 `NightSleep`（01:00，等閒置 10 分鐘就睡，不補跑）和 `MorningWake`（07:00，WakeToRun 叫醒）；並用 `powercfg` 打開「允許喚醒計時器」（要管理員，從控制面板開可能改不到） |

`install.ps1` 若發現同名排程指向別的資料夾，會先列出來問要不要覆蓋。

### 驗證

```powershell
# 排程都在、路徑指向這個資料夾（沒開的選用功能找不到排程是正常的）
Get-ScheduledTask WiFi-AutoLogin-Monitor, TelegramCommands, AutoUpdate, PunchGuard, NightlyBook, NightSleep | ForEach-Object { "$($_.TaskName): $($_.Actions.Arguments)" }

# 監控有在跑：log 有「=== WiFi 監控啟動」，之後持續有新紀錄
Get-Content "<資料夾>\wifi-monitor.log" -Tail 5

# 打卡時間、預約、值班夜邏輯的自我檢查，結尾要是「全部通過」
powershell.exe -ExecutionPolicy Bypass -File "<資料夾>\punch\test-punch-times.ps1"

# 預約試算：只印出會預約什麼，不動排程也不發訊息
powershell.exe -ExecutionPolicy Bypass -File "<資料夾>\punch\nightly-book.ps1" -DryRun

# 睡眠試算：只印今晚睡不睡
powershell.exe -ExecutionPolicy Bypass -File "<資料夾>\sleep.ps1" -DryRun -Now "2026-12-01 01:00"

# 打卡檢查能跑：LastTaskResult 要是 0
Start-ScheduledTask PunchGuard; (Get-ScheduledTaskInfo PunchGuard).LastTaskResult
```

### 要知道的事

- **個人檔不進 GitHub、自動更新也不會蓋**（見 `.gitignore`）：`wifi-accounts.ps1`（訪客 WiFi 帳密，`install.ps1` 產生）、`bot-config.ps1`（`setup-telegram.ps1` 產生）、`settings.ps1`（控制面板改過的監控參數）、`data\`（班表、紀錄、目前版本、`/sleepoff` 的旗標）。打卡的身分不在腳本裡，是打卡網頁在 Chrome 設定檔裡記住的登入狀態。
- **參數**：`wifi-monitor.ps1` 開頭的 `$SSID`、`$PollInterval` 等是預設值；控制面板存檔只寫進 `settings.ps1`，監控程式啟動時讀它覆蓋預設值。
- **自動更新與重開**：`update.ps1` 更新完會重開 `TelegramCommands`。WiFi 監控每 3 秒檢查自己的程式檔和 `settings.ps1`，有變就自己重開（它是管理員權限，一般權限的更新程式停不掉它）。手動更新就直接跑 `update.ps1`。推新版前先跑 `test-punch-times.ps1`，推上去隔天早上所有人都會拿到。
- **依班表自動打卡預設關閉**：大多數使用者是自己傳 `/punch` 打卡。班表 `data\shifts.csv` 一行一天，格式 `yyyy-MM-dd,班別代碼`；手動預約也會參考它。剩 5 天以內時預約通知裡會提醒。21:00 那次若因關機錯過，開機後補跑時預約的是當天剩下的卡。
- **夜間睡眠**：「這一晚」是往前推 6 小時算的，所以 00:30 傳的 `/sleepoff` 還算前一晚。01:00 那張刻意不補跑，免得整晚關機後一開機就被睡掉。Parsec 連線中不睡（遠端操作不算本機閒置）。
- **取消預約**：Telegram 傳 `/cancel`，或刪掉排程 `PunchIn-Booked` / `PunchOut-Booked`。
- **Telegram**：只聽 `$AuthChatId` 本人的訊息，紀錄在 `data\telegram-commands.log`。同一個 bot 同時只能有一支程式讀訊息，`setup-telegram.ps1` 執行時會先停掉 `TelegramCommands`、設定完再啟動。想把通知送進群組的某個話題，可另建 `data\tg-topics.json`（`{"schedule": <話題 id>}`），沒有這個檔就直接送到聊天室。不想收通知就把 `$BotToken` 清空，打卡照常。
- **排程沒有視窗**：打卡排程用 `conhost.exe --headless` 啟動，出錯畫面上看不到，要看 `data\punch-logs\` 和 Telegram。
- **解除安裝**：`Unregister-ScheduledTask -TaskName WiFi-AutoLogin-Monitor, NightlyBook, PunchGuard, TelegramCommands, AutoUpdate, NightSleep, MorningWake, PunchIn-Booked, PunchOut-Booked -Confirm:$false`，再刪掉資料夾和桌面捷徑。
