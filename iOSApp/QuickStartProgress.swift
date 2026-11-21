import Foundation

/// Tutorial bookkeeping is independent of profiles, bridge choices and held input.
/// Existing installations never acquire a new prompt just because the app updates.
struct QuickStartProgress {
    static let key = "controller.quick-start.v1"
    private let defaults: UserDefaults
    private struct Record: Codable {
        let version: Int
        let completed: Bool
        let offerStarter: Bool
    }
    struct LaunchDecision: Equatable {
        let showTutorial: Bool
        let showStarter: Bool
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func begin(isNewLibrary: Bool) -> LaunchDecision {
        if let raw = defaults.data(forKey: Self.key) {
            // Preserve an unreadable or newer record. Help remains available manually.
            guard let record = try? JSONDecoder().decode(Record.self, from: raw), record.version == 1 else {
                return LaunchDecision(showTutorial: false, showStarter: isNewLibrary)
            }
            return LaunchDecision(showTutorial: !record.completed,
                                  showStarter: record.completed && isNewLibrary)
        }
        guard isNewLibrary else { return LaunchDecision(showTutorial: false, showStarter: false) }
        save(Record(version: 1, completed: false, offerStarter: true))
        return LaunchDecision(showTutorial: true, showStarter: false)
    }

    /// Completing or skipping the initial guide may continue to the starter picker.
    /// Replaying the guide from Support does not call this method or change settings.
    func finish() -> Bool {
        guard let raw = defaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(Record.self, from: raw),
              record.version == 1, !record.completed else { return false }
        save(Record(version: 1, completed: true, offerStarter: false))
        return record.offerStarter
    }

    private func save(_ record: Record) {
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Self.key) }
    }
}

enum SimpleControllerSupport {
    static let project = URL(string: "https://github.com/kortorder/simplecontroller-ios")!
    static let issues = URL(string: "https://github.com/kortorder/simplecontroller-ios/issues")!
    static let privacy = URL(string: "https://github.com/kortorder/simplecontroller-ios/blob/main/docs/PRIVACY.md")!
    static let faq = URL(string: "https://github.com/kortorder/simplecontroller-ios/blob/main/FAQ.txt")!
    static let videos = URL(string: "https://github.com/kortorder/simplecontroller-ios/releases")!
    static let wifiBridge = URL(string: "https://github.com/kortorder/simplecontroller-pico-wifi-bridge")!
    static let pcReceiver = URL(string: "https://github.com/kortorder/simplecontroller-ios/tree/main/receiver")!
    static let chairBridge = URL(string: "https://github.com/kortorder/omni2-pico-xbox-joystick")!
    static let githubPrivacy = URL(string: "https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement")!
}
