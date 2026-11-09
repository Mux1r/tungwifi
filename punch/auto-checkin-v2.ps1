#Requires -Version 5.1
# ============================================================
#  自動打卡腳本 v2 - 含 Chrome CDP 自動點擊打卡按鈕
#  用法: auto-checkin-v2.ps1 [-Silent] [-DryRun]
#        平常由 scheduled-punch.ps1 呼叫；-DryRun 只走到「立即打卡」前一步
# ============================================================

param(
    [switch]$Silent,
    [switch]$DryRun
)

$SSID      = "guest_tung"
$LoginURL  = "https://192.168.254.254/"
# Portal 帳密在 wifi-accounts.ps1（install.ps1 產生，不進 GitHub）；這裡只用第一組
$AccountsFile = "$PSScriptRoot\..\wifi-accounts.ps1"
if (Test-Path $AccountsFile) { . $AccountsFile }
$User      = @($Credentials)[0].User
$Pass      = @($Credentials)[0].Pass
$PwaUrl    = "http://service.sltung.com.tw/mobile_service_pwa/"
# Chrome 可能裝在三個地方之一（裝給所有人／32 位元／只裝給自己）
$ChromeExe      = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") |
                  Where-Object { Test-Path $_ } | Select-Object -First 1
$DebugPort      = 9222
# 登入狀態存在這個 Chrome 設定檔裡，不能放 %TEMP%：Windows 的「儲存空間感知」會清暫存，
# 2026-10-18 下午被清掉一次，隔天下班卡就停在「行動登入」掃 QR Code 的頁面打不成
$TempDir        = "$env:LOCALAPPDATA\tungwifi-punch\chrome"
$ScreenshotPath = "$PSScriptRoot\checkin-screenshot.png"

# 整段過程錄進 data/punch-logs/<年月>.log，截圖也留一份；不然事後只剩一張會被蓋掉的截圖可查
# （2026-10-07 那張沒打成的卡，六天後回頭查已經什麼都沒有了）
$LogDir = "$PSScriptRoot\..\data\punch-logs"
New-Item -ItemType Directory -Force $LogDir | Out-Null
try { Start-Transcript -Path "$LogDir\$(Get-Date -Format 'yyyy-MM').log" -Append | Out-Null } catch {}
# 截圖一張約 60KB，留 60 天就好
Get-ChildItem "$LogDir\*.png" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-60) } | Remove-Item -ErrorAction SilentlyContinue

$modeLabel = if ($DryRun) { "測試模式（不會實際打卡）" } else { "打卡" }
Write-Host "`n=============================" -ForegroundColor Magenta
Write-Host "  自動打卡系統 - $modeLabel" -ForegroundColor Magenta
Write-Host "=============================" -ForegroundColor Magenta

# ── 前置：確認連線狀態 ───────────────────────────────────────
function Test-Online {
    try {
        $r = Invoke-WebRequest "http://connectivitycheck.gstatic.com/generate_204" `
                -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        return ($r.StatusCode -in @(200, 204))
    } catch { return $false }
}

$wlanInfo    = (netsh wlan show interfaces) -join "`n"
$onSSID      = $wlanInfo -match "(?m)State\s+:\s+connected" -and $wlanInfo -match [regex]::Escape($SSID)
$skipNetwork = $onSSID -and (Test-Online)

if ($skipNetwork) {
    Write-Host "`n[網路] 已連線 $SSID 且網路正常，直接執行打卡" -ForegroundColor Green
} else {
    Write-Host "`n[網路] 需要重新連線，執行完整流程..." -ForegroundColor Yellow
}

if (-not $skipNetwork) {

# ────────────────────────────────────────────────────────────
# 1. 建立 WiFi Profile
# ────────────────────────────────────────────────────────────
Write-Host "`n[1/4] 建立 WiFi profile..." -ForegroundColor Cyan

$profileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$SSID</name>
  <SSIDConfig>
    <SSID><name>$SSID</name></SSID>
    <nonBroadcast>false</nonBroadcast>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>open</authentication>
        <encryption>none</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
    </security>
  </MSM>
</WLANProfile>
"@

$profilePath = "$env:TEMP\$($SSID -replace '\s','_').xml"
[IO.File]::WriteAllText($profilePath, $profileXml, [Text.Encoding]::UTF8)
netsh wlan delete profile name="$SSID" 2>$null | Out-Null
netsh wlan add profile filename="$profilePath" user=current | Out-Null
Write-Host "  Profile 已建立。"

# ────────────────────────────────────────────────────────────
# 2. 連接 WiFi
# ────────────────────────────────────────────────────────────
Write-Host "`n[2/4] 連接到 '$SSID'..." -ForegroundColor Cyan
netsh wlan connect name="$SSID" | Out-Null

$connected = $false
for ($i = 1; $i -le 20; $i++) {
    Start-Sleep -Seconds 2
    $info = (netsh wlan show interfaces) -join "`n"
    if ($info -match "(?m)State\s+:\s+connected" -and $info -match [regex]::Escape($SSID)) {
        $connected = $true; break
    }
    Write-Host "  等待中... ($($i * 2) 秒)"
}

if ($connected) {
    Write-Host "  已連接到 '$SSID'!" -ForegroundColor Green
} else {
    # 只有 guest_tung 打得了卡，連不上就不用開 Chrome 白跑一趟（多半是電腦不在醫院）
    Write-Host "  RESULT: FAIL no-wifi" -ForegroundColor Red
    Write-Host "  連不上 '$SSID'，無法打卡。" -ForegroundColor Red
    exit 2
}

Start-Sleep -Seconds 3

# ────────────────────────────────────────────────────────────
# 3. 登入 Captive Portal (Cisco WLC 自訂網頁驗證)
# ────────────────────────────────────────────────────────────
Write-Host "`n[3/4] 登入 Portal..." -ForegroundColor Cyan

# 忽略自簽 SSL 憑證
try {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class BypassSSL3 : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int err) { return true; }
}
"@
} catch {}
[Net.ServicePointManager]::CertificatePolicy = New-Object BypassSSL3
[Net.ServicePointManager]::SecurityProtocol  = [Net.SecurityProtocolType]::Tls12

# 取得本機 WiFi 介面 MAC 位址
$wifiMac = ""
try {
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and ($_.PhysicalMediaType -match '802.11' -or $_.Name -match 'Wi-?Fi|Wireless|WLAN') } | Select-Object -First 1
    if ($adapter) {
        $wifiMac = $adapter.MacAddress -replace '-',':' | ForEach-Object { $_.ToLower() }
    }
} catch {}

$portalSuccess = $false

try {
    # GET 登入頁面 (會被重定向到實際登入頁)
    Write-Host "  取得登入頁面..."
    $resp = Invoke-WebRequest -Uri $LoginURL -SessionVariable sess -UseBasicParsing -TimeoutSec 15
    $html = $resp.Content

    # 從重定向後的 URL 取得 Cisco WLC 參數
    $finalUrl = $resp.BaseResponse.ResponseUri.AbsoluteUri
    Write-Host "  登入頁面: $finalUrl"

    # 解析 URL 中的參數 (Cisco WLC 傳遞的)
    $apMac      = if ($finalUrl -match 'ap_mac=([^&]+)')      { [Uri]::UnescapeDataString($matches[1]) } else { "" }
    $clientMac  = if ($finalUrl -match 'client_mac=([^&]+)')  { [Uri]::UnescapeDataString($matches[1]) } else { $wifiMac }
    $wlan       = if ($finalUrl -match 'wlan=([^&]+)')        { [Uri]::UnescapeDataString($matches[1]) } else { $SSID }
    $switchUrl  = if ($finalUrl -match 'switch_url=([^&]+)')  { [Uri]::UnescapeDataString($matches[1]) } else { "https://192.168.254.254/login.html" }
    $redirectTo = if ($finalUrl -match 'redirect=([^&]+)')    { [Uri]::UnescapeDataString($matches[1]) } else { "" }

    # 解析表單：蒐集 hidden fields 和 action
    $action = $switchUrl
    if ($html -match '(?i)<form[^>]+action\s*=\s*[''"]([^''"]+)[''"]') {
        $raw = $matches[1]
        if ($raw -match '^https?://') { $action = $raw }
        else { $action = ([Uri]::new([Uri]$finalUrl, $raw)).AbsoluteUri }
    }

    $body      = [ordered]@{}
    $firstText = $null
    $firstPass = $null

    foreach ($m in [regex]::Matches($html, '(?i)<input[^>]+>')) {
        $tag  = $m.Value
        $name = if ($tag -match '(?i)name\s*=\s*[''"]([^''"]+)[''"]')  { $matches[1] } else { $null }
        $type = if ($tag -match '(?i)type\s*=\s*[''"]([^''"]+)[''"]')  { $matches[1].ToLower() } else { 'text' }
        $val  = if ($tag -match '(?i)value\s*=\s*[''"]([^''"]*)[''"]') { $matches[1] } else { '' }
        if (-not $name) { continue }

        switch ($type) {
            'hidden'   { $body[$name] = $val }
            'submit'   { $body[$name] = $val }
            'text'     { $body[$name] = $val; if (-not $firstText) { $firstText = $name } }
            'email'    { $body[$name] = $val; if (-not $firstText) { $firstText = $name } }
            'password' { $body[$name] = $val; if (-not $firstPass) { $firstPass = $name } }
        }
    }

    # 填入帳密
    if ($firstText) { $body[$firstText] = $User } else { $body['username'] = $User }
    if ($firstPass) { $body[$firstPass] = $Pass } else { $body['password'] = $Pass }

    # Cisco WLC 必要欄位（若頁面未提供則手動補上）
    if (-not $body.Contains('buttonClicked'))  { $body['buttonClicked']  = '4' }
    if (-not $body.Contains('redirect_url'))   { $body['redirect_url']   = $redirectTo }
    if (-not $body.Contains('err_flag'))       { $body['err_flag']       = '0' }
    if (-not $body.Contains('info_flag'))      { $body['info_flag']      = '0' }
    if ($apMac)     { $body['ap_mac']     = $apMac }
    if ($clientMac) { $body['client_mac'] = $clientMac }
    if ($wlan)      { $body['wlan']       = $wlan }

    Write-Host "  POST → $action"
    $loginResp = Invoke-WebRequest -Uri $action -Method POST -Body $body `
                    -WebSession $sess -UseBasicParsing -TimeoutSec 15

    Write-Host "  回應: $($loginResp.StatusCode)" -ForegroundColor Green
    $portalSuccess = $true
    Write-Host "  Portal 登入成功!" -ForegroundColor Green

} catch {
    Write-Host "  Portal 登入失敗: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  繼續嘗試開啟打卡系統..." -ForegroundColor Yellow
}

Start-Sleep -Seconds 2

} # end if (-not $skipNetwork)

# ────────────────────────────────────────────────────────────
# 4. 用 Chrome CDP 開啟 PWA 並自動打卡
# ────────────────────────────────────────────────────────────
Write-Host "`n[4/4] 開啟打卡系統並自動點擊..." -ForegroundColor Cyan

# CDP WebSocket 輔助函數
function Invoke-CDP {
    param(
        [string]$WsUrl,
        [string]$Method,
        [hashtable]$Params = @{}
    )
    $token = [System.Threading.CancellationToken]::None
    $ws    = [System.Net.WebSockets.ClientWebSocket]::new()

    try {
        $ws.ConnectAsync([Uri]$WsUrl, $token).Wait(10000) | Out-Null

        $cmd    = @{ id = 99; method = $Method; params = $Params } | ConvertTo-Json -Depth 10 -Compress
        $outBuf = [Text.Encoding]::UTF8.GetBytes($cmd)
        $ws.SendAsync([ArraySegment[byte]]::new($outBuf),
                      [System.Net.WebSockets.WebSocketMessageType]::Text,
                      $true, $token).Wait(5000) | Out-Null

        $chunkBuf = [byte[]]::new(65536)   # 64 KB chunk，累積至 EndOfMessage
        $deadline = [DateTime]::Now.AddSeconds(30)
        $response = $null

        while ([DateTime]::Now -lt $deadline) {
            $ms     = [IO.MemoryStream]::new()
            $result = $null
            do {
                $seg    = [ArraySegment[byte]]::new($chunkBuf)
                $result = $ws.ReceiveAsync($seg, $token).GetAwaiter().GetResult()
                $ms.Write($chunkBuf, 0, $result.Count)
            } while (-not $result.EndOfMessage -and [DateTime]::Now -lt $deadline)
            $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
            $obj  = $text | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($obj -and $obj.id -eq 99) { $response = $obj; break }
        }
        return $response
    } finally {
        try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $token).Wait(3000) } catch {}
        $ws.Dispose()
    }
}

# 停止可能佔用 9222 port 的舊 Chrome 實例
$oldDebug = Get-NetTCPConnection -LocalPort $DebugPort -ErrorAction SilentlyContinue
if ($oldDebug) {
    $pid2 = ($oldDebug | Select-Object -First 1).OwningProcess
    Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

if (-not $ChromeExe) {
    Write-Host "  RESULT: FAIL no-chrome" -ForegroundColor Red
    Write-Host "  找不到 Chrome，請先安裝 Google Chrome。" -ForegroundColor Red
    exit 1
}

# 啟動附帶 CDP 的 Chrome（獨立使用者目錄，不影響現有 Chrome）
Write-Host "  啟動 Chrome (除錯模式)..."
$chromeProc = Start-Process $ChromeExe -ArgumentList @(
    "--remote-debugging-port=$DebugPort",
    "--user-data-dir=`"$TempDir`"",
    "--app=$PwaUrl",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-sync",
    "--disable-extensions"
) -PassThru

# 等待 Chrome CDP 就緒
$cdpReady = $false
Write-Host "  等待 Chrome 初始化..."
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 2
    try {
        $targets = Invoke-RestMethod "http://localhost:$DebugPort/json/list" -ErrorAction Stop
        if ($targets) { $cdpReady = $true; break }
    } catch {}
    Write-Host "  等待中... ($($i * 2) 秒)"
}

if (-not $cdpReady) {
    Write-Host "  Chrome CDP 無法啟動。請確認 Chrome 路徑正確。" -ForegroundColor Red
    exit 1
}

Write-Host "  Chrome 已就緒。"
Start-Sleep -Seconds 3   # 等待頁面載入

# 取得頁面 WebSocket URL
$target = $null
for ($i = 0; $i -lt 10; $i++) {
    $targets = Invoke-RestMethod "http://localhost:$DebugPort/json/list"
    $target  = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1
    if ($target) { break }
    Start-Sleep -Seconds 2
}

if (-not $target) {
    Write-Host "  找不到 CDP 頁面目標。" -ForegroundColor Red
    exit 1
}

$wsUrl = $target.webSocketDebuggerUrl
Write-Host "  CDP 連接: $($target.url)"

# 等待 SPA 完全渲染（等待頁面 readyState = complete + 額外緩衝）
Write-Host "  等待頁面渲染完成..."
$deadline = [DateTime]::Now.AddSeconds(30)
while ([DateTime]::Now -lt $deadline) {
    $r = Invoke-CDP -WsUrl $wsUrl -Method "Runtime.evaluate" -Params @{
        expression    = "document.readyState"
        returnByValue = $true
    }
    if ($r.result.result.value -eq "complete") { break }
    Start-Sleep -Seconds 1
}
Start-Sleep -Seconds 5   # 等 Vue/React render 完成

# ── 步驟 0：檢查「偵測到系統更新」畫面，有就點「立即更新」──
# 那個更新畫面（#cache-error-screen）其實一直藏在網頁 HTML 裡，只有網頁 8 秒還沒載好才顯示出來；
# 按下去會清掉網頁快取再重整。原本沒檢查有沒有顯示，每次打卡都去按那顆藏起來的鈕，等於每次都強制重整，
# 2026-10-22 08:07 就是重整到一半第三步的鈕不見、之後一直載不完。所以只按看得到的（getClientRects 有東西）
$updateJs = @"
(function(){
    var els = Array.from(document.querySelectorAll('button, a, [role="button"], div'));
    var btn = els.filter(function(e){ return e.textContent.trim() === '立即更新' && e.getClientRects().length > 0; }).pop();
    if (btn) { btn.click(); return true; }
    return false;
})()
"@

# ponytail: 不等 readyState —— 頁面若沒真的重載它一直是 complete，等於空轉
#           （2026-07-28 07:45 就是這樣卡在更新畫面 34 秒後放棄）。改成等打卡按鈕出現。
function Wait-PunchReady {
    param([string]$WsUrl, [int]$Seconds = 30)
    $deadline = [DateTime]::Now.AddSeconds($Seconds)
    while ([DateTime]::Now -lt $deadline) {
        $r = Invoke-CDP -WsUrl $WsUrl -Method "Runtime.evaluate" -Params @{
            # 打卡鈕在更新畫面底下其實一直都在，要等「立即更新」從畫面上消失才算好
        # （2026-10-18 07:49 沒等到就開始按，網頁按到一半自己重整，結果整個不見）
        expression    = "!!document.querySelector('.punch-text') && (document.body.innerText || '').indexOf('立即更新') < 0"
            returnByValue = $true
        }
        if ($r.result.result.value -eq $true) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

# 沒驗到「打卡成功」就重整頁面整套再打，最多 3 次；重複打卡系統只會多一筆紀錄，不影響
# 迴圈到下面「解析結果」那段結束，刻意不縮排，免得整段打卡流程的 diff 糊成一片
$verified = $false
# 登入過期：網頁停在「行動登入」要掃 QR Code，重打幾次都沒用，只能本人重新登入（2026-10-19）
$login = Invoke-CDP -WsUrl $wsUrl -Method "Runtime.evaluate" -Params @{
    expression    = "location.pathname.indexOf('/login') >= 0 || (document.body.innerText || '').indexOf('登入 QR Code') >= 0"
    returnByValue = $true
}
$loginExpired = $login.result.result.value -eq $true
if ($loginExpired) {
    Write-Host "  RESULT: FAIL login-expired" -ForegroundColor Yellow
    Write-Host "  打卡網頁的登入過期了，要重新掃 QR Code 登入。" -ForegroundColor Yellow
}
for ($attempt = 1; $attempt -le 3 -and -not $loginExpired; $attempt++) {
if ($attempt -gt 1) {
    Write-Host "  第 $attempt 次重打：重新載入頁面..." -ForegroundColor Yellow
    Invoke-CDP -WsUrl $wsUrl -Method "Page.reload" -Params @{ ignoreCache = $true } | Out-Null
    Start-Sleep -Seconds 8
}

for ($try = 1; $try -le 2; $try++) {
    $upd = Invoke-CDP -WsUrl $wsUrl -Method "Runtime.evaluate" -Params @{
        expression    = $updateJs
        returnByValue = $true
    }
    if ($upd.result.result.value -eq $true) {
        Write-Host "  偵測到系統更新畫面，已點「立即更新」，等待打卡按鈕出現..." -ForegroundColor Yellow
    }

    if (Wait-PunchReady -WsUrl $wsUrl -Seconds 30) { break }

    if ($try -eq 1) {
        Write-Host "  等不到打卡按鈕，強制重新載入頁面..." -ForegroundColor Yellow
        Invoke-CDP -WsUrl $wsUrl -Method "Page.reload" -Params @{ ignoreCache = $true } | Out-Null
        Start-Sleep -Seconds 8
    } else {
        Write-Host "  重載後仍找不到打卡按鈕，接下來的步驟可能失敗。" -ForegroundColor Yellow
    }
}

# ── JavaScript：三步驟打卡流程 ────────────────────────────
# 步驟 1: 點「出勤打卡」按鈕  (.punch-text)
# 步驟 2: 等 modal 出現 → 點「關閉」(button[data-bs-dismiss="modal"])
# 步驟 3: 等 → 點「立即打卡」(.btn-punch)
$dryRunJs = if ($DryRun) { "true" } else { "false" }
$js = @"
(async function() {
    var dryRun = $dryRunJs;
    function wait(ms) { return new Promise(function(r){ setTimeout(r, ms); }); }
    // 每一步點到的按鈕文字記下來，log 裡才看得出有沒有點錯
    var clicked = [];
    function label(e) { return (e.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 30) + ' <' + e.tagName.toLowerCase() + '.' + (e.className || '') + '>'; }

    // ── 步驟 1：點「出勤打卡」────────────────────────────
    var punchCard = document.querySelector('.punch-text');
    if (!punchCard) {
        return { ok: false, step: 1, msg: '找不到 .punch-text（出勤打卡按鈕）', clicked: clicked };
    }
    clicked.push('1 ' + label(punchCard));
    punchCard.click();

    // ── 步驟 2：等 modal → 點「關閉」───────────────────
    await wait(1800);
    var closeBtn = document.querySelector('button[data-bs-dismiss="modal"]');
    if (!closeBtn) {
        closeBtn = Array.from(document.querySelectorAll('button')).find(function(b){
            return b.textContent.trim() === '關閉';
        });
    }
    if (!closeBtn) {
        return { ok: false, step: 2, msg: '找不到「關閉」按鈕（modal 可能未出現）', clicked: clicked };
    }
    clicked.push('2 ' + label(closeBtn));
    closeBtn.click();

    // ── 步驟 3：點「立即打卡」（DryRun 時跳過）──────────
    await wait(1500);
    if (dryRun) {
        return { ok: true, step: 3, msg: '測試模式：步驟 1-2 成功，跳過立即打卡', dryRun: true, clicked: clicked };
    }
    var nowBtn = document.querySelector('.btn-punch');
    if (!nowBtn) {
        nowBtn = Array.from(document.querySelectorAll('button')).find(function(b){
            return b.textContent.includes('立即打卡');
        });
    }
    if (!nowBtn) {
        return { ok: false, step: 3, msg: '找不到「立即打卡」按鈕（.btn-punch）', clicked: clicked };
    }
    clicked.push('3 ' + label(nowBtn));
    nowBtn.click();

    // ── 步驟 4：等系統訊息「您已於 … 打卡成功！」───────────
    // 點完不代表打成了，要看到系統回的時間才算（2026-10-07 早上系統顯示沒刷，這邊卻沒有任何紀錄）
    var text = '';
    for (var i = 0; i < 20; i++) {
        await wait(500);
        text = document.body.innerText || '';
        if (text.indexOf('打卡成功') >= 0) break;
    }
    var m = text.match(/您已於\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/);
    return { ok: text.indexOf('打卡成功') >= 0, step: 4, when: m ? m[1] : '',
             msg: '畫面文字：' + text.replace(/\s+/g, ' ').slice(0, 200), clicked: clicked };
})()
"@

Write-Host "  執行打卡動作（三步驟）..."
$result = Invoke-CDP -WsUrl $wsUrl -Method "Runtime.evaluate" -Params @{
    expression    = $js
    returnByValue = $true
    awaitPromise  = $true   # 等 async function 跑完
}

# 解析結果
$val = $result.result.result.value
# 驗證通過＝看到「打卡成功」而且系統時間離現在 5 分鐘內（不是某次舊打卡留下的訊息）
$verified = $false
if ($val) {
    @($val.clicked) | ForEach-Object { Write-Host "  點了：$_" }
    Write-Host "  $($val.msg)"
    $when = [datetime]::MinValue
    if ($val.ok -eq $true -and [datetime]::TryParse($val.when, [ref]$when)) {
        $verified = [Math]::Abs(((Get-Date) - $when).TotalMinutes) -lt 5
    }
    if ($val.dryRun) {
        Write-Host "  RESULT: DRYRUN"
    } elseif ($verified) {
        Write-Host "  RESULT: OK $($val.when)" -ForegroundColor Green
    } else {
        Write-Host "  RESULT: FAIL step=$($val.step) when=$($val.when)" -ForegroundColor Yellow
    }
    if ($val.ok -eq $true) {
        Write-Host ""
        Write-Host "  ✓ 三步驟全部執行完畢" -ForegroundColor Green
        Write-Host "    出勤打卡 → 關閉提示 → 立即打卡" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  ✗ 步驟 $($val.step) 失敗" -ForegroundColor Yellow
        Write-Host "    $($val.msg)" -ForegroundColor Yellow
        Write-Host "  → 請在 Chrome 視窗手動完成剩餘步驟" -ForegroundColor Cyan
    }
} else {
    Write-Host "  RESULT: FAIL no-result"
    Write-Host "  無法取得執行結果，請查看 Chrome 視窗確認打卡狀態。" -ForegroundColor Yellow
}
if ($verified -or $DryRun) { break }
}

# ── 截圖：等結果畫面穩定後擷取 ──────────────────────────────
Start-Sleep -Seconds 3
try {
    $sc    = Invoke-CDP -WsUrl $wsUrl -Method "Page.captureScreenshot" -Params @{ format = "png" }
    $bytes = [Convert]::FromBase64String($sc.result.data)
    [IO.File]::WriteAllBytes($ScreenshotPath, $bytes)
    Copy-Item $ScreenshotPath "$LogDir\$(Get-Date -Format 'yyyyMMdd-HHmmss').png"
    Write-Host "  截圖已儲存: $ScreenshotPath" -ForegroundColor Green
} catch {
    Write-Host "  截圖失敗: $($_.Exception.Message)" -ForegroundColor Yellow
}

# 截圖完成後關閉 Chrome 視窗
try {
    Invoke-CDP -WsUrl $wsUrl -Method "Browser.close" -Params @{} | Out-Null
    Write-Host "  Chrome 視窗已關閉。" -ForegroundColor Green
} catch {
    if ($chromeProc -and -not $chromeProc.HasExited) {
        $chromeProc.Kill()
        Write-Host "  Chrome 程序已終止。" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "完成！" -ForegroundColor Green
if (-not $Silent) {
    Write-Host "按任意鍵結束..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
if (-not $DryRun -and -not $verified) { exit 2 }
