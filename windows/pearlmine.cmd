@echo off
rem pearlmine for Windows - runs pearlmine.ps1 without changing your PowerShell execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\pearlmine.ps1" %*
exit /b %ERRORLEVEL%
