import Foundation

/// The first run's decisions (#255, decision 51), kept out of the view so they're tested on their
/// own: which wearable is preselected and marked "In use", what the last page's button does, and
/// when to say the pick isn't the device in use.
///
/// Picking a card in onboarding switches nothing. Only the strap's setup screen ("Save key and use
/// the Helio Strap") and Profile ▸ Device switch, through `DeviceSwitcher` (decision 1). Building a
/// flow reads UserDefaults and the Keychain only: no driver, no `CBCentralManager` (#142), and never
/// `ActiveDeviceChoiceStore.shared`, whose init can write the ownership log.
struct OnboardingFlow: Equatable {
    /// What this phone already has, read with no side effects.
    struct Installed: Equatable {
        /// `ActiveDeviceChoiceStore.persisted()`: `.ringConn` when nothing was ever chosen.
        var persistedChoice: ActiveDeviceChoice
        /// `RingScanner.hasSavedRingToRestore`: a ring was connected on this phone before.
        var hasSavedRing: Bool
        /// The strap's key is in the Keychain.
        var hasStrapKey: Bool

        @MainActor
        static func live(defaults: UserDefaults = .standard, keyStore: (any HelioKeyStoring)? = nil) -> Installed {
            Installed(persistedChoice: ActiveDeviceChoiceStore.persisted(defaults),
                      hasSavedRing: RingScanner.hasSavedRingToRestore,
                      hasStrapKey: (keyStore ?? HelioKeyStore.shared).hasKey)
        }
    }

    enum Page: Int, CaseIterable {
        case welcome, choose, gettingStarted, permissions, finish
    }

    /// The last page's primary button.
    enum Finish: Equatable {
        case getStarted
        /// Pushes the strap's existing setup screen inside onboarding.
        case setUpStrap

        var title: String {
            switch self {
            case .getStarted: return "Get Started"
            case .setUpStrap: return "Set up the strap"
            }
        }
    }

    let installed: Installed

    /// The device in use, if it's been set up (51d). A fresh install's ring default is not a ring in
    /// use, and a saved key alone doesn't make the strap the device in use.
    var inUse: ActiveDeviceChoice? {
        switch installed.persistedChoice {
        case .helioStrap: return .helioStrap
        case .ringConn: return installed.hasSavedRing ? .ringConn : nil
        }
    }

    /// The card picked when onboarding opens: the device in use, else none.
    var preselection: ActiveDeviceChoice? { inUse }

    /// The strap is chosen and has its key, so there's nothing left to set up.
    var strapIsSetUp: Bool { installed.persistedChoice == .helioStrap && installed.hasStrapKey }

    func finish(for pick: ActiveDeviceChoice?) -> Finish {
        pick == .helioStrap && !strapIsSetUp ? .setUpStrap : .getStarted
    }

    /// Shown on Getting started when the pick isn't the device in use.
    func switchNote(for pick: ActiveDeviceChoice?) -> String? {
        guard let pick, let inUse, pick != inUse else { return nil }
        return "You're using the \(inUse.displayName) now. To switch, go to Profile ▸ Device."
    }

    /// Where the strap is set up, while it isn't yet. Nil when the strap's steps aren't shown.
    func strapSetupHint(for pick: ActiveDeviceChoice?) -> String? {
        guard !strapIsSetUp else { return nil }
        switch pick {
        case .helioStrap: return "Set up the strap at the end of this guide, or later in Profile ▸ Device."
        case nil: return "Set it up in Profile ▸ Device."
        case .ringConn: return nil
        }
    }

    /// What VoiceOver reads for a card: the device, then its detail.
    func cardAccessibilityLabel(_ device: ActiveDeviceChoice) -> String {
        let base = "\(device.displayName). \(OnboardingCopy.cardDetail(device))"
        return inUse == device ? base + " In use" : base
    }

#if DEBUG && targetEnvironment(simulator)
    /// Screenshot hook (#255): `-OCOnboardingPage <id>` opens on that page with that pick. Simulator
    /// Debug builds only, like `DemoData`; never in Release.
    static let debugPageArgumentKey = "OCOnboardingPage"

    func debugStart(_ id: String) -> (page: Page, pick: ActiveDeviceChoice?)? {
        switch id {
        case "welcome": return (.welcome, preselection)
        case "choose": return (.choose, preselection)
        case "choose-strap": return (.choose, .helioStrap)
        case "start-ring": return (.gettingStarted, .ringConn)
        case "start-strap": return (.gettingStarted, .helioStrap)
        case "permissions": return (.permissions, preselection)
        case "last-ring": return (.finish, .ringConn)
        case "last-strap": return (.finish, .helioStrap)
        default: return nil
        }
    }
#endif
}

/// Onboarding's copy. Every device claim comes from copy already in the app or the README, and the
/// strap's warnings are `HelioStatus`'s own constants, so the two screens can't drift apart.
enum OnboardingCopy {
    static let welcome = [
        "OpenCircuit works with a RingConn ring (Gen 2, Gen 2 Air or Gen 3) or the Amazfit Helio Strap.",
        "It reads your wearable's metrics over Bluetooth — heart rate, HRV, SpO₂, sleep, skin "
            + "temperature and more.",
        "It's local-first: your data stays on your device and is written only to Apple Health. "
            + "Nothing is sent to any server.",
        "No subscription, no cloud. The ring needs no account. The strap needs the Zepp app once, to "
            + "create its key; after that, OpenCircuit talks only to the strap.",
    ]

    /// `DeviceChoiceView`'s row details and footer (Profile ▸ Device).
    static func cardDetail(_ device: ActiveDeviceChoice) -> String {
        switch device {
        case .ringConn: return "RingConn Gen 2, Gen 2 Air or Gen 3. No account needed."
        case .helioStrap: return "Needs a one-time key from the Zepp app (see setup)."
        }
    }
    static let oneAtATime = "OpenCircuit uses one device at a time. Switching keeps both devices' history on this "
        + "phone; the other device isn't searched for or connected until you switch back."
    static let changeLater = "You can change it later in Profile ▸ Device."

    /// The ring's first steps, unchanged since #106.
    static let ringSteps = [
        "No RingConn account and no official app needed — OpenCircuit connects to your ring on its own, "
            + "even a brand-new ring straight out of the box.",
        "If the official RingConn app is installed, fully close it (swipe it away) before using "
            + "OpenCircuit — only one app can talk to the ring at a time.",
        "Keep your phone nearby — especially overnight — so OpenCircuit can capture your full night of "
            + "sleep and skin-temperature data.",
        "Charge the ring as usual; OpenCircuit picks up where it left off.",
    ]

    /// `HelioSetupView`'s "Before you start" key bullet.
    static let strapKey = "The strap talks only to an app that knows its 16-byte key. The Zepp app creates the "
        + "key once, when you pair the strap. OpenCircuit never signs in to Zepp."
    static var keyGuideURL: URL { HelioStatus.keyGuideURL }
    /// Decision 6's warnings, by reference.
    static var strapWarnings: [String] { [HelioStatus.dontUnpairCopy, HelioStatus.zeppBluetoothCopy] }

    static let bluetoothPermission = "Bluetooth — to find and connect to your ring or strap."

    /// The not-affiliated and not-a-medical-device text, shared by onboarding's last page and
    /// Profile ▸ About so they can't drift apart again. Names match the README's (#225).
    static let disclaimer = "OpenCircuit is an independent, local-first app compatible with RingConn Gen 2, "
        + "Gen 2 Air and Gen 3 smart rings and the Amazfit Helio Strap. It is not affiliated with, "
        + "authorized, or endorsed by RingConn, JZ_Tech, Amazfit or Zepp Health; \"RingConn\", "
        + "\"Amazfit\", \"Helio\" and \"Zepp\" are trademarks of their respective owners. OpenCircuit "
        + "is not a medical device. Its readings are estimates for personal insight, not diagnosis. "
        + "Talk to a clinician about any health concern."
}
