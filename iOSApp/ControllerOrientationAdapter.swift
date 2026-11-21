import SwiftUI
import UIKit
import ControllerCore

extension ControllerDisplayOrientation {
    var interfaceMask: UIInterfaceOrientationMask {
        switch self { case .automatic: .allButUpsideDown; case .portrait: .portrait; case .landscape: .landscape }
    }
}

/// Register once using @UIApplicationDelegateAdaptor in the App. The adapter below
/// updates only its own scene; no global device orientation or private KVC is used.
@MainActor
final class ControllerOrientationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ControllerSceneOrientationCoordinator.shared.mask(for: window?.windowScene)
    }
}

/// Place in the controller view's background. The parent MUST release input and
/// invalidate its canvas epoch before changing preference; drawing still uses
/// actual view geometry, never the requested orientation.
@MainActor
struct ControllerOrientationAdapter: UIViewRepresentable {
    let preference: ControllerDisplayOrientation
    var onError: (String) -> Void = { _ in }
    func makeUIView(context: Context) -> ControllerOrientationRequestView {
        let view = ControllerOrientationRequestView(); view.configure(preference: preference, onError: onError); return view
    }
    func updateUIView(_ uiView: ControllerOrientationRequestView, context: Context) {
        uiView.configure(preference: preference, onError: onError)
    }
    static func dismantleUIView(_ uiView: ControllerOrientationRequestView, coordinator: ()) { uiView.invalidate() }
}

@MainActor
final class ControllerOrientationRequestView: UIView {
    private var preference: ControllerDisplayOrientation = .automatic
    private var onError: (String) -> Void = { _ in }
    private weak var requestedScene: UIWindowScene?
    private var requestedPreference: ControllerDisplayOrientation?
    private var requestID: UUID?
    private var activationObserver: NSObjectProtocol?
    override init(frame: CGRect) {
        super.init(frame: frame); isUserInteractionEnabled = false; isAccessibilityElement = false
        activationObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.request(force: true) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) } }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { invalidate() } else { request(force: false) }
    }
    func configure(preference: ControllerDisplayOrientation, onError: @escaping (String) -> Void) {
        self.preference = preference; self.onError = onError; request(force: false)
    }
    func invalidate() {
        if let requestedScene, let requestID {
            ControllerSceneOrientationCoordinator.shared.invalidate(scene: requestedScene, requestID: requestID)
        }
        requestedScene = nil; requestedPreference = nil; requestID = nil
    }
    private func request(force: Bool) {
        guard let scene = window?.windowScene, scene.activationState == .foregroundActive else { return }
        guard force || requestedScene !== scene || requestedPreference != preference else { return }
        requestedScene = scene; requestedPreference = preference
        requestID = ControllerSceneOrientationCoordinator.shared.request(preference, in: scene) { [weak self] message in
            self?.onError(message)
        }
    }
}

@MainActor
private final class ControllerSceneOrientationCoordinator {
    static let shared = ControllerSceneOrientationCoordinator()
    private final class Entry {
        weak var scene: UIWindowScene?
        let mask: UIInterfaceOrientationMask
        var requestID: UUID
        init(scene: UIWindowScene, mask: UIInterfaceOrientationMask, requestID: UUID) {
            self.scene = scene; self.mask = mask; self.requestID = requestID
        }
    }
    private var entries: [String: Entry] = [:]
    func mask(for scene: UIWindowScene?) -> UIInterfaceOrientationMask {
        guard let scene else { return .allButUpsideDown }
        return entries[scene.session.persistentIdentifier]?.mask ?? .allButUpsideDown
    }
    func invalidate(scene: UIWindowScene, requestID: UUID) {
        let key = scene.session.persistentIdentifier
        if entries[key]?.requestID == requestID { entries[key]?.requestID = UUID() }
    }
    func request(_ preference: ControllerDisplayOrientation, in scene: UIWindowScene,
                 onError: @escaping (String) -> Void) -> UUID {
        entries = entries.filter { $0.value.scene != nil }
        let key = scene.session.persistentIdentifier, token = UUID()
        entries[key] = Entry(scene: scene, mask: preference.interfaceMask, requestID: token)
        for window in scene.windows {
            if let root = window.rootViewController { updateSupportedOrientations(root) }
        }
        // Apple's documented iOS scene geometry API, available from iOS 16.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: preference.interfaceMask)) { [weak self] error in
            let reason = error.localizedDescription
            Task { @MainActor [weak self] in
                guard self?.entries[key]?.requestID == token else { return }
                onError("iOS could not apply \(preference.displayName.lowercased()) orientation: \(reason)")
            }
        }
        return token
    }
    private func updateSupportedOrientations(_ controller: UIViewController) {
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        for child in controller.children { updateSupportedOrientations(child) }
        if let presented = controller.presentedViewController { updateSupportedOrientations(presented) }
    }
}
