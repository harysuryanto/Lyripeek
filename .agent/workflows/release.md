---
description: Full release workflow — bump version, update changelog, build DMG, and publish a GitHub release.
---

Follow these steps when the user asks to "release", "ship", "publish", or "cut a release".

## 1. Determine the Target Version

- Ask the user which version to release (e.g. `0.4.0`).
- If the user says "bump" without a number, analyze commits since the last
  tag and suggest a version:
  - `feat:` commits → bump minor (e.g. `0.3.0` → `0.4.0`).
  - `fix:` only → bump patch (e.g. `0.3.0` → `0.3.1`).
  - `BREAKING CHANGE` or `!` suffix → bump major (e.g. `0.3.0` → `1.0.0`).
- Confirm the version with the user before proceeding.

## 2. Bump the Version in Xcode

Edit `Lyripeek.xcodeproj/project.pbxproj`:

- Replace **`MARKETING_VERSION`** from the old value to the new version
  (e.g. `0.3.0` → `0.4.0`). There are **two occurrences** (Debug and
  Release build configurations) — update both.
- Increment **`CURRENT_PROJECT_VERSION`** by 1 (e.g. `3` → `4`). Also
  two occurrences.

There is no standalone `Info.plist`. Xcode auto-generates it from these
build settings (`MARKETING_VERSION` → `CFBundleShortVersionString`,
`CURRENT_PROJECT_VERSION` → `CFBundleVersion`).

## 3. Update CHANGELOG.md

Follow the same logic as the `update-changelog.md` workflow:

1. List tags with `git tag --list | sort -V`.
2. Find the previous tag with `git describe --tags --abbrev=0`.
3. Collect commits since that tag with `git log --format="%s" <prev-tag>..HEAD`.
4. Categorize user-facing commits under emoji-prefixed headings:
   - `feat:` → **### ✨ Added**
   - `fix:` → **### 🐛 Fixed**
   - `refactor:`, `perf:` → **### 🔧 Changed**
   - `docs:`, `chore:`, `style:`, `test:`, `build:`, `ci:` → omit
5. Write in clear, end-user friendly language. No Swift types, API names,
   or file paths.
6. Add a new `## [X.Y.Z] - YYYY-MM-DD` section at the **top** of
   `CHANGELOG.md` (above all other version sections).

## 4. Check README.md

- Verify no version-specific content needs updating (currently the README
  has no hardcoded version numbers).
- If the new release changes install instructions, features list, or any
  other user-facing documentation, update accordingly.

## 5. Commit

```bash
git add CHANGELOG.md Lyripeek.xcodeproj/project.pbxproj
git commit -m "release: bump version to X.Y.Z"
```

Only stage the files you changed. Do not commit secrets, build artifacts,
or unrelated changes.

## 6. Create Git Tag

```bash
git tag -a vX.Y.Z -m "Release vX.Y.Z"
```

Tag format: `v` prefix + semver (e.g. `v0.4.0`).

## 7. Build DMG

```bash
./scripts/build-dmg.sh
```

The script:
- Reads `MARKETING_VERSION` from the Xcode project.
- Builds the `.app` with `xcodebuild` (unsigned, `CODE_SIGNING_ALLOWED=NO`).
- Creates a compressed DMG at `dist/Lyripeek-X.Y.Z.dmg`.

Verify the output file exists before proceeding:
```bash
ls -lh dist/Lyripeek-X.Y.Z.dmg
```

## 8. Push Commit and Tag

```bash
git push origin main
git push origin vX.Y.Z
```

Push the commit first, then the tag.

## 9. Create GitHub Release

Use `gh release create` with the release formatting rules from
`.agent/rules/release-page-format.md`.

### Release Title

```
Lyripeek vX.Y.Z
```

### Release Body

Build the body as a markdown file with three sections in order:

**Section A — Changelog groups:**

```markdown
### ✨ Added
- (entries from feat: commits)

### 🐛 Fixed
- (entries from fix: commits)

### 🔧 Changed
- (entries from refactor:/perf: commits)
```

Omit any section that has no entries.

**Section B — Installation instructions** (exact text, replace `{VERSION}`):

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
4. Launch the app from Finder or Applications folder.
```

**Section C — Compare link:**

```markdown
Full Changelog: [v{PREV_VERSION}...v{CURR_VERSION}](https://github.com/harysuryanto/Lyripeek/compare/v{PREV_VERSION}...v{CURR_VERSION})
```

### Create the release

```bash
gh release create vX.Y.Z \
  --title "Lyripeek vX.Y.Z" \
  --notes-file /tmp/release-notes-vX.Y.Z.md \
  dist/Lyripeek-X.Y.Z.dmg
```

Clean up the temporary notes file after creation:
```bash
rm /tmp/release-notes-vX.Y.Z.md
```

## 10. Summary

Report back to the user with:

- The version released
- The GitHub release URL
- Confirmation that the DMG was uploaded as a release asset

# Notes for the agent

- This is a Swift / macOS / Xcode project. There is no `package.json`.
  The version lives in `Lyripeek.xcodeproj/project.pbxproj`.
- The build script (`scripts/build-dmg.sh`) uses only stock macOS tools
  (xcodebuild, hdiutil, osascript, ditto) — no Homebrew required.
- The app is **unsigned**. The install instructions must include the
  `xattr -cr` command to bypass Gatekeeper.
- The `dist/` directory is in `.gitignore` — DMG artifacts are not
  tracked in git.
- Do NOT create a GitHub release without the DMG file. Build it first.
- Always follow the release formatting rules in
  `.agent/rules/release-page-format.md` for the release title and body.
