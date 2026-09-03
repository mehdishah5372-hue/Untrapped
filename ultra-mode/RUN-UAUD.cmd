@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
set "PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
  echo [UAUD] Windows PowerShell was not found: "%PS%"
  pause
  exit /b 1
)
if not exist "%ROOT%UAUD.ps1" (
  echo [UAUD] UAUD.ps1 was not found in "%ROOT%"
  pause
  exit /b 1
)
pushd "%ROOT%" >nul 2>&1
if errorlevel 1 (
  echo [UAUD] Could not enter the ultra-mode directory.
  pause
  exit /b 1
)
echo [UAUD] Launching UAUD observable pipeline...
echo [UAUD] Chain: CANON -^> MIDDLEMAN -^> JSON/PS -^> PARSER -^> REPAIR -^> AST/JSON -^> CANON MATCH -^> WINDOWS -^> UARD -^> INSTALL
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File "%ROOT%UAUD.ps1"
set "RC=%ERRORLEVEL%"
popd >nul 2>&1
echo [UAUD] UAUD exited with code %RC%.
echo [UAUD] 0=success, 1=gate/repair failure, 2=verification incomplete.
pause
exit /b %RC%
