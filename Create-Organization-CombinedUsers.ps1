[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [string]$CsvPath = (Join-Path $PSScriptRoot 'Organization-CombinedUserImport-Template.csv'), # CHANGE OPTIONAL: CSV path, if not beside this script
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'Logs'), # CHANGE OPTIONAL: secure local log/credential folder
    [string[]]$GroupAddresses = @('staff-group@example.com'), # CHANGE: existing Microsoft 365 group email address(es)
    [string]$LicenseSkuPartNumber = 'ENTER_YOUR_LICENSE_SKU', # CHANGE: licensed SKU in your tenant (example: SPE_E3, only if owned)
    [string]$UsageLocation = 'ZZ' # CHANGE: ISO two-letter country code, e.g. AE or US
)

$ErrorActionPreference = 'Stop'

# ============================================================
# GENERIC COMBINED ACTIVE DIRECTORY + MICROSOFT 365 ONBOARDING
# FULL-FEATURE TEMPLATE: review every EXAMPLE value before use.
# Run only with organizational authorization, from a managed admin workstation.
# WARNING: this tool can create/update identities, modify NTFS/SMB ACLs,
# create logon BAT files, assign licenses, and email initial passwords.
# CSV passwords are PLAINTEXT. No additional plaintext credential export is created.
# Sending passwords by email is INSECURE; opt-in is required and the
# organization must explicitly accept that risk. Prefer secure delivery.
# ============================================================

# ============================================================
# CHANGE THESE EXAMPLES FOR YOUR ENVIRONMENT (MANDATORY)
# IMPORTANT: # CHANGE is a COMMENT. KEEP IT after editing if you want.
# Example: $UpnSuffix = 'example.com' # CHANGE: verified UPN suffix
# Only replace the VALUE inside quotes (or the relevant number/boolean).
# Never place passwords, real employee data, or API secrets in a public ZIP.
# 1. FileServer: Windows file server DNS name (example FS01.corp.example.com)
# 2. UserFolderRoot: LOCAL path on that server, e.g. D:\UserHomes
# 3. UpnSuffix: verified sign-in domain, e.g. example.com
# 4. PrinterGroupDN: your EXISTING AD group distinguished name
# 5. CommonS / CommonJ: your existing SMB share UNC paths
# 6. AllowedAdminAccounts: authorized Microsoft 365 operator UPN(s)
# 7. WelcomeEmailSender / Cc: your approved mailboxes; SendAs required
# 8. AdCountryCode: AD numeric country code (e.g. 840 for United States)
# 9. GroupAddresses, LicenseSkuPartNumber, UsageLocation
#    are PARAMETERS at the very top of this file. Set them for your tenant.
# 10. CSV: replace ALL fictional sample values and the temporary password.
# 11. Review the drive letters S:, J:, Z: in Get-ExpectedBatContent.
# 12. Set EnablePasswordEmail to $true ONLY if policy allows plaintext
#     initial passwords by email. Default is OFF for security.
# ============================================================
$FileServer       = 'FS01.corp.example.com'        # CHANGE: your Windows file server FQDN, e.g. files.example.com
$UserFolderRoot   = 'D:\UserHomes'                # CHANGE: LOCAL folder path ON that file server, e.g. E:\HomeFolders
$UpnSuffix        = 'example.com'                  # CHANGE: your verified sign-in suffix, e.g. example.com
$PrinterGroupDN   = 'CN=GG-Office-Printers,OU=Groups,DC=corp,DC=example,DC=com' # CHANGE: distinguished name of YOUR EXISTING AD printer group
$PrinterGroupName = 'GG-Office-Printers'           # CHANGE: SAM/name of same EXISTING printer group
$CommonS          = '\\FS01.corp.example.com\Policies' # CHANGE: existing UNC share to map as S:, e.g. \\files.example.com\Policies
$CommonJ          = '\\FS01.corp.example.com\Shared'   # CHANGE: existing UNC share to map as J:, e.g. \\files.example.com\Shared
$ExchangeWaitAttempts = 20                     # CHANGE OPTIONAL: max Exchange provisioning checks
$ExchangeWaitSeconds  = 15                     # CHANGE OPTIONAL: seconds between Exchange checks
$ExpectedTenantId = '00000000-0000-0000-0000-000000000000' # CHANGE: exact Microsoft Entra tenant GUID; required for safe cloud provisioning
$AllowedAdminAccounts = @('admin@example.com') # CHANGE: authorized admin UPN(s), e.g. admin@example.com; NOT passwords
$CurrentAdminAccount  = $null                 # DO NOT CHANGE: runtime-selected operator account
$WelcomeEmailSender   = 'onboarding@example.com' # CHANGE: approved sender mailbox with SendAs rights
$WelcomeEmailCc       = 'helpdesk@example.com'   # CHANGE: approved CC mailbox; ensure it is allowed to receive credentials
$WelcomeEmailSubject  = 'Welcome - Your Organization Account Details' # CHANGE: your organization's subject wording
$AdCountryCode        = 0                        # CHANGE: numeric AD country code, e.g. 784 UAE or 840 US
$EnablePasswordEmail  = $false                   # CHANGE OPTIONAL: $true only with written security approval; emailing passwords is risky
$DriveLetterS = 'S' # CHANGE: common policies drive letter (single letter)
$DriveLetterJ = 'J' # CHANGE: common shared drive letter (single letter)
$DriveLetterHome = 'Z' # CHANGE: personal folder drive letter (single letter)

# ---------------------------
# Logging
# ---------------------------
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$TranscriptPath = Join-Path $OutputDirectory "CombinedUserCreation-$RunStamp.log"
$OperationalLogPath = Join-Path $OutputDirectory "CombinedUserCreation-$RunStamp.csv"
# Plaintext credential export is disabled. The protected input CSV is the only password source.
$CredentialPath = $null
$WelcomeEmailStatePath = Join-Path $OutputDirectory 'WelcomeEmailState.csv'
$Results = [System.Collections.Generic.List[object]]::new()
$Credentials = [System.Collections.Generic.List[object]]::new()
$TranscriptStarted = $false
$CimSession = $null
$CloudConnected = $false
$ExchangeConnected = $false

try {
    Start-Transcript -Path $TranscriptPath -Append -ErrorAction Stop | Out-Null
    $TranscriptStarted = $true
}
catch {
    Write-Host "WARNING: Transcript logging could not start: $($_.Exception.Message)" -ForegroundColor Yellow
}

function Add-Result {
    param(
        [string]$UserName,
        [string]$Upn,
        [string]$Stage,
        [string]$Status,
        [string]$Message
    )

    $script:Results.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        UserName = $UserName
        UserPrincipalName = $Upn
        Stage = $Stage
        Status = $Status
        Message = $Message
    })

    $script:Results |
        Export-Csv -Path $script:OperationalLogPath -NoTypeInformation -Encoding UTF8
}

function Stop-Safely {
    param([string]$Message)

    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host ''
    Add-Result '' '' 'Run' 'Failed' $Message
    Close-OnboardingResources
    exit 1
}

function Close-OnboardingResources {
    param([switch]$KeepTranscript)
    if ($script:CimSession) {
        Remove-CimSession $script:CimSession -ErrorAction SilentlyContinue
        $script:CimSession = $null
    }
    if ($script:ExchangeConnected) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        $script:ExchangeConnected = $false
    }
    if ($script:CloudConnected) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        $script:CloudConnected = $false
    }
    if ($script:TranscriptStarted -and -not $KeepTranscript) {
        try { Stop-Transcript | Out-Null } catch {}
        $script:TranscriptStarted = $false
    }
}

function Get-TextValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim()
}

function Get-AdminFolderPath {
    param([string]$Server,[string]$LocalRoot,[string]$UserName)
    if ($LocalRoot -notmatch '^([A-Za-z]):\\(.+)$') {
        throw 'UserFolderRoot must be a file-server local path such as D:\UserHomes.'
    }
    return "\\$Server\$($matches[1])`$\$($matches[2])\$UserName"
}

function Get-ExpectedBatContent {
    param([string]$ShareName)
    # CHANGE: Drive letters S:, J:, Z: below must match YOUR mapping policy.
    # Example: replace 'S:' with 'P:' in the net use command.
    # S: and J: use $CommonS and $CommonJ; Z: uses each user's hidden share.
    # Keep the # CHANGE comment; it has no effect on execution.
    # CommonS and CommonJ are configured in the CHANGE THESE EXAMPLES block.
    return @"
@echo off
net use ${DriveLetterS}: "$CommonS" /persistent:no
net use ${DriveLetterJ}: "$CommonJ" /persistent:no
net use ${DriveLetterHome}: "\\$FileServer\$ShareName" /persistent:no
"@
}

function Normalize-Text {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace "`r`n","`n" -replace "`r","`n").Trim())
}

function Get-ParentDn {
    param([string]$DistinguishedName)
    $Index = $DistinguishedName.IndexOf(',')
    if ($Index -lt 0) { return '' }
    return $DistinguishedName.Substring($Index + 1)
}

function Escape-AdFilterValue {
    param([string]$Value)
    return $Value.Replace("'", "''")
}

function Escape-LdapValue {
    param([string]$Value)
    $Escaped = $Value.Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29')
    return ($Escaped -replace "`0", '\00')
}

function Get-PrimaryProxyAddress {
    param([object[]]$ProxyAddresses)
    return @($ProxyAddresses | Where-Object { [string]$_ -cmatch '^SMTP:' } | Select-Object -First 1)
}

function Ensure-AdPrimarySmtp {
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$Email
    )

    $Current = Get-ADUser -Identity $Identity -Properties proxyAddresses -ErrorAction Stop
    $Addresses = @($Current.proxyAddresses | ForEach-Object { [string]$_ })
    $ExistingPrimary = @($Addresses | Where-Object { $_ -cmatch '^SMTP:' })

    if ($ExistingPrimary.Count -gt 0) {
        $PrimaryValue = $ExistingPrimary[0].Substring(5)
        if ($PrimaryValue -ine $Email) {
            throw "AD primary SMTP is '$PrimaryValue' instead of '$Email'."
        }
        return 'Existing'
    }

    $NewAddresses = [System.Collections.Generic.List[string]]::new()
    foreach ($Address in $Addresses) {
        if ($Address -imatch '^smtp:' -and $Address.Substring(5) -ieq $Email) {
            continue
        }
        $NewAddresses.Add($Address)
    }
    $NewAddresses.Add("SMTP:$Email")
    Set-ADUser -Identity $Identity -Replace @{ proxyAddresses = @($NewAddresses) } -ErrorAction Stop
    return 'Set'
}

function Wait-ExchangeRecipient {
    param([Parameter(Mandatory)][string]$Identity)
    for ($Attempt = 1; $Attempt -le $script:ExchangeWaitAttempts; $Attempt++) {
        $Recipient = Get-ExchangeRecipientOrNull -Upn $Identity
        if ($Recipient) { return $Recipient }
        if ($Attempt -lt $script:ExchangeWaitAttempts) {
            Write-Host "Waiting for Exchange Online: attempt $Attempt of $($script:ExchangeWaitAttempts)..." -ForegroundColor DarkCyan
            Start-Sleep -Seconds $script:ExchangeWaitSeconds
        }
    }
    throw "The account is not visible in Exchange Online after $($script:ExchangeWaitAttempts * $script:ExchangeWaitSeconds) seconds. Run the same CSV again later; completed items will be kept."
}

function New-SmbShareWithAccountResolutionRetry {
    param(
        [Parameter(Mandatory)][Microsoft.Management.Infrastructure.CimSession]$Session,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$FullAccess,
        [int]$MaximumAttempts = 12,
        [int]$DelaySeconds = 10
    )
    for ($Attempt = 1; $Attempt -le $MaximumAttempts; $Attempt++) {
        try {
            New-SmbShare -CimSession $Session -Name $Name -Path $Path -FullAccess $FullAccess -CachingMode None -ErrorAction Stop | Out-Null
            return
        }
        catch {
            $Message = $_.Exception.Message
            $IsResolutionDelay = $Message -match 'mapping between account names and security IDs|account name.*security ID'
            if (-not $IsResolutionDelay -or $Attempt -eq $MaximumAttempts) { throw }
            Write-Host "Waiting for the new AD account to become resolvable on $FileServer`: attempt $Attempt of $MaximumAttempts..." -ForegroundColor DarkCyan
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Grant-SmbShareAccessWithAccountResolutionRetry {
    param(
        [Parameter(Mandatory)][Microsoft.Management.Infrastructure.CimSession]$Session,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$AccountName,
        [int]$MaximumAttempts = 12,
        [int]$DelaySeconds = 10
    )
    for ($Attempt = 1; $Attempt -le $MaximumAttempts; $Attempt++) {
        try {
            Grant-SmbShareAccess -CimSession $Session -Name $Name -AccountName $AccountName -AccessRight Full -Force -ErrorAction Stop | Out-Null
            return
        }
        catch {
            $Message = $_.Exception.Message
            $IsResolutionDelay = $Message -match 'mapping between account names and security IDs|account name.*security ID'
            if (-not $IsResolutionDelay -or $Attempt -eq $MaximumAttempts) { throw }
            Write-Host "Waiting for $AccountName to become resolvable on $FileServer`: attempt $Attempt of $MaximumAttempts..." -ForegroundColor DarkCyan
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Sync-SmbShareAccess {
    param(
        [Parameter(Mandatory)][Microsoft.Management.Infrastructure.CimSession]$Session,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ExpectedFullAccess
    )

    $CurrentAccess = @(Get-SmbShareAccess -CimSession $Session -Name $Name -ErrorAction Stop)
    if (@($CurrentAccess | Where-Object { $_.AccessControlType.ToString() -eq 'Deny' }).Count -gt 0) {
        throw "Existing SMB share '$Name' contains Deny access entries. Manual review required before any grant."
    }
    $OrphanedEntries = @($CurrentAccess | Where-Object { $_.AccountName -match '^\*S-1-' })
    if ($OrphanedEntries.Count -gt 0) {
        throw "Existing SMB share '$Name' contains unresolved SID access entries. Manual review required; share will not be removed or recreated."
    }

    foreach ($ExpectedAccount in $ExpectedFullAccess) {
        $CorrectEntry = @($CurrentAccess | Where-Object {
            $_.AccountName -ieq $ExpectedAccount -and
            $_.AccessControlType.ToString() -eq 'Allow' -and
            $_.AccessRight.ToString() -eq 'Full'
        })
        if ($CorrectEntry.Count -eq 0) {
            Grant-SmbShareAccessWithAccountResolutionRetry -Session $Session -Name $Name -AccountName $ExpectedAccount
        }
    }

    $VerifiedAccess = @(Get-SmbShareAccess -CimSession $Session -Name $Name -ErrorAction Stop)
    foreach ($ExpectedAccount in $ExpectedFullAccess) {
        $CorrectEntry = @($VerifiedAccess | Where-Object {
            $_.AccountName -ieq $ExpectedAccount -and
            $_.AccessControlType.ToString() -eq 'Allow' -and
            $_.AccessRight.ToString() -eq 'Full'
        })
        if ($CorrectEntry.Count -ne 1) { throw "SMB share permission verification failed for $ExpectedAccount on $Name." }
    }
    $OrphanedEntries = @($VerifiedAccess | Where-Object { $_.AccountName -match '^\*S-1-' })
    if ($OrphanedEntries.Count -gt 0) { throw "SMB share contains unresolved SID entries after reconciliation: $($OrphanedEntries.AccountName -join ', ')." }
}

# Windows-native, non-following entry inspection and single-component creation.
# CreateDirectoryW cannot create missing ancestors and returns ERROR_ALREADY_EXISTS
# rather than modifying the security of a directory created by another operator.
$script:FolderNativeInitialized = $false
function Initialize-PersonalFolderNative {
    if ($script:FolderNativeInitialized) { return }
    if (-not ('OnboardingFolderNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;

public static class OnboardingFolderNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    private struct WIN32_FIND_DATA {
        public uint dwFileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftLastWriteTime;
        public uint nFileSizeHigh;
        public uint nFileSizeLow;
        public uint dwReserved0;
        public uint dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=14)] public string cAlternateFileName;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }
    [DllImport("kernel32.dll", EntryPoint="FindFirstFileW", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr FindFirstFile(string path, out WIN32_FIND_DATA data);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindClose(IntPtr handle);
    [DllImport("kernel32.dll", EntryPoint="CreateDirectoryW", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectory(string path, ref SECURITY_ATTRIBUTES security);

    [DllImport("kernel32.dll", EntryPoint="GetFileAttributesW", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetFileAttributes(string path);

    // Returns -1 only for a genuinely absent entry (error 2/3). A dangling
    // junction/symlink is reported by FindFirstFileW as a reparse point.
    public static long EntryAttributes(string path) {
        // FindFirstFileW cannot inspect drive roots or UNC share roots.
        string root = System.IO.Path.GetPathRoot(path);
        if (!String.IsNullOrEmpty(root) &&
            String.Equals(path.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) {
            uint attrs = GetFileAttributes(path);
            if (attrs == 0xffffffffu) {
                int error = Marshal.GetLastWin32Error();
                if (error == 2 || error == 3) return -1;
                throw new Win32Exception(error, "Unable to inspect root: " + path);
            }
            return (long)attrs;
        }
        WIN32_FIND_DATA data;
        IntPtr h = FindFirstFile(path, out data);
        if (h == new IntPtr(-1)) {
            int error = Marshal.GetLastWin32Error();
            if (error == 2 || error == 3) return -1;
            throw new Win32Exception(error, "Unable to inspect filesystem entry: " + path);
        }
        try { return (long)data.dwFileAttributes; }
        finally { FindClose(h); }
    }
    public static void CreateOneDirectory(string path, DirectorySecurity security) {
        byte[] sd = security.GetSecurityDescriptorBinaryForm();
        IntPtr ptr = Marshal.AllocHGlobal(sd.Length);
        try {
            Marshal.Copy(sd, 0, ptr, sd.Length);
            SECURITY_ATTRIBUTES attrs = new SECURITY_ATTRIBUTES();
            attrs.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            attrs.lpSecurityDescriptor = ptr;
            attrs.bInheritHandle = false;
            if (!CreateDirectory(path, ref attrs)) {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, "Single-component directory creation failed: " + path);
            }
        } finally { Marshal.FreeHGlobal(ptr); }
    }
}
'@ -ErrorAction Stop
    }
    $script:FolderNativeInitialized = $true
}

function Get-SafePathEntryState {
    param([Parameter(Mandatory)][string]$Path)
    Initialize-PersonalFolderNative
    $Attributes = [OnboardingFolderNative]::EntryAttributes($Path)
    if ($Attributes -eq -1) { return 'ABSENT' }
    if (($Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) { return 'CONFLICT' }
    if (($Attributes -band [int][System.IO.FileAttributes]::Directory) -ne 0) { return 'DIRECTORY' }
    return 'CONFLICT'
}

function Assert-NoReparsePointInPath {
    param([Parameter(Mandatory)][string]$Path)
    $Cursor = $Path
    while (-not [string]::IsNullOrWhiteSpace($Cursor)) {
        $State = Get-SafePathEntryState -Path $Cursor
        if ($State -eq 'CONFLICT') {
            throw "Personal-folder path component '$Cursor' is a file or reparse point. Manual review required."
        }
        # Missing ancestors are never implicitly created. Only the final
        # home-folder component may be absent.
        if ($State -eq 'ABSENT' -and $Cursor -ne $Path) {
            throw "Required personal-folder parent '$Cursor' is missing. Manual review required."
        }
        $Parent = Split-Path -Path $Cursor -Parent
        if ([string]::IsNullOrWhiteSpace($Parent) -or $Parent -eq $Cursor) { break }
        $Cursor = $Parent
    }
}

function Get-PersonalFolderPathState {
    param([Parameter(Mandatory)][string]$Path)
    Assert-NoReparsePointInPath -Path $Path
    return (Get-SafePathEntryState -Path $Path)
}

function New-PersonalFolderWithInitialAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$FullControlAccounts
    )
    $Security = [System.Security.AccessControl.DirectorySecurity]::new()
    $Security.SetAccessRuleProtection($true,$false)
    foreach ($Account in $FullControlAccounts) {
        $Rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $Account,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $Security.AddAccessRule($Rule)
    }
    if ((Get-PersonalFolderPathState -Path $Path) -ne 'ABSENT') {
        throw "Personal folder '$Path' is no longer absent. Manual review required."
    }
    # Native CreateDirectoryW creates only the final component, atomically
    # attaching the initial descriptor. ERROR_ALREADY_EXISTS is a hard stop.
    # It does not rewrite an existing/replacement directory ACL.
    [OnboardingFolderNative]::CreateOneDirectory($Path,$Security)
    # The create call succeeded; retain this fact even if later verification
    # fails. The caller records the attempt separately from verified success.
    $script:PersonalFolderCreationSucceeded = $true
    if ((Get-PersonalFolderPathState -Path $Path) -ne 'DIRECTORY') {
        throw "Personal folder path '$Path' changed during creation; manual review required."
    }
    Assert-ExistingPersonalFolderAcl -Path $Path -FullControlAccounts $FullControlAccounts
}

function Assert-ExistingPersonalFolderAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$FullControlAccounts
    )

    # Shared read-only validator for Preview and Apply. Never writes ACLs.
    $Acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (@($Acl.Access | Where-Object {
        $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny
    }).Count -gt 0) {
        throw "Existing folder '$Path' contains Deny ACL entries. Manual review required; no ACL write attempted."
    }
    if (@($Acl.Access | Where-Object {
        $_.IdentityReference -is [System.Security.Principal.SecurityIdentifier]
    }).Count -gt 0) {
        throw "Existing folder '$Path' contains unresolved SID ACL entries. Manual review required; no ACL write attempted."
    }
    foreach ($Account in $FullControlAccounts) {
        $Matching = @($Acl.Access | Where-Object {
            $_.IdentityReference.Value -ieq $Account -and
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq [System.Security.AccessControl.FileSystemRights]::FullControl -and
            ($_.InheritanceFlags -band [System.Security.AccessControl.InheritanceFlags]::ContainerInherit) -ne 0 -and
            ($_.InheritanceFlags -band [System.Security.AccessControl.InheritanceFlags]::ObjectInherit) -ne 0 -and
            ($_.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0 -and
            ($_.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::NoPropagateInherit) -eq 0
        })
        if ($Matching.Count -eq 0) {
            throw "Existing folder '$Path' lacks a Full Control rule covering the folder itself and inheriting to child files/folders for '$Account'. Manual review required; no ACL write attempted."
        }
    }
    # ACL rule presence is not proof of effective access via group tokens and SMB.
}

function Sync-PersonalFolderAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$FullControlAccounts,
        [Parameter(Mandatory)][bool]$ResetToControlledAcl
    )
    # RC7: no path-based ACL writes, even when this run created the folder.
    # The initial ACL is passed to native single-component CreateDirectoryW.
    # A replacement directory cannot have its unrelated Allow rules removed.
    if ($ResetToControlledAcl) {
        throw 'Unsafe post-creation ACL reset is disabled. Initial ACL must be supplied during directory creation.'
    }
    if ((Get-PersonalFolderPathState -Path $Path) -ne 'DIRECTORY') {
        throw "Personal folder '$Path' is no longer a regular directory."
    }
    Assert-ExistingPersonalFolderAcl -Path $Path -FullControlAccounts $FullControlAccounts
}

function Test-CloudGroupMembership {
    param([object]$Group,[string]$Upn)
    $Address = $Group.PrimarySmtpAddress.ToString()
    if ($Group.RecipientTypeDetails -eq 'GroupMailbox') {
        return [bool](Get-UnifiedGroupLinks -Identity $Address -LinkType Members -ResultSize Unlimited -ErrorAction Stop |
            Where-Object { $_.PrimarySmtpAddress -ieq $Upn })
    }
    return [bool](Get-DistributionGroupMember -Identity $Address -ResultSize Unlimited -ErrorAction Stop |
        Where-Object { $_.PrimarySmtpAddress -ieq $Upn })
}

function Add-CloudGroupMembership {
    param([object]$Group,[string]$Upn)
    $Address = $Group.PrimarySmtpAddress.ToString()
    if ($Group.RecipientTypeDetails -eq 'GroupMailbox') {
        Add-UnifiedGroupLinks -Identity $Address -LinkType Members -Links $Upn -Confirm:$false -ErrorAction Stop
    }
    else {
        Add-DistributionGroupMember -Identity $Address -Member $Upn -Confirm:$false -BypassSecurityGroupManagerCheck -ErrorAction Stop
    }
}

function Get-CloudUserOrNull {
    param([Parameter(Mandatory)][string]$Upn)
    try { return Get-MgUser -UserId $Upn -Property Id,DisplayName,GivenName,Surname,UserPrincipalName,AssignedLicenses,OnPremisesSyncEnabled,UsageLocation,JobTitle,Department,CompanyName,EmployeeId,MobilePhone,BusinessPhones,OfficeLocation,State,Country -ErrorAction Stop }
    catch {
        $Status = $_.Exception.ResponseStatusCode
        if ($Status -eq 404 -or [string]$Status -eq 'NotFound') { return $null }
        throw "Cloud lookup failed for '$Upn'; not assuming user is missing: $($_.Exception.Message)"
    }
}
function Get-ExchangeRecipientOrNull {
    param([Parameter(Mandatory)][string]$Upn)
    try { return Get-Recipient -Identity $Upn -ErrorAction Stop }
    catch {
        $ExceptionName = $_.Exception.GetType().FullName
        if ($ExceptionName -match 'ManagementObjectNotFoundException|ObjectNotFoundException') { return $null }
        throw "Exchange lookup failed for '$Upn'; not assuming recipient is missing: $($_.Exception.Message)"
    }
}

function Get-WelcomeEmailState {
    param([Parameter(Mandatory)][string]$Upn)
    if (-not (Test-Path -LiteralPath $script:WelcomeEmailStatePath -PathType Leaf)) { return $null }
    return @(Import-Csv -LiteralPath $script:WelcomeEmailStatePath -ErrorAction Stop |
        Where-Object { $_.UserPrincipalName -ieq $Upn } |
        Select-Object -Last 1)[0]
}

function Set-WelcomeEmailState {
    param(
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][ValidateSet('Pending','Accepted','Failed','Suppressed')][string]$Status,
        [Parameter(Mandatory)][string]$Message
    )
    $Records = @()
    if (Test-Path -LiteralPath $script:WelcomeEmailStatePath -PathType Leaf) {
        $Records = @(Import-Csv -LiteralPath $script:WelcomeEmailStatePath -ErrorAction Stop |
            Where-Object { $_.UserPrincipalName -ine $Upn })
    }
    $Records += [pscustomobject]@{
        UserPrincipalName = $Upn
        Status = $Status
        UpdatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Message = $Message
    }
    $TemporaryStatePath = "$($script:WelcomeEmailStatePath).tmp"
    # Normalize legacy state records; never carry forward password-derived fields.
    $Records | Select-Object UserPrincipalName,Status,UpdatedAt,Message | Export-Csv -LiteralPath $TemporaryStatePath -NoTypeInformation -Encoding UTF8
    Move-Item -LiteralPath $TemporaryStatePath -Destination $script:WelcomeEmailStatePath -Force
}

function ConvertTo-HtmlText {
    param([string]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-WelcomeEmailHtml {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$OrganizationEmail,
        [Parameter(Mandatory)][string]$TemporaryPassword
    )
    # CHANGE: Customize the welcome email greeting, helpdesk, sign-in URL, MFA instructions,
    # and signature in the HTML below to match YOUR organization.
    # CAUTION: This template includes the temporary password. Sending it by email is risky;
    # use only with written authorization and verified recipients.
    $SafeName = ConvertTo-HtmlText $DisplayName
    $SafeEmail = ConvertTo-HtmlText $OrganizationEmail
    $SafePassword = ConvertTo-HtmlText $TemporaryPassword
    return @"
<html><body style="font-family:Segoe UI,Arial,sans-serif;line-height:1.5">
<p>Dear $SafeName,</p>
<p>Welcome to our organization. Your new account has been prepared.</p>
<p><strong>Sign-in:</strong> $SafeEmail</p>
<p><strong>Temporary password:</strong> $SafePassword</p>
<p>Sign in at <a href="https://www.office.com">https://www.office.com</a> and change your password when prompted.</p>
<p>Register Microsoft Authenticator if your organization requires MFA: <a href="https://aka.ms/mfasetup">https://aka.ms/mfasetup</a>.</p>
<p>Never share your password. Contact your organization's IT helpdesk for assistance.</p>
<p>IT Support</p>
</body></html>
"@
}

function Send-OrganizationWelcomeEmail {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$PersonalEmail,
        [Parameter(Mandatory)][string]$OrganizationEmail,
        [Parameter(Mandatory)][string]$TemporaryPassword
    )
    $HtmlBody = New-WelcomeEmailHtml -DisplayName $DisplayName -OrganizationEmail $OrganizationEmail -TemporaryPassword $TemporaryPassword
    $Message = @{
        Subject = $script:WelcomeEmailSubject
        Body = @{ ContentType = 'HTML'; Content = $HtmlBody }
        From = @{ EmailAddress = @{ Address = $script:WelcomeEmailSender } }
        ToRecipients = @(
            @{ EmailAddress = @{ Address = $PersonalEmail } },
            @{ EmailAddress = @{ Address = $OrganizationEmail } }
        )
        CcRecipients = @(@{ EmailAddress = @{ Address = $script:WelcomeEmailCc } })
    }
    if ([string]::IsNullOrWhiteSpace([string]$script:CurrentAdminAccount)) {
        throw 'The authorized Microsoft 365 operator was not established before welcome-email submission.'
    }
    Send-MgUserMail -UserId $script:CurrentAdminAccount -BodyParameter @{ Message = $Message; SaveToSentItems = $true } -ErrorAction Stop
}

trap {
    $UnhandledMessage = $_.Exception.Message
    try { Add-Result '' '' 'Unhandled error' 'Failed' $UnhandledMessage } catch {}
    Write-Host "UNHANDLED ERROR: $UnhandledMessage" -ForegroundColor Red
    Close-OnboardingResources
    exit 1
}

# Setup completion marker is written ONLY by First-Time-Setup.bat.
$SetupMarker = Join-Path $PSScriptRoot '.organization-setup-complete'
if (-not (Test-Path -LiteralPath $SetupMarker)) { Stop-Safely 'First run First-Time-Setup.bat and finish the configuration wizard.' }
# Hard stop if any mandatory environment example has not been replaced.
$Unconfigured = @()
if ($FileServer -eq 'FS01.corp.example.com') { $Unconfigured += 'FileServer' }
if ($UserFolderRoot -eq 'D:\UserHomes') { $Unconfigured += 'UserFolderRoot' }
if ($UpnSuffix -eq 'example.com') { $Unconfigured += 'UpnSuffix' }
if ($PrinterGroupName -eq 'GG-Office-Printers') { $Unconfigured += 'PrinterGroupName' }
if ($PrinterGroupDN -like '*DC=example,*') { $Unconfigured += 'PrinterGroupDN' }
if ($CommonS -like '*FS01.corp.example.com*' -or $CommonJ -like '*FS01.corp.example.com*') { $Unconfigured += 'CommonS/CommonJ' }
if ($AllowedAdminAccounts -contains 'admin@example.com') { $Unconfigured += 'AllowedAdminAccounts' }
if ($EnablePasswordEmail -and ($WelcomeEmailSender -eq 'onboarding@example.com' -or $WelcomeEmailCc -eq 'helpdesk@example.com')) { $Unconfigured += 'WelcomeEmailSender/WelcomeEmailCc' }
if ($LicenseSkuPartNumber -eq 'ENTER_YOUR_LICENSE_SKU') { $Unconfigured += 'LicenseSkuPartNumber' }
if ($GroupAddresses -contains 'staff-group@example.com') { $Unconfigured += 'GroupAddresses' }
if ($UsageLocation -eq 'ZZ') { $Unconfigured += 'UsageLocation' }
if ($AdCountryCode -eq 0) { $Unconfigured += 'AdCountryCode' }
if ($Unconfigured.Count -gt 0) { Stop-Safely ('Replace example configuration values before running: ' + ($Unconfigured -join ', ')) }

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' GENERIC COMBINED AD + MICROSOFT 365 USER ONBOARDING' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "Cloud identity: independent AD and Microsoft 365 accounts (no synchronization)" -ForegroundColor Cyan
Write-Host "Input CSV          : $CsvPath"
Write-Host "Transcript         : $TranscriptPath"
Write-Host "Operational log    : $OperationalLogPath"
Write-Host ''

# ============================================================
# GLOBAL PRE-FLIGHT - NO CHANGES
# ============================================================

Write-Host 'Running global pre-flight checks. No changes are being made...' -ForegroundColor Cyan

$RequiredModules = @(
    'ActiveDirectory',
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Users.Actions',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'ExchangeOnlineManagement'
)
$MissingModules = @($RequiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
if ($MissingModules.Count -gt 0) {
    Stop-Safely "Required modules are missing: $($MissingModules -join ', ')."
}

Import-Module ActiveDirectory -ErrorAction Stop
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module Microsoft.Graph.Users.Actions -ErrorAction Stop
Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
Import-Module ExchangeOnlineManagement -ErrorAction Stop

if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
    Stop-Safely "CSV file not found: $CsvPath"
}

try { $Domain = Get-ADDomain -ErrorAction Stop }
catch { Stop-Safely "Unable to read Active Directory domain. $($_.Exception.Message)" }

$DomainNetBIOS = $Domain.NetBIOSName
$DomainDNS = $Domain.DNSRoot
$NetlogonPath = "\\$DomainDNS\NETLOGON"
$AdminRoot = Get-AdminFolderPath -Server $FileServer -LocalRoot $UserFolderRoot -UserName '__preflight_probe__'
$AdminRoot = Split-Path -Path $AdminRoot -Parent

try { Assert-NoReparsePointInPath -Path $AdminRoot }
catch { Stop-Safely "Personal-folder root is unsafe or inaccessible: $($_.Exception.Message)" }
foreach ($RequiredPath in @($NetlogonPath,$CommonS,$CommonJ,$AdminRoot)) {
    if (-not (Test-Path $RequiredPath)) {
        Stop-Safely "Required path cannot be accessed: $RequiredPath"
    }
}

try { $PrinterGroupObject = Get-ADGroup -Identity $PrinterGroupDN -ErrorAction Stop }
catch { Stop-Safely "Printer security group was not found: $PrinterGroupDN. $($_.Exception.Message)" }

try {
    $CimOption = New-CimSessionOption -Protocol Dcom
    $CimSession = New-CimSession -ComputerName $FileServer -SessionOption $CimOption -ErrorAction Stop
    Get-SmbShare -CimSession $CimSession -ErrorAction Stop | Out-Null
}
catch { Stop-Safely "Cannot manage SMB shares on $FileServer through CIM/DCOM. $($_.Exception.Message)" }

try { $Rows = @(Import-Csv -Path $CsvPath -ErrorAction Stop) }
catch { Stop-Safely "Unable to read the CSV. $($_.Exception.Message)" }
if ($Rows.Count -eq 0) { Stop-Safely 'The CSV contains no users.' }

$RequiredColumns = @(
    'UserName','GivenName','Surname','DisplayName','UserPrincipalName','MailNickname',
    'InitialPassword','PersonalEmail','OU','JobTitle','Department','CompanyName','EmployeeId',
    'MobilePhone','BusinessPhone','OfficeLocation','State','Country'
)
$ActualColumns = @($Rows[0].PSObject.Properties.Name)
foreach ($Column in $RequiredColumns) {
    if ($ActualColumns -notcontains $Column) {
        Stop-Safely "CSV is missing required column: $Column"
    }
}

foreach ($Row in $Rows) {
    foreach ($Column in $RequiredColumns) {
        if ($Column -eq 'InitialPassword') { $Row.$Column = [string]$Row.$Column }
        else { $Row.$Column = (Get-TextValue $Row.$Column) }
    }
    $Row.OU = $Row.OU.Trim('"')
}

# Validate local CSV identity/path components BEFORE any per-row remote reads.
$LocalCsvErrors = [System.Collections.Generic.List[string]]::new()
foreach ($LocalRow in $Rows) {
    $Name = [string]$LocalRow.UserName
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $Name -match '[.]$' -or $Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or $Name.Length -gt 20) {
        $LocalCsvErrors.Add("Unsafe UserName '$Name'.")
    }
    if ([string]$LocalRow.UserPrincipalName -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        $LocalCsvErrors.Add("Invalid UserPrincipalName for '$Name'.")
    }
}
if ($LocalCsvErrors.Count) { Stop-Safely "Local CSV validation failed: $($LocalCsvErrors -join '; ')" }

$PreflightErrors = [System.Collections.Generic.List[string]]::new()
$DuplicateUserNames = @($Rows | Group-Object { ([string]$_.UserName).Trim().ToLowerInvariant() } | Where-Object { $_.Count -gt 1 -or [string]::IsNullOrWhiteSpace($_.Name) })
$DuplicateUpns = @($Rows | Group-Object { ([string]$_.UserPrincipalName).Trim().ToLowerInvariant() } | Where-Object { $_.Count -gt 1 -or [string]::IsNullOrWhiteSpace($_.Name) })
if ($DuplicateUserNames.Count -gt 0) { $PreflightErrors.Add("Duplicate or blank UserName values: $($DuplicateUserNames.Name -join ', ')") }
if ($DuplicateUpns.Count -gt 0) { $PreflightErrors.Add("Duplicate or blank UserPrincipalName values: $($DuplicateUpns.Name -join ', ')") }

if ($ExpectedTenantId -notmatch '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' -or $ExpectedTenantId -in @('00000000-0000-0000-0000-000000000000','11111111-2222-3333-4444-555555555555')) {
    Stop-Safely 'ExpectedTenantId must be set to the actual Microsoft Entra tenant GUID before any cloud connection.'
}
try {
    Connect-MgGraph -TenantId $ExpectedTenantId -Scopes $(if ($EnablePasswordEmail) { @('User.ReadWrite.All','Directory.ReadWrite.All','Organization.Read.All','Mail.Send','Mail.Send.Shared') } else { @('User.ReadWrite.All','Directory.ReadWrite.All','Organization.Read.All') }) -NoWelcome
    $CloudConnected = $true
    $GraphContext = Get-MgContext
    if ([string]$GraphContext.TenantId -ine $ExpectedTenantId) {
        throw "Microsoft Graph tenant mismatch. Expected $ExpectedTenantId; connected to $($GraphContext.TenantId)."
    }
    $CurrentAdminAccount = ([string]$GraphContext.Account).Trim()
    if ([string]::IsNullOrWhiteSpace($CurrentAdminAccount) -or $AllowedAdminAccounts -notcontains $CurrentAdminAccount) {
        throw "Microsoft Graph is signed in as '$CurrentAdminAccount'. Authorized operators: $($AllowedAdminAccounts -join ', ')."
    }
    foreach ($RequiredScope in $(if ($EnablePasswordEmail) { @('Mail.Send','Mail.Send.Shared') } else { @() })) {
        if ($GraphContext.Scopes -notcontains $RequiredScope) { throw "Microsoft Graph consent is missing scope '$RequiredScope'." }
    }
    Connect-ExchangeOnline -UserPrincipalName $CurrentAdminAccount -ShowBanner:$false
    $ExchangeConnected = $true
    $ExchangeOrganization = Get-OrganizationConfig -ErrorAction Stop
    $ExchangeTenantId = [string]$ExchangeOrganization.ExternalDirectoryOrganizationId
    if ($ExchangeTenantId -ine $ExpectedTenantId) {
        throw "Exchange Online tenant mismatch or tenant ID unavailable. Expected $ExpectedTenantId; received '$ExchangeTenantId'."
    }
}
catch { Stop-Safely "Microsoft 365 connection failed. $($_.Exception.Message)" }

try {
    $Sku = Get-MgSubscribedSku -All | Where-Object SkuPartNumber -eq $LicenseSkuPartNumber
    if (-not $Sku) { throw "Licence SKU '$LicenseSkuPartNumber' was not found." }
    if (@($Sku).Count -ne 1) { throw "Expected one exact SKU match for '$LicenseSkuPartNumber'; found $(@($Sku).Count)." }

    $CloudGroups = @(
        foreach ($GroupAddress in $GroupAddresses) {
            $ResolvedGroup = Get-Recipient -Identity $GroupAddress -ErrorAction Stop
            if ($ResolvedGroup.RecipientTypeDetails -notin @('MailUniversalDistributionGroup','MailUniversalSecurityGroup','GroupMailbox')) {
                throw "'$GroupAddress' is not a supported mail group."
            }
            $ResolvedGroup
        }
    )
    if ($EnablePasswordEmail) {
    $SenderMailbox = Get-EXOMailbox -Identity $WelcomeEmailSender -ErrorAction Stop
    if ($SenderMailbox.RecipientTypeDetails -ne 'UserMailbox') {
        throw "Welcome sender '$WelcomeEmailSender' is not a UserMailbox."
    }
    $SendAsPermission = @(Get-RecipientPermission -Identity $WelcomeEmailSender -Trustee $CurrentAdminAccount -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Deny -and $_.AccessRights -contains 'SendAs' })
    if ($SendAsPermission.Count -eq 0) {
        throw "'$CurrentAdminAccount' does not have SendAs permission for '$WelcomeEmailSender'."
    }
    }
    Add-Result '' '' 'Operator authentication' 'Success' "Authorized operator '$CurrentAdminAccount' confirmed for Microsoft Graph and Exchange Online; Password email enabled: $EnablePasswordEmail."
    Write-Host "Authorized operator confirmed: $CurrentAdminAccount" -ForegroundColor Green
}
catch { Stop-Safely "Microsoft 365 pre-flight failed. $($_.Exception.Message)" }

$Plan = [System.Collections.Generic.List[object]]::new()
$PreparedRows = [System.Collections.Generic.List[object]]::new()

foreach ($Row in $Rows) {
    $UserName = $Row.UserName
    $Upn = $Row.UserPrincipalName.ToLowerInvariant()
    $MailNickname = if ([string]::IsNullOrWhiteSpace($Row.MailNickname)) { $UserName } else { $Row.MailNickname }
    if ($UserName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $UserName -match '[.]$' -or $UserName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or $UserName.Length -gt 20) {
        $PreflightErrors.Add("Invalid or unsafe UserName '$UserName'; no remote operations will be performed for this row.")
        continue
    }
    $ShareName = "$UserName`$"
    $BatFileName = "$UserName.bat"
    $BatFilePath = "$NetlogonPath\$BatFileName"
    $LocalFolderPath = "$UserFolderRoot\$UserName"
    $AdminFolderPath = Get-AdminFolderPath -Server $FileServer -LocalRoot $UserFolderRoot -UserName $UserName
    $ExpectedBatContent = Get-ExpectedBatContent -ShareName $ShareName
    $Password = [string]$Row.InitialPassword
    $ExistingEmailState = Get-WelcomeEmailState -Upn $Upn

    $AdAction = ''
    $PrinterAction = ''
    $FolderAction = ''
    $ShareAction = ''
    $BatAction = ''
    $CloudAction = ''
    $LicenseAction = ''
    $GroupAction = ''

    if ($UserName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $UserName -match '[.]$' -or $UserName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { $PreflightErrors.Add("$UserName : UserName contains unsupported characters.") }
    if ($UserName.Length -gt 20) { $PreflightErrors.Add("$UserName : UserName exceeds the 20-character sAMAccountName limit.") }
    if ($Upn -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $PreflightErrors.Add("$UserName : invalid UserPrincipalName '$Upn'.") }
    if ($Upn -ine "$UserName@$UpnSuffix") { $PreflightErrors.Add("$UserName : UserPrincipalName must be '$UserName@$UpnSuffix'.") }
    if ($MailNickname -ine $UserName) { $PreflightErrors.Add("$UserName : MailNickname must match UserName for consistent identity matching.") }
    foreach ($RequiredValue in @('GivenName','Surname','DisplayName','MailNickname','OU','JobTitle','Department','CompanyName','State','Country')) {
        if ([string]::IsNullOrWhiteSpace([string]$Row.$RequiredValue)) {
            $PreflightErrors.Add("$UserName : required field '$RequiredValue' is blank.")
        }
    }
    # Creation-only password requirement is evaluated after both identities are looked up.
    foreach ($PhoneColumn in @('MobilePhone','BusinessPhone')) {
        $PhoneValue = [string]$Row.$PhoneColumn
        if ($PhoneValue -match '^[-+]?\d+(\.\d+)?E[-+]?\d+$') {
            $PreflightErrors.Add("$UserName : $PhoneColumn appears in scientific notation ('$PhoneValue'). Format the CSV value as text and enter the complete phone number.")
        }
    }

    try { Get-ADOrganizationalUnit -Identity $Row.OU -ErrorAction Stop | Out-Null }
    catch { $PreflightErrors.Add("$UserName : OU does not exist -> $($Row.OU)") }

    $SafeUserName = Escape-AdFilterValue $UserName
    $SafeUpn = Escape-AdFilterValue $Upn
    $ExistingAd = Get-ADUser -Filter "SamAccountName -eq '$SafeUserName'" -Properties Enabled,ScriptPath,DistinguishedName,GivenName,Surname,DisplayName,Title,Department,Company,EmployeeID,MobilePhone,OfficePhone,Office,State,Country,co,mail,UserPrincipalName,MemberOf,proxyAddresses -ErrorAction Stop
    $AdIdentityMatches = @(Get-ADUser -Filter "UserPrincipalName -eq '$SafeUpn' -or mail -eq '$SafeUpn'" -Properties SamAccountName,DistinguishedName,UserPrincipalName,mail,proxyAddresses -ErrorAction Stop)
    $LdapUpn = Escape-LdapValue $Upn
    $AdProxyMatches = @(Get-ADUser -LDAPFilter "(proxyAddresses=smtp:$LdapUpn)" -Properties SamAccountName,DistinguishedName,UserPrincipalName,mail,proxyAddresses -ErrorAction Stop)
    $AllAdMatches = @($AdIdentityMatches + $AdProxyMatches | Sort-Object DistinguishedName -Unique)
    foreach ($Match in $AllAdMatches) {
        if ($Match.SamAccountName -ine $UserName) {
            $PreflightErrors.Add("$UserName : UPN/email '$Upn' is already used by AD account '$($Match.SamAccountName)' in '$(Get-ParentDn $Match.DistinguishedName)'.")
        }
    }

    if ($ExistingAd) {
        $ExistingOu = Get-ParentDn $ExistingAd.DistinguishedName
        if ($ExistingOu -ne $Row.OU) { $PreflightErrors.Add("$UserName : existing AD user is in '$ExistingOu' but CSV specifies '$($Row.OU)'.") }
        if (-not $ExistingAd.Enabled) { $PreflightErrors.Add("$UserName : existing AD user is disabled; it will not be enabled automatically.") }
        if ($ExistingAd.UserPrincipalName -and $ExistingAd.UserPrincipalName -ine $Upn) { $PreflightErrors.Add("$UserName : existing AD UPN is '$($ExistingAd.UserPrincipalName)' instead of '$Upn'.") }
        $PrimaryProxy = @(Get-PrimaryProxyAddress $ExistingAd.proxyAddresses)
        if ($PrimaryProxy.Count -gt 0 -and $PrimaryProxy[0].Substring(5) -ine $Upn) {
            $PreflightErrors.Add("$UserName : existing AD primary SMTP is '$($PrimaryProxy[0].Substring(5))' instead of '$Upn'.")
        }
        $NeedsUpdate =
            ([string]$ExistingAd.GivenName -ne $Row.GivenName) -or
            ([string]$ExistingAd.Surname -ne $Row.Surname) -or
            ([string]$ExistingAd.DisplayName -ne $Row.DisplayName) -or
            ([string]$ExistingAd.Title -ne $Row.JobTitle) -or
            ([string]$ExistingAd.Department -ne $Row.Department) -or
            ([string]$ExistingAd.Company -ne $Row.CompanyName) -or
            ([string]$ExistingAd.mail -ne $Upn) -or
            ([string]$ExistingAd.UserPrincipalName -ne $Upn) -or
            ($PrimaryProxy.Count -eq 0) -or
            ((Get-TextValue $Row.EmployeeId) -and ([string]$ExistingAd.EmployeeID -ne $Row.EmployeeId)) -or
            ((Get-TextValue $Row.MobilePhone) -and ([string]$ExistingAd.MobilePhone -ne $Row.MobilePhone)) -or
            ((Get-TextValue $Row.BusinessPhone) -and ([string]$ExistingAd.OfficePhone -ne $Row.BusinessPhone)) -or
            ((Get-TextValue $Row.OfficeLocation) -and ([string]$ExistingAd.Office -ne $Row.OfficeLocation)) -or
            ((Get-TextValue $Row.State) -and ([string]$ExistingAd.State -ne $Row.State)) -or
            ((Get-TextValue $Row.Country) -and ([string]$ExistingAd.co -ne $Row.Country))
        $AdAction = if ($NeedsUpdate) { 'EXISTS - UPDATE' } else { 'EXISTS - KEEP' }
    }
    else { $AdAction = 'CREATE' }

    $PrinterAction = if ($ExistingAd -and $ExistingAd.MemberOf -contains $PrinterGroupObject.DistinguishedName) { 'EXISTS - KEEP' } else { 'ADD' }
    $FolderAction = 'CONFLICT'
    try {
        $FolderPathState = Get-PersonalFolderPathState -Path $AdminFolderPath
        switch ($FolderPathState) {
            'ABSENT'    { $FolderAction = 'CREATE' }
            'DIRECTORY' { $FolderAction = 'VERIFY' }
            default {
                $PreflightErrors.Add("$UserName : personal folder path '$AdminFolderPath' exists but is not a directory. Resolve manually before Apply.")
            }
        }
    } catch {
        $PreflightErrors.Add("$UserName : personal folder path '$AdminFolderPath' could not be inspected. Resolve manually before Apply: $($_.Exception.Message)")
    }
    if ($FolderAction -eq 'VERIFY') {
        try {
            $ExpectedNtfsAccounts = @(
                "$DomainNetBIOS\$UserName",
                "$DomainNetBIOS\Domain Admins",
                'BUILTIN\Administrators',
                'NT AUTHORITY\SYSTEM'
            )
            Assert-ExistingPersonalFolderAcl -Path $AdminFolderPath -FullControlAccounts $ExpectedNtfsAccounts
        } catch {
            $PreflightErrors.Add("$UserName : existing folder ACL requires manual review before Apply: $($_.Exception.Message)")
        }
    }

    $ExistingShare = @(Get-SmbShare -CimSession $CimSession -ErrorAction Stop | Where-Object Name -eq $ShareName | Select-Object -First 1)[0]
    if ($ExistingShare) {
        if ($ExistingShare.Path -ieq $LocalFolderPath) {
            $ShareAction = 'VERIFY/REPAIR'
            try {
                $ShareAces = @(Get-SmbShareAccess -CimSession $CimSession -Name $ShareName -ErrorAction Stop)
                if (@($ShareAces | Where-Object { $_.AccessControlType.ToString() -eq 'Deny' }).Count -gt 0) {
                    $PreflightErrors.Add("$UserName : existing SMB share has Deny permissions. Manual review required before Apply.")
                }
                if (@($ShareAces | Where-Object { $_.AccountName -match '^\*S-1-' }).Count -gt 0) {
                    $PreflightErrors.Add("$UserName : existing SMB share contains unresolved SID entries. Repair manually before Apply.")
                }
            } catch { $PreflightErrors.Add("$UserName : cannot inspect existing share access: $($_.Exception.Message)") }
        }
        else {
            $ShareAction = 'CONFLICT'
            $PreflightErrors.Add("$UserName : share \\$FileServer\$ShareName points to '$($ExistingShare.Path)' instead of '$LocalFolderPath'.")
        }
    }
    else { $ShareAction = 'CREATE' }

    if (Test-Path $BatFilePath) {
        try {
            $ExistingBat = Get-Content -Path $BatFilePath -Raw -ErrorAction Stop
            if ((Normalize-Text $ExistingBat) -eq (Normalize-Text $ExpectedBatContent)) { $BatAction = 'EXISTS - KEEP' }
            else {
                $BatAction = 'CONFLICT'
                $PreflightErrors.Add("$UserName : existing BAT content is different -> $BatFilePath")
            }
        }
        catch {
            $BatAction = 'CONFLICT'
            $PreflightErrors.Add("$UserName : existing BAT cannot be read -> $BatFilePath")
        }
    }
    else { $BatAction = 'CREATE' }

    $CloudUser = Get-CloudUserOrNull -Upn $Upn
    $CloudRecipient = Get-ExchangeRecipientOrNull -Upn $Upn
    if (-not $ExistingAd -or -not $CloudUser) {
        if ([string]::IsNullOrWhiteSpace($Password) -or $Password -in @('EXAMPLE-DO-NOT-USE','CHANGE_ME','KEEP_EXISTING','EXISTING_USER_NO_CHANGE','REPLACE_WITH_TEMP_PASSWORD')) {
            $PreflightErrors.Add("$UserName : a real InitialPassword is required when either identity must be created; placeholders are not accepted.")
        }
    }
    $BothAccountsInitiallyMissing = (-not $ExistingAd -and -not $CloudUser)
    $WelcomeEmailEligibleAtStart = ($EnablePasswordEmail -and $BothAccountsInitiallyMissing -and $ExistingEmailState.Status -ne 'Accepted')
    if ($WelcomeEmailEligibleAtStart) {
        if ([string]::IsNullOrWhiteSpace([string]$Row.PersonalEmail) -or $Row.PersonalEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' -or $Row.PersonalEmail -ieq $Upn) {
            $PreflightErrors.Add("$UserName : a valid PersonalEmail different from the organization UPN is required when sending a welcome email.")
        }
    }
    $WelcomeEmailPlan = if ($WelcomeEmailEligibleAtStart) {
        'SEND AFTER VERIFY'
    }
    elseif (-not $BothAccountsInitiallyMissing) {
        'DO NOT SEND - EXISTING IDENTITY'
    }
    elseif ($ExistingEmailState.Status -eq 'Accepted') {
        'DO NOT SEND - ALREADY ACCEPTED'
    }
    else {
        'DO NOT SEND - IDENTITY MODE'
    }
    if ($WelcomeEmailEligibleAtStart -and $ExistingEmailState -and $ExistingEmailState.Status -in @('Pending','Failed')) {
        $PreflightErrors.Add("$UserName : prior welcome-email attempt was incomplete. Review the existing account and delivery status manually; automated password-email retry is blocked.")
    }
    if ($CloudUser) {
        if ($CloudUser.OnPremisesSyncEnabled -eq $true) {
            $CloudAction = 'CONFLICT - SYNCHRONIZED CLOUD IDENTITY'
            $PreflightErrors.Add("$UserName : cloud account '$Upn' is synchronized. This direct-only tool cannot manage synchronized cloud identities.")
        }
        else {
            $CloudProfileNeedsUpdate =
                ([string]$CloudUser.DisplayName -ne $Row.DisplayName) -or
                ([string]$CloudUser.GivenName -ne $Row.GivenName) -or
                ([string]$CloudUser.Surname -ne $Row.Surname) -or
                ([string]$CloudUser.JobTitle -ne $Row.JobTitle) -or
                ([string]$CloudUser.Department -ne $Row.Department) -or
                ([string]$CloudUser.CompanyName -ne $Row.CompanyName) -or
                ([string]$CloudUser.UsageLocation -ne $UsageLocation) -or
                ((Get-TextValue $Row.EmployeeId) -and ([string]$CloudUser.EmployeeId -ne $Row.EmployeeId)) -or
                ((Get-TextValue $Row.MobilePhone) -and ([string]$CloudUser.MobilePhone -ne $Row.MobilePhone)) -or
                ((Get-TextValue $Row.BusinessPhone) -and (@($CloudUser.BusinessPhones) -notcontains $Row.BusinessPhone)) -or
                ((Get-TextValue $Row.OfficeLocation) -and ([string]$CloudUser.OfficeLocation -ne $Row.OfficeLocation)) -or
                ((Get-TextValue $Row.State) -and ([string]$CloudUser.State -ne $Row.State)) -or
                ((Get-TextValue $Row.Country) -and ([string]$CloudUser.Country -ne $Row.Country))
            $CloudAction = if ($CloudProfileNeedsUpdate) { 'EXISTS - UPDATE' } else { 'EXISTS - KEEP' }
        }
    }
    elseif ($CloudRecipient) {
        $CloudAction = 'CONFLICT'
        $PreflightErrors.Add("$UserName : Exchange recipient '$Upn' exists but the matching Entra user was not found.")
    }
    else { $CloudAction = 'CREATE DIRECT' }

    if ($CloudUser -and $Sku.SkuId -in @($CloudUser.AssignedLicenses | ForEach-Object SkuId)) { $LicenseAction = 'EXISTS - KEEP' }
    else { $LicenseAction = 'ASSIGN' }

    if ($CloudRecipient) {
        $MissingGroups = @($CloudGroups | Where-Object { -not (Test-CloudGroupMembership -Group $_ -Upn $Upn) })
        $GroupAction = if ($MissingGroups.Count -eq 0) { 'EXISTS - KEEP' } else { "ADD $($MissingGroups.Count)" }
    }
    else { $GroupAction = 'ADD AFTER EXCHANGE' }

    $Plan.Add([pscustomobject]@{
        UserName = $UserName
        AD = $AdAction
        Printer = $PrinterAction
        Folder = $FolderAction
        Share = $ShareAction
        BAT = $BatAction
        Cloud = $CloudAction
        Licence = $LicenseAction
        Groups = $GroupAction
        WelcomeEmail = $WelcomeEmailPlan
    })

    $PreparedRows.Add([pscustomobject]@{
        Source = $Row
        UserName = $UserName
        Upn = $Upn
        MailNickname = $MailNickname
        Password = $Password
        ExistingAd = $ExistingAd
        ExistingCloud = $CloudUser
        BothAccountsInitiallyMissing = $BothAccountsInitiallyMissing
        WelcomeEmailEligibleAtStart = $WelcomeEmailEligibleAtStart
        WelcomeEmailPlan = $WelcomeEmailPlan
        ShareName = $ShareName
        BatFileName = $BatFileName
        BatFilePath = $BatFilePath
        LocalFolderPath = $LocalFolderPath
        AdminFolderPath = $AdminFolderPath
        ExpectedBatContent = $ExpectedBatContent
    })
}

if ($PreflightErrors.Count -gt 0) {
    Write-Host ''
    Write-Host 'PRE-FLIGHT FAILED. NOTHING HAS BEEN CHANGED.' -ForegroundColor Red
    Write-Host ''
    $Plan | Format-Table -AutoSize
    Write-Host ''
    Write-Host 'Conflicts / errors:' -ForegroundColor Red
    foreach ($Item in $PreflightErrors) {
        Write-Host " - $Item" -ForegroundColor Yellow
        Add-Result '' '' 'Pre-flight' 'Failed' $Item
    }
    Stop-Safely 'Correct all pre-flight errors and run the same CSV again.'
}

Write-Host ''
# Check currently available seats for planned new assignments before any provisioning write; this does not reserve seats.
$SeatsRequired = @($Plan | Where-Object { $_.Licence -eq 'ASSIGN' }).Count
$AvailableSeats = [int]$Sku.PrepaidUnits.Enabled - [int]$Sku.ConsumedUnits
if ($SeatsRequired -gt 0 -and $AvailableSeats -lt $SeatsRequired) {
    Stop-Safely "Insufficient available licences for '$LicenseSkuPartNumber': $AvailableSeats available; $SeatsRequired planned assignments."
}
Write-Host "Pre-flight checks passed for all $($Rows.Count) user(s)." -ForegroundColor Green
Write-Host ''
Write-Host 'Planned actions:' -ForegroundColor Cyan
$Plan | Format-Table -AutoSize
Write-Host ''
Write-Host 'CREATE/ADD/ASSIGN = missing item will be completed' -ForegroundColor DarkCyan
Write-Host 'EXISTS - KEEP     = existing correct item will not be recreated' -ForegroundColor DarkCyan
Write-Host 'EXISTS - UPDATE   = existing account stays; approved profile fields are updated without changing its password' -ForegroundColor DarkCyan
Write-Host 'VERIFY/REPAIR     = existing folder/share permissions are reconciled and verified' -ForegroundColor DarkCyan
Write-Host 'DO NOT SEND       = either AD or cloud identity existed at pre-flight; passwords are preserved' -ForegroundColor DarkCyan
Write-Host ''

if (-not $WhatIfPreference -and $EnablePasswordEmail) {
    $EmailConsent = Read-Host 'Plaintext passwords will be emailed. Type I ACCEPT EMAIL RISK to authorize'
    if ($EmailConsent -cne 'I ACCEPT EMAIL RISK') { Stop-Safely 'Password email risk was not accepted.' }
}
if (-not $WhatIfPreference) {
    $Confirmation = Read-Host "Type CREATE to perform the planned independent AD and Microsoft 365 actions"
    if ($Confirmation -cne 'CREATE') {
        Add-Result '' '' 'Run' 'Cancelled' 'Operator did not enter the exact confirmation word CREATE.'
        Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow
        Close-OnboardingResources
        exit 0
    }
}

if (-not $PSCmdlet.ShouldProcess("$($Rows.Count) user(s)", "Run combined independent AD and Microsoft 365 onboarding")) {
    Add-Result '' '' 'Run' 'WhatIf' 'Live read-only preflight completed (remote sessions opened); no provisioning writes were performed.'
    Close-OnboardingResources
    exit 0
}

# ============================================================
# PROCESS USERS
# ============================================================

$FinalSummary = [System.Collections.Generic.List[object]]::new()

foreach ($Prepared in $PreparedRows) {
    $Row = $Prepared.Source
    $UserName = $Prepared.UserName
    $Upn = $Prepared.Upn
    $AdCreated = $false
    $FolderCreated = $false
    $script:PersonalFolderCreationSucceeded = $false
    $ShareCreated = $false
    $BatCreated = $false
    $CloudCreated = $false
    $DomainVerified = $false
    $CredentialRecord = $null
    $PriorScriptPath = $null
    $ScriptPathChanged = $false
    $ScriptPathRestored = $false
    $EmailSubmissionAccepted = $false
    $CurrentStage = 'Start'

    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host "Processing: $UserName / $Upn" -ForegroundColor Cyan
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray

    try {
        # 1. AD account
        $CurrentStage = 'AD user'
        $AdUser = Get-ADUser -Filter "SamAccountName -eq '$(Escape-AdFilterValue $UserName)'" -Properties Enabled,ScriptPath,MemberOf -ErrorAction Stop
        if (-not $AdUser) {
            $SecurePassword = ConvertTo-SecureString $Prepared.Password -AsPlainText -Force
            $NewAdParameters = @{
                Name = $Row.DisplayName
                GivenName = $Row.GivenName
                Surname = $Row.Surname
                DisplayName = $Row.DisplayName
                SamAccountName = $UserName
                UserPrincipalName = $Upn
                Title = $Row.JobTitle
                Department = $Row.Department
                Company = $Row.CompanyName
                EmailAddress = $Upn
                Path = $Row.OU
                AccountPassword = $SecurePassword
                Enabled = $true
                ChangePasswordAtLogon = $true
                OtherAttributes = @{ proxyAddresses = @("SMTP:$Upn") }
                ErrorAction = 'Stop'
            }
            foreach ($Mapping in @(
                @('EmployeeID','EmployeeId'),@('MobilePhone','MobilePhone'),@('OfficePhone','BusinessPhone'),
                @('Office','OfficeLocation'),@('State','State')
            )) {
                $Value = Get-TextValue $Row.($Mapping[1])
                if ($Value) { $NewAdParameters[$Mapping[0]] = $Value }
            }
            if (Get-TextValue $Row.Country) {
                $NewAdParameters.OtherAttributes['c'] = $UsageLocation
                $NewAdParameters.OtherAttributes['co'] = $Row.Country
                $NewAdParameters.OtherAttributes['countryCode'] = $AdCountryCode
            }
            New-ADUser @NewAdParameters
            $AdCreated = $true
            Start-Sleep -Seconds 2
            $CredentialRecord = [pscustomobject]@{
                DisplayName = $Row.DisplayName
                UserName = $UserName
                UserPrincipalName = $Upn
                PersonalEmail = $Row.PersonalEmail
                TemporaryPassword = $Prepared.Password
                AppliedTo = 'AD only; Microsoft 365 pending'
                ChangeRequiredAtFirstSignIn = $true
            }
            $Credentials.Add($CredentialRecord)
            # SECURITY: do not create a second plaintext password file.
            if ($Prepared.WelcomeEmailEligibleAtStart) {
                Set-WelcomeEmailState -Upn $Upn -Status Pending -Message 'Both AD and Microsoft 365 accounts were absent at pre-flight; welcome email awaits complete verification.'
            }
            Add-Result $UserName $Upn 'AD user' 'Success' "Created in $($Row.OU); password change required at first logon."
            Write-Host 'AD user CREATED.' -ForegroundColor Green
        }
        else {
            Add-Result $UserName $Upn 'AD user' 'Skipped' 'Existing AD user kept; password was not changed.'
            Write-Host 'AD user already exists - KEPT. Password unchanged.' -ForegroundColor Green
        }

        $AdUser = Get-ADUser -Identity $UserName -Properties Enabled -ErrorAction Stop
        if (-not $AdUser.Enabled) { throw 'AD account is disabled and will not be enabled automatically.' }

        $CurrentStage = 'AD profile'
        $SetAdParameters = @{
            Identity = $UserName
            GivenName = $Row.GivenName
            Surname = $Row.Surname
            DisplayName = $Row.DisplayName
            UserPrincipalName = $Upn
            Title = $Row.JobTitle
            Department = $Row.Department
            Company = $Row.CompanyName
            EmailAddress = $Upn
            ErrorAction = 'Stop'
        }
        foreach ($Mapping in @(
            @('EmployeeID','EmployeeId'),@('MobilePhone','MobilePhone'),@('OfficePhone','BusinessPhone'),
            @('Office','OfficeLocation'),@('State','State')
        )) {
            $Value = Get-TextValue $Row.($Mapping[1])
            if ($Value) { $SetAdParameters[$Mapping[0]] = $Value }
        }
        if (Get-TextValue $Row.Country) {
            $SetAdParameters.Replace = @{ c = $UsageLocation; co = $Row.Country; countryCode = $AdCountryCode }
        }
        Set-ADUser @SetAdParameters
        $ProxyResult = Ensure-AdPrimarySmtp -Identity $UserName -Email $Upn
        Add-Result $UserName $Upn 'AD profile' 'Success' "CSV profile fields, UPN, email and primary SMTP reconciled; existing password unchanged when the account pre-existed. Proxy status: $ProxyResult."
        Write-Host 'AD profile and primary SMTP reconciled.' -ForegroundColor Green

        $CurrentStage = 'Printer group'
        $AdForGroup = Get-ADUser -Identity $UserName -Properties MemberOf -ErrorAction Stop
        if ($AdForGroup.MemberOf -notcontains $PrinterGroupObject.DistinguishedName) {
            Add-ADGroupMember -Identity $PrinterGroupObject -Members $UserName -ErrorAction Stop
            Add-Result $UserName $Upn 'Printer group' 'Success' "Added to $PrinterGroupName."
            Write-Host "Added to $PrinterGroupName." -ForegroundColor Green
        }
        else {
            Add-Result $UserName $Upn 'Printer group' 'Skipped' "Already a direct member of $PrinterGroupName."
            Write-Host "Printer membership already exists - KEPT." -ForegroundColor Green
        }

        # 2. Folder and NTFS
        $CurrentStage = 'Personal folder'
        $UserIdentity = "$DomainNetBIOS\$UserName"
        $DomainAdminsIdentity = "$DomainNetBIOS\Domain Admins"
        $ExpectedNtfsAccounts = @($UserIdentity,$DomainAdminsIdentity,'BUILTIN\Administrators','NT AUTHORITY\SYSTEM')
        $CurrentFolderState = Get-PersonalFolderPathState -Path $Prepared.AdminFolderPath
        if ($CurrentFolderState -eq 'ABSENT') {
            New-PersonalFolderWithInitialAcl -Path $Prepared.AdminFolderPath -FullControlAccounts $ExpectedNtfsAccounts
            $FolderCreated = $true
            Add-Result $UserName $Upn 'Personal folder' 'Success' "Created or verified $($Prepared.LocalFolderPath) with initial ACL."
            Write-Host "Folder CREATED/VERIFIED: $($Prepared.LocalFolderPath)" -ForegroundColor Green
        }
        elseif ($CurrentFolderState -eq 'DIRECTORY') {
            Add-Result $UserName $Upn 'Personal folder' 'Skipped' 'Existing folder kept.'
            Write-Host 'Folder already exists - KEPT.' -ForegroundColor Green
        }
        else {
            throw "Personal folder path '$($Prepared.AdminFolderPath)' exists but is not a directory. Manual review required."
        }

        $CurrentStage = 'NTFS permissions'
        Sync-PersonalFolderAcl -Path $Prepared.AdminFolderPath -FullControlAccounts $ExpectedNtfsAccounts -ResetToControlledAcl $false
        Add-Result $UserName $Upn 'NTFS permissions' 'Success' "Required Full Control ACL entries verified for $UserIdentity, Domain Admins, Administrators and SYSTEM; effective access not established by ACL inspection alone."
        Write-Host 'NTFS permissions confirmed.' -ForegroundColor Green

        # 3. Hidden SMB share
        $CurrentStage = 'Hidden SMB share'
        # Do not publish a share if the folder was replaced, redirected, or
        # its required permissions changed after the earlier validation.
        if ((Get-PersonalFolderPathState -Path $Prepared.AdminFolderPath) -ne 'DIRECTORY') {
            throw "Personal folder changed before SMB share creation. Manual review required."
        }
        Assert-ExistingPersonalFolderAcl -Path $Prepared.AdminFolderPath -FullControlAccounts $ExpectedNtfsAccounts
        $Share = @(Get-SmbShare -CimSession $CimSession -ErrorAction Stop | Where-Object Name -eq $Prepared.ShareName | Select-Object -First 1)[0]
        if (-not $Share) {
            New-SmbShareWithAccountResolutionRetry -Session $CimSession -Name $Prepared.ShareName -Path $Prepared.LocalFolderPath -FullAccess @($UserIdentity,$DomainAdminsIdentity,'BUILTIN\Administrators')
            $ShareCreated = $true
            Write-Host "Hidden share CREATED: \\$FileServer\$($Prepared.ShareName)" -ForegroundColor Green
        }
        else {
            if ($Share.Path -ine $Prepared.LocalFolderPath) { throw "Existing share points to '$($Share.Path)'." }
            Write-Host 'Hidden share already exists - reconciling permissions.' -ForegroundColor DarkCyan
        }
        $ExpectedShareAccounts = @($UserIdentity,$DomainAdminsIdentity,'BUILTIN\Administrators')
        Sync-SmbShareAccess -Session $CimSession -Name $Prepared.ShareName -Path $Prepared.LocalFolderPath -ExpectedFullAccess $ExpectedShareAccounts
        Add-Result $UserName $Upn 'Hidden SMB share' 'Success' "Share path and required Full Access permissions confirmed for $($ExpectedShareAccounts -join ', '); unresolved SID entries must be resolved manually."
        Write-Host 'Hidden share path and permissions confirmed.' -ForegroundColor Green

        # 4. NETLOGON BAT and ScriptPath
        $CurrentStage = 'NETLOGON BAT'
        if (-not (Test-Path $Prepared.BatFilePath)) {
            $BatStream = [System.IO.File]::Open($Prepared.BatFilePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $BatCreated = $true
            try {
                $BatBytes = [System.Text.Encoding]::ASCII.GetBytes($Prepared.ExpectedBatContent)
                $BatStream.Write($BatBytes, 0, $BatBytes.Length)
                $BatStream.Flush()
            }
            finally { $BatStream.Dispose() }
            Add-Result $UserName $Upn 'NETLOGON BAT' 'Success' "Created $($Prepared.BatFileName) with S:, J: and Z: mappings."
            Write-Host "BAT file CREATED: $($Prepared.BatFileName)" -ForegroundColor Green
        }
        else {
            $BatContent = Get-Content -Path $Prepared.BatFilePath -Raw -ErrorAction Stop
            if ((Normalize-Text $BatContent) -ne (Normalize-Text $Prepared.ExpectedBatContent)) { throw 'Existing BAT content differs; it was not overwritten.' }
            Add-Result $UserName $Upn 'NETLOGON BAT' 'Skipped' 'Existing correct BAT kept.'
            Write-Host 'BAT file already exists correctly - KEPT.' -ForegroundColor Green
        }

        $CurrentStage = 'AD ScriptPath'
        $CurrentAd = Get-ADUser -Identity $UserName -Properties ScriptPath -ErrorAction Stop
        if ($CurrentAd.ScriptPath -ne $Prepared.BatFileName) {
            $PriorScriptPath = [string]$CurrentAd.ScriptPath
            Set-ADUser -Identity $UserName -ScriptPath $Prepared.BatFileName -ErrorAction Stop
            $ScriptPathChanged = $true
            Add-Result $UserName $Upn 'AD ScriptPath' 'Success' "Set to $($Prepared.BatFileName)."
        }
        else { Add-Result $UserName $Upn 'AD ScriptPath' 'Skipped' 'Existing ScriptPath is correct.' }

        # 5. Verify domain side before cloud side
        $CurrentStage = 'Domain verification'
        $VerifyAd = Get-ADUser -Identity $UserName -Properties Enabled,ScriptPath,GivenName,Surname,DisplayName,Title,Department,Company,EmployeeID,MobilePhone,OfficePhone,Office,State,Country,co,mail,UserPrincipalName,MemberOf,proxyAddresses -ErrorAction Stop
        $VerifyShare = Get-SmbShare -CimSession $CimSession -Name $Prepared.ShareName -ErrorAction Stop
        $VerifyShareAccess = @(Get-SmbShareAccess -CimSession $CimSession -Name $Prepared.ShareName -ErrorAction Stop)
        if (-not $VerifyAd.Enabled) { throw 'Domain verification: account is not enabled.' }
        if ($VerifyAd.ScriptPath -ne $Prepared.BatFileName) { throw 'Domain verification: ScriptPath mismatch.' }
        if ($VerifyAd.UserPrincipalName -ine $Upn) { throw 'Domain verification: UPN mismatch.' }
        if ($VerifyAd.mail -ine $Upn) { throw 'Domain verification: email mismatch.' }
        if ($VerifyAd.GivenName -ne $Row.GivenName -or $VerifyAd.Surname -ne $Row.Surname -or $VerifyAd.DisplayName -ne $Row.DisplayName -or $VerifyAd.Title -ne $Row.JobTitle -or $VerifyAd.Department -ne $Row.Department -or $VerifyAd.Company -ne $Row.CompanyName) { throw 'Domain verification: required profile field mismatch.' }
        foreach ($Mapping in @(
            @('EmployeeID','EmployeeId'),@('MobilePhone','MobilePhone'),@('OfficePhone','BusinessPhone'),
            @('Office','OfficeLocation'),@('State','State'),@('co','Country')
        )) {
            $ExpectedValue = Get-TextValue $Row.($Mapping[1])
            if ($ExpectedValue -and [string]$VerifyAd.($Mapping[0]) -ne $ExpectedValue) {
                throw "Domain verification: $($Mapping[1]) mismatch."
            }
        }
        if ($VerifyAd.MemberOf -notcontains $PrinterGroupObject.DistinguishedName) { throw 'Domain verification: printer membership missing.' }
        if (-not (Test-Path $Prepared.AdminFolderPath)) { throw 'Domain verification: personal folder missing.' }
        if ($VerifyShare.Path -ine $Prepared.LocalFolderPath) { throw 'Domain verification: share path mismatch.' }
        foreach ($ExpectedAccount in $ExpectedShareAccounts) {
            $MatchingShareAccess = @($VerifyShareAccess | Where-Object { $_.AccountName -ieq $ExpectedAccount -and $_.AccessControlType.ToString() -eq 'Allow' -and $_.AccessRight.ToString() -eq 'Full' })
            if ($MatchingShareAccess.Count -ne 1) { throw "Domain verification: SMB Full Access missing for $ExpectedAccount." }
        }
        if (@($VerifyShareAccess | Where-Object { $_.AccountName -match '^\*S-1-' }).Count -gt 0) { throw 'Domain verification: unresolved SMB SID entry remains.' }
        $VerifyPrimary = @(Get-PrimaryProxyAddress $VerifyAd.proxyAddresses)
        if ($VerifyPrimary.Count -ne 1 -or $VerifyPrimary[0].Substring(5) -ine $Upn) { throw 'Domain verification: primary SMTP mismatch.' }
        if (-not (Test-Path $Prepared.BatFilePath)) { throw 'Domain verification: NETLOGON BAT file is missing.' }
        $VerifyBatContent = Get-Content -Path $Prepared.BatFilePath -Raw -ErrorAction Stop
        if ((Normalize-Text $VerifyBatContent) -ne (Normalize-Text $Prepared.ExpectedBatContent)) { throw 'Domain verification: NETLOGON BAT content mismatch.' }
        Add-Result $UserName $Upn 'Domain verification' 'Success' 'AD account, profile, printer group, folder, permissions, share, BAT and ScriptPath verified.'
        $DomainVerified = $true
        Write-Host 'DOMAIN SIDE COMPLETED AND VERIFIED.' -ForegroundColor Green

        # 6. Cloud identity
        $CurrentStage = 'Microsoft 365 user'
        $CloudUser = Get-CloudUserOrNull -Upn $Upn
        if ($CloudUser -and $CloudUser.OnPremisesSyncEnabled -eq $true) {
            throw "Cloud account '$Upn' is synchronized; direct-only onboarding cannot modify it."
        }
        if (-not $CloudUser) {
                $UserParameters = @{
                    AccountEnabled = $true
                    DisplayName = $Row.DisplayName
                    GivenName = $Row.GivenName
                    Surname = $Row.Surname
                    UserPrincipalName = $Upn
                    MailNickname = $Prepared.MailNickname
                    UsageLocation = $UsageLocation
                    PasswordProfile = @{ Password = $Prepared.Password; ForceChangePasswordNextSignIn = $true }
                }
                foreach ($Mapping in @(
                    @('JobTitle','JobTitle'),@('Department','Department'),@('CompanyName','CompanyName'),
                    @('EmployeeId','EmployeeId'),@('MobilePhone','MobilePhone'),@('OfficeLocation','OfficeLocation'),
                    @('State','State'),@('Country','Country')
                )) {
                    $Value = Get-TextValue $Row.($Mapping[1])
                    if ($Value) { $UserParameters[$Mapping[0]] = $Value }
                }
                $BusinessPhone = Get-TextValue $Row.BusinessPhone
                if ($BusinessPhone) { $UserParameters.BusinessPhones = @($BusinessPhone) }
                $CloudUser = New-MgUser @UserParameters
                $CloudCreated = $true
                Add-Result $UserName $Upn 'Microsoft 365 user' 'Success' "Created cloud user ID $($CloudUser.Id)."
                Write-Host 'Microsoft 365 user CREATED.' -ForegroundColor Green
        }
        else {
            Add-Result $UserName $Upn 'Microsoft 365 user' 'Skipped' 'Existing account kept; password was not changed.'
            Write-Host 'Microsoft 365 user already exists - KEPT. Password unchanged.' -ForegroundColor Green
        }

        if ($CloudCreated) {
            if ($CredentialRecord) {
                $CredentialRecord.AppliedTo = 'AD and Microsoft 365'
            }
            else {
                $CredentialRecord = [pscustomobject]@{
                    DisplayName = $Row.DisplayName
                    UserName = $UserName
                    UserPrincipalName = $Upn
                    PersonalEmail = $Row.PersonalEmail
                    TemporaryPassword = $Prepared.Password
                    AppliedTo = 'Microsoft 365 only; AD password unchanged'
                    ChangeRequiredAtFirstSignIn = $true
                }
                $Credentials.Add($CredentialRecord)
            }
            # SECURITY: do not create a second plaintext password file.
        }

        # Refresh complete cloud properties
        $CloudUser = Get-MgUser -UserId $CloudUser.Id -Property Id,DisplayName,GivenName,Surname,UserPrincipalName,AssignedLicenses,OnPremisesSyncEnabled,UsageLocation,JobTitle,Department,CompanyName,EmployeeId,MobilePhone,BusinessPhones,OfficeLocation,State,Country -ErrorAction Stop

        # Reconcile approved Microsoft 365 profile fields without changing an
        # existing account's password. Synchronized accounts remain AD-mastered.
        $CurrentStage = 'Microsoft 365 profile'
        if ($CloudUser.OnPremisesSyncEnabled -eq $true) {
            Add-Result $UserName $Upn 'Microsoft 365 profile' 'Skipped' 'Synchronized profile remains mastered by Active Directory; cloud password unchanged.'
        }
        else {
            $CloudUpdateParameters = @{ UserId = $CloudUser.Id; ErrorAction = 'Stop' }
            if ([string]$CloudUser.DisplayName -ne $Row.DisplayName) { $CloudUpdateParameters.DisplayName = $Row.DisplayName }
            if ([string]$CloudUser.GivenName -ne $Row.GivenName) { $CloudUpdateParameters.GivenName = $Row.GivenName }
            if ([string]$CloudUser.Surname -ne $Row.Surname) { $CloudUpdateParameters.Surname = $Row.Surname }
            if ([string]$CloudUser.JobTitle -ne $Row.JobTitle) { $CloudUpdateParameters.JobTitle = $Row.JobTitle }
            if ([string]$CloudUser.Department -ne $Row.Department) { $CloudUpdateParameters.Department = $Row.Department }
            if ([string]$CloudUser.CompanyName -ne $Row.CompanyName) { $CloudUpdateParameters.CompanyName = $Row.CompanyName }
            foreach ($Mapping in @(
                @('EmployeeId','EmployeeId'),@('MobilePhone','MobilePhone'),@('OfficeLocation','OfficeLocation'),
                @('State','State'),@('Country','Country')
            )) {
                $ExpectedValue = Get-TextValue $Row.($Mapping[1])
                if ($ExpectedValue -and [string]$CloudUser.($Mapping[0]) -ne $ExpectedValue) {
                    $CloudUpdateParameters[$Mapping[0]] = $ExpectedValue
                }
            }
            $ExpectedBusinessPhone = Get-TextValue $Row.BusinessPhone
            if ($ExpectedBusinessPhone -and @($CloudUser.BusinessPhones) -notcontains $ExpectedBusinessPhone) {
                $CloudUpdateParameters.BusinessPhones = @($ExpectedBusinessPhone)
            }
            if ($CloudUpdateParameters.Count -gt 2) {
                Update-MgUser @CloudUpdateParameters
                Add-Result $UserName $Upn 'Microsoft 365 profile' 'Success' 'CSV profile fields reconciled; password unchanged for any pre-existing account.'
                Write-Host 'Microsoft 365 profile UPDATED. Password unchanged.' -ForegroundColor Green
                $CloudUser = Get-MgUser -UserId $CloudUser.Id -Property Id,DisplayName,GivenName,Surname,UserPrincipalName,AssignedLicenses,OnPremisesSyncEnabled,UsageLocation,JobTitle,Department,CompanyName,EmployeeId,MobilePhone,BusinessPhones,OfficeLocation,State,Country -ErrorAction Stop
            }
            else {
                Add-Result $UserName $Upn 'Microsoft 365 profile' 'Skipped' 'Existing profile already matches the CSV; password unchanged.'
                Write-Host 'Microsoft 365 profile already correct - KEPT.' -ForegroundColor Green
            }
        }

        # UsageLocation is required before assigning a Microsoft 365 licence.
        # Existing cloud accounts may not have it, so repair this prerequisite.
        $CurrentStage = 'Usage location'
        if ($CloudUser.UsageLocation -ine $UsageLocation) {
            Update-MgUser -UserId $CloudUser.Id -UsageLocation $UsageLocation -ErrorAction Stop
            Add-Result $UserName $Upn 'Usage location' 'Success' "Set UsageLocation to $UsageLocation."
            Write-Host "Usage location SET: $UsageLocation" -ForegroundColor Green
            $CloudUser = Get-MgUser -UserId $CloudUser.Id -Property Id,DisplayName,GivenName,Surname,UserPrincipalName,AssignedLicenses,OnPremisesSyncEnabled,UsageLocation,JobTitle,Department,CompanyName,EmployeeId,MobilePhone,BusinessPhones,OfficeLocation,State,Country -ErrorAction Stop
        }
        else {
            Add-Result $UserName $Upn 'Usage location' 'Skipped' "UsageLocation is already $UsageLocation."
        }

        # 7. Licence
        $CurrentStage = 'Assign licence'
        if ($Sku.SkuId -in @($CloudUser.AssignedLicenses | ForEach-Object SkuId)) {
            Add-Result $UserName $Upn 'Assign licence' 'Skipped' "$LicenseSkuPartNumber is already assigned."
            Write-Host 'Configured license already assigned - KEPT.' -ForegroundColor Green
        }
        else {
            Set-MgUserLicense -UserId $CloudUser.Id -AddLicenses @(@{ SkuId = $Sku.SkuId }) -RemoveLicenses @() | Out-Null
            Add-Result $UserName $Upn 'Assign licence' 'Success' "Assigned $LicenseSkuPartNumber."
            Write-Host "Licence ASSIGNED: $LicenseSkuPartNumber" -ForegroundColor Green
        }

        # 8. Exchange and groups
        $CurrentStage = 'Exchange visibility'
        Wait-ExchangeRecipient -Identity $Upn | Out-Null
        Add-Result $UserName $Upn 'Exchange visibility' 'Success' 'Recipient is visible in Exchange Online.'

        foreach ($Group in $CloudGroups) {
            $GroupAddress = $Group.PrimarySmtpAddress.ToString()
            $CurrentStage = "Cloud group $GroupAddress"
            if (Test-CloudGroupMembership -Group $Group -Upn $Upn) {
                Add-Result $UserName $Upn $CurrentStage 'Skipped' "Already a member of $GroupAddress."
                Write-Host "Group membership already exists - KEPT: $GroupAddress" -ForegroundColor Green
            }
            else {
                Add-CloudGroupMembership -Group $Group -Upn $Upn
                Add-Result $UserName $Upn $CurrentStage 'Success' "Added to $GroupAddress."
                Write-Host "Added to cloud group: $GroupAddress" -ForegroundColor Green
            }
        }

        # 9. Final cloud verification
        $CurrentStage = 'Cloud verification'
        $VerifyCloud = Get-MgUser -UserId $Upn -Property Id,DisplayName,GivenName,Surname,UserPrincipalName,AssignedLicenses,OnPremisesSyncEnabled,UsageLocation,JobTitle,Department,CompanyName,EmployeeId,MobilePhone,BusinessPhones,OfficeLocation,State,Country -ErrorAction Stop
        if ($VerifyCloud.UserPrincipalName -ine $Upn) { throw 'Cloud verification: UPN mismatch.' }
        if ($VerifyCloud.UsageLocation -ine $UsageLocation) { throw "Cloud verification: UsageLocation is not $UsageLocation." }
        if ($Sku.SkuId -notin @($VerifyCloud.AssignedLicenses | ForEach-Object SkuId)) { throw 'Cloud verification: configured license missing.' }
        if ($VerifyCloud.OnPremisesSyncEnabled -eq $true) { throw 'Cloud verification: synchronized account is not supported by direct-only onboarding.' }
        if ($VerifyCloud.OnPremisesSyncEnabled -ne $true) {
            if ($VerifyCloud.DisplayName -ne $Row.DisplayName -or $VerifyCloud.GivenName -ne $Row.GivenName -or $VerifyCloud.Surname -ne $Row.Surname -or $VerifyCloud.JobTitle -ne $Row.JobTitle -or $VerifyCloud.Department -ne $Row.Department -or $VerifyCloud.CompanyName -ne $Row.CompanyName) {
                throw 'Cloud verification: required profile field mismatch.'
            }
            foreach ($Mapping in @(
                @('EmployeeId','EmployeeId'),@('MobilePhone','MobilePhone'),@('OfficeLocation','OfficeLocation'),
                @('State','State'),@('Country','Country')
            )) {
                $ExpectedValue = Get-TextValue $Row.($Mapping[1])
                if ($ExpectedValue -and [string]$VerifyCloud.($Mapping[0]) -ne $ExpectedValue) {
                    throw "Cloud verification: $($Mapping[1]) mismatch."
                }
            }
            $ExpectedBusinessPhone = Get-TextValue $Row.BusinessPhone
            if ($ExpectedBusinessPhone -and @($VerifyCloud.BusinessPhones) -notcontains $ExpectedBusinessPhone) {
                throw 'Cloud verification: BusinessPhone mismatch.'
            }
        }
        foreach ($Group in $CloudGroups) {
            if (-not (Test-CloudGroupMembership -Group $Group -Upn $Upn)) { throw "Cloud verification: membership missing from $($Group.PrimarySmtpAddress)." }
        }
        Add-Result $UserName $Upn 'Cloud verification' 'Success' 'Cloud identity, licence, Exchange recipient and requested group memberships verified.'

        # 10. Welcome email. Eligibility is locked from the pre-flight state.
        # It is true only when BOTH AD and Microsoft 365 accounts were absent.
        # If either identity existed at pre-flight, no email is sent even when
        # this run creates the missing counterpart.
        $CurrentStage = 'Welcome email'
        if ($Prepared.WelcomeEmailEligibleAtStart) {
            try {
                Send-OrganizationWelcomeEmail -DisplayName $Row.DisplayName -PersonalEmail $Row.PersonalEmail -OrganizationEmail $Upn -TemporaryPassword $Prepared.Password
                $EmailSubmissionAccepted = $true
                Set-WelcomeEmailState -Upn $Upn -Status Accepted -Message "Microsoft Graph accepted the message. Sender: $WelcomeEmailSender; personal and organization addresses used; CC: $WelcomeEmailCc. Both identities were absent at pre-flight."
                Add-Result $UserName $Upn 'Welcome email' 'Success' "Microsoft Graph accepted the welcome email from $WelcomeEmailSender to the personal and organization addresses; CC $WelcomeEmailCc."
                $WelcomeResult = 'Accepted'
                Write-Host 'Welcome email accepted by Microsoft Graph.' -ForegroundColor Green
            }
            catch {
                if ($EmailSubmissionAccepted) {
                    throw "Microsoft Graph accepted the welcome email, but state recording failed. Delivery outcome must be checked manually; do NOT resend automatically: $($_.Exception.Message)"
                }
                try { Set-WelcomeEmailState -Upn $Upn -Status Failed -Message $_.Exception.Message }
                catch { Add-Result $UserName $Upn 'Welcome email state' 'Manual review' "Failed to persist email failure state: $($_.Exception.Message)" }
                throw "Welcome email submission failed; check delivery before retry: $($_.Exception.Message)"
            }
        }
        else {
            $CurrentEmailState = Get-WelcomeEmailState -Upn $Upn
            if (-not $CurrentEmailState -or $CurrentEmailState.Status -notin @('Accepted','Pending','Failed')) {
                Set-WelcomeEmailState -Upn $Upn -Status Suppressed -Message "Welcome email suppressed by pre-flight policy: $($Prepared.WelcomeEmailPlan)."
            }
            Add-Result $UserName $Upn 'Welcome email' 'Skipped' "Welcome email intentionally not sent. Pre-flight policy: $($Prepared.WelcomeEmailPlan). Existing passwords were preserved."
            $WelcomeResult = $Prepared.WelcomeEmailPlan
            Write-Host "Welcome email NOT SENT. Policy: $($Prepared.WelcomeEmailPlan)." -ForegroundColor Yellow
        }

        Add-Result $UserName $Upn 'Overall' 'Success' 'All domain and Microsoft 365 operations completed and verified; welcome-email policy completed.'
        Write-Host 'SUCCESS: ALL DOMAIN, MICROSOFT 365 AND EMAIL ITEMS COMPLETED.' -ForegroundColor Green

        $FinalSummary.Add([pscustomobject]@{
            UserName = $UserName
            UserPrincipalName = $Upn
            Domain = 'Success'
            Microsoft365 = 'Success'
            WelcomeEmail = $WelcomeResult
            Overall = 'SUCCESS'
        })
    }
    catch {
        $FailureMessage = $_.Exception.Message
        Add-Result $UserName $Upn $CurrentStage 'Failed' $FailureMessage
        Add-Result $UserName $Upn 'Overall' 'Failed' "Stopped during: $CurrentStage."
        Write-Host ''
        Write-Host "FAILED: $UserName during $CurrentStage" -ForegroundColor Red
        Write-Host $FailureMessage -ForegroundColor Red

        # Fail-safe recovery policy: do not automatically remove shares, BAT files,
        # or folders after partial failure. Concurrent operators and pre-existing
        # resources make ownership uncertain. Retain them for manual inspection.
        if (-not $DomainVerified -and $ScriptPathChanged) {
            # No automatic ScriptPath rollback: AD lacks an atomic conditional
            # attribute update here. Another operator may have changed it.
            # Keep the BAT and current AD value for explicit manual review.
            Add-Result $UserName $Upn 'Recovery' 'Manual review' "ScriptPath was changed during this run. Previous value: '$PriorScriptPath'; intended value: '$($Prepared.BatFileName)'. Do not automatically restore or clear; inspect the current AD value and BAT before correcting."
        }
        if ($script:PersonalFolderCreationSucceeded -and -not $FolderCreated) {
            Add-Result $UserName $Upn 'Recovery' 'Manual review' "Directory creation succeeded but verification or later processing failed: $($Prepared.AdminFolderPath). Do not delete automatically; inspect ownership, path and ACL."
        }
        foreach ($Resource in @(
            @{ Created=$ShareCreated; Name='SMB share'; Location=$Prepared.ShareName },
            @{ Created=$BatCreated; Name='NETLOGON BAT'; Location=$Prepared.BatFilePath },
            @{ Created=$FolderCreated; Name='Personal folder'; Location=$Prepared.AdminFolderPath }
        )) {
            if (-not $DomainVerified -and $Resource.Created) {
                Add-Result $UserName $Upn 'Recovery' 'Manual review' "$($Resource.Name) retained after partial failure: $($Resource.Location). Ownership cannot be proven under concurrent operations; inspect manually."
            }
        }
        if ($AdCreated) { Write-Host "IMPORTANT: newly created AD user '$UserName' was NOT deleted. Review it before retrying." -ForegroundColor Yellow }
        if ($CloudCreated) { Write-Host "IMPORTANT: newly created Microsoft 365 user '$Upn' was NOT deleted. Rerun will reuse it." -ForegroundColor Yellow }

        Add-Result $UserName $Upn 'Recovery required' 'Manual review' "Creation flags are historical unless cleanup was verified; inspect changes to existing objects separately. Residual state: ADCreated=$AdCreated; CloudCreated=$CloudCreated; FolderCreated=$FolderCreated; FolderCreationSucceeded=$($script:PersonalFolderCreationSucceeded); ShareCreated=$ShareCreated; BatCreated=$BatCreated; ScriptPathChanged=$ScriptPathChanged; DomainVerified=$DomainVerified. Inspect actual AD, M365, SMB, NTFS, BAT and licensing state before retry."
        $FinalSummary.Add([pscustomobject]@{
            UserName = $UserName
            UserPrincipalName = $Upn
            Domain = if ($CurrentStage -match 'Microsoft 365|licence|Exchange|Cloud|Welcome') { 'Success' } else { 'Failed/Review' }
            Microsoft365 = if ($CurrentStage -eq 'Welcome email') { 'Success' } elseif ($CurrentStage -match 'Microsoft 365|licence|Exchange|Cloud') { 'Failed/Partial' } else { 'Not started' }
            WelcomeEmail = if ($CurrentStage -eq 'Welcome email' -and $EmailSubmissionAccepted) { 'Accepted - state unverified; manual delivery check' } elseif ($CurrentStage -eq 'Welcome email') { 'Failed - delivery check required' } else { 'Not reached' }
            Overall = 'FAILED'
        })
    }
}

# ============================================================
# FINAL RESULT AND DISCONNECT
# ============================================================

Close-OnboardingResources -KeepTranscript

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' FINAL RESULT' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
$FinalSummary | Format-Table -AutoSize

$FailedCount = @($FinalSummary | Where-Object Overall -eq 'FAILED').Count
if ($FailedCount -eq 0) {
    Write-Host 'All users completed successfully.' -ForegroundColor Green
}
else {
    Write-Host "$FailedCount user(s) failed or remain partial. Review the operational log and rerun after correction." -ForegroundColor Yellow
}

Write-Host "Operational log : $OperationalLogPath" -ForegroundColor Cyan
Write-Host "Transcript      : $TranscriptPath" -ForegroundColor Cyan
Write-Host "Email state     : $WelcomeEmailStatePath" -ForegroundColor Cyan
if ($CredentialPath -and (Test-Path $CredentialPath)) {
    Write-Host "Credentials     : $CredentialPath" -ForegroundColor Yellow
    Write-Warning 'Protect and securely delete the credentials file after delivering the temporary passwords.'
}

Close-OnboardingResources

if ($FailedCount -gt 0) { exit 1 }
exit 0
