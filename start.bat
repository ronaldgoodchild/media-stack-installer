@echo off
:: REGTeches Media Stack -- Start
:: Developed by Ronald Goodchild for your pleasure
::
:: Double-click this to run the real installer (the .ps1, not the compiled
:: .exe). Requests admin elevation itself (Install-REGTechesMediaStack.ps1
:: doesn't self-elevate -- it just errors out if it isn't already running
:: elevated), then runs the installer with its default settings.

net session >nul 2>&1
if %errorLevel% == 0 goto :run

echo Requesting administrator privileges...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:run
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install-REGTechesMediaStack.ps1"
echo.
pause
