#Requires -Version 5.1
# WiFi 控制台 — 左側選單四頁：首頁（狀態、操作、日誌）、打卡記錄、功能開關、關於與更新
# 外觀比照 ok-ww 用的 Fluent（Windows 11 設定那種）：圓角卡片、系統強調色、滑動開關，跟著系統深淺色

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# PS1 用 $PSScriptRoot；EXE 用執行檔所在目錄
$script:Dir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    [System.IO.Path]::GetDirectoryName(
        [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    )
}
$script:MonitorScript = Join-Path $script:Dir "wifi-monitor.ps1"
$script:LoginScript   = Join-Path $script:Dir "wifi-login.ps1"
$script:CheckinScript = Join-Path $script:Dir "punch\auto-checkin-v2.ps1"
$script:UpdateScript  = Join-Path $script:Dir "update.ps1"
$script:LogFile       = Join-Path $script:Dir "wifi-monitor.log"
$script:SettingsFile  = Join-Path $script:Dir "settings.ps1"   # 個人設定，不進 GitHub、自動更新不會蓋掉
$script:PunchLogDir   = Join-Path $script:Dir "data\punch-logs"
$script:VersionFile   = Join-Path $script:Dir "data\version.txt"

$script:TaskSvc = New-Object -ComObject Schedule.Service
$script:TaskSvc.Connect()

$MonitorTask = "WiFi-AutoLogin-Monitor"
$PunchTasks  = "PunchIn-Booked", "PunchOut-Booked"   # nightly-book.ps1 每晚建的預約

# ══════════════════════════════════════════════════════════════
# 外觀元件：WinForms 本身畫不出圓角和滑動開關，用內建的 C# 編譯自己畫（不用另外裝任何東西）
# ══════════════════════════════════════════════════════════════

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Fluent
{
    public static class Theme
    {
        public static bool Dark = true;
        public static Color Window, Stack, Card, Stroke, Text, Text2, Text3, Accent, AccentHover, AccentPressed, AccentText,
            Control, ControlHover, ControlPressed, ControlStroke, Field, NavHover, NavSel, Disabled;
        public static Font Body, Icon;

        public static GraphicsPath Round(RectangleF r, float rad)
        {
            GraphicsPath p = new GraphicsPath();
            float d = rad * 2;
            if (d <= 0) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr hwnd, string app, string idList);

        // 標題列跟著深色（Windows 10 1809 以後才有，舊系統呼叫失敗就算了）
        public static void StyleWindow(Form f)
        {
            try { int v = Dark ? 1 : 0; DwmSetWindowAttribute(f.Handle, 20, ref v, 4); } catch { }
        }
        // 捲軸也換成深色
        public static void DarkScroll(Control c)
        {
            try { if (Dark) SetWindowTheme(c.Handle, "DarkMode_Explorer", null); } catch { }
        }
        // 下拉選單換成深色（展開的清單和箭頭）
        public static void DarkCombo(Control c)
        {
            try { if (Dark) SetWindowTheme(c.Handle, "DarkMode_CFD", null); } catch { }
        }
        // 標誌：Lucide 的 calendar-clock（24 格、圓頭線條）；app.ico 也是用同一組座標畫的
        public static void DrawLogo(Graphics g, RectangleF r, Color c, float stroke)
        {
            float s = r.Width / 24f; float x = r.X, y = r.Y;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (Pen p = new Pen(c, stroke * s))
            {
                p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
                using (GraphicsPath f = new GraphicsPath())   // 日曆外框：右上缺一角讓給時鐘
                {
                    f.AddLine(x + 21 * s, y + 7.5f * s, x + 21 * s, y + 6 * s);
                    f.AddArc(x + 17 * s, y + 4 * s, 4 * s, 4 * s, 0, -90);
                    f.AddLine(x + 19 * s, y + 4 * s, x + 5 * s, y + 4 * s);
                    f.AddArc(x + 3 * s, y + 4 * s, 4 * s, 4 * s, 270, -90);
                    f.AddLine(x + 3 * s, y + 6 * s, x + 3 * s, y + 20 * s);
                    f.AddArc(x + 3 * s, y + 18 * s, 4 * s, 4 * s, 180, -90);
                    f.AddLine(x + 5 * s, y + 22 * s, x + 8.5f * s, y + 22 * s);
                    g.DrawPath(p, f);
                }
                g.DrawLine(p, x + 16 * s, y + 2 * s, x + 16 * s, y + 6 * s);
                g.DrawLine(p, x + 8 * s, y + 2 * s, x + 8 * s, y + 6 * s);
                g.DrawLine(p, x + 3 * s, y + 10 * s, x + 8 * s, y + 10 * s);
                g.DrawEllipse(p, x + 10 * s, y + 10 * s, 12 * s, 12 * s);
                g.DrawLines(p, new PointF[] { new PointF(x + 17.5f * s, y + 17.5f * s), new PointF(x + 16 * s, y + 16.3f * s), new PointF(x + 16 * s, y + 14 * s) });
            }
        }
        public static void Buffer(Control c)
        {
            typeof(Control).GetProperty("DoubleBuffered", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance).SetValue(c, true, null);
        }
    }

    public abstract class Drawn : Control
    {
        protected bool hover, down;
        protected Drawn()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            Cursor = Cursors.Hand;
            Font = Theme.Body;
        }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
    }

    // 圓角卡片；裡面的 Label 背景設透明就會透出卡片顏色
    public class Card : Panel
    {
        public int Radius = 6;
        public Color Fill = Color.Empty;
        public bool Border = true;
        public Card()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath p = Theme.Round(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), Radius))
            using (SolidBrush b = new SolidBrush(Fill.IsEmpty ? Theme.Card : Fill))
            {
                g.FillPath(b, p);
                if (Border) using (Pen pen = new Pen(Theme.Stroke)) g.DrawPath(pen, p);
            }
            base.OnPaint(e);
        }
    }

    // 圓角按鈕：Accent＝強調色主按鈕，其他是一般按鈕；Glyph 是圖示字型裡的字元
    public class FButton : Drawn
    {
        public bool Accent;
        string glyph = "";
        public string Glyph { get { return glyph; } set { glyph = value ?? ""; Invalidate(); } }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            Color bg, fg, st;
            if (Accent)
            {
                bg = !Enabled ? Theme.Disabled : down ? Theme.AccentPressed : hover ? Theme.AccentHover : Theme.Accent;
                fg = Enabled ? Theme.AccentText : Theme.Text3; st = bg;
            }
            else
            {
                bg = !Enabled ? Theme.Control : down ? Theme.ControlPressed : hover ? Theme.ControlHover : Theme.Control;
                fg = Enabled ? Theme.Text : Theme.Text3; st = Theme.ControlStroke;
            }
            using (GraphicsPath p = Theme.Round(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), 4))
            using (SolidBrush b = new SolidBrush(bg))
            using (Pen pen = new Pen(st)) { g.FillPath(b, p); g.DrawPath(pen, p); }
            TextFormatFlags f = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine;
            Size ts = TextRenderer.MeasureText(g, Text, Font, Size.Empty, f);
            Size gs = glyph.Length > 0 ? TextRenderer.MeasureText(g, glyph, Theme.Icon, Size.Empty, f) : Size.Empty;
            int gap = (glyph.Length > 0 && Text.Length > 0) ? 8 : 0;
            int x = (Width - ts.Width - gs.Width - gap) / 2;
            if (glyph.Length > 0) TextRenderer.DrawText(g, glyph, Theme.Icon, new Point(x, (Height - gs.Height) / 2 + 1), fg, f);
            TextRenderer.DrawText(g, Text, Font, new Point(x + gs.Width + gap, (Height - ts.Height) / 2), fg, f);
        }
    }

    // 滑動開關。點了不會自己切換：由外面做完實際動作後依結果設 Checked，畫面才不會跟真實狀態對不上
    public class Toggle : Drawn
    {
        bool on;
        public string OnText = "開啟", OffText = "關閉";
        public bool Checked { get { return on; } set { on = value; Invalidate(); } }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            float h = 20, w = 40;
            RectangleF r = new RectangleF(0.5f, (Height - h) / 2f, w, h);
            using (GraphicsPath p = Theme.Round(r, h / 2f))
            {
                if (on)
                    using (SolidBrush b = new SolidBrush(!Enabled ? Theme.Disabled : hover ? Theme.AccentHover : Theme.Accent)) g.FillPath(b, p);
                else
                {
                    using (SolidBrush b = new SolidBrush(hover ? Theme.ControlHover : Theme.Control)) g.FillPath(b, p);
                    using (Pen pen = new Pen(Enabled ? Theme.Text2 : Theme.Text3)) g.DrawPath(pen, p);
                }
            }
            float d = (hover && Enabled) ? 14 : 12;
            float cx = on ? r.Right - 10 : r.X + 10, cy = r.Y + h / 2f;
            using (SolidBrush b = new SolidBrush(on ? Theme.AccentText : (Enabled ? Theme.Text2 : Theme.Text3)))
                g.FillEllipse(b, cx - d / 2f, cy - d / 2f, d, d);
            string t = on ? OnText : OffText;
            Size ts = TextRenderer.MeasureText(g, t, Font);
            TextRenderer.DrawText(g, t, Font, new Point((int)w + 10, (Height - ts.Height) / 2), Enabled ? Theme.Text : Theme.Text3);
        }
    }

    public class Logo : Control
    {
        public Logo()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                     ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
        }
        protected override void OnPaint(PaintEventArgs e) { Theme.DrawLogo(e.Graphics, new RectangleF(0, 0, Width, Height), Theme.Accent, 2); }
    }

    // 左側選單項目：選中時底色加深、左邊一條強調色
    public class NavItem : Drawn
    {
        public string Glyph = "";
        bool sel;
        public bool Selected { get { return sel; } set { sel = value; Invalidate(); } }
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (sel || hover)
                using (GraphicsPath p = Theme.Round(new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f), 4))
                using (SolidBrush b = new SolidBrush(sel ? Theme.NavSel : Theme.NavHover)) g.FillPath(b, p);
            if (sel)
                using (GraphicsPath p = Theme.Round(new RectangleF(1, (Height - 16) / 2f, 3, 16), 1.5f))
                using (SolidBrush b = new SolidBrush(Theme.Accent)) g.FillPath(b, p);
            Size gs = TextRenderer.MeasureText(g, Glyph, Theme.Icon);
            TextRenderer.DrawText(g, Glyph, Theme.Icon, new Point(14, (Height - gs.Height) / 2 + 1), Theme.Text);
            Size ts = TextRenderer.MeasureText(g, Text, Font);
            TextRenderer.DrawText(g, Text, Font, new Point(46, (Height - ts.Height) / 2), Theme.Text);
        }
    }
}
'@

# ── 色票：跟著系統深淺色；強調色取 Windows 個人化設定的強調色 ──
function C([string]$Hex) { [System.Drawing.ColorTranslator]::FromHtml($Hex) }
function Mix($A, $B, [double]$T) {
    [System.Drawing.Color]::FromArgb([int]($A.R + ($B.R - $A.R) * $T), [int]($A.G + ($B.G - $A.G) * $T), [int]($A.B + ($B.B - $A.B) * $T))
}
$dark = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme -ne 1
$T = [Fluent.Theme]
$T::Dark = $dark
# AccentPalette 是 8 組 RGBA，由淺到深；深色模式用淺的（第 2 組）、淺色模式用深的（第 5 組），跟 Windows 設定一樣
$palette = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -ErrorAction SilentlyContinue).AccentPalette
$ai = if ($dark) { 1 } else { 4 }
$accent = if ($palette -and $palette.Length -ge 32) { [System.Drawing.Color]::FromArgb($palette[$ai * 4], $palette[$ai * 4 + 1], $palette[$ai * 4 + 2]) }
          elseif ($dark) { C '#60CDFF' } else { C '#005FB8' }
if ($dark) {
    $T::Window = C '#202020'; $T::Stack = C '#272727'; $T::Card = C '#2D2D2D'; $T::Stroke = C '#1C1C1C'
    $T::Text = C '#FFFFFF'; $T::Text2 = C '#C5C5C5'; $T::Text3 = C '#8B8B8B'
    $T::Control = C '#363636'; $T::ControlHover = C '#3B3B3B'; $T::ControlPressed = C '#303030'; $T::ControlStroke = C '#424242'
    $T::Field = C '#383838'; $T::NavHover = C '#2A2A2A'; $T::NavSel = C '#2D2D2D'; $T::Disabled = C '#434343'
    $T::AccentText = C '#000000'
    $C_GOOD = C '#6CCB5F'; $C_WARN = C '#FCE100'; $C_CRIT = C '#FF99A4'
    $T::AccentHover = Mix $accent $T::Window 0.1; $T::AccentPressed = Mix $accent $T::Window 0.2
} else {
    $T::Window = C '#F3F3F3'; $T::Stack = C '#F9F9F9'; $T::Card = C '#FFFFFF'; $T::Stroke = C '#E5E5E5'
    $T::Text = C '#1B1B1B'; $T::Text2 = C '#5D5D5D'; $T::Text3 = C '#8A8A8A'
    $T::Control = C '#FBFBFB'; $T::ControlHover = C '#F6F6F6'; $T::ControlPressed = C '#F0F0F0'; $T::ControlStroke = C '#E0E0E0'
    $T::Field = C '#FFFFFF'; $T::NavHover = C '#EDEDED'; $T::NavSel = C '#EAEAEA'; $T::Disabled = C '#C5C5C5'
    $T::AccentText = C '#FFFFFF'
    $C_GOOD = C '#0F7B0F'; $C_WARN = C '#9D5D00'; $C_CRIT = C '#C42B1C'
    $T::AccentHover = Mix $accent $T::Window 0.1; $T::AccentPressed = Mix $accent $T::Window 0.2
}
$T::Accent = $accent
$C_INK = $T::Text; $C_INK2 = $T::Text2; $C_MUTE = $T::Text3; $C_ACC = $accent; $C_CARD = $T::Card

$iconFont = if ((New-Object System.Drawing.Text.InstalledFontCollection).Families.Name -contains 'Segoe Fluent Icons') { 'Segoe Fluent Icons' } else { 'Segoe MDL2 Assets' }
$F_Title = New-Object System.Drawing.Font("Segoe UI Semibold", 20)
$F_H     = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$F_Body  = New-Object System.Drawing.Font("Segoe UI", 10)
$F_Cap   = New-Object System.Drawing.Font("Segoe UI", 9)
$F_Val   = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
$F_Mono  = New-Object System.Drawing.Font("Consolas", 9.5)
$F_Icon  = New-Object System.Drawing.Font($iconFont, 12)
$F_IconL = New-Object System.Drawing.Font($iconFont, 16)
$T::Body = $F_Body; $T::Icon = $F_Icon

# 圖示字型裡的字元（Segoe Fluent Icons / MDL2 共用編碼）
function G([int]$Code) { [string][char]$Code }
$Icon = @{   # 不叫 $I：PowerShell 變數不分大小寫，會被迴圈的 $i 蓋掉
    Home = G 0xE80F; History = G 0xE81C; Setting = G 0xE713; Info = G 0xE946; Wifi = G 0xE701; Globe = G 0xE774
    Pulse = G 0xE9D9; Clock = G 0xE823; Play = G 0xE768; Stop = G 0xE71A; Bolt = G 0xE945; Search = G 0xE721
    Refresh = G 0xE72C; Photo = G 0xE91B; Send = G 0xE724; Calendar = G 0xE787; Moon = G 0xE708; Sync = G 0xE895
    Undo = G 0xE7A7; Download = G 0xE896; Edit = G 0xE70F; Save = G 0xE74E; Clear = G 0xE894; List = G 0xEA37
}

# ══════════════════════════════════════════════════════════════
# 參數讀寫
# ══════════════════════════════════════════════════════════════

function Read-Param([string]$File, [string]$VarName) {
    foreach ($line in (Get-Content $File -ErrorAction SilentlyContinue)) {
        $p = '^\s*\$' + [regex]::Escape($VarName) + '\s*=\s*(.+)$'
        if ($line -match $p) {
            $v = $Matches[1] -replace '\s*#.*$', ''
            return $v.Trim().Trim('"').Trim("'").Trim()
        }
    }
    return ""
}

function Write-Param([string]$File, [string]$VarName, [string]$Value) {
    $content = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
    $repl    = if ($Value -match '^\d+$') { "`$$VarName = $Value" }
               else                        { "`$$VarName = `"$Value`"" }
    $pattern    = '(?m)^\s*\$' + [regex]::Escape($VarName) + '\s*=\s*[^\r\n]+'
    $newContent = [regex]::Replace($content, $pattern, $repl)
    [System.IO.File]::WriteAllText($File, $newContent, [System.Text.Encoding]::UTF8)
}

# 個人設定優先，沒設過就用 wifi-monitor.ps1 裡的預設值
function Read-Setting([string]$Name) {
    $v = Read-Param $script:SettingsFile $Name
    if ($v -eq '') { $v = Read-Param $script:MonitorScript $Name }
    $v
}
# 只寫進 settings.ps1：有這一行就改，沒有就加在最後
function Write-Setting([string]$Name, [string]$Value) {
    if (-not (Test-Path $script:SettingsFile)) {
        [IO.File]::WriteAllText($script:SettingsFile,
            "# 個人設定（控制面板寫入）。只存在這台電腦，不進 GitHub，自動更新也不會蓋掉。`r`n", (New-Object Text.UTF8Encoding $true))
    }
    if ((Get-Content $script:SettingsFile -Encoding UTF8) -match ('^\s*\$' + [regex]::Escape($Name) + '\s*=')) {
        Write-Param $script:SettingsFile $Name $Value
    } else {
        $line = if ($Value -match '^\d+$') { "`$$Name = $Value" } else { "`$$Name = `"$Value`"" }
        [IO.File]::AppendAllText($script:SettingsFile, "$line`r`n", (New-Object Text.UTF8Encoding $false))
    }
}

$script:SSID   = Read-Setting "SSID"
$script:Repo   = Read-Param $script:UpdateScript "Repo"     # 跟 update.ps1 用同一個來源，不另外寫死
$script:Branch = Read-Param $script:UpdateScript "Branch"

# ══════════════════════════════════════════════════════════════
# 狀態偵測（不靠 CommandLine，提權程序也偵測得到）
# ══════════════════════════════════════════════════════════════

function Test-MonitorRunning {
    # 監控腳本啟動時會持有此 mutex；開得到就代表在跑（無論權限）
    try {
        $m = [System.Threading.Mutex]::OpenExisting("Global\WifiMonitor_guest_tung")
        $m.Dispose(); return $true
    } catch { return $false }
}

function Get-WifiConnected {
    # ponytail: Get-NetConnectionProfile 不需定位權限；netsh 需要
    return (Get-NetConnectionProfile -ErrorAction SilentlyContinue).Name -contains $script:SSID
}

function Get-TaskRow([string]$Name) {
    # 用 COM 查：Get-ScheduledTask + Get-ScheduledTaskInfo 一張要 1.5 秒，而且跑在畫面執行緒上會卡住視窗
    try { $t = $script:TaskSvc.GetFolder("\").GetTask($Name) } catch { return $null }
    $next = $t.NextRunTime
    if ($next.Year -lt 2000) { $next = $null }   # 沒有下次執行時 COM 回 1899-12-30
    return [pscustomobject]@{ Enabled = $t.Enabled; Next = $next }
}

function Test-ProcRunning([string]$Pattern) {
    [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match $Pattern })
}

# ══════════════════════════════════════════════════════════════
# 啟動 / 停止（優先走排程工作，權限由工作排程器處理）
# ══════════════════════════════════════════════════════════════

function Start-MonitorNow {
    try { Start-ScheduledTask -TaskName $MonitorTask -ErrorAction Stop }
    catch {
        Start-Process powershell.exe -WindowStyle Hidden `
            -ArgumentList "-ExecutionPolicy Bypass -NonInteractive -File `"$script:MonitorScript`""
    }
}

function Stop-MonitorNow {
    try { Stop-ScheduledTask -TaskName $MonitorTask -ErrorAction SilentlyContinue } catch {}
    # 非排程啟動、與本面板同權限的實例
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'wifi-monitor\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# 跑一支腳本並等它結束，等的時候視窗照樣能動（不然會顯示「沒有回應」）
function Invoke-ScriptUI([string]$File, [string[]]$Arguments, [int]$MaxSec = 300) {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -NonInteractive -File `"$File`" $($Arguments -join ' ')"
    $p = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $argLine -PassThru
    $t0 = Get-Date
    while (-not $p.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt $MaxSec) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    return $p.HasExited
}

# 背景工作版本：給要回傳資料的（連網檢查、查 GitHub）
function Wait-JobUI($Job, [int]$MaxSec = 20) {
    $t0 = Get-Date
    while ($Job.State -eq 'Running' -and ((Get-Date) - $t0).TotalSeconds -lt $MaxSec) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    $out = if ($Job.State -eq 'Completed') { Receive-Job $Job } else { $null }
    Remove-Job $Job -Force -ErrorAction SilentlyContinue
    return $out
}

# ══════════════════════════════════════════════════════════════
# 打卡記錄：從 data\punch-logs\<年月>.log 拆出每一次打卡
# ══════════════════════════════════════════════════════════════

# 每次打卡是 auto-checkin-v2.ps1 的一段 transcript，開頭是「Start time: yyyyMMddHHmmss」，
# 結果看最後一行「RESULT: OK/FAIL/DRYRUN」；截圖檔名是截圖當下的時間，落在這段開始後 12 分鐘內就算這次的
function Get-PunchRuns([int]$Days = 60) {
    if (-not (Test-Path $script:PunchLogDir)) { return @() }
    $since = (Get-Date).AddDays(-$Days)
    $pngs  = @(Get-ChildItem "$script:PunchLogDir\*.png" -ErrorAction SilentlyContinue | ForEach-Object {
        $t = [datetime]::MinValue
        if ([datetime]::TryParseExact($_.BaseName, 'yyyyMMdd-HHmmss', $null, 'None', [ref]$t)) {
            [pscustomobject]@{ Time = $t; Path = $_.FullName }
        }
    })
    $runs = foreach ($f in (Get-ChildItem "$script:PunchLogDir\*.log" -ErrorAction SilentlyContinue |
                            Where-Object { $_.LastWriteTime -ge $since })) {
        $text  = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        $parts = [regex]::Split($text, '(?m)^Start time: (\d{14})\s*$')
        for ($i = 1; $i + 1 -lt $parts.Count; $i += 2) {
            $start = [datetime]::ParseExact($parts[$i], 'yyyyMMddHHmmss', $null)
            if ($start -lt $since) { continue }
            $body  = $parts[$i + 1]
            if ($body -notmatch '自動打卡系統') { continue }   # 不是打卡腳本留下的 transcript
            $lines = @($body -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\*{5,}|^(Username|RunAs User|Configuration Name|Machine|Host Application|Process ID|PSVersion|PSEdition|PSCompatibleVersions|BuildVersion|CLRVersion|WSManStackVersion|PSRemotingProtocolVersion|SerializationVersion|End time|Windows PowerShell transcript)' })
            $res   = @($lines | Where-Object { $_ -match 'RESULT: ' }) | Select-Object -Last 1
            $kind = 'unknown'; $info = '沒有跑完（中途被關掉或電腦睡著）'
            if ($res -match 'RESULT: OK (.+)$')     { $kind = 'ok';   $info = "系統記錄 $($matches[1].Trim())" }
            elseif ($res -match 'RESULT: DRYRUN')   { $kind = 'test'; $info = '測試模式，沒有送出打卡' }
            elseif ($res -match 'RESULT: FAIL (.+)$') {
                $kind = 'fail'
                $why  = $matches[1].Trim()
                $info = switch -Regex ($why) {
                    'login-expired' { '打卡網頁登入過期，要重新掃 QR Code'; break }
                    'no-wifi'       { '連不上 guest_tung'; break }
                    'no-chrome'     { '找不到 Chrome'; break }
                    'no-result'     { '沒拿到網頁回應'; break }
                    default {
                        $step = @($lines | Where-Object { $_ -match '✗ 步驟' }) | Select-Object -Last 1
                        if ($step) { $step.Trim() } else { $why }
                    }
                }
            }
            $png = $pngs | Where-Object { $_.Time -ge $start -and $_.Time -le $start.AddMinutes(12) } |
                   Sort-Object Time | Select-Object -Last 1
            [pscustomobject]@{ Start = $start; Kind = $kind; Info = $info; Shot = $png.Path; Detail = ($lines -join "`r`n") }
        }
    }
    @($runs | Sort-Object Start -Descending)
}

$KindText  = @{ ok = '成功'; fail = '失敗'; test = '測試'; unknown = '未完成' }
$KindColor = @{ ok = $C_GOOD; fail = $C_CRIT; test = $C_ACC; unknown = $C_WARN }

# ══════════════════════════════════════════════════════════════
# UI 輔助
# ══════════════════════════════════════════════════════════════

function Set-Box($Ctl, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $Ctl.Location = New-Object System.Drawing.Point($X, $Y)
    $Ctl.Size     = New-Object System.Drawing.Size($W, $H)
}

function New-Card([System.Windows.Forms.Control]$Parent, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $p = New-Object Fluent.Card
    Set-Box $p $X $Y $W $H
    $Parent.Controls.Add($p)
    return $p
}

function New-Lbl([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
                 [System.Drawing.Font]$Font, [System.Drawing.Color]$Color) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $Text
    Set-Box $l $X $Y $W $H
    $l.Font      = $Font
    $l.ForeColor = $Color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $Parent.Controls.Add($l)
    return $l
}

function New-Btn([System.Windows.Forms.Control]$Parent, [string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
                 [string]$Glyph = '', [switch]$Accent) {
    $b = New-Object Fluent.FButton
    $b.Text   = $Text
    $b.Glyph  = $Glyph
    $b.Accent = [bool]$Accent
    Set-Box $b $X $Y $W $H
    $Parent.Controls.Add($b)
    return $b
}

# 卡片左上角的圖示＋標題（Fluent 設定卡片的樣子）
function Add-CardHead($Card, [string]$Glyph, [string]$Title) {
    if ($Glyph) {
        $null = New-Lbl $Card $Glyph 18 14 24 24 $F_IconL $C_INK
        $null = New-Lbl $Card $Title 52 14 400 22 $F_H $C_INK
    } else {
        $null = New-Lbl $Card $Title 18 14 400 22 $F_H $C_INK
    }
}

function New-Tile([System.Windows.Forms.Control]$Parent, [string]$Caption, [string]$Glyph, [int]$X) {
    $card = New-Card $Parent $X 72 162 84
    $null = New-Lbl $card $Glyph 14 14 22 22 $F_Icon $C_ACC
    $null = New-Lbl $card $Caption 40 15 116 18 $F_Cap $C_INK2
    return (New-Lbl $card "○ 檢查中..." 14 44 144 26 $F_Val $C_MUTE)
}

function Set-Tile([System.Windows.Forms.Label]$Lbl, [string]$Text, [System.Drawing.Color]$Color) {
    $Lbl.Text = $Text; $Lbl.ForeColor = $Color
}

function New-Rtb([System.Windows.Forms.Control]$Parent, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $r = New-Object System.Windows.Forms.RichTextBox
    Set-Box $r $X $Y $W $H
    $r.ReadOnly    = $true
    $r.BackColor   = $C_CARD
    $r.ForeColor   = $C_INK2
    $r.Font        = $F_Mono
    $r.BorderStyle = "None"
    $r.ScrollBars  = "Vertical"
    $Parent.Controls.Add($r)
    [Fluent.Theme]::DarkScroll($r)
    return $r
}

# 輸入框：圓角底框裡放一個無邊框 TextBox
function New-Field([System.Windows.Forms.Control]$Parent, [int]$X, [int]$Y, [int]$W, [string]$Value) {
    $box = New-Card $Parent $X $Y $W 32
    $box.Radius = 4; $box.Fill = [Fluent.Theme]::Field
    $t = New-Object System.Windows.Forms.TextBox
    Set-Box $t 10 7 ($W - 20) 20
    $t.BorderStyle = "None"
    $t.BackColor   = [Fluent.Theme]::Field
    $t.ForeColor   = $C_INK
    $t.Font        = $F_Body
    $t.Text        = $Value
    $box.Controls.Add($t)
    return $t
}

# 下拉選單（只能選、不能打字）：$Items 是顯示文字，$Values 是實際存的值
function New-Combo([System.Windows.Forms.Control]$Parent, [int]$X, [int]$Y, [int]$W, [string[]]$Items, [object[]]$Values, $Current) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.DropDownStyle = "DropDownList"
    # 不用 Flat：Flat 會畫系統的白框白箭頭；標準樣式配上 DarkCombo 的深色主題，整個選單（含箭頭、展開清單）才會是深色
    if ($dark) { $c.BackColor = [Fluent.Theme]::Field; $c.ForeColor = $C_INK }
    $c.Font          = $F_Body
    $c.MaxDropDownItems = 12
    Set-Box $c $X $Y $W 30
    $Parent.Controls.Add($c)
    [Fluent.Theme]::DarkCombo($c)
    Set-ComboItems $c $Items $Values $Current
    return $c
}
function Set-ComboItems($C, [string[]]$Items, [object[]]$Values, $Current) {
    $C.Items.Clear()
    $C.Items.AddRange($Items)
    $C.Tag = $Values
    $idx = [Array]::IndexOf($Values, $Current)
    $C.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
}
function Get-ComboValue($C) { if ($C.SelectedIndex -ge 0) { $C.Tag[$C.SelectedIndex] } }

# 功能開關卡：左邊圖示、標題、一行說明，右邊滑動開關
function New-ToggleCard([System.Windows.Forms.Control]$Parent, [int]$Y, [string]$Glyph, [string]$Title) {
    $card = New-Card $Parent 24 $Y 690 64
    $null = New-Lbl $card $Glyph 18 20 24 24 $F_IconL $C_INK
    $null = New-Lbl $card $Title 52 11 400 22 $F_H $C_INK
    $lbl  = New-Lbl $card "" 52 33 480 28 $F_Cap $C_INK2
    $sw   = New-Object Fluent.Toggle
    Set-Box $sw 574 16 100 32
    $card.Controls.Add($sw)
    return @{ Card = $card; Lbl = $lbl; Sw = $sw }
}
function Set-Toggle($T, [bool]$On, [string]$Desc) {
    $T.Sw.Checked = $On
    $T.Lbl.Text   = $Desc
}

# ══════════════════════════════════════════════════════════════
# 主視窗：左側選單 + 右邊四頁
# ══════════════════════════════════════════════════════════════

$NavW = 200
$form = New-Object System.Windows.Forms.Form
$form.Text            = "WiFi 控制台"
$form.ClientSize      = New-Object System.Drawing.Size(($NavW + 740), 700)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox     = $false
$form.StartPosition   = "CenterScreen"
$form.BackColor       = [Fluent.Theme]::Window
$form.ForeColor       = $C_INK
$form.Font            = $F_Body

$logo = New-Object Fluent.Logo
Set-Box $logo 18 16 28 28
$form.Controls.Add($logo)
$null   = New-Lbl $form "WiFi 控制台" 52 20 140 24 $F_H $C_INK
$appIco = Join-Path $script:Dir 'app.ico'
if (Test-Path $appIco) { $form.Icon = New-Object System.Drawing.Icon $appIco }
$lblVer = New-Lbl $form "" 22 670 170 20 $F_Cap $C_MUTE

# 右邊內容區：左上圓角、比視窗底色淺一點（Fluent 視窗的樣子）；往右下超出視窗，只看得到左上角的圓
$stack = New-Card $form $NavW 0 760 720
$stack.Radius = 8; $stack.Fill = [Fluent.Theme]::Stack

$pages = @(); $navs = @()
$names  = '首頁', '打卡記錄', '功能開關', '睡眠與電源', '關於與更新'
$glyphs = $Icon.Home, $Icon.History, $Icon.Setting, $Icon.Moon, $Icon.Info
for ($i = 0; $i -lt $names.Count; $i++) {
    $pg = New-Object System.Windows.Forms.Panel
    Set-Box $pg 1 8 739 692
    $pg.BackColor = [Fluent.Theme]::Stack
    $pg.Visible   = $false
    [Fluent.Theme]::Buffer($pg)
    $stack.Controls.Add($pg)
    $null = New-Lbl $pg $names[$i] 22 14 400 44 $F_Title $C_INK
    $pages += $pg

    $nb = New-Object Fluent.NavItem
    $nb.Text  = $names[$i]
    $nb.Glyph = $glyphs[$i]
    $nb.Tag   = $i
    Set-Box $nb 8 (64 + $i * 44) ($NavW - 16) 40
    $nb.Add_Click({ Show-View $this.Tag })
    $form.Controls.Add($nb)
    $navs += $nb
}
$pgHome, $pgLog, $pgFeat, $pgPower, $pgAbout = $pages

function Show-View([int]$Idx) {
    for ($i = 0; $i -lt $pages.Count; $i++) {
        $pages[$i].Visible = ($i -eq $Idx)
        $navs[$i].Selected = ($i -eq $Idx)
    }
    switch ($Idx) {
        1 { Update-PunchList }
        2 { Update-FeatureCards }
        3 { Update-PowerPage }
        4 { Update-AboutPage }
    }
}

# ── 首頁：狀態列 ──────────────────────────────────────────────
$tileWifi    = New-Tile $pgHome "WiFi 連線" $Icon.Wifi  24
$tileNet     = New-Tile $pgHome "網路連通"  $Icon.Globe 200
$tileMonitor = New-Tile $pgHome "監控程序"  $Icon.Pulse 376
$tilePunch   = New-Tile $pgHome "下次打卡"  $Icon.Clock 552
Set-Tile $tileNet "○ 未檢查" $C_MUTE

# ── 首頁：操作 ────────────────────────────────────────────────
$cardOp = New-Card $pgHome 24 168 690 124
Add-CardHead $cardOp '' "操作"
$btnStart = New-Btn $cardOp "啟動監控" 18  46 156 32 $Icon.Play
$btnStop  = New-Btn $cardOp "停止監控" 182 46 156 32 $Icon.Stop
$btnLogin = New-Btn $cardOp "立即登入" 346 46 156 32 $Icon.Bolt
$btnCheck = New-Btn $cardOp "立即檢查" 510 46 162 32 $Icon.Search
$btnPunch = New-Btn $cardOp "立即打卡" 18  84 320 32 $Icon.Clock -Accent
$btnPunchWeb = New-Btn $cardOp "打開打卡網頁（登入用）" 346 84 326 32 $Icon.Globe

# ── 首頁：上次打卡 ────────────────────────────────────────────
$cardLast = New-Card $pgHome 24 304 690 72
$null = New-Lbl $cardLast $Icon.History 18 24 24 24 $F_IconL $C_INK
$null = New-Lbl $cardLast "上次打卡" 52 12 300 22 $F_H $C_INK
$lblLast = New-Lbl $cardLast "沒有紀錄" 52 36 480 26 $F_Body $C_MUTE
$btnLastShot = New-Btn $cardLast "看截圖" 554 20 120 32 $Icon.Photo
$btnLastShot.Enabled = $false

# ── 首頁：日誌 ────────────────────────────────────────────────
$cardLog = New-Card $pgHome 24 388 690 292
Add-CardHead $cardLog '' "監控日誌（每 3 秒更新，最後 100 行）"
$btnRefresh = New-Btn $cardLog "重新整理" 446 10 110 30 $Icon.Refresh
$btnClear   = New-Btn $cardLog "清除畫面" 564 10 110 30 $Icon.Clear
$rtbLog = New-Rtb $cardLog 18 50 658 230
$rtbLog.WordWrap = $false

# ── 打卡記錄頁 ────────────────────────────────────────────────
$cardRuns = New-Card $pgLog 24 72 690 360
Add-CardHead $cardRuns '' "最近 60 天的打卡（點一筆看過程）"
$btnRunsRefresh = New-Btn $cardRuns "重新整理" 564 10 110 30 $Icon.Refresh
$lvRuns = New-Object System.Windows.Forms.ListView
Set-Box $lvRuns 12 50 666 298
$lvRuns.View          = "Details"
$lvRuns.FullRowSelect = $true
$lvRuns.MultiSelect   = $false
$lvRuns.HeaderStyle   = "Nonclickable"
$lvRuns.BorderStyle   = "None"
$lvRuns.BackColor     = $C_CARD
$lvRuns.ForeColor     = $C_INK2
$lvRuns.Font          = $F_Body
$lvRuns.SmallImageList = New-Object System.Windows.Forms.ImageList
$lvRuns.SmallImageList.ImageSize = New-Object System.Drawing.Size(1, 30)   # 只是用來把列高撐到 30
[void]$lvRuns.Columns.Add("時間", 140)
[void]$lvRuns.Columns.Add("結果", 70)
[void]$lvRuns.Columns.Add("內容", 370)
[void]$lvRuns.Columns.Add("截圖", 60)
# 整張表自己畫：系統畫法是白底藍色選取，跟這個介面不搭
$lvRuns.OwnerDraw = $true
$lvRuns.Add_DrawColumnHeader({
    $_.Graphics.FillRectangle((New-Object System.Drawing.SolidBrush $C_CARD), $_.Bounds)
    $_.Graphics.DrawLine((New-Object System.Drawing.Pen ([Fluent.Theme]::Stroke)), $_.Bounds.Left, $_.Bounds.Bottom - 1, $_.Bounds.Right, $_.Bounds.Bottom - 1)
    $r = $_.Bounds; $r.X += 8
    [System.Windows.Forms.TextRenderer]::DrawText($_.Graphics, $_.Header.Text, $F_Cap, $r, $C_MUTE,
        [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left')
})
$lvRuns.Add_DrawItem({ $_.DrawDefault = $false })
$lvRuns.Add_DrawSubItem({
    $bg = if ($_.Item.Selected) { [Fluent.Theme]::ControlHover } else { $C_CARD }
    $_.Graphics.FillRectangle((New-Object System.Drawing.SolidBrush $bg), $_.Bounds)
    if ($_.Item.Selected -and $_.ColumnIndex -eq 0) {
        $_.Graphics.FillRectangle((New-Object System.Drawing.SolidBrush $C_ACC), $_.Bounds.Left, $_.Bounds.Top + 7, 3, $_.Bounds.Height - 14)
    }
    $fg = if ($_.ColumnIndex -eq 1) { $_.SubItem.ForeColor } elseif ($_.ColumnIndex -eq 0) { $C_INK } else { $C_INK2 }
    $r = $_.Bounds; $r.X += 8; $r.Width -= 8
    [System.Windows.Forms.TextRenderer]::DrawText($_.Graphics, $_.SubItem.Text, $F_Body, $r, $fg,
        [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis')
})
[Fluent.Theme]::Buffer($lvRuns)
$cardRuns.Controls.Add($lvRuns)
[Fluent.Theme]::DarkScroll($lvRuns)

$cardRunDetail = New-Card $pgLog 24 444 690 236
Add-CardHead $cardRunDetail '' "這次的過程"
$btnRunShot = New-Btn $cardRunDetail "看截圖" 564 10 110 30 $Icon.Photo
$btnRunShot.Enabled = $false
$rtbRun = New-Rtb $cardRunDetail 18 50 658 174

# ── 功能開關頁 ────────────────────────────────────────────────
function New-ParamRow([System.Windows.Forms.Control]$Parent, [int]$Y,
                      [string]$Label, [string]$Value, [string]$Hint) {
    $null = New-Lbl $Parent $Label 52 ($Y + 7) 176 20 $F_Body $C_INK2
    $t = New-Field $Parent 232 $Y 160 $Value
    $null = New-Lbl $Parent $Hint 406 ($Y + 8) 270 20 $F_Cap $C_MUTE
    return $t
}

$grpM = New-Card $pgFeat 24 72 690 252
Add-CardHead $grpM $Icon.Wifi "WiFi 監控"
$lblMonState = New-Lbl $grpM "" 52 36 400 20 $F_Cap $C_MUTE
$btnSave     = New-Btn $grpM "儲存參數" 554 16 120 32 $Icon.Save -Accent
$lblSaveMsg  = New-Lbl $grpM "" 330 52 344 18 $F_Cap $C_GOOD
$lblSaveMsg.TextAlign = "TopRight"
# WiFi 名稱只給選、不給打：打錯一個字監控就連不上了。目前只有 guest_tung 打得了卡，以後有別的再加進清單
$SsidChoices = @('guest_tung')
$curSsid = Read-Setting "SSID"
if ($curSsid -and $SsidChoices -notcontains $curSsid) { $SsidChoices += $curSsid }   # 以前手動改過的值也要留著，不然一存就被蓋掉
$null = New-Lbl $grpM "SSID（WiFi 名稱）" 52 79 176 20 $F_Body $C_INK2
$cbSSID = New-Combo $grpM 232 73 160 $SsidChoices $SsidChoices $curSsid
$null = New-Lbl $grpM "目標 WiFi 網路（只能從清單選）" 406 80 270 20 $F_Cap $C_MUTE
$txPollInterval = New-ParamRow $grpM 108 "PollInterval（秒）" (Read-Setting "PollInterval") "保底輪詢間隔，預設 180"
$txEventSleep   = New-ParamRow $grpM 144 "EventSleep（秒）"   (Read-Setting "EventSleep")   "事件掃描間隔，預設 3"
$txDebounceSec  = New-ParamRow $grpM 180 "DebounceSec（秒）"  (Read-Setting "DebounceSec")  "重複觸發冷卻，預設 15"
$txMaxLogKB     = New-ParamRow $grpM 216 "MaxLogKB（KB）"     (Read-Setting "MaxLogKB")     "日誌大小上限，預設 500"
# Portal 帳密不在這裡改：wifi-accounts.ps1 是好幾組輪流試的清單，要改直接編輯那個檔

$tgTele  = New-ToggleCard $pgFeat 336 $Icon.Send     "Telegram 指令"
$btnTeleSetup = New-Btn $tgTele.Card "設定 Telegram" 534 16 140 32 $Icon.Edit -Accent
$tgBook  = New-ToggleCard $pgFeat 408 $Icon.Calendar "依班表自動打卡"
$btnShifts = New-Btn $tgBook.Card "編輯班表" 448 16 110 32 $Icon.Edit
$btnShiftHelp = New-Btn $tgBook.Card "" 408 16 32 32 (G 0xE897)   # 「?」：教怎麼讓 Claude Code 從 OF00 截圖填班表
$tgBook.Lbl.Width = 350   # 讓出右邊按鈕的位置，不然說明文字會蓋在按鈕上

function Open-ShiftFile {
    $csv = Join-Path $script:Dir 'data\shifts.csv'
    if (-not (Test-Path $csv)) {
        New-Item -ItemType Directory -Force (Split-Path $csv) | Out-Null
        [IO.File]::WriteAllText($csv, "# 排班表：一行一天，格式「日期,班別代碼」，例如 2026-12-01,9076`r`n", (New-Object Text.UTF8Encoding $true))
    }
    Start-Process notepad.exe -ArgumentList "`"$csv`""
}

# 班表教學：截 OF00 班表 → 貼給 Claude Code，請它填 data\shifts.csv。提示詞可以一鍵複製
function Show-ShiftHelp {
    $csv = Join-Path $script:Dir 'data\shifts.csv'
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "怎麼填班表"
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 510)
    $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = "CenterParent"
    $dlg.BackColor = [Fluent.Theme]::Stack; $dlg.ForeColor = $C_INK; $dlg.Font = $F_Body
    if ($form.Icon) { $dlg.Icon = $form.Icon }
    $null = New-Lbl $dlg "讓 Claude Code 幫你填班表" 24 18 500 30 $F_Val $C_INK
    $steps = @(
        "1. 打開醫院系統的 OF00 班表，切到要填的月份。",
        "2. 按 Win + Shift + S 截圖，把整個月框進去；日期和班別代碼都要清楚入鏡。",
        "3. 在這個資料夾開 Claude Code，把截圖貼上（Ctrl + V），再貼上下面這段話送出。",
        "4. Claude 寫完會列出填了哪些日期，對照截圖檢查；也可以按「開啟班表檔」自己看。"
    )
    for ($k = 0; $k -lt $steps.Count; $k++) { $null = New-Lbl $dlg $steps[$k] 24 (60 + $k * 42) 512 40 $F_Body $C_INK2 }
    $null = New-Lbl $dlg "要貼給 Claude Code 的話：" 24 232 400 20 $F_Cap $C_MUTE
    $prompt = "附圖是我的 OF00 班表截圖。請把每一天的日期和班別代碼寫進 $csv ，" +
              "格式一行一天「yyyy-MM-dd,代碼」，例如 2026-12-01,9076。" +
              "檔案裡已經有的日期就用截圖的覆蓋，其他行（包含 # 開頭的說明）不要動，檔案要存成 UTF-8 with BOM。" +
              "寫完列出你填了哪些日期和代碼讓我核對，看不清楚的格子要明講，不要用猜的。"
    $box = New-Card $dlg 24 256 512 138
    $box.Fill = [Fluent.Theme]::Card
    $tb = New-Object System.Windows.Forms.TextBox
    Set-Box $tb 12 10 488 118
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.BorderStyle = "None"; $tb.WordWrap = $true
    $tb.BackColor = $C_CARD; $tb.ForeColor = $C_INK; $tb.Font = $F_Body
    $tb.Text = $prompt
    $box.Controls.Add($tb)
    $lblCopied = New-Lbl $dlg "" 24 462 204 20 $F_Cap $C_GOOD
    $bCopy = New-Btn $dlg "複製這段話" 236 454 140 34 (G 0xE8C8) -Accent
    $bCopy.Add_Click({ [System.Windows.Forms.Clipboard]::SetText($prompt); $lblCopied.Text = "✓ 已複製，貼到 Claude Code 就好" }.GetNewClosure())
    $bOpen = New-Btn $dlg "開啟班表檔" 384 454 152 34 $Icon.Edit
    $bOpen.Add_Click({ Open-ShiftFile })
    $null = New-Lbl $dlg "代碼意義：9076 全天班、908 值班隔天中午下班、906 值班隔天早上下班、100/102 不用打卡。" 24 404 512 36 $F_Cap $C_MUTE
    $dlg.ActiveControl = $bCopy   # 不然一打開焦點在提示詞框，整段會被反白
    [Fluent.Theme]::StyleWindow($dlg)
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}
$btnShiftHelp.Add_Click({ Show-ShiftHelp })
$tgUpd   = New-ToggleCard $pgFeat 480 $Icon.Sync     "有新版時自動更新"

function Update-FeatureCards {
    $mRun = Test-MonitorRunning
    $lblMonState.Text      = if ($mRun) { "● 執行中（啟動／停止在首頁）" } else { "○ 未啟動（啟動／停止在首頁）" }
    $lblMonState.ForeColor = if ($mRun) { $C_GOOD } else { $C_MUTE }

    $hasBot = Test-Path (Join-Path $script:Dir 'bot-config.ps1')
    $tgTele.Sw.Visible    = $hasBot
    $btnTeleSetup.Visible = -not $hasBot
    if (-not $hasBot) {
        $tgTele.Lbl.Text = "還沒設定 Telegram，設定好才能用 /punch 等指令和收打卡通知。"
    } else {
        $on  = [bool](Get-TaskRow 'TelegramCommands')
        $run = $on -and (Test-ProcRunning 'telegram-commands\.ps1')
        Set-Toggle $tgTele $on $(if (-not $on) { "傳指令給 bot 不會有反應，預約的卡照樣會打。" }
                                 elseif ($run) { "正在背景接收 /punch、/status 等指令。" }
                                 else          { "現在沒在跑，登入後或一小時內會自動啟動。" })
    }
    $book = [bool](Get-TaskRow 'NightlyBook')
    Set-Toggle $tgBook $book $(if ($book) { "每晚 21:00 照 data\shifts.csv 預約隔天的卡。" } else { "要打卡就傳 /punch，或用 /in、/off 預約。" })
    $auto = (Read-Setting 'AutoUpdate') -eq '1'
    Set-Toggle $tgUpd $auto $(if ($auto) { "每天 09:00 有新版就直接更新，更新完 Telegram 通知。" } else { "每天 09:00 有新版只傳 Telegram 通知，回 /update 才更新（預設）。" })
}

# ── 睡眠與電源頁 ──────────────────────────────────────────────
$script:Loading = $false   # 程式自己在填選單時不要觸發「使用者改了選項」

# 夜間睡眠：開關＋幾點睡、幾點醒。時間存 settings.ps1 的 $SleepAt / $WakeAt（sleep.ps1 讀），開著的話重新註冊排程才會用新時間
$tgSleep = New-ToggleCard $pgPower 72 $Icon.Moon "夜間睡眠"
$tgSleep.Card.Height = 120
$tgSleep.Lbl.Height = 42   # 說明多一句睡眠種類，要兩行
function Get-HalfHours([string]$From, [int]$Count) {
    0..($Count - 1) | ForEach-Object { ([datetime]"2000-01-01 $From").AddMinutes(30 * $_).ToString('HH:mm') }
}
$SleepOpts = @(Get-HalfHours '21:00' 13)   # 21:00–03:00
$WakeOpts  = @(Get-HalfHours '05:00' 11)   # 05:00–10:00
function Get-SleepSetting([string]$Name, [string]$Default) {
    $v = Read-Param $script:SettingsFile $Name
    if ($v -match '^([01]\d|2[0-3]):[0-5]\d$') { $v } else { $Default }
}
$null = New-Lbl $tgSleep.Card "幾點睡" 52 83 54 20 $F_Body $C_INK2
$cbSleepAt = New-Combo $tgSleep.Card 110 78 96 $SleepOpts $SleepOpts '01:00'
$null = New-Lbl $tgSleep.Card "幾點醒" 226 83 54 20 $F_Body $C_INK2
$cbWakeAt  = New-Combo $tgSleep.Card 284 78 96 $WakeOpts $WakeOpts '07:00'
$lblSleepMsg = New-Lbl $tgSleep.Card "" 396 83 280 20 $F_Cap $C_GOOD

# 這台電腦是不是「新式待命」（Modern Standby）：新式的睡著時排程通常照跑，打卡多半不用叫醒（用電池時有些會斷網，不保證）；
# 舊式的是真的睡死，要靠喚醒計時器叫醒，常常叫不醒或醒了又睡回去，打不了卡。
# 讀 GetPwrCapabilities 回傳結構第 20 個位元組（AoAc 欄位）；powercfg /a 的文字會照系統語言翻譯，不好判斷
Add-Type -Namespace Win32 -Name PowrProf -MemberDefinition '[DllImport("powrprof.dll")] public static extern bool GetPwrCapabilities(byte[] caps);'
$caps = New-Object byte[] 128   # 結構實際 72 bytes，留大一點
$script:ModernStandby = [Win32.PowrProf]::GetPwrCapabilities($caps) -and $caps[20] -ne 0

# Windows 電源設定：刻意不在這裡改，只顯示插電時目前的值和建議，按鈕直接打開 Windows 的設定頁讓本人自己調。
# 有人回報關螢幕、睡眠、休眠時會打不了卡，所以建議插電時全部「從不」
$PowerRows = @(
    @{ Name = '關閉螢幕'; Sub = 'SUB_VIDEO'; Key = 'VIDEOIDLE' },
    @{ Name = '睡眠';     Sub = 'SUB_SLEEP'; Key = 'STANDBYIDLE' },
    @{ Name = '休眠';     Sub = 'SUB_SLEEP'; Key = 'HIBERNATEIDLE' }
)
function Format-Minutes([int]$M) {
    if ($M -eq 0) { '從不' } elseif ($M -ge 60 -and $M % 60 -eq 0) { "$($M / 60) 小時" } else { "$M 分鐘" }
}
# 讀目前設定：powercfg /q 的輸出會照系統語言翻譯，但最後兩個 0x 數值固定是「插電、用電池」，單位是秒
function Get-PowerMinutes([string]$Sub, [string]$Key) {
    $hex = @(powercfg /q SCHEME_CURRENT $Sub $Key | Select-String '0x[0-9a-fA-F]{8}' | ForEach-Object { $_.Matches[0].Value })
    if ($hex.Count -lt 2) { return @(-1, -1) }
    @($hex[-2], $hex[-1]) | ForEach-Object { [int][Math]::Round([Convert]::ToInt64($_, 16) / 60) }
}
$cardPw = New-Card $pgPower 24 204 690 218
Add-CardHead $cardPw (G 0xE7E8) "Windows 電源設定"
$btnPwOpen = New-Btn $cardPw "開啟電源設定" 520 16 154 32 (G 0xE8A7) -Accent
$null = New-Lbl $cardPw "建議：插電時「關閉螢幕」和「睡眠」都設成「從不」，也不要開休眠。" 52 40 460 20 $F_Body $C_INK
$null = New-Lbl $cardPw ("有人回報螢幕關掉、睡著或休眠時會打不了卡，插電時讓電腦一直醒著、螢幕一直亮最穩。`n" +
                         "按右上角的按鈕會打開 Windows 的設定頁，自己改；改完回到這裡，下面會更新成新的值。") 52 64 620 40 $F_Cap $C_INK2
$null = New-Lbl $cardPw "目前插電時：" 52 112 200 20 $F_Cap $C_MUTE
foreach ($r in 0..2) { $PowerRows[$r].Lbl = New-Lbl $cardPw "" 52 (134 + $r * 26) 620 22 $F_Body $C_INK2 }
$btnPwOpen.Add_Click({ Start-Process 'ms-settings:powersleep' })
# 從 Windows 設定頁切回來時重讀，讓使用者馬上看到改好的值
$form.Add_Activated({ if ($pgPower.Visible) { Update-PowerPage } })

function Update-PowerPage {
    $script:Loading = $true
    try {
        $sleep = [bool](Get-TaskRow 'NightSleep')
        $sAt = Get-SleepSetting 'SleepAt' '01:00'; $wAt = Get-SleepSetting 'WakeAt' '07:00'
        $kind = if ($script:ModernStandby) { "這台是新式待命，睡著通常不影響打卡。" } else { "⚠ 這台是舊式睡眠，睡著後常叫不醒、打不了卡，不建議開。" }
        Set-Toggle $tgSleep $sleep $(if ($sleep) { "$sAt 閒置 10 分鐘就睡，$wAt 叫醒；值班夜和傳過 /sleepoff 的晚上不睡。$kind" } else { "電腦不會自己睡。$kind" })
        $so = @($SleepOpts + $sAt | Select-Object -Unique); $wo = @($WakeOpts + $wAt | Select-Object -Unique)
        Set-ComboItems $cbSleepAt $so $so $sAt
        Set-ComboItems $cbWakeAt  $wo $wo $wAt
        foreach ($row in $PowerRows) {
            $ac = (Get-PowerMinutes $row.Sub $row.Key)[0]
            if ($ac -lt 0)     { $row.Lbl.Text = "$($row.Name)：讀不到";                          $row.Lbl.ForeColor = $C_MUTE }
            elseif ($ac -eq 0) { $row.Lbl.Text = "✓ $($row.Name)：從不";                          $row.Lbl.ForeColor = $C_GOOD }
            else               { $row.Lbl.Text = "⚠ $($row.Name)：$(Format-Minutes $ac)（建議改成從不）"; $row.Lbl.ForeColor = $C_WARN }
        }
    } finally { $script:Loading = $false }
}

# 改睡覺／起床時間：至少要隔 3 小時（離起床 2 小時內就不睡了，太短等於沒睡）
$onSleepTime = {
    if ($script:Loading) { return }
    $s = Get-ComboValue $cbSleepAt; $w = Get-ComboValue $cbWakeAt
    $span = ((([TimeSpan]$w) - ([TimeSpan]$s)).TotalMinutes + 1440) % 1440
    if ($span -lt 180) {
        $lblSleepMsg.Text = "✕ 沒存：睡和醒至少要隔 3 小時"; $lblSleepMsg.ForeColor = $C_CRIT
        return
    }
    try {
        Write-Setting 'SleepAt' $s
        Write-Setting 'WakeAt'  $w
        if (Get-TaskRow 'NightSleep') { [void](Invoke-ScriptUI (Join-Path $script:Dir 'sleep.ps1') @('-Install') 30) }   # 用新時間重新註冊
        $lblSleepMsg.Text = "✓ 已改成 $s 睡、$w 醒"; $lblSleepMsg.ForeColor = $C_GOOD
    } catch {
        $lblSleepMsg.Text = "✕ 存不進去：$($_.Exception.Message)"; $lblSleepMsg.ForeColor = $C_CRIT
    }
    Update-PowerPage
}
$cbSleepAt.Add_SelectedIndexChanged($onSleepTime)
$cbWakeAt.Add_SelectedIndexChanged($onSleepTime)

# ── 關於與更新頁 ──────────────────────────────────────────────
$cardVer = New-Card $pgAbout 24 72 690 124
Add-CardHead $cardVer $Icon.Info "目前版本"
$lblCurVer = New-Lbl $cardVer "" 52 38 620 24 $F_Body $C_INK2
$btnChkUpd = New-Btn $cardVer "檢查更新"   52  76 124 32 $Icon.Search
$btnApply  = New-Btn $cardVer "立即更新"   184 76 124 32 $Icon.Download -Accent
$btnRollbk = New-Btn $cardVer "退回上一版" 316 76 132 32 $Icon.Undo
$lblUpdMsg = New-Lbl $cardVer "" 460 84 214 20 $F_Cap $C_MUTE
$btnApply.Enabled = $false

$cardNew = New-Card $pgAbout 24 208 690 220
Add-CardHead $cardNew '' "GitHub 上的新版內容"
$rtbNew = New-Rtb $cardNew 18 50 658 158
$rtbNew.Text = "按「檢查更新」看看有沒有新版。"

$cardUpdLog = New-Card $pgAbout 24 440 690 240
Add-CardHead $cardUpdLog '' "更新紀錄（data\update.log）"
$rtbUpdLog = New-Rtb $cardUpdLog 18 50 658 178

function Get-VersionLine {
    $v = @(Get-Content $script:VersionFile -Encoding UTF8 -ErrorAction SilentlyContinue)
    if (-not $v) { return @{ Sha = ''; Label = '未知（還沒透過自動更新裝過）' } }
    $sha = "$($v[0])".Trim()
    $label = if ($v.Count -ge 2 -and $v[1]) { "$($v[1])（$($sha.Substring(0, [Math]::Min(7, $sha.Length))))" } else { $sha.Substring(0, [Math]::Min(7, $sha.Length)) }
    @{ Sha = $sha; Label = $label }
}

function Update-AboutPage {
    $ver = Get-VersionLine
    $lblCurVer.Text = $ver.Label
    $lblVer.Text    = "版本 $(if ($ver.Sha) { $ver.Sha.Substring(0, [Math]::Min(7, $ver.Sha.Length)) } else { '?' })"
    $btnRollbk.Enabled = (Test-Path (Join-Path $script:Dir 'data\backup')) -and (Test-Path (Join-Path $script:Dir 'data\backup-version.txt'))
    $log = Join-Path $script:Dir 'data\update.log'
    $rtbUpdLog.Text = if (Test-Path $log) { (Get-Content $log -Encoding UTF8 -Tail 30) -join "`r`n" } else { "還沒有更新紀錄。" }
    $rtbUpdLog.SelectionStart = $rtbUpdLog.TextLength; $rtbUpdLog.ScrollToCaret()
}

# ══════════════════════════════════════════════════════════════
# 狀態更新
# ══════════════════════════════════════════════════════════════

function Update-Status {
    if (Get-WifiConnected) { Set-Tile $tileWifi "● $($script:SSID)" $C_GOOD }
    else                   { Set-Tile $tileWifi "● 未連線" $C_CRIT }

    $mRun = Test-MonitorRunning
    if ($mRun) { Set-Tile $tileMonitor "● 執行中" $C_GOOD }
    else       { Set-Tile $tileMonitor "○ 未啟動" $C_MUTE }
    $btnStart.Enabled = -not $mRun
    $btnStop.Enabled  = $mRun

    $next = $PunchTasks | ForEach-Object { Get-TaskRow $_ } |
        Where-Object { $_ -and $_.Enabled -and $_.Next } | ForEach-Object Next | Sort-Object | Select-Object -First 1
    if ($next) { Set-Tile $tilePunch "● $($next.ToString('MM/dd HH:mm'))" $C_GOOD }
    else       { Set-Tile $tilePunch "○ 沒有預約" $C_MUTE }
}

$script:LogStamp = [datetime]::MinValue
function Update-LogView([bool]$Force = $false) {
    if (-not (Test-Path $script:LogFile)) { return }
    $stamp = (Get-Item $script:LogFile).LastWriteTime
    if (-not $Force -and $stamp -eq $script:LogStamp) { return }
    $script:LogStamp = $stamp

    $lines = Get-Content $script:LogFile -Tail 100 -ErrorAction SilentlyContinue
    if ($null -eq $lines) { return }

    $rtbLog.SuspendLayout()
    $rtbLog.Clear()
    foreach ($line in $lines) {
        $color = $C_INK2
        if     ($line -match "登入成功|網路已恢復|\[OK\]")              { $color = $C_GOOD }
        elseif ($line -match "失敗|無法上網|\[FAIL\]|Error|connection") { $color = $C_CRIT }
        elseif ($line -match "重連觸發|定時保底|重新連接|送出")           { $color = $C_WARN }
        elseif ($line -match "===|監控啟動|WiFi 監控")                   { $color = $C_ACC  }
        $rtbLog.SelectionStart  = $rtbLog.TextLength
        $rtbLog.SelectionLength = 0
        $rtbLog.SelectionColor  = $color
        $rtbLog.AppendText("$line`n")
    }
    $rtbLog.ResumeLayout()
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.ScrollToCaret()
}

# 打卡記錄只在記錄檔有變時重讀（一個月的 log 有幾百 KB，每 3 秒重拆太浪費）
$script:Runs = @()
$script:RunsStamp = ''
function Update-Runs([bool]$Force = $false) {
    $files = @(Get-ChildItem "$script:PunchLogDir\*" -ErrorAction SilentlyContinue)
    $stamp = "$($files.Count) $(($files | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime.Ticks)"
    if (-not $Force -and $stamp -eq $script:RunsStamp) { return $false }
    $script:RunsStamp = $stamp
    $script:Runs = Get-PunchRuns
    $true
}

function Update-LastPunch {
    $last = $script:Runs | Where-Object { $_.Kind -ne 'test' } | Select-Object -First 1
    if (-not $last) { $lblLast.Text = "沒有紀錄"; $lblLast.ForeColor = $C_MUTE; $btnLastShot.Enabled = $false; return }
    $lblLast.Text      = "$($last.Start.ToString('MM/dd HH:mm'))　$($KindText[$last.Kind])　$($last.Info)"
    $lblLast.ForeColor = $KindColor[$last.Kind]
    $btnLastShot.Tag     = $last.Shot
    $btnLastShot.Enabled = [bool]$last.Shot
}

function Update-PunchList([bool]$Force = $false) {
    if (-not (Update-Runs $Force) -and $lvRuns.Items.Count) { return }
    $lvRuns.BeginUpdate()
    $lvRuns.Items.Clear()
    foreach ($r in $script:Runs) {
        $it = New-Object System.Windows.Forms.ListViewItem($r.Start.ToString('yyyy-MM-dd HH:mm'))
        $it.UseItemStyleForSubItems = $false
        $sub = $it.SubItems.Add($KindText[$r.Kind]); $sub.ForeColor = $KindColor[$r.Kind]
        [void]$it.SubItems.Add($r.Info)
        [void]$it.SubItems.Add($(if ($r.Shot) { '有' } else { '' }))
        $it.Tag = $r
        [void]$lvRuns.Items.Add($it)
    }
    $lvRuns.EndUpdate()
    $lvRuns.Columns[3].Width = -2   # 最後一欄撐滿剩下的寬度，不然標題列右邊會露出一塊系統白底
    $rtbRun.Text = if ($script:Runs) { "點上面任一筆看這次的過程。" } else { "還沒有打卡紀錄。" }
    $btnRunShot.Enabled = $false
    Update-LastPunch
}

# ══════════════════════════════════════════════════════════════
# 事件
# ══════════════════════════════════════════════════════════════

$btnStart.Add_Click({ Start-MonitorNow; Start-Sleep -Milliseconds 600; Update-Status })
$btnStop.Add_Click({
    Stop-MonitorNow; Start-Sleep -Milliseconds 600; Update-Status
    if (Test-MonitorRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            "監控程序以較高權限執行，無法從這裡停止。`n請以系統管理員身分開啟本面板再試。", "無法停止") | Out-Null
    }
})

$btnLogin.Add_Click({
    Start-Process powershell.exe -WindowStyle Normal `
        -ArgumentList "-ExecutionPolicy Bypass -File `"$script:LoginScript`""
})

$btnPunch.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "確定要立即打卡？（會實際送出打卡）", "確認打卡",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        Start-Process powershell.exe -WindowStyle Normal `
            -ArgumentList "-ExecutionPolicy Bypass -File `"$script:CheckinScript`""
    }
})

# 用自動打卡同一個 Chrome 設定檔開打卡網頁：登入過期（要重新掃 QR Code）時在這裡登入，之後自動打卡就認得
$btnPunchWeb.Add_Click({
    # 打卡進行中別開：同一個設定檔的視窗會併進正在被自動操作的 Chrome，打卡結束時也會被一起關掉
    if (Test-ProcRunning 'auto-checkin-v2\.ps1(?!.*-Open)') {   # 排除自己按出來的 -Open
        [System.Windows.Forms.MessageBox]::Show("正在打卡，等打卡結束（約 1–2 分鐘）再開。", "打開打卡網頁") | Out-Null
        return
    }
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script:CheckinScript`" -Open"
    # 不用 Start-Process -Wait：它會連 Chrome（子程序）一起等。-Open 開完 Chrome 就結束，幾秒內就有結果
    if ($p.WaitForExit(15000) -and $p.ExitCode -eq 1) {
        [System.Windows.Forms.MessageBox]::Show("找不到 Chrome，請先安裝 Google Chrome。", "打開打卡網頁") | Out-Null
        return
    }
    # 自動打卡開始時會強制關掉這個設定檔的 Chrome，沒正常關掉的話剛登入的狀態可能沒存到
    [System.Windows.Forms.MessageBox]::Show("在打開的視窗用手機掃 QR Code 登入。`n`n登入完請把那個視窗關掉，登入狀態才會存好。", "打開打卡網頁") | Out-Null
})

$btnCheck.Add_Click({
    $btnCheck.Enabled = $false; $btnCheck.Text = "檢查中..."
    Set-Tile $tileNet "○ 檢查中..." $C_MUTE
    $job = Start-Job -ScriptBlock {
        foreach ($c in @(
            @{ Uri = "http://connectivitycheck.gstatic.com/generate_204"; Code = 204; Body = $null },
            @{ Uri = "http://www.msftconnecttest.com/connecttest.txt";    Code = 200; Body = "Microsoft Connect Test" }
        )) {
            try {
                $r = Invoke-WebRequest -Uri $c.Uri -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                if ($r.StatusCode -eq $c.Code -and (-not $c.Body -or $r.Content -match $c.Body)) { return $true }
            } catch {}
        }
        return $false
    }
    $online = Wait-JobUI $job 12
    if ($online) { Set-Tile $tileNet "● 正常" $C_GOOD }
    else         { Set-Tile $tileNet "● 無法連外" $C_CRIT }
    $btnCheck.Enabled = $true; $btnCheck.Text = "立即檢查"
})

$btnRefresh.Add_Click({ Update-LogView $true })
$btnClear.Add_Click({ $rtbLog.Clear() })
$btnLastShot.Add_Click({ if ($this.Tag -and (Test-Path $this.Tag)) { Start-Process $this.Tag } })

$btnRunsRefresh.Add_Click({ Update-PunchList $true })
$lvRuns.Add_SelectedIndexChanged({
    if ($lvRuns.SelectedItems.Count -eq 0) { return }
    $r = $lvRuns.SelectedItems[0].Tag
    $rtbRun.Text = $r.Detail
    $btnRunShot.Tag     = $r.Shot
    $btnRunShot.Enabled = [bool]$r.Shot
})
$btnRunShot.Add_Click({ if ($this.Tag -and (Test-Path $this.Tag)) { Start-Process $this.Tag } })

$btnSave.Add_Click({
    # 寫壞了監控腳本會整個跑不起來，先擋掉空白和非數字
    $bad = @(@($txPollInterval, $txEventSleep, $txDebounceSec, $txMaxLogKB) | Where-Object { $_.Text -notmatch '^[1-9]\d*$' })
    $ssid = Get-ComboValue $cbSSID
    if (-not $ssid -or $bad) {
        $lblSaveMsg.Text      = "✕ 沒有儲存：秒數和 KB 要填正整數"
        $lblSaveMsg.ForeColor = $C_CRIT
        return
    }
    try {
        Write-Setting "SSID"         $ssid
        Write-Setting "PollInterval" $txPollInterval.Text
        Write-Setting "EventSleep"   $txEventSleep.Text
        Write-Setting "DebounceSec"  $txDebounceSec.Text
        Write-Setting "MaxLogKB"     $txMaxLogKB.Text
        $script:SSID = $ssid
        $lblSaveMsg.Text      = "✓ 已儲存 $(Get-Date -Format 'HH:mm:ss')，監控幾秒內會自動套用"
        $lblSaveMsg.ForeColor = $C_GOOD
    } catch {
        $lblSaveMsg.Text      = "✕ 儲存失敗：$($_.Exception.Message)"
        $lblSaveMsg.ForeColor = $C_CRIT
    }
})

# 開關都只是註冊／刪除自己帳號的排程，一般權限就夠
$btnTeleSetup.Add_Click({
    # 設定過程要在視窗裡貼金鑰，所以開看得到的視窗
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$(Join-Path $script:Dir 'setup-telegram.ps1')`""
})
$tgTele.Sw.Add_Click({
    $this.Enabled = $false
    if (Get-TaskRow 'TelegramCommands') {
        try { Unregister-ScheduledTask -TaskName TelegramCommands -Confirm:$false -ErrorAction Stop } catch {}
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'telegram-commands\.ps1' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } else {
        [void](Invoke-ScriptUI (Join-Path $script:Dir 'punch\telegram-commands.ps1') @('-Install') 30)
        try { Start-ScheduledTask -TaskName TelegramCommands -ErrorAction Stop } catch {}
        Start-Sleep -Milliseconds 800
    }
    $this.Enabled = $true
    Update-FeatureCards
})

$tgBook.Sw.Add_Click({
    $this.Enabled = $false
    if (Get-TaskRow 'NightlyBook') {
        try { Unregister-ScheduledTask -TaskName NightlyBook -Confirm:$false -ErrorAction Stop } catch {}
    } else {
        [void](Invoke-ScriptUI (Join-Path $script:Dir 'punch\nightly-book.ps1') @('-Install') 30)
        $csv = Join-Path $script:Dir 'data\shifts.csv'
        if (-not (Get-Content $csv -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\d{4}-' })) {
            [System.Windows.Forms.MessageBox]::Show(
                "已開啟，但 data\shifts.csv 還沒有班表，沒有班表就不會自動預約。`n按「編輯班表」填進去，一行一天，例如 2026-12-01,9076。", "還沒有班表") | Out-Null
        }
    }
    $this.Enabled = $true
    Update-FeatureCards
})
$btnShifts.Add_Click({ Open-ShiftFile })

# 夜間睡眠開關：開＝註冊 NightSleep/MorningWake 排程，關＝刪掉（實際動作在 sleep.ps1）
$tgSleep.Sw.Add_Click({
    $this.Enabled = $false
    $arg = if (Get-TaskRow 'NightSleep') { '-Uninstall' } else { '-Install' }
    # 舊式睡眠的電腦要開之前先警告，預設按鈕是「否」
    if ($arg -eq '-Install' -and -not $script:ModernStandby) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "這台電腦是舊式睡眠：睡著後網路會斷、程式全停，要靠排程叫醒，常常叫不醒或醒了又睡回去，早上就打不了卡。`n`n不建議開。確定還是要開？",
            "夜間睡眠", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $this.Enabled = $true; return }
    }
    [void](Invoke-ScriptUI (Join-Path $script:Dir 'sleep.ps1') @($arg) 30)
    # 自己打開的就寫旗標，update.ps1「幫大家關一次夜間睡眠」才不會把它關掉
    if ($arg -eq '-Install' -and (Get-TaskRow 'NightSleep')) {
        try { Set-Content (Join-Path $script:Dir 'data\sleep-reset.done') (Get-Date -Format 'yyyy-MM-dd') } catch {}
    }
    $this.Enabled = $true
    Update-PowerPage
})

$tgUpd.Sw.Add_Click({
    $new = if ((Read-Setting 'AutoUpdate') -eq '1') { '0' } else { '1' }
    try { Write-Setting 'AutoUpdate' $new } catch {
        [System.Windows.Forms.MessageBox]::Show("存不進 settings.ps1：$($_.Exception.Message)", "儲存失敗") | Out-Null
    }
    Update-FeatureCards
})

# 檢查更新：直接問 GitHub，列出本機版本之後的每一筆改動（不經過 update.ps1，免得順手傳 Telegram）
$btnChkUpd.Add_Click({
    $btnChkUpd.Enabled = $false; $lblUpdMsg.Text = "檢查中..."; $lblUpdMsg.ForeColor = $C_MUTE
    $local = (Get-VersionLine).Sha
    $job = Start-Job -ArgumentList $script:Repo, $script:Branch, $local -ScriptBlock {
        param($Repo, $Branch, $Local)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            $c = Invoke-RestMethod "https://api.github.com/repos/$Repo/commits/$Branch" -TimeoutSec 15
            $list = @()
            if ($Local -and $Local -ne $c.sha) {
                try {
                    $cmp  = Invoke-RestMethod "https://api.github.com/repos/$Repo/compare/$Local...$($c.sha)" -TimeoutSec 15
                    $list = @($cmp.commits | ForEach-Object { "• $("$($_.commit.author.date)".Substring(0, 10))　$(($_.commit.message -split "`n")[0])" })
                } catch {}
            }
            if (-not $list) { $list = @("• $("$($c.commit.author.date)".Substring(0, 10))　$(($c.commit.message -split "`n")[0])") }
            [pscustomobject]@{ Ok = $true; Sha = $c.sha; List = $list }
        } catch { [pscustomobject]@{ Ok = $false; Err = $_.Exception.Message } }
    }
    $r = Wait-JobUI $job 40
    if (-not $r -or -not $r.Ok) {
        $lblUpdMsg.Text = "✕ 連不上 GitHub"; $lblUpdMsg.ForeColor = $C_CRIT
        $rtbNew.Text = "檢查失敗：$(if ($r) { $r.Err } else { '逾時' })"
        $btnApply.Enabled = $false
    } elseif ($r.Sha -eq $local) {
        $lblUpdMsg.Text = "✓ 已經是最新版"; $lblUpdMsg.ForeColor = $C_GOOD
        $rtbNew.Text = "目前就是 GitHub 上的最新版。"
        $btnApply.Enabled = $false
    } else {
        $lblUpdMsg.Text = "有新版"; $lblUpdMsg.ForeColor = $C_WARN
        $rtbNew.Text = "按「立即更新」會裝這些改動：`r`n`r`n" + ($r.List -join "`r`n")
        $btnApply.Enabled = $true
    }
    $btnChkUpd.Enabled = $true
})

$btnApply.Add_Click({
    $btnApply.Enabled = $false; $btnChkUpd.Enabled = $false; $btnRollbk.Enabled = $false
    $lblUpdMsg.Text = "更新中..."; $lblUpdMsg.ForeColor = $C_MUTE
    $done = Invoke-ScriptUI $script:UpdateScript @('-Apply') 900   # 打卡進行中會等最多 10 分鐘
    Update-AboutPage
    $lblUpdMsg.Text = if ($done) { "完成，重開控制面板才會看到新介面" } else { "還在跑，稍後看更新紀錄" }
    $lblUpdMsg.ForeColor = if ($done) { $C_GOOD } else { $C_WARN }
    $btnChkUpd.Enabled = $true
})

$btnRollbk.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "確定要退回上一版？退掉的這版之後不會再自動裝回來。", "退回上一版",
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $btnRollbk.Enabled = $false; $btnApply.Enabled = $false
    $lblUpdMsg.Text = "退版中..."; $lblUpdMsg.ForeColor = $C_MUTE
    $done = Invoke-ScriptUI $script:UpdateScript @('-Rollback') 900
    Update-AboutPage
    $lblUpdMsg.Text = if ($done) { "已退回，重開控制面板才會看到舊介面" } else { "還在跑，稍後看更新紀錄" }
    $lblUpdMsg.ForeColor = if ($done) { $C_GOOD } else { $C_WARN }
})

# ══════════════════════════════════════════════════════════════
# 定時更新 + 啟動
# ══════════════════════════════════════════════════════════════

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    try { Update-Status } catch {}
    try { if ($pgHome.Visible) { Update-LogView } } catch {}
    try { if (Update-Runs) { Update-LastPunch; if ($pgLog.Visible) { Update-PunchList $true } } } catch {}
})
$timer.Start()

$form.Add_FormClosing({ $timer.Stop() })

[Fluent.Theme]::StyleWindow($form)
Show-View 0
Update-Status
Update-LogView $true
[void](Update-Runs $true); Update-LastPunch
Update-AboutPage
[System.Windows.Forms.Application]::Run($form)
