---
description: Rules for formatting Lyripeek release page titles and descriptions.
trigger: always_on
---

# Lyripeek Release Page Formatting Rules

Always follow these rules when drafting, generating, or updating release titles and descriptions/changelogs for Lyripeek.

## 1. Release Title / Tag Format

- The release title MUST contain "Lyripeek " as a prefix followed by the app version: `Lyripeek vX.Y.Z` (e.g., `Lyripeek v0.3.0`).

## 2. Release Description Structure

The description MUST consist of the following three main sections in order:

### A. Changelog Groups

Categorize user-facing commits/changes under the following headings. Group changes using conventional commit mapping, keeping language non-technical and user-friendly:

- **`### ✨ Added`** - For new features, extensions, and design improvements.
- **`### 🐛 Fixed`** - For bug fixes, timing/stuttering adjustments, and UI corrections.
- **`### 🔧 Changed`** - For existing features modifications, performance improvements, and refactorings.

_Guidelines for entries:_

- Use a bulleted list (`- `).
- Write in clear, end-user friendly language. Avoid developer-facing jargon (no Swift type names, API references, or local file paths).

### B. Installation & Update Instructions

Always append the following block of instructions exactly as written, replacing `{VERSION}` with the version number without the leading `v` (e.g., `0.3.0`):

```markdown
### 📦 Installation & Update Instructions

To install or update Lyripeek, please follow these steps:

1. Download the Lyripeek-{VERSION}.dmg from the Assets section below.
2. Open the DMG and drag Lyripeek.app into your Applications folder.
3. Open Terminal and run the following command to bypass Gatekeeper quarantine blocks (since the app is unsigned):
```

xattr -cr /Applications/Lyripeek.app

```

Without this, macOS will show a "Lyripeek is damaged and can't be opened" error. This happens because the app is not signed with an Apple Developer ID, so macOS Gatekeeper blocks it by default.
1. Launch the app from Finder or Applications folder.
```

### C. Compare / Changelog Link

The release description MUST end with a comparison link comparing the current release tag to the previous release tag:
`Full Changelog: [v{PREV_VERSION}...v{CURR_VERSION}](https://github.com/harysuryanto/Lyripeek/compare/v{PREV_VERSION}...v{CURR_VERSION})`
