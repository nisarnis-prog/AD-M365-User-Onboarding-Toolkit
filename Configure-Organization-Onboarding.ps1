[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$target=Join-Path $root 'Create-Organization-CombinedUsers.ps1'
$marker=Join-Path $root '.organization-setup-complete'
if(-not (Test-Path -LiteralPath $target)){throw 'Main PowerShell script missing.'}
Write-Host 'ORGANIZATION ONBOARDING - DIRECT AD + M365 CONFIGURATION ONLY' -ForegroundColor Cyan
Write-Host 'This wizard changes script settings ONLY. It NEVER runs onboarding.'
Write-Host 'Cloud users are created directly; Entra Connect sync is NOT used.'
Write-Host 'Do not enter passwords here. Passwords belong in a secured, local CSV.'
Write-Host 'Press Enter to keep an existing setting. All EXAMPLE values must be replaced.'
Write-Host ''
$testOnly = ((Read-Host 'Enter TEST to practice with fictional values (no main-script update), or press Enter for REAL setup') -eq 'TEST')
$draftPath=Join-Path $root 'Setup-Draft.json'
$source=[IO.File]::ReadAllText($target)
$edited=$source
function Quote-Ps([string]$value) { return "'" + $value.Replace("'","''") + "'" }
# Match one assignment line, preserving parameter commas and trailing # CHANGE comments.
# Use explicit line parsing rather than a regex that treats the comma as part of a setting value.
function Find-SettingLine([string]$name) {
    $pattern = '(?m)^(?<prefix>\s*(?:\[[^\r\n]*?\]\s*)?\$'+[regex]::Escape($name)+'\s*=\s*)(?<value>.*?)(?<comma>,?)(?<comment>\s+\#.*)?$'
    $m=[regex]::Match($script:edited,$pattern)
    if(-not $m.Success){throw "Setting $name not found; script version may be incompatible."}
    return $m
}
function Get-Setting([string]$name) {
    $m=Find-SettingLine $name
    $v=$m.Groups['value'].Value.Trim()
    # A parameter assignment may end with a comma; never treat that as the setting itself.
    if($v.EndsWith(',')){$v=$v.Substring(0,$v.Length-1).TrimEnd()}
    return $v
}
function Set-Setting([string]$name,[string]$literal){
    $m=Find-SettingLine $name
    $prefix=$m.Groups['prefix'].Value
    $raw=$m.Groups['value'].Value.TrimEnd()
    $comma=if($raw.EndsWith(',') -or $m.Groups['comma'].Value -eq ','){','}else{''}
    $comment=$m.Groups['comment'].Value
    $replacement=$prefix+$literal+$comma+$comment
    $script:edited=$script:edited.Substring(0,$m.Index)+$replacement+$script:edited.Substring($m.Index+$m.Length)
}
function Ask([string]$name,[string]$label,[string]$example,[string]$kind='text'){
    $old=Get-Setting $name
    if($script:testOnly -and $script:draft -and $script:draft.ContainsKey($name)) {
        # Saved drafts are plain user input, not PowerShell source; convert safely.
        $stored=[string]$script:draft[$name]
        $validDraft=$true
        switch($kind){
          'bool' { $validDraft=($stored -in @('true','false')) }
          'int' { $validDraft=($stored -match '^\d+$') }
          'letter' { $validDraft=($stored -match '^[A-Za-z]$') }
          'country' { $validDraft=($stored -match '^[A-Za-z]{2}$') }
          'list' { $validDraft=(@($stored.Split(',') | ForEach-Object {$_.Trim()} | Where-Object {$_}).Count -gt 0) }
        }
        if(-not $validDraft){Write-Warning "Ignoring invalid saved $name value";[void]$script:draft.Remove($name)}
        else { $old=$stored;switch($kind){
          'bool' { if($stored -in @('true','false')){Set-Setting $name ('$'+$stored.ToLowerInvariant())} }
          'int' { if($stored -match '^\d+$'){Set-Setting $name $stored} }
          'letter' { if($stored -match '^[A-Za-z]$'){Set-Setting $name (Quote-Ps $stored.ToUpperInvariant())} }
          'country' { if($stored -match '^[A-Za-z]{2}$'){Set-Setting $name (Quote-Ps $stored.ToUpperInvariant())} }
          'list' { $a=@($stored.Split(',') | ForEach-Object {$_.Trim()} | Where-Object {$_});if($a.Count){Set-Setting $name ('@('+ (($a | ForEach-Object {Quote-Ps $_}) -join ',') +')')} }
          default {Set-Setting $name (Quote-Ps $stored)}
        }}
    }
    Write-Host "`n$label" -ForegroundColor Yellow
    Write-Host "  Example: $example"
    Write-Host "  Current: $old"
    while($true){
        $v=Read-Host '  New value (Enter = keep)'
        if([string]::IsNullOrWhiteSpace($v)){return}
        $v=$v.Trim()
        if($v.Contains("`r") -or $v.Contains("`n")){Write-Warning 'Newlines not allowed';continue}
        # Validate before entering switch: 'continue' inside switch does not retry the input loop.
        $valid=$true
        switch($kind){
            'bool' { $valid=($v -in @('true','false')) }
            'int' { $valid=($v -match '^\d+$') }
            'letter' { $valid=($v -match '^[A-Za-z]$') }
            'country' { $valid=($v -match '^[A-Za-z]{2}$') }
            'list' { $valid=(@($v.Split(',') | ForEach-Object {$_.Trim()} | Where-Object {$_}).Count -gt 0) }
        }
        if(-not $valid){Write-Warning "Invalid $kind value; please retry";continue}
        switch($kind){
            'bool' { if($v -notin @('true','false')){Write-Warning 'Enter true or false';continue};Set-Setting $name ('$'+$v.ToLowerInvariant()) }
            'int' { if($v -notmatch '^\d+$'){Write-Warning 'Enter nonnegative whole number';continue};Set-Setting $name $v }
            'letter' { if($v -notmatch '^[A-Za-z]$'){Write-Warning 'Enter one drive letter';continue};Set-Setting $name (Quote-Ps $v.ToUpperInvariant()) }
            'country' { if($v -notmatch '^[A-Za-z]{2}$'){Write-Warning 'Enter two-letter country code';continue};Set-Setting $name (Quote-Ps $v.ToUpperInvariant()) }
            'list' { $a=@($v.Split(',') | ForEach-Object {$_.Trim()} | Where-Object {$_}); if(-not $a.Count){Write-Warning 'Enter one or more values';continue}; Set-Setting $name ('@('+ (($a | ForEach-Object {Quote-Ps $_}) -join ',') +')') }
            default {Set-Setting $name (Quote-Ps $v)}
        }
        $script:draft[$name]=$v
        return
    }
}
$script:draft=@{}
if($testOnly -and (Test-Path -LiteralPath $draftPath)){
    try { $loaded=Get-Content -LiteralPath $draftPath -Raw | ConvertFrom-Json
        foreach($prop in $loaded.PSObject.Properties){$script:draft[$prop.Name]=[string]$prop.Value}
    } catch { Write-Warning 'Previous draft could not be read. Starting fresh.' }
}
# The four values below are in the param block. Use same exact assignment parser.
Ask GroupAddresses 'Cloud mail-enabled group addresses (comma-separated)' 'staff@example.com' list
Ask LicenseSkuPartNumber 'Microsoft 365 SKU part number (tenant must own it)' 'SPE_E3'
Ask UsageLocation 'Microsoft 365 usage location' 'AE' country
Ask FileServer 'Windows file server FQDN' 'files.example.com'
Ask UserFolderRoot 'Local folder root ON that server' 'D:\HomeFolders'
Ask UpnSuffix 'Verified user sign-in UPN suffix' 'example.com'
Ask PrinterGroupDN 'Existing printer group distinguished name' 'CN=GG-Printers,OU=Groups,DC=corp,DC=example,DC=com'
Ask PrinterGroupName 'Existing printer group name' 'GG-Printers'
Ask CommonS 'Existing shared UNC for first mapped drive' '\\files.example.com\Policies'
Ask CommonJ 'Existing shared UNC for second mapped drive' '\\files.example.com\Shared'
Ask DriveLetterS 'First shared drive letter' 'S' letter
Ask DriveLetterJ 'Second shared drive letter' 'J' letter
Ask DriveLetterHome 'Personal share drive letter' 'Z' letter
Ask ExpectedTenantId 'Expected Microsoft Entra tenant GUID (mandatory)' '11111111-2222-3333-4444-555555555555'
Ask AllowedAdminAccounts 'Authorized cloud operator UPNs (comma-separated)' 'admin@example.com' list
Ask WelcomeEmailSender 'Authorized sender mailbox' 'onboarding@example.com'
Ask WelcomeEmailCc 'Approved welcome email CC (credential exposure risk)' 'helpdesk@example.com'
Ask WelcomeEmailSubject 'Welcome email subject' 'Welcome to My Company'
Ask AdCountryCode 'AD numeric country code' '784' int
Ask EnablePasswordEmail 'Email temporary passwords? true/false (NOT RECOMMENDED)' 'false' bool
Write-Host "`nOptional advanced retry values (press Enter to keep defaults):" -ForegroundColor Cyan
Ask ExchangeWaitAttempts 'Exchange retry attempts' '20' int
Ask ExchangeWaitSeconds 'Seconds between Exchange checks' '15' int
# A practice session must NEVER alter the executable onboarding engine or create the setup marker.
if($testOnly){
    Write-Host "`nPRACTICE SUMMARY (fictional values allowed; not ready for onboarding)" -ForegroundColor Cyan
    foreach($name in @('GroupAddresses','LicenseSkuPartNumber','UsageLocation','FileServer','UserFolderRoot','UpnSuffix','PrinterGroupDN','PrinterGroupName','CommonS','CommonJ','DriveLetterS','DriveLetterJ','DriveLetterHome','ExpectedTenantId','AllowedAdminAccounts','WelcomeEmailSender','WelcomeEmailCc','WelcomeEmailSubject','AdCountryCode','EnablePasswordEmail')){
        Write-Host ("  {0}: {1}" -f $name,(Get-Setting $name))
    }
    $decision=Read-Host 'Type SAVE-TEST to save your practice answers to Setup-Draft.json (main PS1 untouched), or press Enter to discard'
    if($decision -ceq 'SAVE-TEST'){
        $script:draft | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $draftPath -Encoding UTF8
        Write-Host 'TEST SAVED. Only Setup-Draft.json changed. Main PS1 and setup marker untouched.' -ForegroundColor Green
    }else{Write-Host 'Practice answers discarded.'}
    exit 0
}
# Reject placeholders and inconsistent drive letters before writing anything.
$placeholders=@('FS01.corp.example.com','D:\UserHomes','example.com','GG-Office-Printers','staff-group@example.com','ENTER_YOUR_LICENSE_SKU','admin@example.com','onboarding@example.com','helpdesk@example.com')
$missing=@()
foreach($n in @('GroupAddresses','LicenseSkuPartNumber','UsageLocation','FileServer','UserFolderRoot','UpnSuffix','PrinterGroupDN','PrinterGroupName','CommonS','CommonJ','ExpectedTenantId','AllowedAdminAccounts','AdCountryCode')){
  $value=Get-Setting $n
  if($value -match '(^|[^A-Za-z])ZZ([^A-Za-z]|$)' -or $value -eq '0' -or $value -eq "'D:\UserHomes'" -or $value -match 'example\.com|GG-Office-Printers|ENTER_YOUR_LICENSE_SKU|FS01\.corp\.example\.com'){$missing+=$n}
}
if((Get-Setting EnablePasswordEmail) -eq '$true') {
  foreach($n in @('WelcomeEmailSender','WelcomeEmailCc')) {
    if((Get-Setting $n) -match 'example\.com|^\s*''\s*$'){$missing+=$n}
  }
}
$tenantValue=(Get-Setting ExpectedTenantId).Trim([char]39)
if($tenantValue -notmatch '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' -or $tenantValue -eq '00000000-0000-0000-0000-000000000000' -or $tenantValue -eq '11111111-2222-3333-4444-555555555555'){$missing+='ExpectedTenantId'}
if($missing.Count){Write-Host "`nNOT SAVED: Replace remaining examples: $($missing -join ', ')" -ForegroundColor Red;exit 2}
$letters=@((Get-Setting DriveLetterS),(Get-Setting DriveLetterJ),(Get-Setting DriveLetterHome))
if(@($letters | Select-Object -Unique).Count -ne 3){Write-Host 'NOT SAVED: Drive letters must be different.' -ForegroundColor Red;exit 3}
# Check syntax with the built-in PowerShell parser BEFORE replacing the original.
$tokens=$null;$errors=$null
[System.Management.Automation.Language.Parser]::ParseInput($edited,[ref]$tokens,[ref]$errors)|Out-Null
if($errors.Count){$errors | ForEach-Object {Write-Host $_ -ForegroundColor Red};throw 'Generated PowerShell failed syntax validation. Original remains untouched.'}
Write-Host "`nReview CSV template separately: replace fictional user, OU, InitialPassword, personal email." -ForegroundColor Yellow
Write-Host 'CAUTION: the main script can modify existing users, NTFS/SMB permissions, groups and licenses.' -ForegroundColor Yellow
Write-Host 'Plaintext passwords in CSV and email are insecure. Use only with written approval.' -ForegroundColor Yellow
$confirm=Read-Host 'Type SAVE to back up and update main PowerShell script (NO onboarding will run)'
if($confirm -cne 'SAVE'){Write-Host 'Canceled. No files modified.';exit 0}
$backup=Join-Path $root 'Backups'
New-Item -ItemType Directory -Force -Path $backup | Out-Null
$backupFile=Join-Path $backup ('Create-Organization-CombinedUsers_'+(Get-Date -Format yyyyMMdd_HHmmss)+'.ps1')
Copy-Item -LiteralPath $target -Destination $backupFile -ErrorAction Stop
$temp=Join-Path $root ('._setup_'+[guid]::NewGuid().ToString('N')+'.tmp')
try{
 [IO.File]::WriteAllText($temp,$edited,[Text.UTF8Encoding]::new($true))
 Move-Item -LiteralPath $temp -Destination $target -Force
 [IO.File]::WriteAllText($marker,'Configured '+(Get-Date -Format o)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
 Write-Host "`nSETUP COMPLETE. PowerShell configuration updated; onboarding NOT executed." -ForegroundColor Green
 Write-Host "Backup: $backupFile"
 Write-Host 'Next: securely fill CSV, then run Run-Organization-Onboarding.bat and select PREVIEW.'
}catch{Remove-Item $temp -ErrorAction SilentlyContinue;throw}
