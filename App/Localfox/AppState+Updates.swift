import Foundation

extension AppState {
    /// AppKit refuses Sparkle's quit while a sheet is attached, so an install
    /// started from Preferences left the old version running.
    func checkForUpdates() {
        guard presentsPreferences else {
            Updater.shared.checkForUpdates()
            return
        }
        updateCheckQueued = true
        presentsPreferences = false
    }

    func sheetDidDismiss() {
        guard updateCheckQueued else { return }
        updateCheckQueued = false
        Updater.shared.checkForUpdates()
    }
}
