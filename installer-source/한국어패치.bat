@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
attrib +h +s "%~dp0.nfb-ko-data" >nul 2>&1
set "ACTION="
if /i "%~1"=="uninstall" set "ACTION=-Uninstall"
if "%~1"=="제거" set "ACTION=-Uninstall"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0.nfb-ko-data\install.ps1" -GameRoot "%~dp0" %ACTION%
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo 작업이 완료되었습니다.
) else (
  echo 오류가 발생했습니다. 위 메시지를 확인해 주세요.
)
pause
exit /b %RC%
