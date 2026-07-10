//
//  LoginItemService.swift
//  Lyripeek
//

import ServiceManagement

/// Registers and unregisters the app as a macOS login item via
/// `SMAppService.mainApp`.
///
/// The system owns the persisted registration state, so this service is a
/// thin wrapper that reads `status` and calls `register()`/`unregister()`.
/// The state can also be flipped by the user from System Settings › General ›
/// Login Items, so callers should always re-read `isEnabled` before showing
/// UI rather than caching it.
final class LoginItemService {
    // IMPORTANT: Do NOT add this key to UserDefaults.register(defaults:).
    // Absence of the key (nil) is the sentinel for "never decided" (new install),
    // which is what triggers the one-time default. Registering a default value
    // would mask nil and prevent the default from ever being applied.
    private let preferenceKey = "launchAtLoginEnabled"

    /// Whether the app is currently registered to launch at login.
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Three-state preference stored in UserDefaults:
    /// - `nil`   → never decided (new install or first run after update)
    /// - `true`  → login-item is intentionally enabled
    /// - `false` → login-item is intentionally disabled
    private var preference: Bool? {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool
    }

    /// Enables launch-at-login once for new installs.
    ///
    /// Guards on `preference == nil` so it is a no-op on every subsequent
    /// launch regardless of the actual system state. Persists the **actual**
    /// resulting `isEnabled` value (not just the requested `true`) so that a
    /// silent `register()` failure keeps `preference` at `false` — allowing a
    /// future app update to retry if needed.
    func enableByDefaultIfNeeded() {
        guard preference == nil else { return }
        setEnabled(true)
        UserDefaults.standard.set(isEnabled, forKey: preferenceKey)
    }

    /// Sets the login-item registration and records the explicit user choice.
    ///
    /// Returns the resulting `isEnabled` value so callers can refresh their
    /// UI even if the requested state could not be applied (e.g. the user
    /// disabled it from System Settings).
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
        UserDefaults.standard.set(isEnabled, forKey: preferenceKey)
        return isEnabled
    }
}
