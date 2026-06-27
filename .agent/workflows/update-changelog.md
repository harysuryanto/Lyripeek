---
description: Update the CHANGELOG.md file for the end-user
---

Follow these steps when the user asks to "update the changelog":

1.  **Identify the current version**: Read the `MARKETING_VERSION` value from
    `Lyripeek.xcodeproj/project.pbxproj`. There are two occurrences (Debug and
    Release build configurations) — they should always match; use the one
    under the Release configuration (the second occurrence, in the
    `Release` XCBuildConfiguration section).

2.  **Get the changes**:
    - List existing version tags with `git tag --list | sort -V`.
    - Find the most recent tag **before** the current `MARKETING_VERSION`
      using `git describe --tags --abbrev=0` (this returns the latest tag
      reachable from HEAD; if it equals the current version, fall back to
      the previous one). Then collect its commits with
      `git log <prev-tag>..HEAD`.
    - If no tags exist yet (this is common for early-stage projects), take
      commits from the very first commit to HEAD with
      `git log <first-commit>..HEAD`.
    - Run `git log` **without** the `--oneline` flag so full commit messages
      are captured. The range is from the previous version boundary up to
      the current state.
    - Capture changes from the **last 4 versions** at most. If fewer than 4
      prior tags exist, include whatever exists.

3.  **Generate the content**:
    - Write/replace `CHANGELOG.md` **at the repository root** (next to
      `README.md` — this project has no `docs/` directory).
    - Show **only the last 4 versions** in `CHANGELOG.md` (replace existing
      content; do not append).
    - Paraphrase the technical commit messages into user-friendly language
      for end-users (the audience is people who use the Lyripeek menu-bar
      app, not Swift developers).
    - Group changes under each version by conventional-commit type when
      possible, e.g. **Added**, **Changed**, **Fixed**, **Removed**. Drop
      types that have no entries. The commit prefixes in this repo are:
      `feat:`, `refactor:`, `fix:`, `docs:`, `chore:`, `style:`,
      `test:`, `perf:`, `build:`, `ci:`. Map them to:
      - `feat` → **Added**
      - `fix` → **Fixed**
      - `refactor`, `perf` → **Changed**
      - `docs`, `chore`, `style`, `test`, `build`, `ci` → omit (internal;
        end-users don't care)
    - Include a small variety of **emojis** to make it engaging (e.g. ✨
      for Added, 🐛 for Fixed, 🔧 for Changed).
    - Maintain the structure: `# Changelog` heading, then `## [Version] -
      YYYY-MM-DD` for each version (newest first). Use today's date
      (`date +%Y-%m-%d` in shell) for the current version; infer the date
      of past versions from `git log -1 --format=%as <tag>`.

4.  **Formatting**: Keep the file concise and easy to read. Use a short
    bullet list per section; one line per user-visible change. Avoid
    jargon (no Swift type names, no API names, no file paths).

5.  **Language**: Use Bahasa Indonesia. You may use English words that
    Indonesians use more often than the Bahasa Indonesia equivalent
    (e.g. "app", "update", "menu bar", "lyrics", "now playing", "release",
    "download", "install").

# Reference Prompt

"i want to make a changelog for my app which i will give to the end user.
please help me. use commits from the last 4 versions to list the changes.
use 'git log' command without '--oneline'. you can paraphrase to make it
easier to read by the end users. use emojis."

# Notes for the agent

- This is a Swift / macOS / Xcode project, not a JS project. Do NOT look at
  `package.json`; it does not exist. The version lives in
  `Lyripeek.xcodeproj/project.pbxproj` as `MARKETING_VERSION`.
- Tags in this project are created at release time on the `main` branch and
  follow the `vX.Y.Z` format (matching `MARKETING_VERSION`). If the user
  asks to "update the changelog" before any tag exists, treat the entire
  history as the "first version" and write a single section.
- Do NOT commit the resulting `CHANGELOG.md` unless the user explicitly
  asks. Just create/update the file and show a summary of what changed.
