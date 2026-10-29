@echo off
rem BRAVO-Toolkit 5.2: one-step server update (see deploy\README.md).
rem Double-click and confirm UAC. All work is done by Update-BRAVO52.ps1.
rem
rem ASCII only: cmd.exe reads this file in the OEM code page.
rem
rem -ExecutionPolicy Bypass is process-scoped: the update pack is downloaded
rem from the internet, and RemoteSigned would block its scripts. Nothing is
rem changed in the machine or user execution policy.
rem
rem Optional arguments are passed through, e.g.:
rem   UPDATE-BRAVO52.cmd -CheckOnly
rem   UPDATE-BRAVO52.cmd -Tag v5.2.6 -RuntimeRoot "D:\BRAVO-Toolkit"
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-BRAVO52.ps1" %*
set "BRAVO_UPDATE_EXIT=%ERRORLEVEL%"
endlocal & exit /b %BRAVO_UPDATE_EXIT%
