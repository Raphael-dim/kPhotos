# Security

kPhotos is alpha software. Only the latest revision on `main` receives fixes.

Report vulnerabilities privately through GitHub’s **Security → Report a vulnerability** when available.
Do not include a token, photo, database, signed URL or real-library manifest in a public issue.
Include the affected revision, impact and reproduction using synthetic data where possible.

For issues in dependencies that affect kPhotos, identify the affected package/version and coordinate with upstream maintainers.
Service-side Infomaniak issues should also be reported to Infomaniak support.
If a credential was published, revoke it at its issuer; deleting a file or rewriting Git history does not revoke it.

## Before publication

- Run `make check-secrets`: Gitleaks scans publishable working files, including untracked files, and all locally reachable commits.
- Review binary assets manually; text scanners do not detect an e-mail or token embedded in a screenshot.
- Keep signing settings in ignored `.mise.local.toml`; private experiments and diagnostics belong in ignored `.local/`.
- Never commit app databases, account exports, original media or generated build/test results.
- Git ignores do not remove files already tracked or data in earlier commits. Review `git diff --cached` before committing.

The app stores credentials in Keychain and its local index in encrypted Realm. Derived metadata caches on kDrive
can include dates, GPS and media identifiers and must be treated as private user data.
