# Security & Privacy Policy

## Privacy Guarantees

Milkit is designed from the ground up as a **100% local, offline, read-only** macOS utility:

- **Zero Network Calls**: The application makes no outbound HTTP/HTTPS requests, sends no analytics/telemetry, and never phones home.
- **Read-Only Access to AI Logs**: Third-party tool directories (`~/.claude`, `~/.codex`, `~/.gemini/antigravity`) are opened strictly read-only (`fopen(..., "rb")` and `SQLITE_OPEN_READONLY`). The app never modifies or deletes your AI conversation logs.
- **No Prompt Content Stored**: Only aggregate numeric token counts, model names, timestamps, session IDs, and project folder names are stored in the local rollup cache (`~/Library/Application Support/Milkit/usage_rollup.sqlite`). Prompt text and code snippets are never extracted or saved.
- **No Accessibility Permissions Required**: Global shortcuts use Carbon `RegisterEventHotKey` rather than global keystroke taps.

## Reporting a Vulnerability

If you discover a security or privacy issue (such as accidental data exposure, unsafe file handling, or SQLite/parser crashes on untrusted local input), please open a private GitHub Security Advisory on the repository or contact the maintainer directly before disclosing publicly.
