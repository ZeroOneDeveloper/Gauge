# Security

Gauge stores account credentials in the macOS Keychain and account metadata and
usage history in the current user's Application Support directory. These files
must never be attached to public issues or committed to this repository.

For security reports, use GitHub's private vulnerability reporting feature under
this repository's **Security → Report a vulnerability** tab. Do not post tokens,
cookies, authorization codes, Keychain exports, or private account data in issues.

Usage collection depends on provider interfaces and installed official CLIs.
Provider-side changes can require a new release or a fresh login.
