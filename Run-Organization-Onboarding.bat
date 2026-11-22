@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0"
title Organization Onboarding - AD and Microsoft 365
color 0C
set "PS_FILE=%~dp0Create-Organization-CombinedUsers.ps1"
set "CSV_FILE=%~dp0Organization-CombinedUserImport-Template.csv"
echo ==============================================================
echo  WARNING - ACTIVE DIRECTORY AND MICROSOFT 365
 echo ==============================================================
echo  This tool may CREATE or UPDATE users and cloud accounts,
echo  change group membership, license assignments, NTFS/SMB
 echo  permissions, home folders, shares and logon scripts.
echo  Optional welcome emails may expose temporary passwords.
echo.
echo  Incorrect settings or CSV data can cause security incidents,
echo  service interruption, unauthorized access or data loss.
echo  Obtain written authorization, verify backups, and test in a lab.
echo  Provided AS IS, without warranty. Authors and distributors
 echo  disclaim liability to the extent permitted by applicable law.
echo.
set "CONSENT="
set /p "CONSENT=Type AGREE to continue or EXIT to cancel: "
if /I not "%CONSENT%"=="AGREE" (echo Canceled. & pause & exit /b 0)
if not exist "%PS_FILE%" (echo ERROR: Missing onboarding PowerShell file. & pause & exit /b 2)
if not exist "%~dp0.organization-setup-complete" (echo ERROR: First-time REAL setup not completed. & pause & exit /b 5)
if not exist "%CSV_FILE%" (echo ERROR: Missing CSV file. & pause & exit /b 3)
echo.
echo  1 - PREVIEW ONLY ^(WhatIf^)
echo  2 - APPLY CHANGES ^(requires second confirmation^)
echo  0 - EXIT
echo.
choice /c 120 /n /m "Choose 1, 2 or 0: "
if errorlevel 3 exit /b 0
if errorlevel 2 goto APPLY
:PREVIEW
powershell.exe -NoProfile -File "%PS_FILE%" -CsvPath "%CSV_FILE%" -WhatIf
set "RC=%ERRORLEVEL%"
echo Preview exit code: %RC%
pause
exit /b %RC%
:APPLY
net session >nul 2>&1
if errorlevel 1 (echo ERROR: Run as Administrator on an authorized admin workstation. & pause & exit /b 4)
echo.
echo LAST WARNING: Real persistent changes may occur.
set "CONFIRM="
set /p "CONFIRM=Type EXECUTE-ONBOARDING to proceed: "
if not "%CONFIRM%"=="EXECUTE-ONBOARDING" (echo Canceled. & pause & exit /b 0)
powershell.exe -NoProfile -File "%PS_FILE%" -CsvPath "%CSV_FILE%"
set "RC=%ERRORLEVEL%"
echo Onboarding exit code: %RC%
pause
exit /b %RC%
