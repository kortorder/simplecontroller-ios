import Foundation
@main struct Checks {
 static func main() throws {
  let name = "sc-quick-start-test-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: name)!
  defer { defaults.removePersistentDomain(forName: name) }
  defaults.set(Data([1,2,3]), forKey: "controller.profiles.v1")
  defaults.set("existing bridge", forKey: "bridge.host")
  let old = defaults.persistentDomain(forName: name)! as NSDictionary
  let progress = QuickStartProgress(defaults: defaults)
  precondition(progress.begin(isNewLibrary: false) == .init(showTutorial: false, showStarter: false))
  precondition(defaults.persistentDomain(forName: name)! as NSDictionary == old, "Upgrade must change no preferences")
  precondition(progress.begin(isNewLibrary: true) == .init(showTutorial: true, showStarter: false))
  precondition(QuickStartProgress(defaults: defaults).begin(isNewLibrary: false).showTutorial, "Interrupted first-run guide resumes")
  precondition(progress.finish(), "Initial guide continues to game starters")
  precondition(!progress.finish(), "Finishing is idempotent")
  precondition(progress.begin(isNewLibrary: false) == .init(showTutorial: false, showStarter: false))
  precondition(progress.begin(isNewLibrary: true) == .init(showTutorial: false, showStarter: true))
  precondition(defaults.data(forKey: "controller.profiles.v1") == Data([1,2,3]))
  precondition(defaults.string(forKey: "bridge.host") == "existing bridge")
  let malformed = Data("not valid".utf8)
  defaults.set(malformed, forKey: QuickStartProgress.key)
  precondition(!progress.begin(isNewLibrary: false).showTutorial)
  precondition(!progress.finish())
  precondition(defaults.data(forKey: QuickStartProgress.key) == malformed)
  let newer = Data(#"{"version":99,"completed":false,"offerStarter":true}"#.utf8)
  defaults.set(newer, forKey: QuickStartProgress.key)
  precondition(!progress.begin(isNewLibrary: false).showTutorial)
  precondition(defaults.data(forKey: QuickStartProgress.key) == newer)
  let links = [SimpleControllerSupport.project, .init(string: "https://github.com/kortorder/simplecontroller-ios/issues")!, SimpleControllerSupport.issues, SimpleControllerSupport.faq, SimpleControllerSupport.videos, SimpleControllerSupport.wifiBridge, SimpleControllerSupport.chairBridge, SimpleControllerSupport.pcReceiver, SimpleControllerSupport.privacy, SimpleControllerSupport.githubPrivacy]
  precondition(links.allSatisfy { $0.scheme == "https" && ["github.com", "docs.github.com"].contains($0.host ?? "") })
  precondition(SimpleControllerSupport.pcReceiver.path == "/kortorder/simplecontroller-ios/tree/main/receiver")
  precondition(SimpleControllerSupport.wifiBridge.path == "/kortorder/simplecontroller-pico-wifi-bridge")
  precondition(SimpleControllerSupport.chairBridge.path == "/kortorder/omni2-pico-xbox-joystick")
  precondition(SimpleControllerSupport.faq.path.hasSuffix("/FAQ.txt"))
  print("PASS: 20 first-run persistence and support-destination checks")
 }
}
