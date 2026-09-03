@echo off
setlocal
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
echo [UAUD] Launching UARD with process-scoped ExecutionPolicy Bypass...
echo [UAUD] If Group Policy or application-control policy blocks PowerShell, UARD will report it rather than changing that policy.
"%PS%" -NoProfile -ExecutionPolicy Bypass -NoExit -File "%ROOT%self-repair.ps1"
set "RC=%ERRORLEVEL%"
echo [UAUD] UARD exited with code %RC%.
pause
exit /b %RC%
