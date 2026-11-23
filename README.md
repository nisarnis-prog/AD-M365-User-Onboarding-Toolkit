# AD & Microsoft 365 User Onboarding Toolkit

By Nisar Muhammad

## 📘 New Here? Start with the Step-by-Step Guide

**[📥 Download the Complete Step-by-Step Administrator Guide (PDF)](Documentation/AD-M365-User-Onboarding-Step-by-Step-Guide.pdf)**

A Windows PowerShell toolkit that reads a CSV to create or update an on-premises Active Directory (AD DS) account and a separate cloud-only Microsoft 365 account. It can also manage a configured AD printer-group membership, assign a Microsoft 365 license and Exchange group memberships, provision a home folder and SMB share, and set up NETLOGON drive mappings.

**v1.0.0-preview.1 is for isolated lab evaluation.** The reported offline Windows test results were **15 passed, 0 failed, 0 skipped**. Live AD DS, SMB/NTFS, Microsoft 365, and Exchange Online integration testing is pending. Complete lab validation before considering production use.

> [!IMPORTANT]
> **Use this preview only for authorized, isolated lab evaluation until independently validated.** Apply can create or modify real AD and Microsoft 365 resources. Read [Safety, user responsibilities and liability](#safety-user-responsibilities-and-liability) before running the toolkit.

## Identity and licensing

The toolkit provisions independent AD and cloud-only Microsoft 365 accounts. Matching UPNs do not synchronize passwords or account lifecycles. Hybrid synchronization through Microsoft Entra Connect Sync is outside this toolkit's scope.

### Important: Existing Microsoft 365 Accounts

The term "unsupported synchronized identity" refers to a limitation of the onboarding automation. It does not mean the user's Microsoft 365 sign-in is disabled.

When the toolkit detects an existing synchronized Microsoft 365 account, its intended behavior is to reject that onboarding operation.

The toolkit does not intentionally:

- Disable Microsoft 365 sign-in.
- Delete existing Microsoft 365 accounts.
- Delete Exchange Online mailboxes.
- Reset passwords for existing cloud accounts.
- Remove existing Microsoft 365 licenses.

Existing cloud-only Microsoft 365 accounts may be reused and updated by the toolkit, including profile attributes, license assignment, and group membership.

**Important:** Preflight checks are intended to detect conflicts before Apply. If a conflict or failure is discovered after processing begins, earlier Active Directory or resource changes may remain. The toolkit does not guarantee automatic rollback.

The toolkit uses Microsoft Graph to set the configured usage location and assign a license directly from the configured SKU. Preflight checks seat availability. Exchange Online handles membership in configured mail-enabled groups. Confirm that the groups exist, support manual membership, and that your operator has the necessary permissions.

## Home folders and drive mappings

- The toolkit creates the final home-folder directory with an initial NTFS ACL. Existing folder ACLs are validated read-only. Missing required rules, Deny entries, unresolved SIDs, and unsafe home-folder paths can block the run for manual review.
- The home folder is published as a hidden SMB share such as `\\fileserver\jane.doe$`. The trailing dollar sign hides it from ordinary browsing. Access still depends on both SMB share permissions and NTFS permissions. Validate effective access using representative accounts.
- The toolkit can create a per-user BAT file in NETLOGON and point the AD user's `ScriptPath` at it. The BAT maps two common shares and the user's home share with `net use`. Check drive-letter conflicts, NETLOGON access and replication, and mapping behavior at domain sign-in.

## Prerequisites

- An authorized Windows administrator workstation with Windows PowerShell 5.1, the RSAT `ActiveDirectory` module, and network access to the lab domain controller, NETLOGON share, and Windows SMB file server through CIM.
- Microsoft Graph PowerShell modules `Microsoft.Graph.Authentication`, `Microsoft.Graph.Users`, `Microsoft.Graph.Users.Actions`, and `Microsoft.Graph.Identity.DirectoryManagement`, plus `ExchangeOnlineManagement`.
- An authorized AD operator, file-server and NETLOGON permissions, and a permitted cloud operator with the Microsoft Graph delegated consent and Exchange roles required for the selected operations. The Graph session requests `User.ReadWrite.All`, `Directory.ReadWrite.All`, and `Organization.Read.All`, with additional mail scopes if password email is enabled. Review these permissions before consenting.
- A lab tenant ID, approved UPN suffix and OU, existing printer and mail-enabled groups, a license SKU with available seats, a valid usage location, a pre-existing home root, and accessible common shares.

## Setup and operation

1. Extract the release ZIP to a restricted lab directory outside any Git checkout. Read `START-HERE.txt` for the bundled operational notes.
2. Run `First-Time-Setup.bat` and enter `AGREE`. Enter the lab organization settings, including the tenant GUID, approved admin accounts, file-server and share paths, group identifiers, drive letters, and license settings. Normal setup updates the local engine copy, creates a backup, and writes a setup marker. The optional `TEST` setup mode uses fictional inputs and can save `Setup-Draft.json` without enabling onboarding.
3. Replace the fictional example row in the **lab copy** of `Organization-CombinedUserImport-Template.csv` with authorized test data. Keep its header and filename. The launcher expects this exact filename, and new users require a valid initial password.
4. Run `Run-Organization-Onboarding.bat`, enter `AGREE`, and select **1 — Preview**. This passes `-WhatIf`. Preview may authenticate, perform live AD DS, SMB, Microsoft Graph, and Exchange Online lookups, and write local logs. Review the planned operations, target tenant, account matches, paths, license capacity, and errors before proceeding.
5. After isolated lab review, authorization, and backups, run the launcher from an elevated session and select **2 — Apply**. Apply makes actual changes to AD, Microsoft 365, and Windows file infrastructure. Enter `EXECUTE-ONBOARDING` in the launcher, then review the engine's preflight plan and enter `CREATE` to proceed. If optional password email is enabled, the engine also requires `I ACCEPT EMAIL RISK` before `CREATE`. Verify the resulting identities, permissions, memberships, licenses, and mappings.

## Security and recovery

- Populated CSV files may contain plaintext passwords in `InitialPassword`. **Never commit or upload a populated CSV to GitHub, including to a private repository.** Keep populated inputs, configured scripts, backups, setup drafts, markers, and logs in restricted storage outside the checkout. The bundled fictional CSV is tracked, so Git can detect changes to it regardless of ignore rules.
- Keep password email disabled. Enabling it can send the temporary password to personal and corporate mailboxes, copy a configured recipient, and retain the message in Sent Items. Use an approved secure credential-delivery process.
- A partial failure can leave created resources or changes to existing resources. Review the logs and actual state before retrying. The toolkit does not perform complete rollback or automatic cleanup, and manual review is required for ambiguous email attempts.
- Filesystem races and effective access depend on the environment. Validate native path handling, SMB and NTFS permissions, NETLOGON behavior, and live AD and Microsoft 365 operations in a representative isolated lab.

See [SECURITY.md](SECURITY.md) for private reporting guidance and [CHANGELOG.md](CHANGELOG.md) for release history.


## License

The toolkit is licensed under the [MIT License](LICENSE).

Copyright (c) 2026 Nisar Muhammad.

You may use, modify, and redistribute the toolkit under the MIT License. The software is provided AS IS without warranty. This preview is intended for isolated lab evaluation. The toolkit has no production certification.

## Safety, user responsibilities and liability

- Verify the target tenant, domain, OU, account matches, groups, license SKU and capacity, filesystem and share paths, and delegated permissions. Incorrect configuration can cause account, licensing, permission, or service problems.
- Protect initial passwords and populated CSVs. Keep them in restricted storage outside the repository and use an approved credential-delivery process.
- Review Preview and validate independently in an isolated lab. Preview does not guarantee that Apply will succeed or that changes can be reversed. Partial operations may leave resources or settings that need manual intervention.
- Administrators are responsible for authorization, correct configuration, recoverable backups, testing, operational security, and compliance with applicable organizational and regulatory requirements.

The preview is provided as is under the [MIT License](LICENSE), without warranty. The author does not guarantee successful onboarding, compatibility, or uninterrupted operation. To the extent permitted by applicable law, the author is not liable for losses or damage arising from use. See the [security policy](SECURITY.md).
