@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ROOT=%~dp0"
set "PS=%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (
  echo [UAUD] Windows PowerShell was not found: "%PS%"
  pause
  exit /b 1
)
if not exist "%ROOT%self-repair.ps1" (
  echo [UAUD] self-repair.ps1 was not found in "%ROOT%"
  pause
  exit /b 1
)
pushd "%ROOT%" >nul 2>&1
if errorlevel 1 (
  echo [UAUD] Could not enter the ultra-mode directory.
  pause
  exit /b 1
)
echo [UAUD] Launching UARD 1.0.3 with process-scoped ExecutionPolicy Bypass...
echo [UAUD] UARD will diagnose Group Policy/application-control restrictions instead of attempting to bypass them.
"%PS%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -NoExit -File "%ROOT%self-repair.ps1"
set "RC=%ERRORLEVEL%"
popd >nul 2>&1
echo [UAUD] UARD exited with code %RC%.
echo [UAUD] 0=success, 1=repair failure, 2=verification incomplete.
pause
exit /b %RC%
