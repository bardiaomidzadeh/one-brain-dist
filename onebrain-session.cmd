@echo off
REM ONE Brain - oeffnet die SSH-Sitzung zum Server.
REM
REM Doppelklicken, Serveradresse eingeben, Passwort eingeben. Fertig.
REM
REM Warum eine .cmd und kein Aufruf in der PowerShell: das mit Windows
REM gelieferte OpenSSH kann keine Sitzungen teilen ("getsockname failed").
REM Das OpenSSH in Git for Windows kann es. Diese Datei sucht es und benutzt
REM es - damit niemand wissen muss, dass es diesen Unterschied gibt.

setlocal

set "BASH="
if exist "%ProgramFiles%\Git\bin\bash.exe"      set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"

if not defined BASH (
  echo.
  echo   Git for Windows wurde nicht gefunden.
  echo.
  echo   ONE Brain braucht dessen SSH, weil das SSH von Windows keine
  echo   Sitzungen teilen kann. Installieren:
  echo.
  echo       https://git-scm.com/downloads/win
  echo.
  echo   Danach diese Datei erneut ausfuehren.
  echo.
  pause
  exit /b 1
)

set "TARGET=%~1"
if "%TARGET%"=="" (
  echo.
  echo   ONE Brain - Sitzung oeffnen
  echo.
  set /p "TARGET=  Server (z.B. root@brain.acme.de): "
)

if "%TARGET%"=="" (
  echo   Keine Adresse angegeben.
  pause
  exit /b 1
)

"%BASH%" -lc "cd '%CD:\=/%' && ./onebrain-setup.sh session '%TARGET%'"

echo.
pause
