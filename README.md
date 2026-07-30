# Proxy-Chameleon
Automatic proxy rotation




Imports System.Drawing
Imports System.IO
Imports System.Net
Imports System.Net.Http
Imports System.Net.NetworkInformation
Imports System.Runtime.InteropServices
Imports System.Text
Imports System.Text.RegularExpressions
Imports System.Threading
Imports System.Threading.Tasks
Imports System.Windows.Forms
Imports System.Diagnostics
Imports Microsoft.Win32

Public Class Form1

' Windows-API für sofortige Übernahme der Proxy-Änderungen im Browser
<DllImport("wininet.dll", SetLastError:=True, CharSet:=CharSet.Auto)>
Private Shared Function InternetSetOption(ByVal hInternet As IntPtr, ByVal dwOption As Integer, ByVal lpBuffer As IntPtr, ByVal dwBufferLength As Integer) As Boolean
End Function

Private Const INTERNET_OPTION_SETTINGS_CHANGED As Integer = 39
Private Const INTERNET_OPTION_REFRESH As Integer = 37

' Timeouts (konfigurierbar an einer Stelle)
Private Const DOWNLOAD_TIMEOUT_MS As Integer = 10000
Private Const PROXY_CHECK_TIMEOUT_MS As Integer = 6000

' System-Tray Objekte
Private trayMenu As New ContextMenuStrip()

' ==================== DATEN ====================
Private ReadOnly Sources As New List(Of String)
Private ReadOnly FoundProxies As New List(Of String)
Private ReadOnly ValidProxies As New List(Of String)
Private IsRunning As Boolean = False
Private ScannerThread As Thread
Private ReadOnly LockObj As New Object()

' Ein einziger, wiederverwendeter HttpClient (Best Practice statt pro Request neu erzeugen)
Private ReadOnly SourceHttpClient As New HttpClient() With {
.Timeout = TimeSpan.FromMilliseconds(DOWNLOAD_TIMEOUT_MS)
}

' ==================== FORM LOAD ====================
Private Sub Form1_Load(sender As Object, e As EventArgs) Handles MyBase.Load
Try
' 1. Kontextmenü für Tray-Icon (Rechtsklick)
trayMenu.Items.Clear()
trayMenu.Items.Add("Öffnen", Nothing, AddressOf RestoreFromTray)
trayMenu.Items.Add("-")
trayMenu.Items.Add("Beenden", Nothing, AddressOf ExitApplication)

' 2. NotifyIcon einrichten
If Me.Icon IsNot Nothing Then
NotifyIcon1.Icon = Me.Icon
Else
NotifyIcon1.Icon = SystemIcons.Application
End If

SetNotifyIconText("Proxy Switcher (Inaktiv)")
NotifyIcon1.ContextMenuStrip = trayMenu
NotifyIcon1.Visible = True

RemoveHandler NotifyIcon1.MouseDoubleClick, AddressOf NotifyIcon_MouseDoubleClick
AddHandler NotifyIcon1.MouseDoubleClick, AddressOf NotifyIcon_MouseDoubleClick

SourceHttpClient.DefaultRequestHeaders.UserAgent.P arseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64)")

InitSources()
Log("Anwendung bereit. Quellen geladen.")

' Auto-Scan und Auto-Switch direkt starten
StartProxySwitcherTimer()
AUTOSCANStart()

Catch ex As Exception
MessageBox.Show("Fehler beim Initialisieren des Programms: " & ex.Message, "Startfehler", MessageBoxButtons.OK, MessageBoxIcon.Error)
End Try
End Sub

' --- STEUERUNG FÜR DEN AUTOMATISCHEN WINDOWS-PROXY-WECHSEL ---
Private Sub StartProxySwitcherTimer()
Dim minutes As Double = 5
If numInterval IsNot Nothing AndAlso numInterval.Value >= 1 Then
minutes = CDbl(numInterval.Value)
End If

Dim msInterval As Double = minutes * 60.0 * 1000.0
If msInterval > Integer.MaxValue Then msInterval = Integer.MaxValue

tmrProxySwitch.Interval = CInt(msInterval)
tmrProxySwitch.Start()
End Sub

' --- BUTTON 1: STARTEN ---
Private Sub btnStart_Click(sender As Object, e As EventArgs) Handles btnStart.Click
Try
StartProxySwitcherTimer()
AUTOSCANStart()

' Falls bereits Proxys existieren, direkt den ersten aktivieren
If lstProxies.Items.Count > 0 Then
SwitchToCurrentProxy()
End If

lblStatus.Text = "Status: Aktiv (Scan & Switch)"
Catch ex As Exception
MessageBox.Show("Fehler beim Starten: " & ex.Message, "Fehler", MessageBoxButtons.OK, MessageBoxIcon.Error)
End Try
End Sub

' --- BUTTON 2: STOPPEN & RÜCKGÄNGIG MACHEN ---
Private Sub btnStop_Click(sender As Object, e As EventArgs) Handles btnStop.Click
Try
AUTOSCANStop()
tmrProxySwitch.Stop()

' Proxy im System sofort wieder deaktivieren
ApplyProxy("", False)

lblStatus.Text = "Status: Gestoppt"
SetNotifyIconText("Proxy Switcher (Gestoppt)")

NotifyIcon1.ShowBalloonTip(2000, "Proxy Change", "Proxy wurde deaktiviert.", ToolTipIcon.Info)
Catch ex As Exception
MessageBox.Show("Fehler beim Stoppen: " & ex.Message, "Fehler", MessageBoxButtons.OK, MessageBoxIcon.Error)
End Try
End Sub

' --- TIMER-EVENT: WECHSELT ZUM NÄCHSTEN PROXY ---
Private Sub tmrProxySwitch_Tick(sender As Object, e As EventArgs) Handles tmrProxySwitch.Tick
Try
If lstProxies.Items.Count = 0 Then Return

Dim nextIndex As Integer = lstProxies.SelectedIndex + 1
If nextIndex >= lstProxies.Items.Count OrElse nextIndex < 0 Then
nextIndex = 0
End If

lstProxies.SelectedIndex = nextIndex
SwitchToCurrentProxy()

Catch ex As Exception
lblStatus.Text = "Fehler beim Wechseln: " & ex.Message
End Try
End Sub

' --- HILFSFUNKTION: PROXY AUS DER LISTBOX AKTIVIEREN ---
Private Sub SwitchToCurrentProxy()
If lstProxies.InvokeRequired Then
lstProxies.Invoke(New Action(AddressOf SwitchToCurrentProxy))
Return
End If

If lstProxies.Items.Count = 0 Then Return

If lstProxies.SelectedIndex = -1 Then
lstProxies.SelectedIndex = 0
End If

If lstProxies.SelectedItem IsNot Nothing Then
Dim selectedProxy As String = lstProxies.SelectedItem.ToString().Trim()
ApplyProxy(selectedProxy, True)

lblStatus.Text = "Status: Proxy AKTIV (" & selectedProxy & ")"
SetNotifyIconText("Proxy AKTIV: " & selectedProxy)
Log($"[SYSTEM PROXY GEWECHSELT] -> {selectedProxy}", Color.Yellow)

NotifyIcon1.ShowBalloonTip(2000, "Proxy Change", "Neuer Proxy aktiv:" & vbCrLf & selectedProxy, ToolTipIcon.Info)
End If
End Sub

' --- REGISTRY-SCHALTER FÜR DEN PROXY ---
Private Sub ApplyProxy(ByVal proxyAddress As String, ByVal enable As Boolean)
Try
Using key As RegistryKey = Registry.CurrentUser.OpenSubKey("Software\Microsof t\Windows\CurrentVersion\Internet Settings", True)
If key IsNot Nothing Then
If enable Then
key.SetValue("ProxyServer", proxyAddress, RegistryValueKind.String)
key.SetValue("ProxyEnable", 1, RegistryValueKind.DWord)
Else
key.SetValue("ProxyEnable", 0, RegistryValueKind.DWord)
End If
End If
End Using

' Windows & Browser aktualisieren
InternetSetOption(IntPtr.Zero, INTERNET_OPTION_SETTINGS_CHANGED, IntPtr.Zero, 0)
InternetSetOption(IntPtr.Zero, INTERNET_OPTION_REFRESH, IntPtr.Zero, 0)

Catch ex As UnauthorizedAccessException
MessageBox.Show("Keine ausreichenden Rechte zum Ändern der Registry!", "Rechte-Fehler", MessageBoxButtons.OK, MessageBoxIcon.Error)
Catch ex As Exception
MessageBox.Show("Fehler beim Ändern des System-Proxys: " & ex.Message, "Registry-Fehler", MessageBoxButtons.OK, MessageBoxIcon.Error)
End Try
End Sub

Private Sub SetNotifyIconText(ByVal text As String)
Try
If text.Length > 63 Then
text = text.Substring(0, 60) & "..."
End If
NotifyIcon1.Text = text
Catch
End Try
End Sub

Private Sub Form1_Resize(sender As Object, e As EventArgs) Handles MyBase.Resize
Try
If Me.WindowState = FormWindowState.Minimized Then
Me.Hide()
NotifyIcon1.ShowBalloonTip(1000, "Proxy Switcher", "Das Programm läuft im Hintergrund weiter.", ToolTipIcon.Info)
End If
Catch
End Try
End Sub

Private Sub NotifyIcon_MouseDoubleClick(sender As Object, e As MouseEventArgs)
If e.Button = MouseButtons.Left Then
RestoreFromTray(Nothing, Nothing)
End If
End Sub

Private Sub RestoreFromTray(sender As Object, e As EventArgs)
Try
Me.Show()
Me.WindowState = FormWindowState.Normal
Me.BringToFront()
Catch
End Try
End Sub

Private Sub ExitApplication(sender As Object, e As EventArgs)
CleanUpAndExit()
End Sub

Private Sub CleanUpAndExit()
Static isExiting As Boolean = False
If isExiting Then Exit Sub
isExiting = True

Try
tmrProxySwitch.Stop()
Autotimer.Stop()
ApplyProxy("", False) ' Proxy vor Beenden ausschalten
Catch
Finally
Try
NotifyIcon1.Visible = False
NotifyIcon1.Dispose()
Catch
End Try
Try
SourceHttpClient.Dispose()
Catch
End Try
Application.Exit()
End Try
End Sub

Private Sub InitSources()
Sources.Clear()
Sources.Add("https://www.proxy-list.download/api/v1/get?type=http")
Sources.Add("https://api.proxyscrape.com/v2/?request=get&protocol=http&timeout=10000&country=a ll&ssl=all&anonymity=all")
Sources.Add("https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt")
Sources.Add("https://raw.githubusercontent.com/ShiftyTR/Proxy-List/master/http.txt")
Sources.Add("https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt")
Sources.Add("https://raw.githubusercontent.com/clarketm/proxy-list/master/proxy-list-raw.txt")
End Sub

Private Sub Log(msg As String, Optional color As Color = Nothing)
If PLLConsole.InvokeRequired Then
PLLConsole.Invoke(New Action(Sub() Log(msg, color)))
Return
End If

If color = Nothing Then color = Color.LimeGreen

PLLConsole.SelectionStart = PLLConsole.TextLength
PLLConsole.SelectionLength = 0
PLLConsole.SelectionColor = color
PLLConsole.AppendText($"[{DateTime.Now:HH:mm:ss}] {msg}{Environment.NewLine}")
PLLConsole.ScrollToCaret()
End Sub

Private Sub SetStatus(msg As String)
If lblStatus.InvokeRequired Then
lblStatus.Invoke(New Action(Sub() SetStatus(msg)))
Return
End If
lblStatus.Text = $"Status: {msg}"
End Sub

Private Sub AddProxiesToPLL(proxies As List(Of String))
If proxies Is Nothing OrElse proxies.Count = 0 Then Return

If PLL.InvokeRequired Then
PLL.Invoke(New Action(Sub() AddProxiesToPLL(proxies)))
Return
End If

PLL.BeginUpdate()
Try
For Each p In proxies
PLL.Items.Add(p)
Next
Finally
PLL.EndUpdate()
End Try

If PLL.Items.Count > 0 Then
PLL.TopIndex = PLL.Items.Count - 1
End If
PLL.Refresh()
End Sub

Private Sub AddOrUpdateListView(proxy As String, statusOrPing As String)
If PLLChecked.InvokeRequired Then
PLLChecked.Invoke(New Action(Sub() AddOrUpdateListView(proxy, statusOrPing)))
Return
End If

For Each item As ListViewItem In PLLChecked.Items
If item.Text = proxy Then
item.SubItems(1).Text = statusOrPing
Return
End If
Next

Dim newItem As New ListViewItem(proxy)
newItem.SubItems.Add(statusOrPing)
PLLChecked.Items.Add(newItem)
End Sub

Private Sub AddToFinalList(proxy As String)
If lstProxies.InvokeRequired Then
lstProxies.Invoke(New Action(Sub() AddToFinalList(proxy)))
Return
End If
If Not lstProxies.Items.Contains(proxy) Then
lstProxies.Items.Add(proxy)
' Falls es der allererste funktionierende Proxy ist, direkt in Windows aktivieren
If lstProxies.Items.Count = 1 Then
SwitchToCurrentProxy()
End If
End If
End Sub

Private Sub ClearAllUI()
If PLL.InvokeRequired Then
PLL.Invoke(New Action(AddressOf ClearAllUI))
Return
End If
PLL.Items.Clear()
PLLChecked.Items.Clear()
lstProxies.Items.Clear()
End Sub

Public Sub AUTOSCANStart()
IsRunning = True
btnStart.Enabled = False
btnStop.Enabled = True
Log("=== AUTO-SCAN GESTARTET ===", Color.Cyan)

RunScan()
Autotimer.Start()
End Sub

Public Sub AUTOSCANStop()
IsRunning = False
Autotimer.Stop()
btnStart.Enabled = True
btnStop.Enabled = False
SetStatus("Gestoppt")
Log("=== AUTO-SCAN GESTOPPT ===", Color.Orange)
End Sub

Private Sub Autotimer_Tick(sender As Object, e As EventArgs) Handles Autotimer.Tick
If IsRunning Then
Log("Timer: Nächster Durchlauf startet...", Color.Cyan)
RunScan()
End If
End Sub

Private Sub RunScan()
If ScannerThread IsNot Nothing AndAlso ScannerThread.IsAlive Then
Log("Scan läuft bereits...", Color.Yellow)
Return
End If
ScannerThread = New Thread(AddressOf ScanWorker) With {.IsBackground = True}
ScannerThread.Start()
End Sub

Private Sub ScanWorker()
SetStatus("Scraping...")
Log("Starte Quellen-Abruf...")

SyncLock LockObj
FoundProxies.Clear()
ValidProxies.Clear()
End SyncLock

ClearAllUI()

For Each url In Sources
If Not IsRunning Then Exit For

Try
Log($"Lade Quelle: {url}")
Dim content = DownloadString(url)
Dim extracted = ExtractProxies(content)

Dim newlyFound As New List(Of String)()

SyncLock LockObj
For Each p In extracted
If Not FoundProxies.Contains(p) Then
FoundProxies.Add(p)
newlyFound.Add(p)
End If
Next
End SyncLock

If newlyFound.Count > 0 Then
AddProxiesToPLL(newlyFound)
Log($"{newlyFound.Count} neue Proxys in PLL eingetragen.")
Else
Log("Keine neuen/eindeutigen Proxys in dieser Quelle.")
End If

Catch ex As Exception
Log($"FEHLER bei {url}: {ex.Message}", Color.Red)
End Try

Thread.Sleep(300)
Next

Dim proxyCount As Integer
SyncLock LockObj
proxyCount = FoundProxies.Count
End SyncLock

Log($"{proxyCount} eindeutige Proxies in 'PLL' geladen.", Color.White)

If IsRunning AndAlso proxyCount > 0 Then
ValidateProxies()
End If

SetStatus($"Bereit | {ValidProxies.Count} OK / {proxyCount} Gesamt")
Log("Durchlauf komplett. Nächster Scan in 10 Min.", Color.Cyan)
End Sub

' Extrahiert IP:Port-Muster und validiert sie anschließend (echte Range-Prüfung statt nur Ziffernanzahl)
Private Function ExtractProxies(text As String) As List(Of String)
Dim result As New List(Of String)
If String.IsNullOrWhiteSpace(text) Then Return result

Dim pattern As String = "\b(?:\d{1,3}\.){3}\d{1,3}:\d{1,5}\b"
For Each m As Match In Regex.Matches(text, pattern)
Dim candidate As String = m.Value
If IsValidProxyEntry(candidate) Then
result.Add(candidate)
End If
Next
Return result
End Function

' Prüft, ob IP-Teil eine gültige IPv4-Adresse und der Port im gültigen Bereich (1–65535) ist
Private Function IsValidProxyEntry(entry As String) As Boolean
Dim parts = entry.Split(":"c)
If parts.Length <> 2 Then Return False

Dim ipPart As IPAddress = Nothing
If Not IPAddress.TryParse(parts(0), ipPart) Then Return False
If ipPart.AddressFamily <> Sockets.AddressFamily.InterNetwork Then Return False

Dim port As Integer
If Not Integer.TryParse(parts(1), port) Then Return False
If port < 1 OrElse port > 65535 Then Return False

Return True
End Function

Private Sub ValidateProxies()
Dim proxiesToCheck As List(Of String)
SyncLock LockObj
proxiesToCheck = New List(Of String)(FoundProxies)
End SyncLock

SetStatus("Prüfe Latenz & Verbindung...")
Log("Starte Erreichbarkeitsprüfung (Latenzmessung)...")

Dim checkUrl As String = "http://httpbin.org/ip"
Dim okCount As Integer = 0

Parallel.ForEach(proxiesToCheck,
New ParallelOptions With {.MaxDegreeOfParallelism = 40},
Sub(proxy, loopState)
If Not IsRunning Then
loopState.Stop()
Return
End If

If Not IsValidProxyEntry(proxy) Then Return

Dim parts = proxy.Split(":"c)
Dim ip = parts(0)
Dim port As Integer = Integer.Parse(parts(1))

AddOrUpdateListView(proxy, "Prüfe...")

Dim sw As New Stopwatch()
sw.Start()

Try
Dim handler As New HttpClientHandler() With {
.Proxy = New WebProxy(ip, port),
.UseProxy = True
}

Using httpClient As New HttpClient(handler) With {
.Timeout = TimeSpan.FromMilliseconds(PROXY_CHECK_TIMEOUT_MS)
}
httpClient.DefaultRequestHeaders.UserAgent.ParseAd d("Mozilla/5.0")

' GET statt HEAD, da viele Server/Proxys HEAD nicht zuverlässig unterstützen
Dim response = httpClient.GetAsync(checkUrl).GetAwaiter().GetResu lt()
sw.Stop()

If response.IsSuccessStatusCode Then
Dim latencyMs As Long = sw.ElapsedMilliseconds

SyncLock LockObj
ValidProxies.Add(proxy)
End SyncLock

Interlocked.Increment(okCount)

AddOrUpdateListView(proxy, $"{latencyMs} ms")
AddToFinalList(proxy)
Else
AddOrUpdateListView(proxy, "Fehler")
End If
End Using
Catch
sw.Stop()
AddOrUpdateListView(proxy, "Dead")
End Try
End Sub)

Log($"Prüfung beendet: {okCount} von {proxiesToCheck.Count} funktionieren und wurden nach 'lstProxies' übernommen.", Color.Yellow)

Try
Dim snapshot As List(Of String)
SyncLock LockObj
snapshot = New List(Of String)(ValidProxies)
End SyncLock

Dim outputPath As String = Path.Combine(AppDomain.CurrentDomain.BaseDirectory , "working_proxies.txt")
File.WriteAllLines(outputPath, snapshot)
Log($"Gültige Proxies wurden in '{outputPath}' gespeichert.", Color.White)
Catch ex As UnauthorizedAccessException
Log("Speicherfehler: Keine Schreibrechte im Programmverzeichnis. Bitte Anwendung an einen beschreibbaren Ort verschieben oder als Administrator ausführen.", Color.Red)
Catch ex As Exception
Log($"Speicherfehler: {ex.Message}", Color.Red)
End Try
End Sub

' Download über HttpClient mit festem Timeout (statt WebClient ohne Timeout)
Private Function DownloadString(url As String) As String
Try
Dim response = SourceHttpClient.GetAsync(url).GetAwaiter().GetRes ult()
response.EnsureSuccessStatusCode()
Return response.Content.ReadAsStringAsync().GetAwaiter(). GetResult()
Catch ex As TaskCanceledException
Throw New Exception($"Zeitüberschreitung nach {DOWNLOAD_TIMEOUT_MS} ms")
End Try
End Function

Private Sub Form1_FormClosing(sender As Object, e As FormClosingEventArgs) Handles MyBase.FormClosing
IsRunning = False
Autotimer.Stop()
tmrProxySwitch.Stop()
End Sub

End Class



==========
CMD FILE
==========

@echo off
setlocal EnableDelayedExpansion
title Proxy Rotator - Automatische Umschaltung

:: Zentrale Variablen-Definitionen
set "SCRIPT_DIR=%~dp0"
set "PROXYFILE=%SCRIPT_DIR%proxy.txt"
set "REGKEY=HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
set "last_idx=0"

:: Pruefen, ob proxy.txt im selben Ordner existiert
if not exist "%PROXYFILE%" (
    cls
    echo ========================================================
    echo   FEHLER: proxy.txt wurde nicht gefunden!
    echo ========================================================
    echo   Bitte erstelle die Datei "proxy.txt" im selben Ordner:
    echo   %SCRIPT_DIR%
    echo   und trage dort Proxys ein ^(Format: IP:PORT, einer pro Zeile^).
    echo ========================================================
    echo.
    pause
    exit /b
)

:MAIN_MENU
cls
echo ========================================================
echo               PROXY ROTATOR - STEUERUNG
echo ========================================================
echo.
echo   [1] Proxy jetzt einmal setzen (zufaellig)
echo   [2] Auto-Rotation starten (alle 5 Min., zufaellig)
echo   [3] Aktuellen Proxy-Status anzeigen
echo   [4] Proxy-Einstellungen komplett deaktivieren
echo   [5] Beenden
echo.
echo ========================================================
set "user_choice="
set /p user_choice="Bitte Option waehlen (1-5): "

if "%user_choice%"=="1" goto SET_ONCE
if "%user_choice%"=="2" goto ROTATE_LOOP
if "%user_choice%"=="3" goto SHOW_PROXY
if "%user_choice%"=="4" goto DISABLE_PROXY
if "%user_choice%"=="5" exit /b
goto MAIN_MENU


:: ========================================================
:: FUNKTIONEN (SUBROUTINES)
:: ========================================================

:LOAD_PROXIES
:: Vorhandene Array-Variablen bereinigen
if defined count (
    for /l %%i in (1,1,!count!) do set "proxy[%%i]="
)
set count=0

for /f "usebackq eol=# tokens=1*" %%A in ("%PROXYFILE%") do (
    if not "%%A"=="" (
        set /a count+=1
        set "proxy[!count!]=%%A"
    )
)
exit /b

:PICK_PROXY
:: Falls mehr als 1 Proxy existiert, direkten Wiederholungs-Fetch vermeiden
:RE_PICK
set /a rand_idx=(%random% %% count) + 1
if %count% GTR 1 (
    if !rand_idx!==%last_idx% goto RE_PICK
)
set "selected_proxy=!proxy[%rand_idx%]!"
set "last_idx=%rand_idx%"
exit /b

:APPLY_PROXY
reg add "%REGKEY%" /v ProxyEnable /t REG_DWORD /d 1 /f >nul
reg add "%REGKEY%" /v ProxyServer /t REG_SZ /d "%selected_proxy%" /f >nul
exit /b


:: ========================================================
:: MENUE-LOGIK / ABLAEUFE
:: ========================================================

:SET_ONCE
call :LOAD_PROXIES
if %count% LEQ 0 (
    cls
    echo FEHLER: Die Datei proxy.txt ist leer oder enthaelt nur Leerzeilen!
    echo.
    pause
    goto MAIN_MENU
)
call :PICK_PROXY
call :APPLY_PROXY
cls
echo ========================================================
echo   Proxy erfolgreich gesetzt: %selected_proxy%
echo ========================================================
echo.
pause
goto MAIN_MENU

:ROTATE_LOOP
call :LOAD_PROXIES
if %count% LEQ 0 (
    cls
    echo FEHLER: Die Datei proxy.txt ist leer oder enthaelt nur Leerzeilen!
    echo.
    pause
    goto MAIN_MENU
)
call :PICK_PROXY
call :APPLY_PROXY
cls
echo ========================================================
echo               PROXY ROTATOR - AKTIV
echo ========================================================
echo.
echo   Aktiver Proxy:  %selected_proxy%
echo   Gesamte Proxys: %count% Stueck geladen
echo   Aktiviert am:   %date% um %time% Uhr
echo.
echo ========================================================
echo   Der Proxy wird alle 5 Minuten automatisch gewechselt.
echo   [Beliebige Taste druecken = Sofort naechster Wechsel]
echo   [Strg + C = Skript abbrechen]
echo ========================================================
echo.
timeout /t 300
goto ROTATE_LOOP

:SHOW_PROXY
cls
echo ========================================================
echo               AKTUELLER PROXY-STATUS
echo ========================================================
echo.
set "cur_enable=0x0"
set "cur_proxy=Keine IP zugewiesen"

for /f "tokens=3" %%E in ('reg query "%REGKEY%" /v ProxyEnable 2^>nul ^| findstr /i "ProxyEnable"') do set "cur_enable=%%E"
for /f "tokens=2,*" %%P in ('reg query "%REGKEY%" /v ProxyServer 2^>nul ^| findstr /i "ProxyServer"') do set "cur_proxy=%%Q"

if "%cur_enable%"=="0x1" (
    echo   Status:  AKTIV
    echo   Proxy:   %cur_proxy%
) else (
    echo   Status:  DEAKTIVIERT
)
echo.
echo ========================================================
echo.
pause
goto MAIN_MENU

:DISABLE_PROXY
reg add "%REGKEY%" /v ProxyEnable /t REG_DWORD /d 0 /f >nul
:: Optional: ProxyServer-Wert leeren, um Reste zu entfernen
reg add "%REGKEY%" /v ProxyServer /t REG_SZ /d "" /f >nul
cls
echo ========================================================
echo   System-Proxy wurde erfolgreich DEAKTIVIERT.
echo ========================================================
echo.
pause
goto MAIN_MENU



