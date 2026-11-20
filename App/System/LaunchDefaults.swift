import Foundation

/// Where this lane's small preferences are kept: the standard defaults, or on UI test
/// launches a domain of their own, emptied at launch, so test accounts and test links never
/// touch the user's.
enum LaunchDefaults {
    static func make(_ name: String) -> UserDefaults {
        #if DEBUG || UITEST_HOOKS
            if UITestLaunch.isActive {
                let suite = "eu.xippi.Xippi.uitest-\(name)"
                let defaults = UserDefaults(suiteName: suite) ?? .standard
                defaults.removePersistentDomain(forName: suite)
                return defaults
            }
        #endif
        return .standard
    }
}
