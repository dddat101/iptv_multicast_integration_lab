@echo off
title IPTV Multicast Windows Client
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\run_client.ps1" %*
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Script finished with exit code %ERRORLEVEL%.
    pause
)
