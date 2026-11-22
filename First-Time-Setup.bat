@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title Organization Onboarding - First-Time Setup
color 0E
echo ==============================================================
echo  ORGANIZATION ONBOARDING - FIRST-TIME SETUP
 echo ==============================================================
echo  IMPORTANT NOTICE
echo.
echo  This wizard changes local script configuration ONLY.
echo  It does NOT create accounts, folders or shares.
echo  Do not enter passwords or confidential information here.
echo  Incorrect settings can affect later onboarding operations.
echo  Use only with your organization's authorization.
echo  Provided AS IS, without warranty, to the extent permitted by law.
echo.
set "CONSENT="
set /p "CONSENT=Type AGREE to continue or EXIT to cancel: "
if /I not "%CONSENT%"=="AGREE" (echo Canceled. & pause & exit /b 0)
if not exist "%~dp0Configure-Organization-Onboarding.ps1" (echo ERROR: Setup PowerShell file missing. & pause & exit /b 2)
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Configure-Organization-Onboarding.ps1"
set "RC=%ERRORLEVEL%"
echo.
echo Setup exit code: %RC%
pause
exit /b %RC%
