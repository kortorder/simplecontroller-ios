import SwiftUI
import UIKit
import ControllerCore

@MainActor
struct ContentView: View {
    @StateObject private var model = ProfileControllerViewModel()
    @StateObject private var toolbarPositions = ControllerToolbarPositionModel.shared
    @State private var toolbarIssue: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingControls = false
    @State private var nextTool: ControllerTool?
    @State private var historyForTool: PracticeOutputSnapshot?
    @State private var showingSettings = false
    @State private var showingBridgeSettings = false
    @State private var connectAfterBridgeSettings = false
    @State private var showingBridgeStatus = false
    @State private var confirmingProfilesRestore = false
    @State private var showingProfiles = false
    @State private var showingStarterWelcome = false
    @State private var showingQuickStart = false
    @State private var showingSupport = false
    @State private var didCheckQuickStart = false
    @State private var showingProfileOptions = false
    @State private var showingPages = false
    @State private var showingFloating = false
    @State private var showingDisplay = false
    @State private var outputSnapshot: PracticeOutputSnapshot?
    @State private var configuringControl: ControlSelection?

    private struct ControlSelection: Identifiable {
        let control: UUID
        var orientation: ControllerOrientation = .portrait
        var id: UUID { control }
    }

    private let background = Color(uiColor: ControllerAppearancePalette.background)
    private let accent = Color(uiColor: ControllerAppearancePalette.accent)
    private var preferredScheme: ColorScheme? {
        switch model.presentation.theme { case .dark: .dark; case .light: .light; case .system: nil }
    }

    var body: some View {
        GeometryReader { geometry in
            // Keep the toolbars within the safe area, while the controller itself
            // includes the space around the home indicator and display corners.
            let insets = geometry.safeAreaInsets
            let fullSize = CGSize(width: geometry.size.width + insets.leading + insets.trailing,
                                  height: geometry.size.height + insets.top + insets.bottom)
            let orientation: ControllerOrientation = fullSize.width > fullSize.height ? .landscape : .portrait
            let toolbarWidth = min(176, fullSize.width - insets.leading - insets.trailing - 16)
            ZStack(alignment: .topLeading) {
                canvas(orientation: orientation)
                    .frame(width: fullSize.width, height: fullSize.height)
                if toolbarPositions.topMenuMinimized {
                    MovableControllerMenuButton(orientation: orientation, screenSize: fullSize,
                        safeInsets: insets, onMove: model.releaseAll,
                        reopen: { setTopMenuMinimized(false) })
                } else {
                    controllerToolbar
                        .padding(4)
                        .frame(width: min(300, fullSize.width - insets.leading - insets.trailing - 16))
                        .fixedSize(horizontal: false, vertical: true)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.2)).allowsHitTesting(false))
                        .frame(width: fullSize.width, alignment: .top)
                        .padding(.top, insets.top + 2)
                }
                if toolbarPositions.actionsMenuMinimized {
                    MovableControllerMenuButton(orientation: orientation, screenSize: fullSize,
                        safeInsets: insets, id: "actionsMenuButton", label: "Open actions menu",
                        symbol: "slider.horizontal.3", defaultAnchor: CGPoint(x: 1, y: 1),
                        onMove: model.releaseAll, reopen: { setActionsMenuMinimized(false) })
                } else {
                    MovableControllerToolbar(id: "actions", title: "actions", orientation: orientation,
                        screenSize: fullSize, safeInsets: insets,
                        defaultAnchor: CGPoint(x: orientation == .landscape ? 1 : 0.5, y: 1),
                        width: toolbarWidth, onMove: model.releaseAll,
                        onMinimize: { setActionsMenuMinimized(true) }) { vertical in
                        layoutActions(orientation: orientation, vertical: vertical)
                    }
                }
            }
            .frame(width: fullSize.width, height: fullSize.height)
            .offset(x: -insets.leading, y: -insets.top)
        }
        .background(background.ignoresSafeArea())
        .preferredColorScheme(preferredScheme)
        .background(ControllerOrientationAdapter(preference: model.requestedOrientation, onError: model.reportBackupMessage).frame(width: 0, height: 0))
        .tint(accent)
        .alert("Menu setting not saved", isPresented: Binding(get: { toolbarIssue != nil }, set: { if !$0 { toolbarIssue = nil } })) {
            Button("OK", role: .cancel) { toolbarIssue = nil }
        } message: { Text(toolbarIssue ?? "") }
        .onChange(of: model.buttonFeedbackGeneration) { _, _ in
            guard !model.latestButtonFeedback.isEmpty else { return }
            UISelectionFeedbackGenerator().selectionChanged()
        }
        .sheet(isPresented: $showingControls, onDismiss: openSelectedTool) {
            ControllerToolsPanel(model: model, choose: chooseTool)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showingSettings, onDismiss: { model.finishSettings() }) { connectionSettings }
        .sheet(isPresented: $showingBridgeSettings, onDismiss: bridgeSettingsDismissed) { bridgeSettings }
        .alert("Bridge status", isPresented: $showingBridgeStatus) {
            Button("OK", role: .cancel) { }
        } message: { Text(model.statusDetail) }
        .sheet(item: $outputSnapshot, onDismiss: { model.finishSettings() }) { snapshot in
            PracticeOutputHistoryView(snapshot: snapshot, clearHistory: model.clearPracticeHistory)
        }
        .onAppear {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains(DebugApprovedGTA6LiveStickUpdate.argument) {
                model.applyRequestedApprovedGTA6LiveStickUpdate()
            } else if ProcessInfo.processInfo.arguments.contains(DebugApprovedGTA6DrivingUpdate.argument) {
                model.applyRequestedApprovedGTA6DrivingUpdate()
            } else if ProcessInfo.processInfo.arguments.contains(DebugApprovedGTA6WalkUpdate.argument) {
                model.applyRequestedApprovedGTA6WalkUpdate()
            } else if ProcessInfo.processInfo.arguments.contains(DebugButtonSwipeUpdate.argument) {
                model.applyRequestedButtonSwipeUpdate()
            } else {
                model.applyRequestedProfileUpdate()
            }
#endif
            model.setForeground(scenePhase == .active, didEnterBackground: scenePhase == .background)
            presentInitialGuideIfNeeded()
        }
        .sheet(isPresented: $showingQuickStart, onDismiss: initialGuideDismissed) {
            NavigationStack { AppQuickStartView(onFinish: { showingQuickStart = false }) }
        }
        .sheet(isPresented: $showingSupport, onDismiss: { model.finishControlConfiguration() }) {
            NavigationStack {
                AppHelpView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSupport = false } } }
            }
        }
        .sheet(isPresented: $showingStarterWelcome, onDismiss: { model.finishProfileManagement() }) {
            NavigationStack {
                GameStarterPicker(model: model, welcome: true, onFinish: { showingStarterWelcome = false })
            }
        }
        .sheet(isPresented: $showingProfiles, onDismiss: { model.finishProfileManagement() }) {
            ProfileManagerView(model: model)
        }
        .sheet(isPresented: $showingProfileOptions, onDismiss: { model.finishControlConfiguration() }) {
            ProfileOptionsView(profile: model.profile, onSave: model.saveProfileOptions)
        }
        .sheet(isPresented: $showingPages, onDismiss: { model.finishControlConfiguration() }) {
            ProfilePagesView(profile: model.profile, selectedPageID: model.currentPageID,
                             sourceProfiles: model.library.profiles, onSave: model.savePages)
        }
        .sheet(isPresented: $showingFloating, onDismiss: { model.finishControlConfiguration() }) {
            FloatingControlsEditor(profile: model.profile, pageID: model.currentPageID,
                                   snapshots: model.floatingCanvasSnapshots, settingsPresets: model.library.settingsPresets,
                                   onSavePresets: model.saveSettingsPresets, onUnfloat: model.restoreFloatingButtons, onSave: model.saveFloatingDraft)
        }
        .sheet(isPresented: $showingDisplay, onDismiss: { model.finishControlConfiguration() }) {
            DisplaySettingsView(preferences: model.presentation, editorOrientation: model.editorOrientation,
                                isEditing: model.isEditingLayout, onSave: model.savePresentation)
        }
        .sheet(item: $configuringControl, onDismiss: { model.finishControlConfiguration() }) { selection in
            if let control = model.profile.control(for: selection.control) {
                ProfileControlEditor(control: control, pages: model.profile.pages, availableControls: model.profile.controls, orientation: selection.orientation, pageID: model.currentControlPage(control.id), canDuplicate: model.profile.controls.count < ControllerProfile.maximumControls,
                                     settingsPresets: model.library.settingsPresets, onSavePresets: model.saveSettingsPresets,
                                     onSave: { model.saveControl($0, onPage: $1) },
                                     onDuplicate: { model.duplicateControl($0, toPage: $1) }, onDelete: { id in
                    // Close the owning sheet before removing its backing item.
                    configuringControl = nil
                    model.deleteControl(id)
                })
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { connectAfterBridgeSettings = false; nextTool = nil; historyForTool = nil }
            model.setForeground(phase == .active, didEnterBackground: phase == .background)
            UIApplication.shared.isIdleTimerDisabled = model.keepsScreenAwake
        }
        .onChange(of: model.keepsScreenAwake) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
        .onDisappear {
            model.setForeground(false)
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func presentInitialGuideIfNeeded() {
        guard !didCheckQuickStart else { return }
        didCheckQuickStart = true
        let decision = QuickStartProgress().begin(isNewLibrary: model.takeStarterWelcome())
        if decision.showTutorial {
            model.beginProfileManagement()
            showingQuickStart = true
        } else if decision.showStarter {
            model.beginProfileManagement()
            showingStarterWelcome = true
        }
    }

    private func initialGuideDismissed() {
        model.finishProfileManagement()
        if QuickStartProgress().finish() {
            model.beginProfileManagement()
            showingStarterWelcome = true
        }
    }

    private func openSupport() {
        model.beginControlConfiguration()
        showingSupport = true
    }

    // A compact, fixed top menu. Only the separate actions toolbar moves.
    private var controllerToolbar: some View {
        VStack(spacing: 3) {
            Text("\(model.profile.name) · \(model.currentPage.name)")
                .font(.caption2.weight(.medium))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
            HStack(spacing: 3) {
                bridgeMenu
                profileButton
                pageMenu
                cameraButton
                allControlsButton
                Button { setTopMenuMinimized(true) } label: {
                    ControllerToolTile(title: "Hide", detail: "menu", symbol: "minus.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimize top menu")
                .accessibilityHint("Shows a small movable circle. Tap the circle to reopen this fixed menu.")
            }
            if model.mode == .practice && !model.isEditingLayout {
                PracticeOutputHeader(state: model.practiceState, showDesktop: hasDesktopOutputs,
                    showPointer: hasPointerOutputs, lastEvent: model.recentPracticeEvents.last,
                    showCameraFollow: model.hasCameraFollowOutputs,
                    cameraFollowSnapshot: model.cameraFollowSnapshot)
                    .foregroundStyle(accent)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityIdentifier("controller.topMenu")
    }

    private func setTopMenuMinimized(_ value: Bool) {
        model.releaseAll()
        do { try toolbarPositions.setTopMenuMinimized(value) }
        catch { toolbarIssue = error.localizedDescription }
    }

    private func setActionsMenuMinimized(_ value: Bool) {
        model.releaseAll()
        do { try toolbarPositions.setActionsMenuMinimized(value) }
        catch { toolbarIssue = error.localizedDescription }
    }

    private var cameraButton: some View {
        let inPractice = model.allowsDesktopControls && !model.isEditingLayout
        let badge = CameraFollowPresentation.badge(model.cameraFollowSnapshot)
        let detail = model.isEditingLayout ? "Editing layout" : inPractice ? badge.capitalized : "PC / Practice"
        return Button {
            guard let snapshot = model.cameraFollowSnapshot else { return }
            model.setCameraFollowEnabled(!snapshot.requestedEnabled)
        } label: {
            ControllerToolTile(title: "Camera", detail: detail, symbol: "camera", emphasized: inPractice && badge != "OFF")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera Follow").accessibilityValue(detail)
        .accessibilityHint("Turn Camera Follow on or off in Practice or Windows PC mode. Strength is in All controls.")
        .disabled(!inPractice || !model.controlsEnabled || model.cameraFollowSnapshot == nil)
    }

    private var allControlsButton: some View {
        let issueCount = controlNotices.count
        let detail = issueCount > 0 ? "\(issueCount) needing attention" :
            dynamicTypeSize.isAccessibilitySize ? "Profiles, pages, strength & settings" : "Settings, camera strength & status"
        return Button { showingControls = true } label: {
            ControllerToolTile(title: "Tools", detail: issueCount > 0 ? "\(issueCount) notices" : "Settings", symbol: "list.bullet", accessory: "chevron.right")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("All controls").accessibilityValue(detail)
        .accessibilityHint("Opens a full-size list of controller tools and settings.")
    }

    private var profileButton: some View {
        Button { openProfilesOrOptions() } label: {
            ControllerToolTile(title: model.isEditingLayout ? "Options" : "Profiles",
                               detail: model.canEditLayout ? model.profile.name : "Recovery",
                               symbol: "rectangle.stack", accessory: "chevron.right")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isEditingLayout ? "Profile options" : model.canEditLayout ? "Profiles, \(model.profile.name)" : "Profiles and recovery")
    }

    private var pageMenu: some View {
        Menu {
            ForEach(model.profile.pages) { page in
                Button { model.selectPage(page.id) } label: {
                    if page.id == model.currentPageID { Label(page.name, systemImage: "checkmark") }
                    else { Text(page.name) }
                }
            }
            if model.isEditingLayout {
                Divider()
                Button("Manage pages") { model.beginControlConfiguration(); showingPages = true }
            }
        } label: {
            ControllerToolTile(title: "Page", detail: model.currentPage.name, symbol: "rectangle.on.rectangle", accessory: "chevron.down")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("Current page, \(model.currentPage.name)")
        .accessibilityHint("Choose another page. Changing pages releases all held controls.")
    }

    private func openProfilesOrOptions() {
        if model.isEditingLayout { model.beginControlConfiguration(); showingProfileOptions = true }
        else { model.beginProfileManagement(); showingProfiles = true }
    }

    private func chooseTool(_ tool: ControllerTool) {
        // Capture held Practice outputs before opening history releases them.
        if tool == .history {
            historyForTool = PracticeOutputSnapshot(state: model.practiceState, events: model.recentPracticeEvents,
                                                    omittedCount: model.practiceEventsOmittedCount)
        }
        nextTool = tool
        showingControls = false
    }

    private func openSelectedTool() {
        guard let tool = nextTool else { return }
        nextTool = nil
        guard scenePhase == .active else { historyForTool = nil; return }
        switch tool {
        case .settings: model.prepareSettings(); showingSettings = true
        case .history:
            if let history = historyForTool { model.prepareSettings(); outputSnapshot = history }
            historyForTool = nil
        case .profile: openProfilesOrOptions()
        case .pages: model.beginControlConfiguration(); showingPages = true
        case .display: model.beginControlConfiguration(); showingDisplay = true
        case .support: openSupport()
        }
    }

    private var bridgeMenu: some View {
        BridgeActionMenu(isBridge: model.mode == .bridge, connectionRequested: model.connectionRequested,
                         editing: model.isEditingLayout, status: model.bridgeMenuStatus) { action in
            switch action {
            case .connect: connectFromMenu()
            case .disconnect: model.stop()
            case .settings: openBridgeSettings()
            case .details: showingBridgeStatus = true
            case .practice: model.setMode(.practice)
            case .support: openSupport()
            }
        }.equatable()
    }

    private func connectFromMenu() {
        if model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            openBridgeSettings()
        } else {
            model.setMode(.bridge)
            model.connect()
        }
    }

    private func openBridgeSettings() {
        connectAfterBridgeSettings = false
        model.prepareSettings()
        showingBridgeSettings = true
    }

    private func bridgeSettingsDismissed() {
        // Leaving settings releases inputs. Do that before opening a new session.
        let shouldConnect = connectAfterBridgeSettings
        connectAfterBridgeSettings = false
        model.finishSettings()
        if shouldConnect && scenePhase == .active {
            model.setMode(.bridge)
            model.connect()
        }
    }

    private var hasDesktopOutputs: Bool { model.hasDesktopOutputs }
    private var hasPointerOutputs: Bool { model.hasPointerOutputs }
    private var controlNotices: [UUID: String] {
        var notices = model.fixedStickIssues
        for (id, state) in model.floatingRingStates {
            if let issue = state.issue { notices[id] = issue }
        }
        return notices
    }
    private func canvas(orientation: ControllerOrientation) -> some View {
        ProfileCanvas(state: model.state, enabled: model.controlsEnabled,
                         profile: model.profile, pageID: model.currentPageID, orientation: orientation,
                         editing: model.isEditingLayout,
                         allowExtendedControls: model.mode == .practice,
                         allowDesktopControls: model.allowsDesktopControls,
                         allowTriggerControls: model.allowsTriggerControls,
                         activeControls: model.activeControls,
                         latchedControls: model.latchedControls,
                         retainedSticks: model.retainedSticks,
                         stickPositions: model.stickPositions,
                         buttonAimStates: model.buttonAimStates,
                         buttonDirectionalSelections: model.buttonDirectionalSelections,
                         touchAimStates: model.touchAimStates, touchAimScores: model.touchAimScores,
                         touchAimIssues: model.touchAimIssues,
                         floatingRingStates: model.floatingRingStates,
                         dismissedFloatingButtonSessions: model.dismissedFloatingButtonSessions,
                         activeTouchpads: model.activeTouchpads,
                         lockedTouchpads: model.lockedTouchpads,
                         pendingTouchpadLocks: model.pendingTouchpadLocks,
                         scrollModeEnabled: model.practiceState.scrollModeEnabled,
                         showCameraFollow: model.hasCameraFollowOutputs,
                         cameraFollowSnapshot: model.cameraFollowSnapshot,
                         autoCenterOverride: model.autoCenterOverride,
                         allSticksAutoCenterEnabled: model.allSticksAutoCenterEnabled,
                         autoCenterMixed: model.autoCenterMixed,
                         onProfileChange: { [epoch = model.inputEpoch] layout in
                             model.updateProfile(layout, epoch: epoch)
                         }, onInput: { [epoch = model.inputEpoch] event in
                             model.handleInput(event, epoch: epoch)
                         }, onConfigure: { control in
                             guard model.canEditBehaviors else { return }
                             model.beginControlConfiguration()
                             configuringControl = ControlSelection(control: control, orientation: orientation)
                         }, onMeasure: { snapshot, profile, page, measuredOrientation in
                             model.recordCanvasSnapshot(snapshot, profile: profile, pageID: page, orientation: measuredOrientation)
                         }, onIssue: model.reportBackupMessage)
        .id(model.inputEpoch)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.mode == .bridge && !model.isReady && scenePhase == .active &&
                !model.isEditingLayout && !model.isShowingSettings && !model.isManagingProfiles && !model.isConfiguringControl {
                Text(model.connectionRequested ? "Connecting automatically…\nControls are paused." : "Open Bridge menu → Connect bridge to play")
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .background(background.opacity(0.93), in: RoundedRectangle(cornerRadius: 16))
                    .padding(18)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func layoutActions(orientation: ControllerOrientation, vertical: Bool) -> some View {
        if model.isEditingLayout {
            actionStack(vertical: vertical) {
                Button { model.cancelLayoutEditing() } label: {
                    actionTile("Cancel", symbol: "xmark")
                }
                .accessibilityLabel("Cancel")
                Menu {
                    Group {
                    Button("Button") { addControl(.button, orientation: orientation) }
                    Button("Left stick") { addControl(.leftStick, orientation: orientation) }
                    Button("Right stick") { addControl(.rightStick, orientation: orientation) }
                    Button("Re-center") { addControl(.recenter, orientation: orientation) }
                    Button("Auto-center toggle") { addAutoCenterControl(orientation: orientation) }
                    Button("Touchpad") { addControl(.touchpad, orientation: orientation) }
                    Button("TouchAim") { addControl(.touchAim, orientation: orientation) }
                    Button("Page button") { addControl(.pageButton, orientation: orientation) }
                    }.disabled(model.profile.controls.count >= ControllerProfile.maximumControls)
                    Divider()
                    Button("Floating controls") { model.beginControlConfiguration(); showingFloating = true }
                    Button("Display and orientation") { model.beginControlConfiguration(); showingDisplay = true }
                } label: { actionTile("Add", symbol: "plus") }
                .menuIndicator(.hidden)
                .accessibilityLabel("Add control")
                Button { model.saveLayoutEditing() } label: {
                    actionTile("Save", symbol: "checkmark", emphasized: true)
                }
                .accessibilityLabel("Save layout")
            }
        } else {
            actionStack(vertical: vertical) {
                Button { model.beginLayoutEditing() } label: {
                    actionTile("Edit", symbol: "pencil", emphasized: true)
                }
                .disabled(!model.canEditLayout)
                .accessibilityLabel("Edit layout")
                .accessibilityHint("Pauses controls so you can drag each button and stick. Hold a control for settings. Save keeps both orientations.")
                Button { model.recenterSticks() } label: {
                    actionTile("Center", symbol: "scope", color: .orange)
                }
                .accessibilityLabel("Re-center sticks")
                .accessibilityHint("Centers both sticks and releases their Stick Plus actions. Separately held buttons remain held.")
                Button(action: model.releaseAll) {
                    actionTile("Stop", symbol: "stop.fill", color: .orange)
                }
                .accessibilityLabel("Release all controls")
                .accessibilityHint("Releases this phone's buttons, sticks and timed actions while keeping the bridge connection active.")
            }
        }
    }

    private func actionStack<Content: View>(vertical: Bool, @ViewBuilder content: () -> Content) -> some View {
        let stack = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
        return stack { content() }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
    }

    private func actionTile(_ title: String, symbol: String, color: Color? = nil, emphasized: Bool = false) -> some View {
        let tint = color ?? accent
        return VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
            Text(title).font(.system(size: 9, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(emphasized ? background : tint)
        .frame(width: 44, height: 44)
        .background(emphasized ? tint : tint.opacity(0.12), in: Circle())
        .contentShape(Circle())
    }

    private var bridgeSettings: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.bridgeProtocol == .windowsPC ? "Start the updated free Windows receiver. Use its IPv4 address and port; the iPhone and PC must share your local network. No Pico or adaptive controller is needed for PC play." : "Use the Pico’s Wi-Fi address. Your iPhone and Pico must be on the same network.")
                        .font(.subheadline)
                }
                bridgeAddress
                Section {
                    Button("Save and connect") {
                        model.saveSettings()
                        connectAfterBridgeSettings = true
                        showingBridgeSettings = false
                    }
                    .disabled(model.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Done saves your settings and updates an active connection. If disconnected, use Save and connect to start.")
                }
                bridgeOptions
            }
            .navigationTitle("Bridge settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.saveSettings(); showingBridgeSettings = false }
                }
            }
        }
    }

    private var bridgeAddress: some View {
        Section(model.bridgeProtocol == .windowsPC ? "Your Windows PC" : "Your Pico") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wi-Fi address").font(.caption).foregroundStyle(.secondary)
                TextField(model.bridgeProtocol == .windowsPC ? "PC IPv4 address" : "Bridge IPv4 address", text: $model.host)
                    .keyboardType(.decimalPad)
                    .textContentType(.none)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(model.bridgeProtocol == .windowsPC ? "PC IPv4 address" : "Bridge IPv4 address")
                    .accessibilityHint(model.bridgeProtocol == .windowsPC ? "Enter the IPv4 address printed by the Windows receiver." : "Enter the bridge address provided during setup, not the Xbox console address.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Port").font(.caption).foregroundStyle(.secondary)
                TextField("Port", text: $model.portText).keyboardType(.numberPad).accessibilityLabel("Port")
            }
        }
    }

    private var bridgeOptions: some View {
        Section("Bridge options") {
            Picker("Bridge protocol", selection: Binding(get: { model.bridgeProtocol }, set: { model.setBridgeProtocol($0) })) {
                ForEach(BridgeProtocolVersion.allCases, id: \.self) { item in Text(item.displayName).tag(item) }
            }
            Text(model.bridgeProtocol == .windowsPC
                 ? "Uses the updated free Windows receiver on the PC. Its default port is 42734; enter the port printed by the receiver. It releases this phone’s inputs if the connection is lost. Save and connect uses the typed address, and opening the app reconnects to your saved PC. Install the virtual-controller driver for gamepad output."
                 : model.bridgeProtocol == .scx2
                 ? "Pages, profiles and Stop (Release all) release inputs without disconnecting. Opening the app connects to your saved bridge with all controls released. Disconnect pauses until you leave and reopen. Practice stays offline until you choose Connect bridge."
                 : "Legacy SCX1 is retained for earlier test receivers. Select the protocol matching your receiver; the app never falls back automatically.")
                .font(.footnote).foregroundStyle(.secondary)
            if model.bridgeProtocol == .scx2 {
                Picker("LT and RT output", selection: Binding(
                    get: { model.bridgeTriggerMode }, set: { model.setBridgeTriggerMode($0) })) {
                    ForEach(BridgeTriggerMode.allCases, id: \.self) { mode in Text(mode.displayName).tag(mode) }
                }
                Text(triggerModeHelp)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var triggerModeHelp: String {
        switch model.bridgeTriggerMode {
        case .off:
            "Trigger controls are available in Practice. Select the output matching your Pico setup to use them on Xbox."
        case .usbButtons:
            "Use the XAC phone Pico firmware. In Xbox Accessories, assign X1 to LT and X2 to RT. Any pressure above zero becomes a full press; zero releases it. Saved pressure values stay unchanged."
        case .adjustable:
            "Use the analog-circuit Pico firmware and the added circuit connected to the Adaptive Controller's LT/RT jacks. Values such as RT:0.5 retain their requested pressure."
        case .cronusZen:
            "Use the Zen phone Pico firmware and plug that Pico into Cronus Zen. Values such as LT:0.5 and RT:0.7 keep their requested pressure over USB. The chair Pico can stay on the Adaptive Controller; combine the two Xbox connections with Controller Assist. This new setup needs its physical Xbox check."
        }
    }

    private var connectionSettings: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    NavigationLink("Theme and screen orientation") {
                        DisplaySettingsView(preferences: model.presentation, editorOrientation: model.editorOrientation,
                                            isEditing: false, wrapInNavigationStack: false, onSave: model.savePresentation)
                    }
                    if let issue = model.presentationIssue { Text(issue).foregroundStyle(.orange) }
                }
                bridgeAddress
                bridgeOptions
                Section {
                    Text(model.bridgeProtocol == .windowsPC ? "Start the updated Windows receiver, enter its IP and port, then tap Bridge menu → Connect bridge. Practice stays offline." : "On the controller screen, tap Bridge menu, then Connect bridge. Practice works without a Pico.")
                    Text("Allow Local Network access when iOS asks. Use the same trusted home network as the bridge.")
                    Text(model.bridgeProtocol == .windowsPC ? "PC play uses your local network and free receiver software. No Pico, adaptive controller or console adapter is needed." : "The Xbox stays connected to your TV. Your Adaptive Controller connects the bridge to the console.")
                } header: { Text("Before connecting") }
                Section("Hardware requirements") {
                    Label("Practice mode works without a bridge", systemImage: "hand.tap")
                    Label(model.bridgeProtocol == .windowsPC ? "Windows PC setup" : "The tested Xbox setup requires a Pico bridge and an Xbox Adaptive Controller", systemImage: model.bridgeProtocol == .windowsPC ? "desktopcomputer" : "wrench.and.screwdriver")
                    Text(model.bridgeProtocol == .windowsPC ? "Install the compatible Windows receiver and its virtual-gamepad driver. Support → PC contains the download and setup guide. Allow the receiver on your private network; do not forward its port to the Internet." : "The Pico USB path through the Xbox Adaptive Controller has been tested on Xbox, including LT/RT press and release. Use the matching firmware and Xbox Accessories mappings. The Cronus Zen route still requires its physical Xbox check.")
                }
                Section("Profiles and controls") {
                    Text("Use the profile button on the controller screen to create, copy, rename or switch profiles.")
                    Text("Tap Edit, then Add for a new control. Hold a control to change its name, size, actions or behavior, or to copy or delete it. Done updates the draft; Save layout keeps every change. Cancel on the controller restores the entire saved profile.")
                    Text("Portrait and landscape have separate positions. Each control can also use separate sizes; names and behaviors apply to both orientations.")
                    Text(model.bridgeProtocol == .windowsPC ? "PC controller output keeps analog LT/RT values and timed pulses. Keyboard, mouse, touchpad and Camera Follow can also control the PC. Xbox Guide and Share are unsupported by this receiver." : "Custom payloads set trigger pressure and timed pulses. In Bridge settings, select USB buttons for full presses, USB adjustable for Cronus Zen, or Adjustable for the analog circuit. Use the matching Pico firmware. Practice needs no hardware.")
                    Text("Profile options in Edit controls Turbo and sliding between controls. Each button can also use Auto-tap or Hold Toggle. Release all cancels every repeat and delayed action.")
                    if let message = model.message { Text(message).foregroundStyle(.secondary) }
                    Button("Restore profiles", role: .destructive) { confirmingProfilesRestore = true }
                }
                Section("Help and privacy") {
                    NavigationLink {
                        AppHelpView()
                    } label: {
                        Label("Support", systemImage: "lifepreserver")
                    }
                    .accessibilityHint("Read setup help, backup information and support options.")
                    NavigationLink {
                        AppPrivacyView()
                    } label: {
                        Label("Privacy policy", systemImage: "hand.raised")
                    }
                    .accessibilityHint("Read the privacy policy on this iPhone without an internet connection.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.saveSettings(); showingSettings = false }
                }
            }
            .confirmationDialog("Start a fresh profile library?", isPresented: $confirmingProfilesRestore, titleVisibility: .visible) {
                Button("Restore profiles", role: .destructive) { model.restoreProfiles() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This returns to the standard controller. A recovery copy of your previous saved profiles is kept on this phone.")
            }
        }
    }

    private func addAutoCenterControl(orientation: ControllerOrientation) {
        guard let id = model.addAutoCenterControl() else { return }
        model.beginControlConfiguration()
        configuringControl = ControlSelection(control: id, orientation: orientation)
    }

    private func addControl(_ kind: ProfileControlKind, orientation: ControllerOrientation) {
        guard let id = model.addControl(kind: kind) else { return }
        model.beginControlConfiguration()
        configuringControl = ControlSelection(control: id, orientation: orientation)
    }
}

/// Holds and repeating game inputs change much more often than the bridge menu.
/// Keep an open native menu stable until its actual label or actions change.
private struct BridgeActionMenu: View, Equatable {
    enum Action { case connect, disconnect, settings, details, practice, support }
    let isBridge: Bool
    let connectionRequested: Bool
    let editing: Bool
    let status: String
    let perform: (Action) -> Void
    private var accent: Color { Color(uiColor: ControllerAppearancePalette.accent) }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isBridge == rhs.isBridge && lhs.connectionRequested == rhs.connectionRequested &&
            lhs.editing == rhs.editing && lhs.status == rhs.status
    }

    var body: some View {
        Menu {
            Section("Controller connection") {
                if connectionRequested {
                    Button { perform(.disconnect) } label: {
                        Label("Disconnect bridge", systemImage: "xmark.circle")
                    }
                } else {
                    Button { perform(.connect) } label: {
                        Label("Connect bridge", systemImage: "wifi")
                    }
                }
                Button { perform(.settings) } label: {
                    Label("Bridge settings", systemImage: "gearshape")
                }
                if isBridge {
                    Button { perform(.details) } label: {
                        Label("Connection details", systemImage: "info.circle")
                    }
                }
            }
            Section {
                Button { perform(.support) } label: {
                    Label("Support: PC and console setup", systemImage: "lifepreserver")
                }
                Button { perform(.practice) } label: {
                    Label("Practice on this iPhone", systemImage: !isBridge ? "checkmark" : "hand.tap")
                }
            }
        } label: {
            ControllerToolTile(title: "Bridge", detail: status, symbol: "wifi", accessory: "chevron.down",
                               emphasized: isBridge)

        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .menuOrder(.fixed)
        .accessibilityLabel("Bridge menu")
        .accessibilityValue(status)
        .accessibilityHint("Connect to a Windows PC receiver or compatible console bridge, change connection settings, or use Practice.")
        .disabled(editing)
    }
}

private struct ControllerToolTile: View {
    let title: String
    let detail: String
    let symbol: String
    var accessory: String? = nil
    var emphasized = false
    private var accent: Color { Color(uiColor: ControllerAppearancePalette.accent) }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                if let accessory { Image(systemName: accessory).font(.system(size: 7, weight: .semibold)) }
            }.foregroundStyle(accent).frame(height: 13)
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 9, weight: .medium))
                .foregroundStyle(emphasized ? accent : Color(uiColor: .secondaryLabel))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 1)
        .background(accent.opacity(emphasized ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

}

private enum ControllerTool { case settings, history, profile, pages, display, support }

private struct ControllerToolsPanel: View {
    @ObservedObject var model: ProfileControllerViewModel
    let choose: (ControllerTool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { choose(.support) } label: {
                        Label("Support", systemImage: "lifepreserver")
                    }
                    .accessibilityHint("Quick-start pictures, PC and console setup, videos, and FAQ.")
                    .accessibilityIdentifier("tools.support")
                }
                Section("Camera Follow") {
                    if model.allowsDesktopControls && !model.isEditingLayout, let snapshot = model.cameraFollowSnapshot {
                        CameraFollowPracticeView(snapshot: snapshot, enabled: model.controlsEnabled,
                                                 onEnable: model.setCameraFollowEnabled, onStrength: model.setCameraFollowStrength)
                    } else {
                        Text(model.isEditingLayout ? "Save or cancel your edits to use Camera Follow in Practice." :
                             "Camera Follow works in Practice and Windows PC mode. It does not send camera movement to the Xbox bridge.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Controller tools") {
                    if !model.isEditingLayout {
                        Button { choose(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                    }
                    Button { choose(.profile) } label: {
                        Label(model.isEditingLayout ? "Profile options" : "Profiles: \(model.profile.name)", systemImage: "rectangle.stack")
                    }
                    Picker("Page", selection: Binding(get: { model.currentPageID }, set: { model.selectPage($0) })) {
                        ForEach(model.profile.pages) { Text($0.name).tag($0.id) }
                    }
                    if model.isEditingLayout {
                        Button("Manage pages") { choose(.pages) }
                        Button("Display and orientation") { choose(.display) }
                    }
                    if model.mode == .practice && !model.isEditingLayout && model.hasDesktopOutputs {
                        Button { choose(.history) } label: { Label("Practice output history", systemImage: "list.bullet.rectangle") }
                    }
                    if !model.isEditingLayout { Button("Release all controls", action: model.releaseAll) }
                }
                Section("Status") {
                    Text(model.statusTitle).font(.headline)
                    Text(model.statusDetail)
                    if let message = model.layoutMessage { Text(message) }
                    if model.profile.turboEnabled { Text("Turbo · \(model.profile.turboIntervalMilliseconds) ms interval") }
                    if model.profile.globalHoldEnabled { Text("Tap to hold ordinary buttons. Tap again to release.") }
                    if !model.latchedControls.isEmpty || !model.retainedSticks.isEmpty || !model.lockedTouchpads.isEmpty || !model.pendingTouchpadLocks.isEmpty {
                        Text("Held input active. Re-center stops sticks; Release all stops everything.")
                    }
                    if model.mode == .bridge {
                        Text(model.usesWindowsPC
                             ? "The Windows receiver supports controller, keyboard and mouse inputs. Xbox Guide and Share are not supported by that receiver."
                             : model.usesCronusZen
                             ? "LT/RT retain their pressure through the Zen Pico's USB output. Keyboard, mouse, Xbox and Share are Practice only."
                             : model.usesUSBButtonTriggers
                             ? "LT/RT are full press or release through X1/X2 USB buttons. Keyboard, mouse, Xbox and Share are Practice only."
                             : model.usesTriggerPressure
                             ? "Adjustable LT/RT requires the Pico’s analog trigger circuit. Keyboard, mouse, Xbox and Share are Practice only."
                             : "Keyboard, mouse, LT, RT, Xbox and Share are Practice only with the current bridge settings.")
                        if model.usesCronusZen { Text("Verify this new connection on Xbox before playing.") }
                    }
                }
                if !notices.isEmpty {
                    Section("Controls needing attention") {
                        ForEach(notices.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                            let name = model.profile.control(for: id)?.name ??
                                model.currentPage.floatingRingZones.first(where: { $0.id == id })?.name ?? "Floating control"
                            Text("\(name): \(notices[id] ?? "")")
                        }
                    }
                }
            }
            .navigationTitle("All controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private var notices: [UUID: String] {
        var notes = model.fixedStickIssues
        for (id, state) in model.floatingRingStates { if let issue = state.issue { notes[id] = issue } }
        return notes
    }
}
