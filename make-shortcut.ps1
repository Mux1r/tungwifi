#Requires -Version 5.1
# 幫 wifi-dashboard.ps1 做一個捷徑。換電腦或搬資料夾之後跑一次。
# 捷徑裡是絕對路徑，所以不進版控

$Dir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Target = Join-Path $Dir "wifi-dashboard.ps1"
$LnkPaths = @(
    (Join-Path $Dir "WiFi 控制面板.lnk"),
    (Join-Path ([Environment]::GetFolderPath("Desktop")) "WiFi 控制面板.lnk")
)

if (-not (Test-Path $Target)) {
    Write-Host "[FAIL] 找不到 $Target" -ForegroundColor Red
    exit 1
}

# 不直接指 powershell.exe：-WindowStyle Hidden 是 PowerShell 啟動「之後」
# 才去藏視窗，conhost 早就把視窗畫出來了，到點會閃一下。
# conhost --headless 開出來的 console 根本不建視窗，連閃都沒有。
# 捷徑物件不叫 $lnk：PowerShell 變數不分大小寫，$lnk 和 $Lnk 是同一個，
# 會把路徑變數蓋掉
$ws = New-Object -ComObject WScript.Shell
foreach ($LnkPath in $LnkPaths) {
    $sc  = $ws.CreateShortcut($LnkPath)
    $sc.TargetPath       = "$env:SystemRoot\System32\conhost.exe"
    $sc.Arguments        = "--headless powershell.exe -ExecutionPolicy Bypass -File `"$Target`""
    $sc.WorkingDirectory = $Dir
    $sc.IconLocation     = "$env:SystemRoot\System32\netshell.dll,0"
    $sc.Description      = "WiFi 監控與打卡控制面板"
    $sc.WindowStyle      = 7    # 最小化。--headless 生效時用不到，當第二層保險
    $sc.Save()
    if (Test-Path -LiteralPath $LnkPath) {
        Write-Host "[OK] 捷徑建好了：$LnkPath" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] 捷徑沒建成：$LnkPath" -ForegroundColor Red
        exit 1
    }
}
