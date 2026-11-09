#Requires -Version 5.1
# ============================================================
#  guest_tung Captive Portal 登入腳本 (純登入，不處理 WiFi 連線)
#  前提：手動連接到 guest_tung WiFi 後執行此腳本
#  -Silent : 非互動模式（供 wifi-monitor.ps1 呼叫），跳過 ReadKey
#            成功 exit 0，失敗 exit 1
# ============================================================

param([switch]$Silent)
$SSID = "guest_tung"
if (Test-Path "$PSScriptRoot\settings.ps1") { . "$PSScriptRoot\settings.ps1" }   # 控制面板改過的 SSID
# 帳密在 wifi-accounts.ps1（install.ps1 產生，只存在自己電腦，不進 GitHub、更新也不會蓋掉）。
# 裡面的 $Credentials 依序嘗試，前面失敗就換下一組。
$AccountsFile = Join-Path $PSScriptRoot 'wifi-accounts.ps1'
if (Test-Path $AccountsFile) { . $AccountsFile }
if (-not $Credentials) {
    Write-Host "[FAIL] 找不到訪客 WiFi 帳密（wifi-accounts.ps1），請重跑 install.cmd 輸入。" -ForegroundColor Red
    if (-not $Silent) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
    exit 1
}

# ────────────────────────────────────────────────────────────
# SSL bypass (PS5 compatible)
# ────────────────────────────────────────────────────────────
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $sslParam = @{ SkipCertificateCheck = $true }
} else {
    try {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class BypassSSL : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int err) {
        return true;
    }
}
"@
    } catch {}
    [Net.ServicePointManager]::CertificatePolicy = New-Object BypassSSL
    [Net.ServicePointManager]::SecurityProtocol  = [Net.SecurityProtocolType]::Tls12
    $sslParam = @{}
}

# ────────────────────────────────────────────────────────────
# 1. 組出登入 URL (從 netsh 取 MAC，或使用已知固定值)
# ────────────────────────────────────────────────────────────
Write-Host "`n[1/2] 取得登入 URL..." -ForegroundColor Cyan

$wlanInfo  = (netsh wlan show interfaces) -join "`n"
$apMac     = if ($wlanInfo -match "(?m)BSSID\s*:\s*([\da-fA-F:]{17})")            { $matches[1] } else { "84:b2:61:9d:33:90" }
# 備援值只有在 netsh 讀不到時才會用到，換成自己網卡的 MAC（netsh wlan show interfaces 可查）
$clientMac = if ($wlanInfo -match "(?m)Physical address\s*:\s*([\da-fA-F:]{17})") { $matches[1] } else { "00:00:00:00:00:00" }

$loginURL = "https://192.168.254.254/fs/customwebauth/login.html" +
            "?switch_url=https://192.168.254.254/login.html" +
            "&ap_mac=$apMac&client_mac=$clientMac" +
            "&wlan=$SSID&redirect=www.msftconnecttest.com/redirect"

Write-Host "  AP MAC    : $apMac"
Write-Host "  Client MAC: $clientMac"
Write-Host "  URL: $loginURL"

# ────────────────────────────────────────────────────────────
# 2. 依序 POST 登入，失敗（或登入後仍無法上網）就換下一組帳密
# action="https://192.168.254.254/login.html"
# submitAction() 將 buttonClicked 由 0 改成 4 再送出
# ────────────────────────────────────────────────────────────
$loginAction = "https://192.168.254.254/login.html"
$online = $false

foreach ($cred in $Credentials) {
    Write-Host "`n[2/2] 登入 Captive Portal (帳號 $($cred.User))..." -ForegroundColor Cyan

    $body = @{
        buttonClicked = '4'
        redirect_url  = ''
        err_flag      = '0'
        username      = $cred.User
        password      = $cred.Pass
    }

    try {
        $loginResp = Invoke-WebRequest -Uri $loginAction -Method POST -Body $body `
                         -UseBasicParsing @sslParam -TimeoutSec 15 -ErrorAction Stop
        Write-Host "  HTTP 回應: $($loginResp.StatusCode)" -ForegroundColor Green
    } catch {
        Write-Host "  POST 失敗: $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    Write-Host "`n[驗證] 測試網路連線..." -ForegroundColor Cyan
    Start-Sleep -Seconds 4

    try {
        $r = Invoke-WebRequest -Uri "http://connectivitycheck.gstatic.com/generate_204" `
                -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 8 -ErrorAction Stop
        if ($r.StatusCode -eq 204) { $online = $true; Write-Host "  HTTP 204 - 連線成功!" -ForegroundColor Green }
        else { Write-Host "  generate_204 回傳 $($r.StatusCode)，仍被攔截" -ForegroundColor Yellow }
    } catch { Write-Host "  generate_204: $($_.Exception.Message)" -ForegroundColor Yellow }

    if (-not $online) {
        try {
            $r = Invoke-WebRequest -Uri "http://www.msftconnecttest.com/connecttest.txt" `
                    -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 8 -ErrorAction Stop
            if ($r.StatusCode -eq 200 -and $r.Content -match "Microsoft Connect Test") {
                $online = $true
                Write-Host "  connecttest 內容正確 - 連線成功!" -ForegroundColor Green
            } else {
                Write-Host "  connecttest 內容不符，仍被攔截 (status=$($r.StatusCode))" -ForegroundColor Yellow
            }
        } catch { Write-Host "  connecttest: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    if ($online) { break }
    Write-Host "  帳號 $($cred.User) 登入後仍無法上網，換下一組..." -ForegroundColor Yellow
}

if ($online) {
    Write-Host "`n[OK] 登入成功，可以上網!" -ForegroundColor Green
} else {
    Write-Host "`n[FAIL] 所有帳密都登入後仍無法上網。" -ForegroundColor Red
    if (-not $Silent) {
        Write-Host "  開啟瀏覽器手動登入: $loginURL" -ForegroundColor Yellow
        Start-Process $loginURL
    }
}

if (-not $Silent) {
    Write-Host "`n完成! 按任意鍵結束..." -ForegroundColor Green
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

exit $(if ($online) { 0 } else { 1 })
