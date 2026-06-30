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
    /// Whether the app is currently registered to launch at login.
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Sets the login-item registration.
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
        return isEnabled
    }
}
