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