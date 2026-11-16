# tungwifi

維持 `guest_tung` WiFi 連線，用 Telegram 一個指令打卡、把結果和截圖傳回來。

- **WiFi 監控**：開機常駐，斷線自動重連並登入訪客 WiFi。
- **打卡**：在 Telegram 傳 `/punch`，電腦自動開 Chrome 打卡，結果和截圖傳回 Telegram；也可以用 `/in`、`/off` 先預約。
- **控制面板**：桌面捷徑「WiFi 控制面板」，看連線狀態、手動打卡、看打卡記錄、開關各項功能、更新。
- **選用功能**（預設關閉）：依班表自動打卡、夜間讓電腦睡覺早上自動叫醒。

## 需要什麼

- **電腦放在醫院，或任何連得到 `guest_tung` 的地方**，而且一直開著。連不到 `guest_tung` 就打不了卡。
- Windows 10/11，登入的帳號是系統管理員。
- 裝好 Chrome。
- 手機有 Telegram。

## 安裝（建議交給 AI）

1. 在電腦上打開 Claude Code（或其他能在電腦上執行指令的 AI 助理），貼上這句話：

   ```text
   幫我安裝 tungwifi，照這份說明做：https://raw.githubusercontent.com/Mux1r/tungwifi/main/AI-INSTALL.md
   ```
2. AI 會幫你下載、打開安裝視窗，並一步步帶你回答問題（包括 `guest_tung` 的帳密）、建立自己的 Telegram bot。跳出系統管理員確認時按「是」。
3. 裝好後，在控制面板按「打開打卡網頁（登入用）」，用手機掃 QR Code 登入，之後就會記住。登入過期時也按這顆重新登入。

不想用 AI，可以照 [INSTALL.md](INSTALL.md) 自己裝。

## Telegram 指令

對自己的 bot 傳這些指令（輸入框打 `/` 會跳出選單）：


| 指令                                    | 作用                                                           |
| ----------------------------------------- | ---------------------------------------------------------------- |
| **⏰ 打卡**                             |                                                                |
| `/punch`（或 `/打卡`）                  | 立即打卡，約 1 分鐘後回報結果並附截圖                          |
| `/test`（或 `/測試`）                   | 測試打卡流程（不實際送出）                                     |
| **📅 預約**                             |                                                                |
| `/in`（或 `/上班卡`）                   | 預約上班卡，08:00 前 10–15 分鐘打                             |
| `/off`（或 `/下班卡`）                  | 預約下班卡，17:30 後 5–10 分鐘打                              |
| `/am_off`                               | 預約值班隔日早上下班卡（08:05 左右）                           |
| `/pm_off`                               | 預約值班隔日中午下班卡（11:35 左右）                           |
| `/cancel`（或 `/取消預約`）             | 取消預約                                                       |
| **🔍 查詢**                             |                                                                |
| `/status`（或 `/狀態`）                 | 查詢系統狀態：網路、預約、今晚睡眠                             |
| **😴 睡眠**（有開夜間睡眠才出現在選單） |                                                                |
| `/sleepoff`（或 `/不睡`）               | 今晚停用睡眠，明晚自動恢復                                     |
| `/sleepon`（或 `/恢復睡眠`）            | 今晚恢復睡眠（取消 `/sleepoff`）                               |
| **🔄 更新**                             |                                                                |
| `/update`（或 `/更新`）                 | 更新至最新版本                                                 |
| `/rollback`（或 `/還原`）               | 還原上一版本（新版有異常時使用；有上一版本才出現在選單）       |

電腦要開著、連得上網才收得到指令，連上 `guest_tung` 才打得了卡。電腦睡著時傳的指令，醒來後不會補做。

## 更新

裝好之後不用再下載。每天 09:00 有新版就自動更新，更新完 Telegram 會通知；想先看過再裝，可以在控制面板「功能開關」關掉「有新版時自動更新」，之後有新版只會通知，回 `/update` 或在「關於與更新」按「立即更新」才裝。Telegram 金鑰、WiFi 帳密、班表和控制面板的設定都不會被更新蓋掉。

### 每個整點閃一下藍色視窗

2026-11-15 以前安裝的電腦，每個整點會閃一下藍色的 PowerShell 視窗。那是 WiFi 監控每小時檢查自己有沒有在跑，不影響打卡和 WiFi。更新程式改不到這張排程（要管理員權限），想讓它消失的話，在開始選單找「PowerShell」，按右鍵選「以系統管理員身分執行」，貼上這一行按 Enter：

```powershell
$a=(Get-ScheduledTask WiFi-AutoLogin-Monitor).Actions[0]; if ($a.Execute -ne 'conhost.exe') { Set-ScheduledTask -TaskName WiFi-AutoLogin-Monitor -Action (New-ScheduledTaskAction -Execute conhost.exe -Argument "--headless powershell.exe $($a.Arguments)") | Out-Null }; '改好了'
```

看到「改好了」就完成。這行只改這張排程的啟動方式，其他設定都不動，貼兩次也沒關係。之後新安裝的電腦已經是不閃的版本，不用做。

## 其他說明

- [INSTALL.md](INSTALL.md)：自己手動安裝、設定 Telegram bot、改選項和填班表、指令的細節。
- [AI-INSTALL.md](AI-INSTALL.md)：給 AI 看的安裝步驟、驗證方式和技術細節。
