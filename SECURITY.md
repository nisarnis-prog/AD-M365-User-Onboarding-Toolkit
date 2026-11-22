# Security policy

## Preview status

`v1.0.0-preview.1` is for isolated lab evaluation. Live AD DS, SMB/NTFS, Microsoft 365, and Exchange Online integration testing is pending.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository if the option is available. Otherwise, contact the maintainer privately through an established channel. Provide the affected version, impact, and a minimal reproduction using fictional configuration and data. Keep secrets, user data, logs, and organization details out of public issues. For an active incident, follow your organization's incident response process.

## Handling sensitive data

Populated CSV files may contain plaintext passwords in `InitialPassword`. **Never commit or upload a populated CSV to GitHub, including to a private repository.** The bundled fictional template is tracked, so populate it only in a restricted working copy outside the Git checkout. Protect populated CSVs, logs, setup drafts, configured scripts, and backups. Keep password email disabled and use an approved secure delivery method.

Preview may authenticate and perform live directory and cloud lookups, and it can write local logs. Apply makes actual infrastructure changes. Review the intended tenant, delegated permissions, and planned operations before Apply.
