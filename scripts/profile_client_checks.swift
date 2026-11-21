import Foundation
import ControllerCore

@MainActor
final class ProfileCheckTransport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var sent: [BridgePacket] = []
    var closed: [BridgePacket] = []
    var opens = 0
    func open(host: String, port: UInt16) { opens += 1; onReady?() }
    func send(_ data: Data) { sent.append(try! BridgeCodec.decode(data)) }
    func close(afterSending data: Data?) {
        if let data { closed.append(try! BridgeCodec.decode(data)) }
    }
    func reply(_ packet: BridgePacket) { onMessage?(try! BridgeCodec.encode(packet)) }
}

@MainActor
final class ProfileSCX2Transport: BridgeTransporting {
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?
    var sent: [SCX2Packet] = []
    var closed: [SCX2Packet] = []
    func open(host: String, port: UInt16) { onReady?() }
    func send(_ data: Data) { sent.append(try! SCX2Codec.decode(data)) }
    func close(afterSending data: Data?) { if let data { closed.append(try! SCX2Codec.decode(data)) } }
    func reply(_ packet: SCX2Packet) { onMessage?(try! SCX2Codec.encode(packet)) }
    func acknowledge(_ packet: SCX2Packet) {
        reply(.init(kind: .ack, session: packet.session, boot: packet.boot, challenge: packet.challenge,
                    sequence: packet.sequence, hidReady: true))
    }
}

@MainActor
final class ProfileCheckClock { var time: TimeInterval = 10 }

@main
struct ProfileClientChecks {
    @MainActor
    static func main() async throws {
        var checks = 0
        var failures: [String] = []
        var suites: [String] = []
        defer { for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) } }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !condition() { failures.append(message); print("FAIL: \(message)") }
        }
        func freshDefaults() -> UserDefaults {
            let suite = "SimpleController.ProfileChecks.\(UUID().uuidString)"
            suites.append(suite)
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return defaults
        }
        func makeModel(_ defaults: UserDefaults, link: ProfileCheckTransport? = nil,
                       clock: ProfileCheckClock? = nil, persist: Bool = true) -> ProfileControllerViewModel {
            let activeLink = link ?? ProfileCheckTransport()
            let activeClock = clock ?? ProfileCheckClock()
            return ProfileControllerViewModel(defaults: defaults, transport: activeLink, clock: { activeClock.time },
                                              automaticTimer: false, persistSettings: persist)
        }
        func input(_ model: ProfileControllerViewModel, _ event: ProfileInputEvent) {
            model.handleInput(event, epoch: model.inputEpoch)
        }
        func legacyID(_ profile: ControllerProfile, _ control: ControllerControlID) -> UUID {
            profile.controls.first { item in
                control.isStick ? item.logicalStick == control : item.kind == .button && item.actions == [control]
            }!.id
        }
        func position(_ profile: ControllerProfile, _ id: UUID,
                      _ orientation: ControllerOrientation) -> NormalizedControlPosition? {
            profile.placements(for: orientation).first { $0.id == id }?.position
        }
        func activateBridge(_ model: ProfileControllerViewModel, _ link: ProfileCheckTransport) -> String {
            model.setBridgeProtocol(.scx1)
            model.setMode(.bridge)
            model.host = "192.168.1.80"
            model.portText = "42735"
            model.connect()
            let session = link.sent.last!.session
            link.reply(.init(kind: .ready, session: session, sequence: 0, hidReady: true))
            return session
        }

        // Preserve authentic legacy fixtures as current schemas acquire unrelated fields.
        func legacyJSON(_ object: [String: Any]) -> [String: Any] {
            var fields = object
            let version = fields["version"] as? Int ?? ControllerProfileLibrary.currentVersion
            if version < 14 { fields.removeValue(forKey: "settingsPresets") }
            if var profiles = fields["profiles"] as? [[String: Any]] {
                for i in profiles.indices {
                    if version < 19, var sources = profiles[i]["androidSources"] as? [[String: Any]] {
                        for j in sources.indices {
                            for key in ["pages", "controls", "zones"] {
                                if var bindings = sources[j][key] as? [[String: Any]] {
                                    for k in bindings.indices { bindings[k].removeValue(forKey: "floatingRestoration") }
                                    sources[j][key] = bindings
                                }
                            }
                        }
                        profiles[i]["androidSources"] = sources
                    }
                    if version < 16, var sources = profiles[i]["androidSources"] as? [[String: Any]] {
                        for j in sources.indices {
                            sources[j].removeValue(forKey: "zones")
                            if var baseline = sources[j]["exportBaseline"] as? [String: Any] {
                                baseline["version"] = 1; baseline.removeValue(forKey: "zones")
                                sources[j]["exportBaseline"] = baseline
                            }
                        }
                        profiles[i]["androidSources"] = sources
                    }
                    if version < 13 { profiles[i].removeValue(forKey: "globalHoldEnabled") }
                    if version < 12, var pages = profiles[i]["pages"] as? [[String: Any]] {
                        for j in pages.indices { pages[j].removeValue(forKey: "floatingButtonZones"); pages[j].removeValue(forKey: "floatingRingZones") }
                        profiles[i]["pages"] = pages
                    }
                    if version < 17, var controls = profiles[i]["controls"] as? [[String: Any]] {
                        for j in controls.indices {
                            for key in ["cameraFollowStrengthPercent", "excludeFromCameraFollow", "mouseSuppressCameraFollow"] { controls[j].removeValue(forKey: key) }
                        }
                        profiles[i]["controls"] = controls
                    }
                    if version < 18, var controls = profiles[i]["controls"] as? [[String: Any]] {
                        for j in controls.indices { controls[j].removeValue(forKey: "floatingAction") }
                        profiles[i]["controls"] = controls
                    }
                    if version < 19, var controls = profiles[i]["controls"] as? [[String: Any]] {
                        for j in controls.indices { controls[j].removeValue(forKey: "orientationDimensions") }
                        profiles[i]["controls"] = controls
                    }
                    if version < 20, var controls = profiles[i]["controls"] as? [[String: Any]] {
                        for j in controls.indices { controls[j].removeValue(forKey: "stickPlusRepeatIntervalMilliseconds") }
                        profiles[i]["controls"] = controls
                    }
                    if version < 22, var controls = profiles[i]["controls"] as? [[String: Any]] {
                        for j in controls.indices { controls[j].removeValue(forKey: "macroModeEnabled") }
                        profiles[i]["controls"] = controls
                    }
                    if version < 15, var controls = profiles[i]["controls"] as? [[String: Any]] {
                        for j in controls.indices {
                            if var aim = controls[j]["touchAim"] as? [String: Any] { aim.removeValue(forKey: "requiresLocalSetup"); controls[j]["touchAim"] = aim }
                        }
                        profiles[i]["controls"] = controls
                    }
                }
                fields["profiles"] = profiles
            }
            return fields
        }

        // Migrate the user's previous layout and behaviors exactly once, retaining recovery bytes.
        let migrationDefaults = freshDefaults()
        var legacyLayout = ControllerLayout.default
        try legacyLayout.move(.b, to: .init(x: 0.81, y: 0.91), orientation: .portrait)
        try legacyLayout.move(.b, to: .init(x: 0.43, y: 0.27), orientation: .landscape)
        var legacyBehaviors = ControllerBehaviors.default
        try legacyBehaviors.setButton(.init(holdToggle: true, holdMilliseconds: 700), for: .b)
        var oldStick = StickBehavior(autoCenter: false, stickPlusEnabled: true,
                                     boostThreshold: 0.4, superBoostThreshold: 0.8)
        oldStick.directions[.up] = .init(normalControls: [.x], boostControls: [.leftStickClick],
                                        superBoostControls: [.a])
        try legacyBehaviors.setStick(oldStick, for: .leftStick)
        let layoutBytes = try ControllerLayoutCodec.encode(legacyLayout)
        let behaviorBytes = try ControllerBehaviorsCodec.encode(legacyBehaviors)
        migrationDefaults.set(layoutBytes, forKey: "controller.layout.v1")
        migrationDefaults.set(behaviorBytes, forKey: "controller.behaviors.v1")
        let migrationClock = ProfileCheckClock()
        let migrationLink = ProfileCheckTransport()
        let migrated = makeModel(migrationDefaults, link: migrationLink, clock: migrationClock)
        let bID = legacyID(migrated.profile, .b)
        let leftID = legacyID(migrated.profile, .leftStick)
        require(migrated.profile.controls.count == 20 && Set(migrated.profile.controls.map(\.id)).count == 20,
                "Migration creates 20 distinct control instances")
        require(position(migrated.profile, bID, .portrait) == .init(x: 0.81, y: 0.91) &&
                position(migrated.profile, bID, .landscape) == .init(x: 0.43, y: 0.27),
                "Migration keeps separate custom portrait and landscape positions")
        require(migrated.profile.control(for: bID)?.buttonBehavior == legacyBehaviors.button(for: .b) &&
                migrated.profile.control(for: leftID)?.stickBehavior == oldStick,
                "Migration keeps custom hold timing, retention, thresholds and stage actions")
        require(migrationDefaults.data(forKey: "controller.layout.v1") == layoutBytes &&
                migrationDefaults.data(forKey: "controller.behaviors.v1") == behaviorBytes,
                "Migration retains both exact legacy documents")
        let firstLibrary = migrated.library
        let firstBytes = migrationDefaults.data(forKey: ProfileControllerViewModel.libraryKey)!
        let migratedAgain = makeModel(migrationDefaults)
        require(migratedAgain.library == firstLibrary &&
                migrationDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == firstBytes,
                "Restart loads the migrated IDs instead of migrating again")
        migrationDefaults.set(try ControllerLayoutCodec.encode(.default), forKey: "controller.layout.v1")
        require(makeModel(migrationDefaults).library == firstLibrary,
                "An existing profile library takes precedence over later legacy changes")

        // Runtime input is never written into the profile document or restored as held input.
        input(migrated, .begin(contact: 1, control: bID, position: .zero))
        migrationClock.time += 0.71
        migrated.tickInput()
        input(migrated, .end(contact: 1))
        input(migrated, .begin(contact: 2, control: leftID, position: .init(x: 0, y: 1)))
        input(migrated, .end(contact: 2))
        require(migrated.state.buttons == [.a, .b] && migrated.latchedControls == [bID] &&
                migrated.retainedSticks == [leftID], "Migrated behavior produces independent held owners")
        require(migrationLink.sent.isEmpty && migrationDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == firstBytes,
                "Practice input neither sends packets nor persists runtime owners")
        let neutralRestart = makeModel(migrationDefaults)
        require(neutralRestart.state.isNeutral && neutralRestart.latchedControls.isEmpty &&
                neutralRestart.retainedSticks.isEmpty && neutralRestart.activeControls.isEmpty &&
                neutralRestart.stickPositions.isEmpty, "Restart is neutral despite previously latched and retained input")

        // Ordinary actions must not overwrite unsupported or corrupt current/legacy documents.
        let future = Data("{\"version\":999,\"future\":\"keep me\"}".utf8)
        let corrupt = Data([0xff, 0x00, 0x7b])
        let protectedFixtures: [(String, Data)] = [
            (ProfileControllerViewModel.libraryKey, future), (ProfileControllerViewModel.libraryKey, corrupt),
            ("controller.layout.v1", future), ("controller.layout.v1", corrupt),
            ("controller.behaviors.v1", future), ("controller.behaviors.v1", corrupt)
        ]
        for (key, raw) in protectedFixtures {
            let defaults = freshDefaults()
            defaults.set(raw, forKey: key)
            let model = makeModel(defaults)
            let originalCurrent = defaults.data(forKey: ProfileControllerViewModel.libraryKey)
            let originalFallback = model.library
            model.beginLayoutEditing()
            model.saveLayoutEditing()
            require(!model.canEditLayout && !model.isEditingLayout && model.message != nil,
                    "Protected \(key) data blocks editing and explains recovery")
            require(!model.createProfile(name: "Do not overwrite", standardControls: false) &&
                    !model.renameProfile(model.profile.id, name: "Do not overwrite") &&
                    !model.duplicateProfile(model.profile.id) && !model.selectProfile(model.profile.id),
                    "Protected \(key) data blocks ordinary library changes")
            require(defaults.data(forKey: key) == raw &&
                    defaults.data(forKey: ProfileControllerViewModel.libraryKey) == originalCurrent &&
                    model.library == originalFallback, "Protected bytes survive attempted ordinary saves")
            require(model.exportProfiles() == nil && !model.importProfiles(firstBytes) &&
                    defaults.data(forKey: key) == raw,
                    "Protected current or legacy data cannot be exported as fallback profiles or overwritten by import")
            model.restoreProfiles()
            let recovered = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("controller.profiles.recovery.") }
                .values.compactMap { $0 as? Data }
            require(model.canEditLayout && recovered.contains(raw) &&
                    (try? ControllerProfileLibraryCodec.decode(defaults.data(forKey: ProfileControllerViewModel.libraryKey)!)) != nil,
                    "Explicit Restore makes a valid library and preserves the original recovery bytes")
            if key != ProfileControllerViewModel.libraryKey {
                require(defaults.data(forKey: key) == raw, "Restore never modifies the original legacy source bytes")
            }
        }

        // Draft changes include both placements and per-instance settings; Cancel discards all of them.
        let editorDefaults = freshDefaults()
        let editor = makeModel(editorDefaults)
        let original = editor.profile
        let originalBytes = editorDefaults.data(forKey: ProfileControllerViewModel.libraryKey)!
        let aID = legacyID(original, .a)
        let xID = legacyID(original, .x)
        input(editor, .begin(contact: 3, control: aID, position: .zero))
        let preEditEpoch = editor.inputEpoch
        editor.beginLayoutEditing()
        require(editor.isEditingLayout && !editor.controlsEnabled && editor.state.isNeutral &&
                editor.inputEpoch != preEditEpoch, "Beginning an edit releases input and invalidates old contacts")
        var modified = editor.profile.control(for: aID)!
        modified.name = "Jump and interact"
        modified.diameter = 112
        modified.actions = [.b, .x]
        modified.buttonBehavior = .init(holdToggle: true, holdMilliseconds: 900)
        editor.saveControl(modified)
        var movedDraft = editor.profile
        try movedDraft.move(aID, to: .init(x: 0.24, y: 0.77), orientation: .portrait)
        try movedDraft.move(aID, to: .init(x: 0.64, y: 0.32), orientation: .landscape)
        editor.updateProfile(movedDraft, epoch: editor.inputEpoch)
        editor.deleteControl(xID)
        let temporaryID = editor.addControl(kind: .recenter)!
        require(editor.profile.control(for: aID) == modified && editor.profile.control(for: xID) == nil &&
                editor.profile.control(for: temporaryID)?.kind == .recenter, "Draft accepts name, size, actions, behavior, delete and add")
        require(editorDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == originalBytes,
                "Editing does not persist the draft before Save")
        editor.cancelLayoutEditing()
        require(editor.profile == original && !editor.isEditingLayout &&
                editorDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == originalBytes,
                "Cancel restores all draft settings, placements and control membership")
        editor.handleInput(.begin(contact: 4, control: aID, position: .zero), epoch: preEditEpoch)
        require(editor.state.isNeutral, "A pre-edit touch cannot apply after Cancel")
        editor.beginLayoutEditing()
        editor.saveControl(modified)
        editor.updateProfile(movedDraft, epoch: editor.inputEpoch)
        editor.deleteControl(xID)
        let savedRecenter = editor.addControl(kind: .recenter)!
        let expectedSaved = editor.profile
        editor.saveLayoutEditing()
        require(editor.profile == expectedSaved && editor.library.activeProfile == expectedSaved && !editor.isEditingLayout,
                "Save commits all validated draft changes atomically")
        require(makeModel(editorDefaults).profile == expectedSaved && editor.profile.control(for: savedRecenter) != nil,
                "Saved size, remapping, timing, add/delete and both positions survive recreation")
        editor.beginLayoutEditing()
        var invalid = editor.profile.control(for: aID)!
        invalid.diameter = .nan
        editor.saveControl(invalid)
        require(editor.profile.control(for: aID) == modified && editor.message != nil,
                "Invalid control updates leave the existing draft unchanged")
        let validDraft = editor.profile
        let configurationEpoch = editor.inputEpoch
        editor.beginControlConfiguration()
        var staleDraft = validDraft
        try staleDraft.move(aID, to: .init(x: 0.1, y: 0.1), orientation: .portrait)
        editor.updateProfile(staleDraft, epoch: configurationEpoch)
        input(editor, .accessibilityActivate(aID))
        require(editor.profile == validDraft && !editor.controlsEnabled && editor.state.isNeutral,
                "The control settings modal preserves its draft and blocks stale drags/input")
        editor.finishControlConfiguration()
        editor.updateProfile(staleDraft, epoch: configurationEpoch)
        require(editor.profile == validDraft && !editor.controlsEnabled,
                "Closing control settings leaves editing paused and rejects its old epoch")
        editor.cancelLayoutEditing()

        // A completely empty canvas is valid, persistent and can receive new controls later.
        editor.beginLayoutEditing()
        for id in editor.profile.controls.map(\.id) { editor.deleteControl(id) }
        require(editor.profile.controls.isEmpty && editor.profile.portrait.isEmpty && editor.profile.landscape.isEmpty,
                "Deleting every instance leaves valid empty placement arrays")
        editor.saveLayoutEditing()
        let emptyRestart = makeModel(editorDefaults)
        require(emptyRestart.profile.controls.isEmpty && emptyRestart.state.isNeutral,
                "An empty canvas survives Save and recreation")
        emptyRestart.beginLayoutEditing()
        let addedA = emptyRestart.addControl(kind: .button)!
        let addedStick = emptyRestart.addControl(kind: .rightStick)!
        require(emptyRestart.profile.control(for: addedA)?.actions == [.a] &&
                emptyRestart.profile.control(for: addedStick)?.logicalStick == .rightStick &&
                emptyRestart.profile.portrait.count == 2 && emptyRestart.profile.landscape.count == 2,
                "Add repopulates an empty canvas with placements in both orientations")
        emptyRestart.cancelLayoutEditing()
        require(emptyRestart.profile.controls.isEmpty, "Cancel also discards additions to an empty canvas")

        // Copy creates a separate UUID and independent ownership even when outputs overlap.
        let copyDefaults = freshDefaults()
        let copyClock = ProfileCheckClock()
        let copyModel = makeModel(copyDefaults, clock: copyClock)
        let sourceID = legacyID(copyModel.profile, .a)
        copyModel.beginLayoutEditing()
        var source = copyModel.profile.control(for: sourceID)!
        source.actions = [.a, .b]
        source.name = "Shared actions"
        source.buttonBehavior = .init(holdToggle: true, holdMilliseconds: 500)
        copyModel.saveControl(source)
        let beforeCopyIDs = Set(copyModel.profile.controls.map(\.id))
        copyModel.duplicateControl(source)
        let copy = copyModel.profile.controls.first { !beforeCopyIDs.contains($0.id) }!
        require(copy.id != sourceID && copy.actions == source.actions &&
                copy.buttonBehavior == source.buttonBehavior && copy.name == "Shared actions copy",
                "Copy preserves settings under a fresh UUID and distinct name")
        require(position(copyModel.profile, copy.id, .portrait) != nil &&
                position(copyModel.profile, copy.id, .landscape) != nil,
                "Copy receives independent placements in both orientations")
        copyModel.saveLayoutEditing()
        input(copyModel, .accessibilityActivate(sourceID))
        input(copyModel, .accessibilityActivate(copy.id))
        require(copyModel.state.buttons == [.a, .b] && copyModel.latchedControls == [sourceID, copy.id],
                "Two copied toggles own the same actions independently")
        input(copyModel, .accessibilityActivate(sourceID))
        require(copyModel.state.buttons == [.a, .b] && copyModel.latchedControls == [copy.id],
                "Turning off one copied toggle cannot clear the other owner's actions")
        copyModel.releaseAll()
        require(copyModel.state.isNeutral && copyModel.latchedControls.isEmpty,
                "Release all clears every copied owner")
        copyModel.beginLayoutEditing()
        copyModel.deleteControl(copy.id)
        copyModel.saveLayoutEditing()
        input(copyModel, .accessibilityActivate(copy.id))
        require(copyModel.state.isNeutral, "A deleted instance cannot emit input from a late callback")

        // Profile CRUD preserves IDs, active selection, cloned instances and recoverable deletion.
        let profilesDefaults = freshDefaults()
        let profiles = makeModel(profilesDefaults)
        let firstID = profiles.profile.id
        let firstControlIDs = Set(profiles.profile.controls.map(\.id))
        require(profiles.createProfile(name: "Blank", standardControls: false), "Create accepts an empty named profile")
        let blankID = profiles.profile.id
        require(blankID != firstID && profiles.profile.controls.isEmpty && makeModel(profilesDefaults).profile.id == blankID,
                "Create selects and persists the new empty profile ID")
        require(profiles.renameProfile(blankID, name: "Quiet layout") &&
                makeModel(profilesDefaults).profile.name == "Quiet layout", "Rename persists without changing the active ID")
        let beforeInvalidRename = profilesDefaults.data(forKey: ProfileControllerViewModel.libraryKey)
        require(!profiles.renameProfile(blankID, name: "   ") &&
                profilesDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == beforeInvalidRename,
                "An invalid profile name never overwrites a valid library")
        require(profiles.selectProfile(firstID) && profiles.profile.id == firstID &&
                Set(profiles.profile.controls.map(\.id)) == firstControlIDs,
                "Select returns to the original profile and original instance IDs")
        require(profiles.duplicateProfile(firstID), "Duplicate creates a new active profile")
        let duplicatedID = profiles.profile.id
        let duplicatedControls = Set(profiles.profile.controls.map(\.id))
        require(duplicatedID != firstID && duplicatedControls.isDisjoint(with: firstControlIDs) &&
                duplicatedControls.count == firstControlIDs.count &&
                Set(profiles.profile.portrait.map(\.id)) == duplicatedControls &&
                Set(profiles.profile.landscape.map(\.id)) == duplicatedControls,
                "Profile duplication remaps every control and placement to fresh IDs")
        require(makeModel(profilesDefaults).library == profiles.library,
                "Duplicate profile data and active selection survive recreation")
        let deletedLibraryBytes = profilesDefaults.data(forKey: ProfileControllerViewModel.libraryKey)
        require(profiles.deleteProfile(duplicatedID) && profiles.profile.id == firstID &&
                profilesDefaults.data(forKey: "controller.profiles.before-delete.\(duplicatedID.uuidString)") == deletedLibraryBytes,
                "Deleting the active profile selects a remaining one and retains a recovery document")
        require(profiles.deleteProfile(blankID) && profiles.library.profiles.count == 1 &&
                !profiles.deleteProfile(firstID), "Deleting the final profile is blocked")
        require(makeModel(profilesDefaults).library == profiles.library,
                "Delete persists the valid remaining active profile")
        require(profiles.createProfile(name: "Standard", standardControls: true) && profiles.profile.controls.count == 20,
                "Create can also populate a profile with the standard control set")
        let standardID = profiles.profile.id
        let standardA = legacyID(profiles.profile, .a)
        input(profiles, .begin(contact: 100, control: standardA, position: .zero))
        let heldEpoch = profiles.inputEpoch
        require(profiles.state.buttons == [.a], "Profile input is active before a selection change")
        require(profiles.selectProfile(firstID) && profiles.state.isNeutral && profiles.activeControls.isEmpty &&
                profiles.inputEpoch != heldEpoch, "Selecting another profile clears all runtime input")
        profiles.handleInput(.begin(contact: 101, control: standardA, position: .zero), epoch: heldEpoch)
        profiles.tickInput(epoch: heldEpoch)
        require(profiles.state.isNeutral, "An old profile touch or timer cannot reactivate input after selection")
        require(profiles.selectProfile(standardID), "The saved standard profile remains selectable")
        input(profiles, .begin(contact: 102, control: standardA, position: .zero))
        require(profiles.renameProfile(standardID, name: "Renamed") && profiles.state.isNeutral,
                "Renaming a live profile also clears its runtime owners")
        profiles.beginLayoutEditing()
        let editingLibrary = profiles.library
        require(!profiles.selectProfile(firstID) && !profiles.createProfile(name: "Blocked", standardControls: false) &&
                !profiles.duplicateProfile(firstID) && !profiles.deleteProfile(firstID) && profiles.library == editingLibrary,
                "Profile operations cannot replace an unfinished edit draft")
        profiles.cancelLayoutEditing()

        // All modal settings and edit states pause input and do not silently reconnect.
        let modalDefaults = freshDefaults()
        let modalLink = ProfileCheckTransport()
        let modal = makeModel(modalDefaults, link: modalLink)
        let modalA = legacyID(modal.profile, .a)
        input(modal, .begin(contact: 200, control: modalA, position: .zero))
        modal.prepareSettings()
        input(modal, .begin(contact: 201, control: modalA, position: .zero))
        require(!modal.controlsEnabled && modal.state.isNeutral,
                "Outer Settings releases input and blocks contacts behind the modal")
        modal.finishSettings()
        require(modal.controlsEnabled && modal.state.isNeutral, "Closing Settings resumes neutral Practice only")
        modal.beginProfileManagement()
        input(modal, .begin(contact: 202, control: modalA, position: .zero))
        require(!modal.controlsEnabled && modal.state.isNeutral, "Profile management blocks game input")
        modal.finishProfileManagement()
        _ = activateBridge(modal, modalLink)
        require(modal.isReady, "The test bridge completes a real matching Ready handshake")
        modal.beginLayoutEditing()
        let modalOpenCount = modalLink.opens
        modal.connect()
        input(modal, .begin(contact: 203, control: modalA, position: .zero))
        require(modal.isReady && !modal.controlsEnabled && modal.connectionRequested && modal.state.isNeutral &&
                modalLink.sent.last?.state?.isNeutral == true && modalLink.opens == modalOpenCount,
                "Editing preserves the legacy neutral connection and blocks input behind the editor")
        modal.cancelLayoutEditing()
        require(modal.isReady && modal.controlsEnabled && modal.state.isNeutral,
                "Closing an editor resumes the neutral legacy connection without an old hold")

        // Actual composed-client lease checking precedes hold timers; unsupported mixed actions are filtered.
        let bridgeDefaults = freshDefaults()
        let bridgeClock = ProfileCheckClock()
        let bridgeLink = ProfileCheckTransport()
        let bridge = makeModel(bridgeDefaults, link: bridgeLink, clock: bridgeClock)
        let bridgeA = legacyID(bridge.profile, .a)
        let bridgeB = legacyID(bridge.profile, .b)
        bridge.beginLayoutEditing()
        var mixed = bridge.profile.control(for: bridgeA)!
        mixed.actions = [.a, .leftTrigger, .rightTrigger, .guide, .share, .dpadRight]
        bridge.saveControl(mixed)
        var held = bridge.profile.control(for: bridgeB)!
        held.buttonBehavior = .init(holdToggle: true, holdMilliseconds: 500)
        bridge.saveControl(held)
        bridge.saveLayoutEditing()
        let session = activateBridge(bridge, bridgeLink)
        input(bridge, .begin(contact: 300, control: bridgeA, position: .zero))
        require(bridge.state.buttons == [.a] && bridge.state.dpad == .right &&
                bridgeLink.sent.last?.state?.buttons == [.a] && bridgeLink.sent.last?.state?.dpad == .right,
                "A mixed remapping emits supported actions while filtering LT RT Guide and Share")
        input(bridge, .end(contact: 300))
        let lastSequence = bridgeLink.sent.last!.sequence
        bridgeLink.reply(.init(kind: .ack, session: session, sequence: lastSequence, hidReady: true))
        input(bridge, .begin(contact: 301, control: bridgeB, position: .zero))
        let holdEpoch = bridge.inputEpoch
        bridgeClock.time += 0.8
        let beforeExpiredHold = bridgeLink.sent.count
        bridge.tickInput(epoch: holdEpoch)
        require(!bridge.isReady && bridge.state.isNeutral && bridge.latchedControls.isEmpty &&
                bridgeLink.sent.count == beforeExpiredHold && bridgeLink.closed.last?.kind == .stop,
                "Lease expiry is enforced before a delayed Hold Toggle timer can publish")
        bridge.handleInput(.begin(contact: 302, control: bridgeA, position: .zero), epoch: holdEpoch)
        require(bridge.state.isNeutral, "Expired-session input cannot resurrect a remapped action")
        _ = activateBridge(bridge, bridgeLink)
        let beforeSwitch = bridgeLink.opens
        require(bridge.createProfile(name: "Fresh", standardControls: false) && bridge.isReady && bridge.connectionRequested &&
                bridge.state.isNeutral && bridgeLink.opens == beforeSwitch,
                "Creating a profile preserves the legacy connection and clears all old input")

        // Input cancellation and foreground transitions also clear profile-specific ownership.
        copyModel.setMode(.practice)
        input(copyModel, .accessibilityActivate(sourceID))
        let backgroundEpoch = copyModel.inputEpoch
        copyModel.setForeground(false)
        copyModel.setForeground(true)
        copyModel.handleInput(.accessibilityActivate(sourceID), epoch: backgroundEpoch)
        require(copyModel.state.isNeutral && copyModel.latchedControls.isEmpty,
                "Background/foreground releases latches and rejects old callbacks")
        input(copyModel, .begin(contact: 400, control: sourceID, position: .zero))
        input(copyModel, .cancelAll)
        copyClock.time += 1
        copyModel.tickInput()
        require(copyModel.state.isNeutral && copyModel.latchedControls.isEmpty,
                "Cancellation removes a pending per-instance hold deadline")
        let ephemeralDefaults = freshDefaults()
        let ephemeral = makeModel(ephemeralDefaults, persist: false)
        _ = ephemeral.createProfile(name: "Memory only", standardControls: false)
        require(ephemeralDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == nil,
                "The non-persisting test mode never writes a profile library")

        // Native backup export excludes accounts/connection/runtime; import merges fresh instances atomically.
        let backupDefaults = freshDefaults()
        backupDefaults.set("192.168.9.99", forKey: "bridge.host")
        backupDefaults.set("dummy-account-marker", forKey: "test.account")
        let backupSource = makeModel(backupDefaults)
        let backupOriginalID = backupSource.profile.id
        let backupA = legacyID(backupSource.profile, .a)
        backupSource.beginLayoutEditing()
        var backupButton = backupSource.profile.control(for: backupA)!
        backupButton.name = "Shared backup button"
        backupButton.diameter = 144
        backupButton.actions = [.a, .rightBumper]
        backupButton.buttonBehavior = .init(holdToggle: true, holdMilliseconds: 650)
        backupSource.saveControl(backupButton)
        var backupMoved = backupSource.profile
        try backupMoved.move(backupA, to: .init(x: 0.12, y: 0.34), orientation: .portrait)
        try backupMoved.move(backupA, to: .init(x: 0.78, y: 0.56), orientation: .landscape)
        backupSource.updateProfile(backupMoved, epoch: backupSource.inputEpoch)
        backupSource.saveLayoutEditing()
        require(backupSource.renameProfile(backupOriginalID, name: String(repeating: "P", count: 64)) &&
                backupSource.createProfile(name: "My Controller", standardControls: false) &&
                backupSource.selectProfile(backupOriginalID), "Backup fixture contains named custom and empty profiles")
        input(backupSource, .accessibilityActivate(backupA))
        let exported = backupSource.exportProfiles()!
        let decodedExport = try ControllerProfileLibraryCodec.decode(exported)
        require(decodedExport == backupSource.library && decodedExport.profiles.count == 2,
                "Native export round-trips every saved profile and property")
        let exportObject = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        let exportText = String(decoding: exported, as: UTF8.self)
        require(Set(exportObject.keys) == ["version", "activeProfileID", "profiles", "androidSources", "settingsPresets"] &&
                !exportText.contains("192.168.9.99") && !exportText.contains("dummy-account-marker") &&
                !exportText.contains("latchedControls") && !exportText.contains("retainedSticks"),
                "Export includes only profile configuration, not connection/account/runtime data")
        require(backupSource.latchedControls == [backupA], "Export itself does not mutate current runtime ownership")

        let mergeDefaults = freshDefaults()
        let mergeModel = makeModel(mergeDefaults)
        let beforeMerge = mergeModel.library
        let preservedActive = beforeMerge.activeProfileID
        let mergeA = legacyID(mergeModel.profile, .a)
        input(mergeModel, .begin(contact: 500, control: mergeA, position: .zero))
        let beforeImportEpoch = mergeModel.inputEpoch
        require(mergeModel.importProfiles(exported), "A valid native backup imports successfully")
        require(mergeModel.library.profiles.count == 3 && mergeModel.library.activeProfileID == preservedActive &&
                mergeModel.library.profiles[0] == beforeMerge.profiles[0],
                "Import appends copies without changing existing profiles or active selection")
        let importedCopies = Array(mergeModel.library.profiles.suffix(2))
        let oldIDs = Set((beforeMerge.profiles + decodedExport.profiles).flatMap { [$0.id] + $0.controls.map(\.id) })
        let newIDs = importedCopies.flatMap { [$0.id] + $0.controls.map(\.id) }
        require(Set(newIDs).count == newIDs.count && Set(newIDs).isDisjoint(with: oldIDs),
                "Every imported profile and control receives a globally fresh UUID")
        var importedSettingsMatch = true
        for (original, copy) in zip(decodedExport.profiles, importedCopies) {
            importedSettingsMatch = importedSettingsMatch && original.controls.count == copy.controls.count &&
                original.portrait.map(\.position) == copy.portrait.map(\.position) &&
                original.landscape.map(\.position) == copy.landscape.map(\.position)
            for (oldControl, newControl) in zip(original.controls, copy.controls) {
                var comparable = newControl; comparable.id = oldControl.id
                importedSettingsMatch = importedSettingsMatch && comparable == oldControl
            }
            let copiedIDs = Set(copy.controls.map(\.id))
            importedSettingsMatch = importedSettingsMatch && Set(copy.portrait.map(\.id)) == copiedIDs &&
                Set(copy.landscape.map(\.id)) == copiedIDs
        }
        require(importedSettingsMatch, "Import preserves every control setting and rewrites both placement ID lists")
        require(mergeModel.state.isNeutral && mergeModel.latchedControls.isEmpty && mergeModel.retainedSticks.isEmpty &&
                mergeModel.inputEpoch != beforeImportEpoch, "Accepted import clears runtime input and stale callback epochs")
        mergeModel.handleInput(.begin(contact: 501, control: mergeA, position: .zero), epoch: beforeImportEpoch)
        require(mergeModel.state.isNeutral && makeModel(mergeDefaults).library == mergeModel.library,
                "Imported profiles persist with the old active selection and reject pre-import contacts")
        require(mergeModel.importProfiles(exported), "The same backup can be imported again as separate copies")
        let mergedNames = mergeModel.library.profiles.map { $0.name.lowercased() }
        require(Set(mergedNames).count == mergedNames.count && mergeModel.library.profiles.allSatisfy { $0.name.count <= 64 },
                "Repeated import assigns unique names even for 64-character originals")
        require(mergeModel.library.activeProfileID == preservedActive && mergeModel.library.profiles[0] == beforeMerge.profiles[0],
                "Repeated import still preserves existing data and the active profile")
        let mergedRoundTrip = try ControllerProfileLibraryCodec.decode(mergeModel.exportProfiles()!)
        require(mergedRoundTrip == mergeModel.library,
                "A merged library exports and decodes without loss")

        var badNameObject = exportObject
        var badProfiles = badNameObject["profiles"] as! [[String: Any]]
        badProfiles[0]["name"] = "   "
        badNameObject["profiles"] = badProfiles
        let badNameBackup = try JSONSerialization.data(withJSONObject: badNameObject)
        let invalidBackups: [Data] = [future, corrupt, badNameBackup,
            Data("{\"type\":\"simplecontroller-profile\",\"version\":1}".utf8),
            Data(repeating: 0x20, count: ControllerProfileLibraryCodec.maximumBytes + 1)]
        for invalidBackup in invalidBackups {
            let savedLibrary = mergeModel.library
            let savedBytes = mergeDefaults.data(forKey: ProfileControllerViewModel.libraryKey)
            input(mergeModel, .begin(contact: 600, control: mergeA, position: .zero))
            let heldState = mergeModel.state
            let heldInputEpoch = mergeModel.inputEpoch
            require(!mergeModel.importProfiles(invalidBackup) && mergeModel.message != nil &&
                    mergeModel.library == savedLibrary && mergeDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == savedBytes &&
                    mergeModel.state == heldState && mergeModel.inputEpoch == heldInputEpoch,
                    "Invalid/future/Android/oversized backups reject atomically without changing existing data or input")
            mergeModel.releaseAll()
        }
        mergeModel.beginLayoutEditing()
        var unsavedImportDraft = mergeModel.profile
        unsavedImportDraft.name = "Unsaved edit"
        mergeModel.updateProfile(unsavedImportDraft, epoch: mergeModel.inputEpoch)
        let beforeEditingImport = mergeDefaults.data(forKey: ProfileControllerViewModel.libraryKey)
        require(!mergeModel.importProfiles(exported) && mergeModel.exportProfiles() == nil &&
                mergeModel.profile == unsavedImportDraft &&
                mergeDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == beforeEditingImport,
                "Import and export cannot discard or bypass an unfinished layout draft")
        mergeModel.cancelLayoutEditing()

        let capacityDefaults = freshDefaults()
        var capacityProfiles = [try ControllerProfile.migrating(layout: .default, behaviors: .default)]
        for index in 1..<31 { capacityProfiles.append(try ControllerProfile(name: "Existing \(index)")) }
        let capacityLibrary = try ControllerProfileLibrary(activeProfileID: capacityProfiles[0].id, profiles: capacityProfiles)
        let capacityBytes = try ControllerProfileLibraryCodec.encode(capacityLibrary)
        capacityDefaults.set(capacityBytes, forKey: ProfileControllerViewModel.libraryKey)
        let capacityModel = makeModel(capacityDefaults)
        require(!capacityModel.importProfiles(exported) && capacityModel.library == capacityLibrary &&
                capacityDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == capacityBytes,
                "A merge exceeding 32 profiles rejects the entire backup instead of partially importing")
        let oneProfile = try ControllerProfile(name: "Last space")
        let oneProfileData = try ControllerProfileLibraryCodec.encode(.init(activeProfileID: oneProfile.id, profiles: [oneProfile]))
        require(capacityModel.importProfiles(oneProfileData) && capacityModel.library.profiles.count == 32 &&
                capacityModel.library.activeProfileID == capacityLibrary.activeProfileID,
                "Import can fill the 32nd slot while retaining the active profile")
        let fullLibrary = capacityModel.library
        require(!capacityModel.importProfiles(oneProfileData) && capacityModel.library == fullLibrary,
                "Further import into a full library leaves it unchanged")
        let importLink = ProfileCheckTransport()
        let importLive = makeModel(freshDefaults(), link: importLink)
        _ = activateBridge(importLive, importLink)
        require(importLive.importProfiles(oneProfileData) && importLive.isReady && importLive.connectionRequested && importLive.state.isNeutral &&
                importLink.sent.last?.state?.isNeutral == true,
                "Accepted import keeps the legacy bridge connected with neutral output")

        // Exercise 0.5 programs through the actual view model, with deterministic monotonic time.
        func programScenario(_ controls: [ProfileControl], turbo: Bool = false,
                             interval: Int = 200, swipe: ProfileSwipeMode = .off) throws -> (ProfileControllerViewModel, ProfileCheckClock, ProfileCheckTransport, UserDefaults) {
            let defaults = freshDefaults()
            let placements = controls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
            var profile = try ControllerProfile(name: "Timing checks", controls: controls,
                                                portrait: placements, landscape: placements,
                                                turboEnabled: turbo, turboIntervalMilliseconds: interval)
            profile.swipeMode = swipe
            let library = try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile])
            defaults.set(try ControllerProfileLibraryCodec.encode(library), forKey: ProfileControllerViewModel.libraryKey)
            let clock = ProfileCheckClock()
            let link = ProfileCheckTransport()
            return (makeModel(defaults, link: link, clock: clock), clock, link, defaults)
        }
        func pressureIs(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 0.000_001 }

        let sequenced = ProfileControl(name: "Sequence", actions: [.x], payload: "X360A, WAIT_200, X360B, WAIT_150, X360Y")
        let (sequenceModel, sequenceClock, _, _) = try programScenario([sequenced])
        input(sequenceModel, .begin(contact: 700, control: sequenced.id, position: .zero))
        require(sequenceModel.state.buttons == [.a] && sequenceModel.activeControls == [sequenced.id],
                "Custom payload overrides mapped actions and emits only the first immediate command")
        sequenceClock.time = 10.19; sequenceModel.tickInput()
        require(sequenceModel.state.buttons == [.a], "WAIT keeps later controller commands from firing early")
        sequenceClock.time = 10.21; sequenceModel.tickInput()
        require(sequenceModel.state.buttons == [.a, .b], "The first WAIT continuation adds B in command order")
        sequenceClock.time = 10.36; sequenceModel.tickInput()
        require(sequenceModel.state.buttons == [.a, .b, .y], "Successive WAIT durations order later combined actions")
        input(sequenceModel, .end(contact: 700))
        require(sequenceModel.state.isNeutral, "Normal lift releases all immediate sequence actions")
        sequenceClock.time = 11
        input(sequenceModel, .begin(contact: 701, control: sequenced.id, position: .zero))
        sequenceClock.time = 11.1
        input(sequenceModel, .end(contact: 701))
        sequenceClock.time = 12; sequenceModel.tickInput()
        require(sequenceModel.state.isNeutral && sequenceModel.activeControls.isEmpty,
                "Ordinary lift cancels pending WAIT continuations instead of firing them later")

        let delayedLatch = ProfileControl(name: "Latched wait", buttonBehavior: .init(holdToggle: true, holdMilliseconds: 500),
                                           payload: "WAIT_200, X360B, WAIT_100, X360Y")
        let (latchedSequence, latchClock, _, _) = try programScenario([delayedLatch])
        input(latchedSequence, .begin(contact: 710, control: delayedLatch.id, position: .zero))
        latchClock.time = 10.51; latchedSequence.tickInput()
        input(latchedSequence, .end(contact: 710))
        require(latchedSequence.latchedControls == [delayedLatch.id] && latchedSequence.activeControls.isEmpty &&
                latchedSequence.state.isNeutral, "A latched WAIT survives normal lift but is not highlighted before output")
        latchClock.time = 10.71; latchedSequence.tickInput()
        require(latchedSequence.state.buttons == [.b] && latchedSequence.activeControls == [delayedLatch.id],
                "A latched sequence continues its WAIT after the finger lifts")
        latchClock.time = 10.82; latchedSequence.tickInput()
        require(latchedSequence.state.buttons == [.b, .y], "Later latched WAIT stages continue until a clearing tap")
        input(latchedSequence, .begin(contact: 711, control: delayedLatch.id, position: .zero))
        input(latchedSequence, .end(contact: 711))
        latchClock.time = 12; latchedSequence.tickInput()
        require(latchedSequence.state.isNeutral && latchedSequence.latchedControls.isEmpty &&
                latchedSequence.activeControls.isEmpty, "A clearing tap cancels a latched program and pending work")

        let partialPulse = ProfileControl(name: "Partial pulse", payload: "RT:0.45P0.3")
        let (pulseModel, pulseClock, _, _) = try programScenario([partialPulse])
        input(pulseModel, .begin(contact: 720, control: partialPulse.id, position: .zero))
        require(pressureIs(pulseModel.practiceState.rightTrigger, 0.45) &&
                pulseModel.activeControls == [partialPulse.id], "Practice exposes fractional trigger intensity and producing owner")
        pulseClock.time = 10.1; input(pulseModel, .end(contact: 720))
        require(pressureIs(pulseModel.practiceState.rightTrigger, 0.45) && pulseModel.activeControls == [partialPulse.id],
                "An ordinary pulse remains visible after normal finger lift until its own deadline")
        pulseClock.time = 10.299; pulseModel.tickInput()
        require(pressureIs(pulseModel.practiceState.rightTrigger, 0.45), "A detached pulse remains active before its deadline")
        pulseClock.time = 10.301; pulseModel.tickInput()
        require(pulseModel.practiceState == .neutral && pulseModel.state.isNeutral && pulseModel.activeControls.isEmpty,
                "The pulse deadline clears pressure and highlight without another touch")

        let lowPressure = ProfileControl(name: "Low pressure", payload: "RT:0.25")
        let highPulse = ProfileControl(name: "High pulse", payload: "RT:0.8P0.2")
        let (overlap, overlapClock, _, _) = try programScenario([lowPressure, highPulse])
        input(overlap, .begin(contact: 730, control: lowPressure.id, position: .zero))
        input(overlap, .begin(contact: 731, control: highPulse.id, position: .zero))
        input(overlap, .end(contact: 731))
        require(pressureIs(overlap.practiceState.rightTrigger, 0.8), "Overlapping trigger owners combine using maximum pressure")
        overlapClock.time = 10.21; overlap.tickInput()
        require(pressureIs(overlap.practiceState.rightTrigger, 0.25) && overlap.activeControls == [lowPressure.id],
                "Expiring a stronger pulse restores the independently held weaker pressure")
        input(overlap, .end(contact: 730))
        require(overlap.practiceState == .neutral, "Releasing the last pressure owner restores neutral")

        // A cleanup event must discard already detached pulses and not-yet-run WAITs together.
        for cleanup in ["editing", "background", "settings", "release all"] {
            let pulse = ProfileControl(name: "Detached", payload: "RT:0.5P1.0")
            let waiting = ProfileControl(name: "Waiting", payload: "WAIT_300, X360A")
            let (cleanupModel, cleanupClock, _, _) = try programScenario([pulse, waiting])
            input(cleanupModel, .begin(contact: 740, control: pulse.id, position: .zero))
            cleanupClock.time = 10.05; input(cleanupModel, .end(contact: 740))
            input(cleanupModel, .begin(contact: 741, control: waiting.id, position: .zero))
            let oldEpoch = cleanupModel.inputEpoch
            require(pressureIs(cleanupModel.practiceState.rightTrigger, 0.5) && cleanupModel.state.buttons == [.rightTrigger],
                    "\(cleanup) fixture has a detached pulse and pending WAIT")
            switch cleanup {
            case "editing": cleanupModel.beginLayoutEditing(); cleanupModel.cancelLayoutEditing()
            case "background": cleanupModel.setForeground(false); cleanupModel.setForeground(true)
            case "settings": cleanupModel.prepareSettings(); cleanupModel.finishSettings()
            default: cleanupModel.releaseAll()
            }
            cleanupClock.time = 10.6
            cleanupModel.tickInput(epoch: oldEpoch)
            cleanupModel.tickInput()
            require(cleanupModel.practiceState == .neutral && cleanupModel.state.isNeutral &&
                    cleanupModel.activeControls.isEmpty && cleanupModel.inputEpoch != oldEpoch,
                    "\(cleanup) cancels detached pulse, pending WAIT, and stale timer work")
        }

        let autoTap = ProfileControl(name: "AutoTap", payload: "X360X", autoTapEnabled: true,
                                     autoTapIntervalMilliseconds: 200)
        let (autoModel, autoClock, _, _) = try programScenario([autoTap])
        input(autoModel, .begin(contact: 750, control: autoTap.id, position: .zero))
        input(autoModel, .end(contact: 750))
        require(autoModel.state.buttons == [.x] && autoModel.latchedControls == [autoTap.id],
                "AutoTap begins immediately and stays latched after normal lift")
        autoClock.time = 10.06; autoModel.tickInput()
        require(autoModel.state.isNeutral && autoModel.activeControls.isEmpty && autoModel.latchedControls == [autoTap.id],
                "AutoTap off-phase removes output/highlight while retaining the latch")
        autoClock.time = 10.21; autoModel.tickInput()
        require(autoModel.state.buttons == [.x] && autoModel.activeControls == [autoTap.id],
                "AutoTap resumes output on its next phase")
        input(autoModel, .begin(contact: 751, control: autoTap.id, position: .zero))
        input(autoModel, .end(contact: 751))
        autoClock.time = 10.8; autoModel.tickInput()
        require(autoModel.state.isNeutral && autoModel.latchedControls.isEmpty,
                "The next AutoTap touch unlatches and cancels repeating output")

        let turboButton = ProfileControl(name: "Turbo action", actions: [.a],
                                         buttonBehavior: .init(holdToggle: true, holdMilliseconds: 500))
        let (turboModel, turboClock, _, turboDefaults) = try programScenario([turboButton])
        let originalTurboProfile = turboModel.profile
        turboModel.beginLayoutEditing()
        var options = turboModel.profile
        options.name = "Turbo draft"; options.turboEnabled = true; options.turboIntervalMilliseconds = 200
        turboModel.saveProfileOptions(options)
        require(turboModel.profile.turboEnabled && !turboModel.library.activeProfile.turboEnabled &&
                turboModel.profile.controls == originalTurboProfile.controls,
                "Profile options update only the draft and preserve instance settings")
        turboModel.cancelLayoutEditing()
        require(turboModel.profile == originalTurboProfile, "Layout Cancel restores the original profile Turbo settings")
        turboModel.beginLayoutEditing(); turboModel.saveProfileOptions(options); turboModel.saveLayoutEditing()
        let restoredTurbo = makeModel(turboDefaults)
        require(restoredTurbo.profile.turboEnabled && restoredTurbo.profile.turboIntervalMilliseconds == 200 &&
                restoredTurbo.profile.name == "Turbo draft" && restoredTurbo.profile.controls == originalTurboProfile.controls,
                "Save layout persists global Turbo options with the unchanged controls")
        input(turboModel, .begin(contact: 760, control: turboButton.id, position: .zero))
        require(turboModel.state.buttons == [.a] && turboModel.latchedControls.isEmpty,
                "Global Turbo starts immediately instead of waiting for a button's Hold Toggle delay")
        turboClock.time = 10.11; turboModel.tickInput()
        require(turboModel.state.isNeutral && turboModel.activeControls.isEmpty, "Global Turbo has an observable off phase")
        turboClock.time = 10.21; turboModel.tickInput()
        require(turboModel.state.buttons == [.a], "Global Turbo repeats while its ordinary contact remains down")
        input(turboModel, .end(contact: 760)); turboClock.time = 11; turboModel.tickInput()
        require(turboModel.state.isNeutral && turboModel.activeControls.isEmpty,
                "Releasing the global Turbo contact stops repetition")

        let mixedPulse = ProfileControl(name: "Bridge mixed", payload: "X360A, RT:0.8P1.2")
        let (payloadBridge, payloadBridgeClock, payloadLink, _) = try programScenario([mixedPulse])
        _ = activateBridge(payloadBridge, payloadLink)
        input(payloadBridge, .begin(contact: 770, control: mixedPulse.id, position: .zero))
        require(payloadBridge.state.buttons == [.a] && payloadLink.sent.last?.state?.buttons == [.a] &&
                pressureIs(payloadBridge.practiceState.rightTrigger, 0.8),
                "Bridge mixed payload keeps A but filters unverified RT pressure from transmitted state")
        payloadBridgeClock.time = 10.1; input(payloadBridge, .end(contact: 770))
        require(payloadBridge.state.isNeutral && pressureIs(payloadBridge.practiceState.rightTrigger, 0.8),
                "Detached Practice trigger pressure never becomes a bridge trigger packet")
        let pulseBridgeEpoch = payloadBridge.inputEpoch
        let beforePulseExpiry = payloadLink.sent.count
        payloadBridgeClock.time = 10.8; payloadBridge.tickInput(epoch: pulseBridgeEpoch)
        require(!payloadBridge.isReady && payloadBridge.state.isNeutral && payloadBridge.practiceState == .neutral &&
                payloadBridge.activeControls.isEmpty && payloadLink.sent.count == beforePulseExpiry,
                "An expired bridge lease clears detached pressure before its next timer can publish")
        let (repeatBridge, repeatBridgeClock, repeatLink, _) = try programScenario([autoTap])
        _ = activateBridge(repeatBridge, repeatLink)
        input(repeatBridge, .begin(contact: 780, control: autoTap.id, position: .zero))
        input(repeatBridge, .end(contact: 780))
        let beforeRepeatExpiry = repeatLink.sent.count
        repeatBridgeClock.time = 10.81; repeatBridge.tickInput()
        require(!repeatBridge.isReady && repeatBridge.state.isNeutral && repeatBridge.practiceState == .neutral &&
                repeatBridge.latchedControls.isEmpty && repeatLink.sent.count == beforeRepeatExpiry,
                "A delayed repeating timer cannot emit into an expired bridge session")

        // Build an actual v1 document by removing exactly the fields introduced in v2.
        var versionOneObject = try JSONSerialization.jsonObject(with: firstBytes) as! [String: Any]
        versionOneObject["version"] = 1
        versionOneObject.removeValue(forKey: "androidSources")
        var versionOneProfiles = versionOneObject["profiles"] as! [[String: Any]]
        for profileIndex in versionOneProfiles.indices {
            versionOneProfiles[profileIndex].removeValue(forKey: "androidSources")
            versionOneProfiles[profileIndex].removeValue(forKey: "pages")
            versionOneProfiles[profileIndex].removeValue(forKey: "homePageID")
            versionOneProfiles[profileIndex].removeValue(forKey: "swipeMode")
            versionOneProfiles[profileIndex].removeValue(forKey: "turboEnabled")
            versionOneProfiles[profileIndex].removeValue(forKey: "turboIntervalMilliseconds")
            var oldControls = versionOneProfiles[profileIndex]["controls"] as! [[String: Any]]
            for controlIndex in oldControls.indices {
                for key in ["touchAim", "buttonAim", "buttonDirectional", "controlWidth", "controlHeight"] { oldControls[controlIndex].removeValue(forKey: key) }
                oldControls[controlIndex].removeValue(forKey: "stickResponse")
                oldControls[controlIndex].removeValue(forKey: "extendedBoost")
                oldControls[controlIndex].removeValue(forKey: "pageNavigation")
                oldControls[controlIndex].removeValue(forKey: "swipeActivationEnabled")
                oldControls[controlIndex].removeValue(forKey: "payload")
                oldControls[controlIndex].removeValue(forKey: "autoTapEnabled")
                oldControls[controlIndex].removeValue(forKey: "autoTapIntervalMilliseconds")
                oldControls[controlIndex].removeValue(forKey: "directionalEnabled")
                oldControls[controlIndex].removeValue(forKey: "directionPayloads")
                oldControls[controlIndex].removeValue(forKey: "touchpadWidth")
                oldControls[controlIndex].removeValue(forKey: "touchpadHeight")
                oldControls[controlIndex].removeValue(forKey: "touchpadBehavior")
            }
            versionOneProfiles[profileIndex]["controls"] = oldControls
        }
        versionOneObject["profiles"] = versionOneProfiles
        let versionOneBytes = try JSONSerialization.data(withJSONObject: legacyJSON(versionOneObject), options: [.sortedKeys])
        let upgradeDefaults = freshDefaults()
        upgradeDefaults.set(versionOneBytes, forKey: ProfileControllerViewModel.libraryKey)
        let upgraded = makeModel(upgradeDefaults)
        require(upgraded.canEditLayout && upgraded.library.version == ControllerProfileLibrary.currentVersion &&
                upgraded.library.activeProfileID == firstLibrary.activeProfileID &&
                upgraded.profile.controls.map(\.id) == firstLibrary.activeProfile.controls.map(\.id),
                "A v1 native library loads into the current schema without changing existing IDs")
        require(upgraded.library.profiles.allSatisfy { !$0.turboEnabled && $0.turboIntervalMilliseconds == 16 &&
                    $0.controls.allSatisfy { $0.payload == nil && !$0.autoTapEnabled && $0.autoTapIntervalMilliseconds == 100 } },
                "Version-one migration assigns safe defaults for payload and repetition fields")
        let upgradedExport = upgraded.exportProfiles()!
        let upgradedExportObject = try JSONSerialization.jsonObject(with: upgradedExport) as! [String: Any]
        require(upgradedExportObject["version"] as? Int == ControllerProfileLibrary.currentVersion &&
                upgradeDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == versionOneBytes,
                "Export uses the current schema while load/export leave original stored v1 bytes unchanged")
        upgraded.beginLayoutEditing()
        var upgradedControl = upgraded.profile.controls[0]
        upgradedControl.name = "Upgraded edit"
        upgraded.saveControl(upgradedControl)
        upgraded.saveLayoutEditing()
        let writtenUpgrade = try JSONSerialization.jsonObject(with: upgradeDefaults.data(forKey: ProfileControllerViewModel.libraryKey)!) as! [String: Any]
        require(writtenUpgrade["version"] as? Int == ControllerProfileLibrary.currentVersion &&
                upgradeDefaults.data(forKey: "controller.profiles.before-format-1") == versionOneBytes,
                "The first explicit format upgrade retains an exact v1 recovery document")
        _ = upgraded.renameProfile(upgraded.profile.id, name: "Later change")
        require(upgradeDefaults.data(forKey: "controller.profiles.before-format-1") == versionOneBytes,
                "Later saves do not replace the original version-one recovery bytes")
        let nativeV1Import = makeModel(freshDefaults())
        require(nativeV1Import.importProfiles(versionOneBytes) && nativeV1Import.library.version == ControllerProfileLibrary.currentVersion &&
                nativeV1Import.library.profiles.count == 2, "Native v1 backup import uses the same supported migration")

        // Exercise desktop previews and direction stages through the actual 0.6 app model.
        func eventKinds(_ model: ProfileControllerViewModel) -> [PracticeOutputEvent.Kind] {
            model.recentPracticeEvents.map(\.kind)
        }
        func sequencesIncrease(_ events: [PracticeOutputEvent]) -> Bool {
            zip(events, events.dropFirst()).allSatisfy { pair in pair.0.sequence < pair.1.sequence }
        }
        let keyboard = ProfileControl(name: "Keyboard chord", payload: "LCTRL, W")
        let (keyboardModel, _, keyboardLink, keyboardDefaults) = try programScenario([keyboard])
        let keyboardBytes = keyboardDefaults.data(forKey: ProfileControllerViewModel.libraryKey)
        input(keyboardModel, .begin(contact: 800, control: keyboard.id, position: .zero))
        require(keyboardModel.practiceState.heldKeys == [.leftControl, .w] &&
                keyboardModel.practiceState.heldMouseButtons.isEmpty && keyboardModel.state.isNeutral &&
                keyboardModel.activeControls == [keyboard.id],
                "Keyboard chord previews held keys and its owner without creating a gamepad action")
        require(eventKinds(keyboardModel) == [.keyDown(.leftControl), .keyDown(.w)],
                "Keyboard payload keeps its ordered resolved down events")
        keyboardModel.clearPracticeHistory()
        require(keyboardModel.recentPracticeEvents.isEmpty && keyboardModel.practiceEventsOmittedCount == 0 &&
                keyboardModel.practiceState.heldKeys == [.leftControl, .w],
                "Clearing preview history does not release held keys")
        input(keyboardModel, .end(contact: 800))
        require(keyboardModel.practiceState == .neutral && keyboardModel.activeControls.isEmpty &&
                eventKinds(keyboardModel).contains(.keyUp(.leftControl)) &&
                eventKinds(keyboardModel).contains(.keyUp(.w)),
                "Normal lift releases the keyboard chord and records resolved up events")
        require(keyboardLink.sent.isEmpty &&
                keyboardDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == keyboardBytes,
                "Desktop Practice output and history are neither transmitted nor persisted")
        let keyboardRestart = makeModel(keyboardDefaults)
        require(keyboardRestart.practiceState == .neutral && keyboardRestart.recentPracticeEvents.isEmpty &&
                keyboardRestart.practiceEventsOmittedCount == 0,
                "Restart restores desktop settings without held keys or event history")

        let click = ProfileControl(name: "Mouse click", payload: "MOUSE_LEFT_DOWN, MOUSE_LEFT_UP")
        let (clickModel, _, _, _) = try programScenario([click])
        input(clickModel, .begin(contact: 810, control: click.id, position: .zero))
        require(clickModel.practiceState.heldMouseButtons.isEmpty && clickModel.state.isNeutral &&
                eventKinds(clickModel) == [.mouseDown(.left), .mouseUp(.left)],
                "A same-turn mouse click retains ordered DOWN and UP despite neutral final state")
        input(clickModel, .end(contact: 810))
        require(eventKinds(clickModel) == [.mouseDown(.left), .mouseUp(.left)] &&
                sequencesIncrease(clickModel.recentPracticeEvents),
                "Ordinary lift does not invent an extra edge after an already completed click")
        clickModel.clearPracticeHistory()
        for index in 0..<20 {
            input(clickModel, .begin(contact: 820 + index, control: click.id, position: .zero))
            input(clickModel, .end(contact: 820 + index))
        }
        require(clickModel.recentPracticeEvents.count == 32 && clickModel.practiceEventsOmittedCount == 8 &&
                sequencesIncrease(clickModel.recentPracticeEvents),
                "Preview history retains newest 32 events and counts dropped display entries")
        require(eventKinds(clickModel).first == .mouseDown(.left) &&
                eventKinds(clickModel).last == .mouseUp(.left),
                "Truncated click history remains ordered and ends with the actual release")
        clickModel.clearPracticeHistory()
        require(clickModel.recentPracticeEvents.isEmpty && clickModel.practiceEventsOmittedCount == 0,
                "Clear history resets the bounded display and omitted count")

        for repeatingMode in ["Auto-Tap", "Turbo"] {
            var repeatingClick = click
            repeatingClick.id = UUID(); repeatingClick.name = repeatingMode + " click"
            repeatingClick.autoTapEnabled = repeatingMode == "Auto-Tap"
            repeatingClick.autoTapIntervalMilliseconds = 200
            let (repeatClickModel, repeatClickClock, _, _) = try programScenario([repeatingClick], turbo: repeatingMode == "Turbo")
            input(repeatClickModel, .begin(contact: 840, control: repeatingClick.id, position: .zero))
            if repeatingMode == "Auto-Tap" { input(repeatClickModel, .end(contact: 840)) }
            require(eventKinds(repeatClickModel) == [.mouseDown(.left), .mouseUp(.left)],
                    "\(repeatingMode) begins a complete click even though its final held mouse set is empty")
            repeatClickModel.clearPracticeHistory()
            repeatClickClock.time = 10.11; repeatClickModel.tickInput()
            require(repeatClickModel.recentPracticeEvents.isEmpty,
                    "\(repeatingMode) off phase does not emit an extra completed click")
            repeatClickClock.time = 10.21; repeatClickModel.tickInput(); repeatClickModel.tickInput()
            require(eventKinds(repeatClickModel) == [.mouseDown(.left), .mouseUp(.left)],
                    "\(repeatingMode) next on phase emits one ordered click without same-phase duplication")
            repeatClickModel.clearPracticeHistory()
            repeatClickClock.time = 12.01; repeatClickModel.tickInput()
            require(eventKinds(repeatClickModel) == [.mouseDown(.left), .mouseUp(.left)],
                    "A late \(repeatingMode) tick emits only the current observed click rather than replaying missed cycles")
            repeatClickModel.clearPracticeHistory()
            if repeatingMode == "Auto-Tap" {
                input(repeatClickModel, .begin(contact: 841, control: repeatingClick.id, position: .zero))
                input(repeatClickModel, .end(contact: 841))
            } else { input(repeatClickModel, .end(contact: 840)) }
            repeatClickClock.time = 13.01; repeatClickModel.tickInput()
            require(repeatClickModel.recentPracticeEvents.isEmpty && repeatClickModel.latchedControls.isEmpty,
                    "Stopping \(repeatingMode) cancels future click edges")
        }

        let mouseOwner = ProfileControl(name: "Held mouse", payload: "MOUSE_LEFT_DOWN")
        let mouseUp = ProfileControl(name: "Owner-local up", payload: "MOUSE_LEFT_UP")
        let (sharedMouse, _, _, _) = try programScenario([mouseOwner, click, mouseUp])
        input(sharedMouse, .begin(contact: 850, control: mouseOwner.id, position: .zero))
        sharedMouse.clearPracticeHistory()
        input(sharedMouse, .begin(contact: 851, control: click.id, position: .zero))
        input(sharedMouse, .end(contact: 851))
        input(sharedMouse, .begin(contact: 852, control: mouseUp.id, position: .zero))
        input(sharedMouse, .end(contact: 852))
        require(sharedMouse.practiceState.heldMouseButtons == [.left] && sharedMouse.recentPracticeEvents.isEmpty,
                "Another run's click or explicit UP cannot release a shared mouse-button owner or invent edges")
        input(sharedMouse, .end(contact: 850))
        require(sharedMouse.practiceState.heldMouseButtons.isEmpty && eventKinds(sharedMouse) == [.mouseUp(.left)],
                "The last owning run's lift produces the single resolved mouse release")
        let delayedMouse = ProfileControl(name: "Delayed mouse release", payload: "MOUSE_LEFT_DOWN, WAIT_200, MOUSE_LEFT_UP")
        let (delayedMouseModel, delayedMouseClock, _, _) = try programScenario([delayedMouse])
        input(delayedMouseModel, .begin(contact: 860, control: delayedMouse.id, position: .zero))
        require(delayedMouseModel.practiceState.heldMouseButtons == [.left],
                "Mouse DOWN remains held while its own WAIT is pending")
        delayedMouseClock.time = 10.21; delayedMouseModel.tickInput()
        require(delayedMouseModel.practiceState.heldMouseButtons.isEmpty &&
                eventKinds(delayedMouseModel) == [.mouseDown(.left), .mouseUp(.left)],
                "A WAIT followed by same-run UP releases at the next model deadline")

        let sharedW = ProfileControl(name: "Independent W", payload: "W")
        var direction = ProfileControl(name: "Directional stages", kind: .leftStick,
                                        stickBehavior: .init(autoCenter: false, stickPlusEnabled: false,
                                                             boostThreshold: 0.5, superBoostThreshold: 0.75))
        direction.directionalEnabled = true
        direction.directionPayloads[.up] = .init(normalPayload: "W", boostPayload: "W, LSHIFT",
                                                  superBoostPayload: "W, SPACE")
        direction.directionPayloads[.right] = .init(normalPayload: "D", boostPayload: "D", superBoostPayload: "D")
        let (directionModel, _, _, _) = try programScenario([direction, sharedW])
        input(directionModel, .begin(contact: 870, control: sharedW.id, position: .zero))
        directionModel.clearPracticeHistory()
        input(directionModel, .begin(contact: 871, control: direction.id, position: .init(x: 0, y: 0.3)))
        require(directionModel.practiceState.heldKeys == [.w] && directionModel.state.leftStick == .zero &&
                directionModel.recentPracticeEvents.isEmpty,
                "Directional mode emits Normal keys without analog motion and preserves shared key ownership")
        input(directionModel, .move(contact: 871, position: .init(x: 0, y: 0.6)))
        require(directionModel.practiceState.heldKeys == [.w, .leftShift] &&
                eventKinds(directionModel) == [.keyDown(.leftShift)],
                "Boost adds Shift without releasing or re-pressing a W shared across stages")
        directionModel.clearPracticeHistory()
        input(directionModel, .move(contact: 871, position: .init(x: 0, y: 0.9)))
        require(directionModel.practiceState.heldKeys == [.w, .space] &&
                eventKinds(directionModel).contains(.keyUp(.leftShift)) &&
                eventKinds(directionModel).contains(.keyDown(.space)) &&
                !eventKinds(directionModel).contains(.keyUp(.w)) && !eventKinds(directionModel).contains(.keyDown(.w)),
                "Super replaces Boost while retaining shared W without a spurious release/repress")
        input(directionModel, .end(contact: 871))
        require(directionModel.practiceState.heldKeys == [.w, .space] &&
                directionModel.retainedSticks == [direction.id] && directionModel.state.isNeutral,
                "Auto-center off retains directional keys on normal lift without analog output")
        directionModel.recenterSticks()
        require(directionModel.practiceState.heldKeys == [.w] && directionModel.retainedSticks.isEmpty,
                "Re-center removes retained directional output but preserves an independent keyboard button")
        input(directionModel, .end(contact: 870))
        require(directionModel.practiceState == .neutral, "Releasing the last independent key owner restores neutral")
        input(directionModel, .begin(contact: 872, control: direction.id, position: .init(x: 0.6, y: 0.6)))
        require(directionModel.practiceState.heldKeys == [.w, .leftShift, .d] && directionModel.state.isNeutral,
                "A diagonal directional movement combines both selected direction stages without analog output")
        directionModel.releaseAll()
        var secondDirection = direction
        secondDirection.id = UUID(); secondDirection.name = "Second directional surface"
        secondDirection.directionPayloads[.up] = .init(normalPayload: "S", boostPayload: "S", superBoostPayload: "S")
        let (independentDirections, _, _, _) = try programScenario([direction, secondDirection])
        input(independentDirections, .begin(contact: 873, control: direction.id, position: .init(x: 0, y: 0.3)))
        input(independentDirections, .begin(contact: 874, control: secondDirection.id, position: .init(x: 0, y: 0.3)))
        require(independentDirections.practiceState.heldKeys == [.w, .s] &&
                independentDirections.activeControls == [direction.id, secondDirection.id],
                "Two directional surfaces sharing a logical stick kind own independent captures and keys")
        independentDirections.recenterSticks()
        require(independentDirections.practiceState == .neutral && independentDirections.activeControls.isEmpty,
                "Re-center clears both simultaneous directional captures")

        let desktopWait = ProfileControl(name: "Desktop pending", payload: "LCTRL, MOUSE_LEFT_DOWN, WAIT_500, SPACE")
        for cleanup in ["editing", "background", "settings", "release all", "profile change"] {
            let (desktopCleanup, desktopClock, _, _) = try programScenario([desktopWait])
            input(desktopCleanup, .begin(contact: 880, control: desktopWait.id, position: .zero))
            let epoch = desktopCleanup.inputEpoch
            require(desktopCleanup.practiceState.heldKeys == [.leftControl] &&
                    desktopCleanup.practiceState.heldMouseButtons == [.left],
                    "\(cleanup) desktop fixture has held owners and pending WAIT")
            switch cleanup {
            case "editing": desktopCleanup.beginLayoutEditing(); desktopCleanup.cancelLayoutEditing()
            case "background": desktopCleanup.setForeground(false); desktopCleanup.setForeground(true)
            case "settings": desktopCleanup.prepareSettings(); desktopCleanup.finishSettings()
            case "profile change": _ = desktopCleanup.createProfile(name: "Fresh desktop profile", standardControls: false)
            default: desktopCleanup.releaseAll()
            }
            desktopClock.time = 11
            desktopCleanup.tickInput(epoch: epoch); desktopCleanup.tickInput()
            require(desktopCleanup.practiceState == .neutral && desktopCleanup.activeControls.isEmpty &&
                    desktopCleanup.inputEpoch != epoch &&
                    (cleanup == "profile change" ? desktopCleanup.recentPracticeEvents.isEmpty : eventKinds(desktopCleanup).contains(.reset)) &&
                    !eventKinds(desktopCleanup).contains(.keyDown(.space)),
                    "\(cleanup) clears desktop owners, applies its history policy, and rejects delayed/stale output")
        }
        let (resetHistory, resetHistoryClock, _, _) = try programScenario([desktopWait])
        input(resetHistory, .begin(contact: 885, control: desktopWait.id, position: .zero))
        let beforeResetEvents = resetHistory.recentPracticeEvents
        resetHistory.releaseAll()
        require(Array(resetHistory.recentPracticeEvents.prefix(beforeResetEvents.count)) == beforeResetEvents &&
                eventKinds(resetHistory).suffix(3) == [.keyUp(.leftControl), .mouseUp(.left), .reset] &&
                sequencesIncrease(resetHistory.recentPracticeEvents),
                "Release all preserves inspected down events and appends their resolved releases followed by reset")
        resetHistoryClock.time = 11; resetHistory.tickInput()
        require(!eventKinds(resetHistory).contains(.keyDown(.space)) && resetHistory.practiceState == .neutral,
                "Retaining history never allows a canceled WAIT to become active again")
        resetHistory.setMode(.bridge)
        require(resetHistory.recentPracticeEvents.isEmpty && resetHistory.practiceEventsOmittedCount == 0,
                "A mode change clears preview history to separate Practice from bridge sessions")

        let (desktopCancel, desktopCancelClock, _, _) = try programScenario([desktopWait])
        input(desktopCancel, .begin(contact: 890, control: desktopWait.id, position: .zero))
        desktopCancelClock.time = 10.1; input(desktopCancel, .end(contact: 890))
        desktopCancelClock.time = 11; desktopCancel.tickInput()
        require(desktopCancel.practiceState == .neutral && !eventKinds(desktopCancel).contains(.keyDown(.space)),
                "Ordinary desktop lift cancels pending WAIT and releases already-held desktop output")

        let desktopMixed = ProfileControl(name: "Mixed desktop and controller", payload: "W, MOUSE_LEFT_DOWN, X360A")
        let (desktopBridge, desktopBridgeClock, desktopBridgeLink, _) = try programScenario([desktopMixed, keyboard])
        _ = activateBridge(desktopBridge, desktopBridgeLink)
        input(desktopBridge, .begin(contact: 900, control: desktopMixed.id, position: .zero))
        require(desktopBridge.state.buttons == [.a] && desktopBridgeLink.sent.last?.state?.buttons == [.a] &&
                desktopBridge.practiceState.heldKeys == [.w] && desktopBridge.practiceState.heldMouseButtons == [.left],
                "Mixed desktop/controller payload transmits only its supported controller portion")
        require(desktopBridgeLink.sent.filter { $0.kind == .state }.allSatisfy {
                    $0.state?.buttons == [.a] || $0.state?.isNeutral == true
                }, "SCX1 packets contain only complete controller states, never desktop payload commands")
        input(desktopBridge, .end(contact: 900))
        input(desktopBridge, .begin(contact: 901, control: keyboard.id, position: .zero))
        require(desktopBridge.state.isNeutral && desktopBridgeLink.sent.last?.state?.isNeutral == true,
                "A desktop-only control cannot produce bridge gamepad output")
        let desktopBridgeEpoch = desktopBridge.inputEpoch
        let beforeDesktopLoss = desktopBridgeLink.sent.count
        desktopBridgeClock.time = 10.81; desktopBridge.tickInput(epoch: desktopBridgeEpoch)
        require(!desktopBridge.isReady && desktopBridge.practiceState == .neutral &&
                eventKinds(desktopBridge).contains(.reset) && desktopBridgeLink.sent.count == beforeDesktopLoss,
                "Bridge expiry clears desktop preview owners before any delayed engine output")
        var mixedDirection = direction
        mixedDirection.directionPayloads[.up] = .init(normalPayload: "W, X360A", boostPayload: "W, X360A", superBoostPayload: "W, X360A")
        let (directionBridge, _, directionLink, _) = try programScenario([mixedDirection])
        _ = activateBridge(directionBridge, directionLink)
        input(directionBridge, .begin(contact: 902, control: mixedDirection.id, position: .init(x: 0, y: 0.6)))
        require(directionBridge.state.buttons == [.a] && directionBridge.state.leftStick == .zero &&
                directionLink.sent.last?.state?.buttons == [.a] && directionLink.sent.last?.state?.leftStick == .zero,
                "A mixed directional stage forwards supported buttons but no synthesized analog or keyboard output")

        // Create authentic format 2 data by removing only the two fields introduced in format 3.
        let (oldFormatSource, _, _, _) = try programScenario([sequenced, autoTap, turboButton], turbo: true, interval: 220)
        var versionTwoObject = try JSONSerialization.jsonObject(with: oldFormatSource.exportProfiles()!) as! [String: Any]
        versionTwoObject["version"] = 2
        versionTwoObject.removeValue(forKey: "androidSources")
        var versionTwoProfiles = versionTwoObject["profiles"] as! [[String: Any]]
        for index in versionTwoProfiles.indices {
            versionTwoProfiles[index].removeValue(forKey: "androidSources")
            versionTwoProfiles[index].removeValue(forKey: "pages")
            versionTwoProfiles[index].removeValue(forKey: "homePageID")
            versionTwoProfiles[index].removeValue(forKey: "swipeMode")
            var controls = versionTwoProfiles[index]["controls"] as! [[String: Any]]
            for controlIndex in controls.indices {
                for key in ["touchAim", "buttonAim", "buttonDirectional", "controlWidth", "controlHeight"] { controls[controlIndex].removeValue(forKey: key) }
                controls[controlIndex].removeValue(forKey: "stickResponse")
                controls[controlIndex].removeValue(forKey: "extendedBoost")
                controls[controlIndex].removeValue(forKey: "pageNavigation")
                controls[controlIndex].removeValue(forKey: "swipeActivationEnabled")
                controls[controlIndex].removeValue(forKey: "directionalEnabled")
                controls[controlIndex].removeValue(forKey: "directionPayloads")
                controls[controlIndex].removeValue(forKey: "touchpadWidth")
                controls[controlIndex].removeValue(forKey: "touchpadHeight")
                controls[controlIndex].removeValue(forKey: "touchpadBehavior")
            }
            versionTwoProfiles[index]["controls"] = controls
        }
        versionTwoObject["profiles"] = versionTwoProfiles
        let versionTwoBytes = try JSONSerialization.data(withJSONObject: legacyJSON(versionTwoObject), options: [.sortedKeys])
        let v2Defaults = freshDefaults()
        v2Defaults.set(versionTwoBytes, forKey: ProfileControllerViewModel.libraryKey)
        let v2Loaded = makeModel(v2Defaults)
        require(v2Loaded.canEditLayout && v2Loaded.library.version == ControllerProfileLibrary.currentVersion &&
                v2Loaded.profile.id == oldFormatSource.profile.id &&
                v2Loaded.profile.controls.map(\.id) == oldFormatSource.profile.controls.map(\.id),
                "Native format 2 loads with original profile and control IDs")
        require(v2Loaded.profile.turboEnabled && v2Loaded.profile.turboIntervalMilliseconds == 220 &&
                v2Loaded.profile.control(for: sequenced.id)?.payload == sequenced.payload &&
                v2Loaded.profile.control(for: autoTap.id)?.autoTapEnabled == true &&
                v2Loaded.profile.controls.allSatisfy { !$0.directionalEnabled && $0.directionPayloads.values.allSatisfy {
                    $0.normalPayload == nil && $0.boostPayload == nil && $0.superBoostPayload == nil
                } }, "Format 2 migration preserves payload/repeat settings and supplies empty directional defaults")
        let v2Export = v2Loaded.exportProfiles()!
        let v2ExportObject = try JSONSerialization.jsonObject(with: v2Export) as! [String: Any]
        require(v2ExportObject["version"] as? Int == ControllerProfileLibrary.currentVersion &&
                v2Defaults.data(forKey: ProfileControllerViewModel.libraryKey) == versionTwoBytes &&
                v2Defaults.data(forKey: "controller.profiles.before-format-2") == nil,
                "Loading and exporting upgraded format 2 data never rewrites its stored original")
        v2Loaded.beginLayoutEditing()
        var v2Changed = v2Loaded.profile.controls[0]; v2Changed.name = "Explicit format upgrade"
        v2Loaded.saveControl(v2Changed); v2Loaded.saveLayoutEditing()
        let v2Written = try JSONSerialization.jsonObject(with: v2Defaults.data(forKey: ProfileControllerViewModel.libraryKey)!) as! [String: Any]
        require(v2Written["version"] as? Int == ControllerProfileLibrary.currentVersion &&
                v2Defaults.data(forKey: "controller.profiles.before-format-2") == versionTwoBytes,
                "First explicit current-format save preserves exact format 2 recovery bytes")
        _ = v2Loaded.renameProfile(v2Loaded.profile.id, name: "Later format rename")
        require(v2Defaults.data(forKey: "controller.profiles.before-format-2") == versionTwoBytes,
                "Later saves do not overwrite the original format 2 recovery document")
        let (directionSaved, _, _, directionDefaults) = try programScenario([direction])
        input(directionSaved, .begin(contact: 910, control: direction.id, position: .init(x: 0, y: 0.6)))
        input(directionSaved, .end(contact: 910))
        let directionRestored = makeModel(directionDefaults)
        require(directionRestored.profile.controls[0].directionalEnabled &&
                directionRestored.profile.controls[0].directionPayloads == direction.directionPayloads &&
                directionRestored.practiceState == .neutral && directionRestored.recentPracticeEvents.isEmpty,
                "Relaunch restores directional configuration without retained keys, contacts or history")
        let importedDesktop = makeModel(freshDefaults())
        require(importedDesktop.importProfiles(directionSaved.exportProfiles()!) &&
                importedDesktop.library.profiles.last?.controls.first?.directionPayloads == direction.directionPayloads &&
                importedDesktop.library.profiles.last?.controls.first?.id != direction.id,
                "Native format 3 backup merge preserves directional payloads with fresh instance ownership")
        let importedFormatTwo = makeModel(freshDefaults())
        require(importedFormatTwo.importProfiles(versionTwoBytes) &&
                importedFormatTwo.library.profiles.last?.controls.first?.payload == sequenced.payload,
                "Native format 2 backup import preserves existing controller payload semantics")

        // Exercise 0.7 touchpads through the real model, including its modal/cache/persistence paths.
        func pointerIs(_ value: PointerDelta, _ dx: Double, _ dy: Double) -> Bool {
            pressureIs(value.dx, dx) && pressureIs(value.dy, dy)
        }
        let padEditor = makeModel(freshDefaults())
        require(!padEditor.hasPointerOutputs && !padEditor.hasDesktopOutputs,
                "A standard controller starts without touchpad/desktop capability flags")
        padEditor.beginLayoutEditing()
        let firstPadID = padEditor.addControl(kind: .touchpad)!
        require(padEditor.hasPointerOutputs && padEditor.hasDesktopOutputs &&
                padEditor.profile.control(for: firstPadID)?.name == "Touchpad" &&
                padEditor.profile.control(for: firstPadID)?.touchpadWidth == 220 &&
                padEditor.profile.control(for: firstPadID)?.touchpadHeight == 160,
                "Add touchpad creates defaults and updates cached draft capabilities immediately")
        padEditor.cancelLayoutEditing()
        require(!padEditor.hasPointerOutputs && !padEditor.hasDesktopOutputs &&
                padEditor.profile.control(for: firstPadID) == nil,
                "Cancel removes a draft touchpad and restores cached capabilities")
        padEditor.beginLayoutEditing()
        let savedPadID = padEditor.addControl(kind: .touchpad)!
        var savedPad = padEditor.profile.control(for: savedPadID)!
        savedPad.name = "My touchpad"; savedPad.touchpadWidth = 320; savedPad.touchpadHeight = 180
        savedPad.touchpadBehavior = .init(sensitivity: 1.5, clickMode: .toggle)
        padEditor.saveControl(savedPad)
        require(padEditor.profile.control(for: savedPadID) == savedPad &&
                padEditor.library.activeProfile.control(for: savedPadID) == nil,
                "Touchpad appearance/click/sensitivity edits remain only in the whole-profile draft")
        let beforeInvalidPad = padEditor.profile
        var invalidPad = savedPad; invalidPad.touchpadWidth = 43
        padEditor.saveControl(invalidPad)
        require(padEditor.profile == beforeInvalidPad && padEditor.message != nil,
                "An invalid touchpad size is rejected without replacing the valid draft")
        padEditor.saveLayoutEditing()
        require(padEditor.library.activeProfile.control(for: savedPadID) == savedPad && padEditor.hasPointerOutputs,
                "Save layout persists the validated touchpad and capability state")

        let touchpad = ProfileControl(name: "Movement pad", kind: .touchpad,
                                       touchpadBehavior: .init(sensitivity: 1, clickMode: .none))
        let (pointerModel, pointerClock, pointerLink, pointerDefaults) = try programScenario([touchpad])
        let pointerBytes = pointerDefaults.data(forKey: ProfileControllerViewModel.libraryKey)
        input(pointerModel, .beginTouchpad(contact: 1000, control: touchpad.id))
        require(pointerModel.activeTouchpads == [touchpad.id] && pointerModel.practiceState.heldMouseButtons.isEmpty,
                "A movement-only pad begins a touch without inventing a mouse press")
        input(pointerModel, .moveTouchpad(contact: 1000, delta: .init(dx: 2, dy: 4)))
        require(pointerIs(pointerModel.practiceState.pointerOffset, 0.92, 1.72) &&
                eventKinds(pointerModel).contains { if case let .pointerMoved(dx, dy) = $0 { return pressureIs(dx, 0.92) && pressureIs(dy, 1.72) }; return false },
                "Pointer deltas reach the local preview with the specified initial response")
        pointerClock.time = 10.001
        input(pointerModel, .moveTouchpad(contact: 1000, delta: .init(dx: 2, dy: 4)))
        require(pointerIs(pointerModel.practiceState.pointerOffset, 2.24, 4.24),
                "A second sub-eight-millisecond sample is processed instead of dropping movement")
        input(pointerModel, .end(contact: 1000))
        require(pointerModel.activeTouchpads.isEmpty && pointerModel.practiceState.heldMouseButtons.isEmpty &&
                pointerIs(pointerModel.practiceState.pointerOffset, 2.24, 4.24) &&
                !eventKinds(pointerModel).contains(.mouseDown(.left)),
                "Ordinary movement-only lift keeps preview totals but creates no click")
        pointerModel.clearPracticeHistory()
        require(pointerModel.recentPracticeEvents.isEmpty && pointerIs(pointerModel.practiceState.pointerOffset, 2.24, 4.24),
                "Clear history does not reset pointer preview totals")
        input(pointerModel, .beginTouchpad(contact: 1001, control: touchpad.id))
        input(pointerModel, .moveTouchpad(contact: 1001, delta: .init(dx: 2, dy: 4)))
        require(pointerIs(pointerModel.practiceState.pointerOffset, 3.16, 5.96),
                "A new touch resets smoothing while accumulating the displayed pointer total")
        input(pointerModel, .cancel(contact: 1001))
        require(pointerModel.activeTouchpads.isEmpty && pointerLink.sent.isEmpty &&
                pointerDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == pointerBytes,
                "Contact cancellation stops pointer tracking without network output or saved runtime data")
        let pointerRestart = makeModel(pointerDefaults)
        require(pointerRestart.practiceState == .neutral && pointerRestart.activeTouchpads.isEmpty &&
                pointerRestart.lockedTouchpads.isEmpty && pointerRestart.pendingTouchpadLocks.isEmpty,
                "Restart restores touchpad settings with zero pointer/scroll totals and no active locks")

        let holdPad = ProfileControl(name: "Hold pad", kind: .touchpad,
                                     touchpadBehavior: .init(sensitivity: 1, clickMode: .hold))
        let (heldPadModel, _, _, _) = try programScenario([holdPad, mouseOwner])
        input(heldPadModel, .beginTouchpad(contact: 1010, control: holdPad.id))
        require(heldPadModel.practiceState.heldMouseButtons == [.left] &&
                eventKinds(heldPadModel) == [.mouseDown(.left)], "Hold-mode touchpad presses left mouse on contact")
        input(heldPadModel, .begin(contact: 1011, control: mouseOwner.id, position: .zero))
        heldPadModel.clearPracticeHistory()
        input(heldPadModel, .cancel(contact: 1010))
        require(heldPadModel.activeTouchpads.isEmpty && heldPadModel.practiceState.heldMouseButtons == [.left] &&
                heldPadModel.recentPracticeEvents.isEmpty,
                "Canceling a hold pad removes only its owner and preserves an independent mouse button")
        input(heldPadModel, .end(contact: 1011))
        require(heldPadModel.practiceState.heldMouseButtons.isEmpty && eventKinds(heldPadModel) == [.mouseUp(.left)],
                "The last independent mouse owner creates the resolved release after pad cancellation")
        input(heldPadModel, .beginTouchpad(contact: 1012, control: holdPad.id))
        input(heldPadModel, .end(contact: 1012))
        require(heldPadModel.practiceState.heldMouseButtons.isEmpty && heldPadModel.activeTouchpads.isEmpty,
                "Ordinary lift releases a hold-mode pad")

        let togglePad = ProfileControl(name: "Delayed toggle pad", kind: .touchpad,
                                       touchpadBehavior: .init(sensitivity: 1, clickMode: .toggle))
        let (togglePadModel, togglePadClock, _, _) = try programScenario([togglePad])
        input(togglePadModel, .beginTouchpad(contact: 1020, control: togglePad.id))
        togglePadClock.time = 10.05; input(togglePadModel, .end(contact: 1020))
        require(togglePadModel.pendingTouchpadLocks == [togglePad.id] &&
                togglePadModel.activeTouchpads.isEmpty && togglePadModel.practiceState.heldMouseButtons.isEmpty,
                "Toggle-mode normal lift preserves its pending 750 ms lock without clicking early")
        togglePadClock.time = 10.749; togglePadModel.tickInput()
        require(togglePadModel.pendingTouchpadLocks == [togglePad.id] && togglePadModel.lockedTouchpads.isEmpty,
                "Toggle pad remains pending before the lock deadline")
        togglePadClock.time = 10.751; togglePadModel.tickInput()
        require(togglePadModel.pendingTouchpadLocks.isEmpty && togglePadModel.lockedTouchpads == [togglePad.id] &&
                togglePadModel.practiceState.heldMouseButtons == [.left],
                "The model's pending deadline locks toggle output after normal lift")
        togglePadClock.time = 11
        input(togglePadModel, .beginTouchpad(contact: 1021, control: togglePad.id))
        input(togglePadModel, .end(contact: 1021))
        require(togglePadModel.lockedTouchpads.isEmpty && togglePadModel.pendingTouchpadLocks.isEmpty &&
                togglePadModel.practiceState.heldMouseButtons.isEmpty,
                "The next direct toggle-pad touch turns off its retained lock")
        togglePadClock.time = 12
        input(togglePadModel, .beginTouchpad(contact: 1022, control: togglePad.id))
        input(togglePadModel, .cancel(contact: 1022))
        togglePadClock.time = 13; togglePadModel.tickInput()
        require(togglePadModel.lockedTouchpads.isEmpty && togglePadModel.pendingTouchpadLocks.isEmpty &&
                togglePadModel.practiceState.heldMouseButtons.isEmpty,
                "Canceling a pending toggle-pad contact prevents the later lock")

        let doublePad = ProfileControl(name: "Double-tap lock pad", kind: .touchpad,
                                       touchpadBehavior: .init(sensitivity: 1, clickMode: .doubleTapLock))
        let (doublePadModel, doublePadClock, _, _) = try programScenario([doublePad])
        input(doublePadModel, .beginTouchpad(contact: 1030, control: doublePad.id))
        doublePadClock.time = 10.05; input(doublePadModel, .end(contact: 1030))
        require(eventKinds(doublePadModel) == [.mouseDown(.left), .mouseUp(.left)] &&
                doublePadModel.practiceState.heldMouseButtons.isEmpty,
                "A clean first tap produces a resolved click and primes double-tap lock")
        doublePadClock.time = 10.1
        input(doublePadModel, .beginTouchpad(contact: 1031, control: doublePad.id))
        require(doublePadModel.pendingTouchpadLocks == [doublePad.id] && doublePadModel.lockedTouchpads.isEmpty,
                "A second touch inside the 120 ms window arms its held lock candidate")
        doublePadClock.time = 10.479; doublePadModel.tickInput()
        require(doublePadModel.lockedTouchpads.isEmpty, "Double-tap candidate remains unlocked before its 380 ms hold")
        doublePadClock.time = 10.481; doublePadModel.tickInput()
        input(doublePadModel, .end(contact: 1031))
        require(doublePadModel.lockedTouchpads == [doublePad.id] && doublePadModel.pendingTouchpadLocks.isEmpty &&
                doublePadModel.practiceState.heldMouseButtons == [.left],
                "Matured double-tap lock survives ordinary lift")
        doublePadModel.clearPracticeHistory()
        doublePadClock.time = 11
        input(doublePadModel, .beginTouchpad(contact: 1032, control: doublePad.id))
        doublePadClock.time = 11.05; input(doublePadModel, .end(contact: 1032))
        require(doublePadModel.lockedTouchpads.isEmpty && eventKinds(doublePadModel) == [.mouseUp(.left)],
                "A clean tap unlocks double-tap mode without adding another click")
        let (latePad, latePadClock, _, _) = try programScenario([doublePad])
        input(latePad, .beginTouchpad(contact: 1040, control: doublePad.id))
        latePadClock.time = 10.05; input(latePad, .end(contact: 1040))
        latePadClock.time = 10.1; input(latePad, .beginTouchpad(contact: 1041, control: doublePad.id))
        latePadClock.time = 10.6; input(latePad, .end(contact: 1041))
        latePadClock.time = 11; latePad.tickInput()
        require(latePad.lockedTouchpads.isEmpty && latePad.pendingTouchpadLocks.isEmpty &&
                latePad.practiceState.heldMouseButtons.isEmpty &&
                eventKinds(latePad) == [.mouseDown(.left), .mouseUp(.left)],
                "A late normal end cancels an unexecuted double-tap deadline instead of creating a lock")
        let (slopPad, slopPadClock, _, _) = try programScenario([doublePad])
        input(slopPad, .beginTouchpad(contact: 1050, control: doublePad.id))
        slopPadClock.time = 10.05; input(slopPad, .end(contact: 1050))
        slopPadClock.time = 10.1; input(slopPad, .beginTouchpad(contact: 1051, control: doublePad.id))
        slopPadClock.time = 10.2; input(slopPad, .moveTouchpad(contact: 1051, delta: .init(dx: 30, dy: 0)))
        slopPadClock.time = 10.25; input(slopPad, .moveTouchpad(contact: 1051, delta: .init(dx: -30, dy: 0)))
        slopPadClock.time = 10.6; slopPad.tickInput(); input(slopPad, .end(contact: 1051))
        require(slopPad.lockedTouchpads.isEmpty && slopPad.pendingTouchpadLocks.isEmpty &&
                eventKinds(slopPad).filter { $0 == .mouseDown(.left) }.count == 1,
                "Moving out and back cannot recover tap eligibility or fire a double-tap lock")

        let (finalPathPad, finalPathClock, _, _) = try programScenario([doublePad])
        input(finalPathPad, .beginTouchpad(contact: 1055, control: doublePad.id))
        finalPathClock.time = 10.05
        input(finalPathPad, .endTouchpad(contact: 1055, finalDeltas: [.init(dx: 30, dy: 0), .init(dx: -30, dy: 0)]))
        require(finalPathPad.activeTouchpads.isEmpty && finalPathPad.pendingTouchpadLocks.isEmpty &&
                !eventKinds(finalPathPad).contains(.mouseDown(.left)),
                "A coalesced final out-and-back path disqualifies a tap despite a zero net endpoint")
        let (finalLatePad, finalLateClock, _, _) = try programScenario([doublePad])
        input(finalLatePad, .beginTouchpad(contact: 1056, control: doublePad.id))
        finalLateClock.time = 10.05; input(finalLatePad, .end(contact: 1056))
        finalLateClock.time = 10.1; input(finalLatePad, .beginTouchpad(contact: 1057, control: doublePad.id))
        finalLateClock.time = 10.6
        input(finalLatePad, .endTouchpad(contact: 1057, finalDeltas: [.init(dx: 1, dy: 0)]))
        finalLateClock.time = 11; finalLatePad.tickInput()
        require(finalLatePad.lockedTouchpads.isEmpty && finalLatePad.pendingTouchpadLocks.isEmpty &&
                eventKinds(finalLatePad).filter { $0 == .mouseDown(.left) }.count == 1,
                "An atomic final movement/end cancels an overdue unexecuted lock before advancing its deadline")
        let (finalSlopPad, finalSlopClock, _, _) = try programScenario([doublePad])
        input(finalSlopPad, .beginTouchpad(contact: 1058, control: doublePad.id))
        finalSlopClock.time = 10.05
        input(finalSlopPad, .endTouchpad(contact: 1058, finalDeltas: [.init(dx: 21, dy: 0)]))
        require(finalSlopPad.practiceState.heldMouseButtons.isEmpty &&
                !eventKinds(finalSlopPad).contains(.mouseDown(.left)) &&
                finalSlopPad.practiceState.pointerOffset != .zero,
                "Movement arriving only with finger-up is processed and prevents a false click beyond tap slop")

        let scrollToggle = ProfileControl(name: "Scroll toggle", payload: "SCROLL_MODE_TOGGLE")
        let (scrollModel, scrollClock, scrollLink, _) = try programScenario([touchpad, scrollToggle, turboButton], turbo: true)
        require(scrollModel.hasPointerOutputs && scrollModel.hasDesktopOutputs,
                "A profile with a touchpad and scroll toggle advertises desktop/pointer capability")
        input(scrollModel, .begin(contact: 1060, control: scrollToggle.id, position: .zero))
        require(scrollModel.practiceState.scrollModeEnabled && eventKinds(scrollModel).last == .scrollModeChanged(true),
                "Direct scroll-toggle press changes the Practice mode once")
        scrollClock.time = 10.81; scrollModel.tickInput()
        input(scrollModel, .end(contact: 1060))
        require(scrollModel.practiceState.scrollModeEnabled &&
                eventKinds(scrollModel).filter { $0 == .scrollModeChanged(true) }.count == 1,
                "Global Turbo and normal lift do not repeat a scroll-mode toggle")
        input(scrollModel, .beginTouchpad(contact: 1061, control: touchpad.id))
        input(scrollModel, .moveTouchpad(contact: 1061, delta: .init(dx: 8, dy: 0)))
        require(scrollModel.practiceState.scrollOffset == 0 && scrollModel.practiceState.pointerOffset == .zero,
                "Horizontal touchpad motion contributes neither scroll nor pointer motion in scroll mode")
        input(scrollModel, .moveTouchpad(contact: 1061, delta: .init(dx: 0, dy: 4)))
        require(pressureIs(scrollModel.practiceState.scrollOffset, -1.72) && scrollModel.practiceState.pointerOffset == .zero &&
                eventKinds(scrollModel).contains { if case let .scrolled(delta) = $0 { return pressureIs(delta, -1.72) }; return false },
                "Vertical touchpad motion produces signed scroll history instead of pointer output")
        input(scrollModel, .end(contact: 1061))
        input(scrollModel, .begin(contact: 1062, control: scrollToggle.id, position: .zero))
        input(scrollModel, .end(contact: 1062))
        require(!scrollModel.practiceState.scrollModeEnabled, "A new direct press toggles scroll mode off")
        input(scrollModel, .begin(contact: 1063, control: turboButton.id, position: .zero))
        input(scrollModel, .transfer(contact: 1063, to: scrollToggle.id))
        input(scrollModel, .end(contact: 1063))
        require(!scrollModel.practiceState.scrollModeEnabled,
                "Sliding from another button onto scroll toggle does not activate its mode change")
        input(scrollModel, .accessibilityActivate(scrollToggle.id))
        require(scrollModel.practiceState.scrollModeEnabled, "Explicit accessibility activation can toggle scrolling")
        scrollModel.releaseAll()
        require(scrollModel.practiceState == .neutral && scrollLink.sent.isEmpty,
                "Release all clears scroll mode/totals and local touchpad output has no network traffic")
        let (toggleOnly, _, _, _) = try programScenario([scrollToggle])
        require(toggleOnly.hasDesktopOutputs && toggleOnly.hasPointerOutputs,
                "A scroll-toggle-only profile updates the pointer-related capability cache")

        for cleanup in ["release all", "background", "editing", "settings", "profile change"] {
            let (padCleanup, padCleanupClock, _, _) = try programScenario([togglePad, touchpad, scrollToggle])
            input(padCleanup, .begin(contact: 1070, control: scrollToggle.id, position: .zero))
            input(padCleanup, .end(contact: 1070))
            input(padCleanup, .beginTouchpad(contact: 1071, control: touchpad.id))
            input(padCleanup, .moveTouchpad(contact: 1071, delta: .init(dx: 0, dy: 4)))
            input(padCleanup, .end(contact: 1071))
            input(padCleanup, .beginTouchpad(contact: 1072, control: togglePad.id))
            input(padCleanup, .end(contact: 1072))
            let oldPadEpoch = padCleanup.inputEpoch
            require(padCleanup.pendingTouchpadLocks == [togglePad.id] && padCleanup.practiceState.scrollModeEnabled,
                    "\(cleanup) touchpad fixture has pending lock and local scroll state")
            switch cleanup {
            case "background": padCleanup.setForeground(false); padCleanup.setForeground(true)
            case "editing": padCleanup.beginLayoutEditing(); padCleanup.cancelLayoutEditing()
            case "settings": padCleanup.prepareSettings(); padCleanup.finishSettings()
            case "profile change": _ = padCleanup.createProfile(name: "Neutral touchpad profile", standardControls: false)
            default: padCleanup.releaseAll()
            }
            padCleanupClock.time = 12
            padCleanup.tickInput(epoch: oldPadEpoch); padCleanup.tickInput()
            padCleanup.handleInput(.moveTouchpad(contact: 1072, delta: .init(dx: 20, dy: 20)), epoch: oldPadEpoch)
            require(padCleanup.practiceState == .neutral && padCleanup.activeTouchpads.isEmpty &&
                    padCleanup.lockedTouchpads.isEmpty && padCleanup.pendingTouchpadLocks.isEmpty &&
                    padCleanup.inputEpoch != oldPadEpoch,
                    "\(cleanup) clears scroll totals and every touchpad owner/deadline, rejecting stale callbacks")
        }
        let (invalidMotion, _, _, _) = try programScenario([holdPad])
        input(invalidMotion, .beginTouchpad(contact: 1080, control: holdPad.id))
        input(invalidMotion, .moveTouchpad(contact: 1080, delta: .init(dx: .nan, dy: 0)))
        require(invalidMotion.practiceState == .neutral && invalidMotion.activeTouchpads.isEmpty,
                "Nonfinite pointer input triggers the model's neutral cleanup path")

        let (padBridge, padBridgeClock, padBridgeLink, _) = try programScenario([holdPad, scrollToggle, desktopMixed])
        _ = activateBridge(padBridge, padBridgeLink)
        input(padBridge, .beginTouchpad(contact: 1090, control: holdPad.id))
        input(padBridge, .moveTouchpad(contact: 1090, delta: .init(dx: 2, dy: 4)))
        require(padBridge.state.isNeutral && padBridgeLink.sent.last?.state?.isNeutral == true,
                "Touchpad movement and mouse hold cannot leak desktop output into bridge gamepad state")
        input(padBridge, .begin(contact: 1091, control: desktopMixed.id, position: .zero))
        require(padBridge.state.buttons == [.a] && padBridgeLink.sent.last?.state?.buttons == [.a],
                "A supported controller button still forwards alongside local-only touchpad output")
        let beforePadLoss = padBridgeLink.sent.count
        padBridgeClock.time = 10.81; padBridge.tickInput()
        require(!padBridge.isReady && padBridge.practiceState == .neutral && padBridge.activeTouchpads.isEmpty &&
                padBridge.lockedTouchpads.isEmpty && padBridgeLink.sent.count == beforePadLoss,
                "Bridge lease expiry clears touchpad owners and totals before further output")

        // Authentic format 3 lacks exactly the new per-control touchpad fields.
        var versionThreeObject = try JSONSerialization.jsonObject(with: directionSaved.exportProfiles()!) as! [String: Any]
        versionThreeObject["version"] = 3
        versionThreeObject.removeValue(forKey: "androidSources")
        var versionThreeProfiles = versionThreeObject["profiles"] as! [[String: Any]]
        for profileIndex in versionThreeProfiles.indices {
            versionThreeProfiles[profileIndex].removeValue(forKey: "androidSources")
            versionThreeProfiles[profileIndex].removeValue(forKey: "pages")
            versionThreeProfiles[profileIndex].removeValue(forKey: "homePageID")
            versionThreeProfiles[profileIndex].removeValue(forKey: "swipeMode")
            var controls = versionThreeProfiles[profileIndex]["controls"] as! [[String: Any]]
            for controlIndex in controls.indices {
                for key in ["touchAim", "buttonAim", "buttonDirectional", "controlWidth", "controlHeight"] { controls[controlIndex].removeValue(forKey: key) }
                controls[controlIndex].removeValue(forKey: "stickResponse")
                controls[controlIndex].removeValue(forKey: "extendedBoost")
                controls[controlIndex].removeValue(forKey: "pageNavigation")
                controls[controlIndex].removeValue(forKey: "swipeActivationEnabled")
                for key in ["touchpadWidth", "touchpadHeight", "touchpadBehavior"] {
                    controls[controlIndex].removeValue(forKey: key)
                }
            }
            versionThreeProfiles[profileIndex]["controls"] = controls
        }
        versionThreeObject["profiles"] = versionThreeProfiles
        let versionThreeBytes = try JSONSerialization.data(withJSONObject: legacyJSON(versionThreeObject), options: [.sortedKeys])
        let v3Defaults = freshDefaults()
        v3Defaults.set(versionThreeBytes, forKey: ProfileControllerViewModel.libraryKey)
        let v3Loaded = makeModel(v3Defaults)
        require(v3Loaded.canEditLayout && v3Loaded.library.version == ControllerProfileLibrary.currentVersion &&
                v3Loaded.profile.controls[0].id == direction.id &&
                v3Loaded.profile.controls[0].directionPayloads == direction.directionPayloads &&
                v3Loaded.profile.controls[0].touchpadWidth == 220 && v3Loaded.profile.controls[0].touchpadHeight == 160 &&
                v3Loaded.profile.controls[0].touchpadBehavior == .init(),
                "Format 3 migration preserves directional IDs/settings and supplies safe touchpad defaults")
        _ = v3Loaded.exportProfiles()
        require(v3Defaults.data(forKey: ProfileControllerViewModel.libraryKey) == versionThreeBytes &&
                v3Defaults.data(forKey: "controller.profiles.before-format-3") == nil,
                "Format 3 load/export does not rewrite original stored bytes or invent a saved upgrade")
        v3Loaded.beginLayoutEditing()
        _ = v3Loaded.addControl(kind: .touchpad)
        v3Loaded.saveLayoutEditing()
        let v3SavedObject = try JSONSerialization.jsonObject(with: v3Defaults.data(forKey: ProfileControllerViewModel.libraryKey)!) as! [String: Any]
        require(v3SavedObject["version"] as? Int == ControllerProfileLibrary.currentVersion &&
                v3Defaults.data(forKey: "controller.profiles.before-format-3") == versionThreeBytes,
                "First explicit format 4 save preserves exact format 3 recovery bytes")
        _ = v3Loaded.renameProfile(v3Loaded.profile.id, name: "Later touchpad save")
        require(v3Defaults.data(forKey: "controller.profiles.before-format-3") == versionThreeBytes,
                "Later saves keep the original format 3 recovery document")
        let padBackup = padEditor.exportProfiles()!
        let padBackupObject = try JSONSerialization.jsonObject(with: padBackup) as! [String: Any]
        let (backupPadModel, backupPadClock, _, backupPadDefaults) = try programScenario([savedPad])
        input(backupPadModel, .beginTouchpad(contact: 1100, control: savedPad.id))
        input(backupPadModel, .end(contact: 1100)); backupPadClock.time = 10.8; backupPadModel.tickInput()
        let restartedPad = makeModel(backupPadDefaults)
        require(restartedPad.profile.controls[0] == savedPad && restartedPad.practiceState == .neutral &&
                restartedPad.lockedTouchpads.isEmpty && restartedPad.pendingTouchpadLocks.isEmpty,
                "Touchpad dimensions/behavior persist across restart while active lock state does not")
        let padImporter = makeModel(freshDefaults())
        let originalImportSelection = padImporter.profile.id
        require(padBackupObject["version"] as? Int == ControllerProfileLibrary.currentVersion &&
                padImporter.importProfiles(padBackup) && padImporter.profile.id == originalImportSelection,
                "Format 4 native backup imports atomically while preserving the existing active profile")
        let importedPad = padImporter.library.profiles.last!.controls.first { $0.kind == .touchpad }!
        require(importedPad.id != savedPad.id && importedPad.touchpadWidth == 320 && importedPad.touchpadHeight == 180 &&
                importedPad.touchpadBehavior == savedPad.touchpadBehavior,
                "Imported format 4 touchpad receives fresh identity and preserves dimensions/click behavior")

        // Swipe migration preserves existing phone gestures while genuinely new profiles opt out.
        let freshSwipe = makeModel(freshDefaults())
        require(freshSwipe.profile.swipeMode == .off && ControllerProfileLibrary.default.activeProfile.swipeMode == .off,
                "A first launch and explicit recovery default keep touches on their starting control")
        require(freshSwipe.createProfile(name: "New standard", standardControls: true) && freshSwipe.profile.swipeMode == .off,
                "A newly created standard controller does not inherit the migration-only button slide mode")
        require(freshSwipe.createProfile(name: "New empty", standardControls: false) && freshSwipe.profile.swipeMode == .off,
                "A newly created empty controller starts with Swipe off")
        require(migrated.profile.swipeMode == .buttons && migrated.profile.controls.allSatisfy(\.swipeActivationEnabled),
                "Actual old layout/behavior migration preserves buttons-only sliding with default enabled entry")
        require([upgraded, v2Loaded, v3Loaded].allSatisfy { $0.profile.swipeMode == .buttons },
                "Native formats 1, 2 and 3 retain the pre-Swipe iPhone gesture mode")

        // Build authentic format 4, including touchpad settings and both orientations' placements.
        var versionFourObject = try JSONSerialization.jsonObject(with: padBackup) as! [String: Any]
        versionFourObject["version"] = 4
        versionFourObject.removeValue(forKey: "androidSources")
        var versionFourProfiles = versionFourObject["profiles"] as! [[String: Any]]
        for profileIndex in versionFourProfiles.indices {
            versionFourProfiles[profileIndex].removeValue(forKey: "androidSources")
            versionFourProfiles[profileIndex].removeValue(forKey: "pages")
            versionFourProfiles[profileIndex].removeValue(forKey: "homePageID")
            versionFourProfiles[profileIndex].removeValue(forKey: "swipeMode")
            var controls = versionFourProfiles[profileIndex]["controls"] as! [[String: Any]]
            for controlIndex in controls.indices { for key in ["touchAim", "buttonAim", "buttonDirectional", "controlWidth", "controlHeight"] { controls[controlIndex].removeValue(forKey: key) }
                controls[controlIndex].removeValue(forKey: "stickResponse")
                controls[controlIndex].removeValue(forKey: "extendedBoost")
                controls[controlIndex].removeValue(forKey: "pageNavigation")
                controls[controlIndex].removeValue(forKey: "swipeActivationEnabled") }
            versionFourProfiles[profileIndex]["controls"] = controls
        }
        versionFourObject["profiles"] = versionFourProfiles
        let versionFourBytes = try JSONSerialization.data(withJSONObject: legacyJSON(versionFourObject), options: [.sortedKeys])
        let v4Defaults = freshDefaults()
        v4Defaults.set(versionFourBytes, forKey: ProfileControllerViewModel.libraryKey)
        let v4Loaded = makeModel(v4Defaults)
        let v4Original = v4Loaded.profile
        require(v4Loaded.canEditLayout && v4Original.swipeMode == .buttons &&
                v4Original.id == padEditor.profile.id && v4Original.controls == padEditor.profile.controls &&
                v4Original.portrait == padEditor.profile.portrait && v4Original.landscape == padEditor.profile.landscape,
                "Format 4 migration keeps IDs, touchpad settings and both placements while preserving button-slide behavior")
        let v4Export = v4Loaded.exportProfiles()!
        let v4ExportObject = try JSONSerialization.jsonObject(with: v4Export) as! [String: Any]
        require(v4ExportObject["version"] as? Int == ControllerProfileLibrary.currentVersion &&
                v4Defaults.data(forKey: ProfileControllerViewModel.libraryKey) == versionFourBytes &&
                v4Defaults.data(forKey: "controller.profiles.before-format-4") == nil,
                "Reading/exporting an old format 4 document produces format 5 without replacing original stored bytes")
        v4Loaded.beginLayoutEditing()
        var swipeOptions = v4Loaded.profile
        swipeOptions.name = "Swipe settings test"
        swipeOptions.swipeMode = .controls
        swipeOptions.turboEnabled = true
        swipeOptions.turboIntervalMilliseconds = 180
        v4Loaded.saveProfileOptions(swipeOptions)
        let swipeButtonID = v4Loaded.addControl(kind: .button)!
        var gatedButton = v4Loaded.profile.control(for: swipeButtonID)!
        gatedButton.name = "Direct only"
        gatedButton.swipeActivationEnabled = false
        v4Loaded.saveControl(gatedButton)
        var swipeDraft = v4Loaded.profile
        try swipeDraft.move(swipeButtonID, to: .init(x: 0.73, y: 0.29), orientation: .portrait)
        v4Loaded.updateProfile(swipeDraft, epoch: v4Loaded.inputEpoch)
        require(v4Loaded.profile.swipeMode == .controls && v4Loaded.profile.control(for: swipeButtonID)?.swipeActivationEnabled == false &&
                v4Defaults.data(forKey: ProfileControllerViewModel.libraryKey) == versionFourBytes,
                "Profile options and per-button swipe entry participate in the unsaved whole-profile draft")
        v4Loaded.cancelLayoutEditing()
        require(v4Loaded.profile == v4Original && v4Defaults.data(forKey: ProfileControllerViewModel.libraryKey) == versionFourBytes,
                "Parent Cancel discards Swipe, Turbo, name, entry flag, added control and position together")
        v4Loaded.beginLayoutEditing()
        v4Loaded.updateProfile(swipeDraft, epoch: v4Loaded.inputEpoch)
        v4Loaded.saveLayoutEditing()
        let savedSwipeBytes = v4Defaults.data(forKey: ProfileControllerViewModel.libraryKey)!
        let savedSwipeObject = try JSONSerialization.jsonObject(with: savedSwipeBytes) as! [String: Any]
        let savedSwipe = makeModel(v4Defaults)
        require(savedSwipe.profile == swipeDraft && savedSwipe.profile.swipeMode == .controls &&
                savedSwipe.profile.control(for: swipeButtonID)?.swipeActivationEnabled == false && savedSwipe.state.isNeutral,
                "Save layout persists Swipe mode and per-instance eligibility together with all other edits")
        require(v4Defaults.data(forKey: "controller.profiles.before-format-4") == versionFourBytes &&
                savedSwipeObject["version"] as? Int == ControllerProfileLibrary.currentVersion,
                "First explicit Swipe save preserves exact format 4 bytes before writing format 5")
        let savedSwipeBackup = savedSwipe.exportProfiles()!
        let swipeImporter = makeModel(freshDefaults())
        let originalSwipeImportID = swipeImporter.profile.id
        require(swipeImporter.importProfiles(savedSwipeBackup) && swipeImporter.profile.id == originalSwipeImportID,
                "Swipe backup merge preserves the current active profile")
        let importedSwipe = swipeImporter.library.profiles.last!
        require(importedSwipe.swipeMode == .controls && importedSwipe.id != savedSwipe.profile.id &&
                Set(importedSwipe.controls.map(\.id)).isDisjoint(with: Set(savedSwipe.profile.controls.map(\.id))) &&
                importedSwipe.controls.first(where: { $0.name == "Direct only" })?.swipeActivationEnabled == false,
                "Native format 5 backup retains Swipe settings while imported profile/control identities are fresh")
        _ = v4Loaded.renameProfile(v4Loaded.profile.id, name: "Second Swipe save")
        require(v4Defaults.data(forKey: "controller.profiles.before-format-4") == versionFourBytes,
                "Later Swipe saves never replace the original format 4 recovery source")
        var futureSwipeObject = try JSONSerialization.jsonObject(with: savedSwipeBackup) as! [String: Any]
        futureSwipeObject["version"] = ControllerProfileLibrary.currentVersion + 1
        let futureSwipeBytes = try JSONSerialization.data(withJSONObject: futureSwipeObject, options: [.sortedKeys])
        let futureSwipeDefaults = freshDefaults()
        futureSwipeDefaults.set(futureSwipeBytes, forKey: ProfileControllerViewModel.libraryKey)
        let futureSwipe = makeModel(futureSwipeDefaults)
        futureSwipe.beginLayoutEditing()
        futureSwipe.saveProfileOptions(swipeDraft)
        futureSwipe.saveLayoutEditing()
        require(!futureSwipe.canEditLayout && futureSwipe.exportProfiles() == nil &&
                futureSwipeDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == futureSwipeBytes,
                "A complete but future format 6 library stays protected from Swipe edits or fallback export")
        let beforeFutureImport = swipeImporter.library
        require(!swipeImporter.importProfiles(futureSwipeBytes) && swipeImporter.library == beforeFutureImport,
                "Future format 6 import is rejected atomically without replacing existing profiles")

        // The actual app model reports handoff acceptance, so the canvas never commits a rejected route.
        func handoff(_ model: ProfileControllerViewModel, contact: Int, to destination: UUID,
                     departing: StickPosition? = nil, arriving: StickPosition = .zero,
                     padDeltas: [PointerDelta] = [], epoch: Int? = nil) -> Bool {
            model.handleInput(.handoff(contact: contact, to: destination, departingStickPosition: departing,
                                      arrivingStickPosition: arriving, finalPadDeltas: padDeltas),
                              epoch: epoch ?? model.inputEpoch)
        }
        let swipeA = ProfileControl(name: "Swipe A", actions: [.a])
        let swipeB = ProfileControl(name: "Swipe B", actions: [.b])
        var directOnly = ProfileControl(name: "Direct X", actions: [.x])
        directOnly.swipeActivationEnabled = false
        let (offSwipe, _, _, _) = try programScenario([swipeA, swipeB], swipe: .off)
        input(offSwipe, .begin(contact: 1200, control: swipeA.id, position: .zero))
        require(!handoff(offSwipe, contact: 1200, to: swipeB.id) && offSwipe.state.buttons == [.a],
                "Swipe off rejects routed destinations without releasing the starting button")
        input(offSwipe, .transfer(contact: 1200, to: nil))
        require(offSwipe.state.buttons == [.a], "Swipe off does not turn an outside gap into button release")
        input(offSwipe, .end(contact: 1200))
        require(offSwipe.state.isNeutral, "Normal lift ends the original button after rejected off-mode transfers")

        let swipeStick = ProfileControl(name: "Swipe stick", kind: .leftStick,
                                        stickBehavior: .init(autoCenter: false))
        let (buttonsSwipe, _, _, _) = try programScenario([swipeA, swipeB, directOnly, swipeStick], swipe: .buttons)
        input(buttonsSwipe, .begin(contact: 1210, control: swipeA.id, position: .zero))
        input(buttonsSwipe, .transfer(contact: 1210, to: directOnly.id))
        require(buttonsSwipe.state.isNeutral,
                "Buttons-only mode treats an entry-disabled target as an ineligible gap without activating it")
        input(buttonsSwipe, .transfer(contact: 1210, to: swipeA.id))
        input(buttonsSwipe, .transfer(contact: 1210, to: swipeStick.id))
        require(
                buttonsSwipe.state.buttons == [.a] && buttonsSwipe.state.leftStick == .zero,
                "Buttons-only mode rejects stick handoff without destroying the current press")
        input(buttonsSwipe, .transfer(contact: 1210, to: swipeB.id))
        require(buttonsSwipe.state.buttons == [.b],
                "Buttons-only handoff atomically replaces the prior ordinary button")
        input(buttonsSwipe, .transfer(contact: 1210, to: nil))
        require(buttonsSwipe.state.isNeutral, "Legacy buttons-only gap transfer releases its current press")
        input(buttonsSwipe, .end(contact: 1210))
        input(buttonsSwipe, .begin(contact: 1211, control: directOnly.id, position: .zero))
        require(buttonsSwipe.state.buttons == [.x], "Disabling swipe entry leaves direct touches usable")
        input(buttonsSwipe, .transfer(contact: 1211, to: swipeA.id))
        require(buttonsSwipe.state.buttons == [.a],
                "A directly touched entry-disabled button can still swipe outward")
        buttonsSwipe.releaseAll()

        let swipePad = ProfileControl(name: "Swipe pad", kind: .touchpad,
                                      touchpadBehavior: .init(clickMode: .hold))
        let swipeRecenter = ProfileControl(name: "Direct Re-center", kind: .recenter)
        let (controlsSwipe, _, _, _) = try programScenario([swipeA, swipeB, directOnly, swipeStick, swipePad, swipeRecenter, scrollToggle], swipe: .controls)
        input(controlsSwipe, .begin(contact: 1220, control: swipeA.id, position: .zero))
        require(!handoff(controlsSwipe, contact: 1220, to: directOnly.id) && controlsSwipe.state.buttons == [.a],
                "Across-controls mode rejects disabled entry without changing the previous captured button")
        require(handoff(controlsSwipe, contact: 1220, to: swipeStick.id, arriving: .init(x: 0.6, y: 0.2)) &&
                controlsSwipe.state.buttons.isEmpty && controlsSwipe.state.leftStick == .init(x: 0.6, y: 0.2),
                "Across-controls handoff releases the button and publishes the arriving stick position immediately")
        require(!handoff(controlsSwipe, contact: 1220, to: swipeRecenter.id) &&
                !handoff(controlsSwipe, contact: 1220, to: scrollToggle.id) &&
                !controlsSwipe.practiceState.scrollModeEnabled && controlsSwipe.state.leftStick == .init(x: 0.6, y: 0.2),
                "Re-center and scroll remain direct-only and cannot steal a swiped stick")
        require(handoff(controlsSwipe, contact: 1220, to: swipePad.id, departing: .init(x: 0.8, y: 0.1)) &&
                controlsSwipe.retainedSticks == [swipeStick.id] && controlsSwipe.state.leftStick == .init(x: 0.8, y: 0.1) &&
                controlsSwipe.activeTouchpads == [swipePad.id] && controlsSwipe.practiceState.heldMouseButtons == [.left],
                "Stick departure retains its final position while the same contact starts the destination touchpad")
        require(handoff(controlsSwipe, contact: 1220, to: swipeB.id, padDeltas: [.init(dx: 2, dy: 4)]) &&
                controlsSwipe.state.buttons == [.b] && controlsSwipe.activeTouchpads.isEmpty &&
                controlsSwipe.practiceState.heldMouseButtons.isEmpty &&
                pressureIs(controlsSwipe.practiceState.pointerOffset.dx, 0.92) && pressureIs(controlsSwipe.practiceState.pointerOffset.dy, 1.72),
                "Pad departure consumes its final movement and releases its hold before entering the next button")
        controlsSwipe.releaseAll()

        let (cancelSwipe, cancelSwipeClock, _, _) = try programScenario([doublePad, swipeB], swipe: .controls)
        input(cancelSwipe, .beginTouchpad(contact: 1230, control: doublePad.id))
        cancelSwipeClock.time = 10.05
        require(handoff(cancelSwipe, contact: 1230, to: swipeB.id) &&
                !eventKinds(cancelSwipe).contains(.mouseDown(.left)),
                "A brief touchpad departure through Swipe does not synthesize a click")
        input(cancelSwipe, .end(contact: 1230))
        cancelSwipeClock.time = 11
        input(cancelSwipe, .beginTouchpad(contact: 1231, control: doublePad.id))
        cancelSwipeClock.time = 11.05; input(cancelSwipe, .end(contact: 1231))
        cancelSwipeClock.time = 11.1; input(cancelSwipe, .beginTouchpad(contact: 1232, control: doublePad.id))
        cancelSwipe.clearPracticeHistory()
        cancelSwipeClock.time = 11.6
        require(handoff(cancelSwipe, contact: 1232, to: swipeB.id, padDeltas: [.init(dx: 1, dy: 0)]) &&
                cancelSwipe.lockedTouchpads.isEmpty && cancelSwipe.pendingTouchpadLocks.isEmpty &&
                !eventKinds(cancelSwipe).contains(.mouseDown(.left)),
                "Late Swipe departure cancels an unobserved double-tap lock before advancing its timer")
        cancelSwipeClock.time = 12; cancelSwipe.tickInput()
        require(cancelSwipe.practiceState.heldMouseButtons.isEmpty && cancelSwipe.state.buttons == [.b],
                "A canceled swipe lock deadline cannot reappear after the destination is active")

        let (enteredSwipePad, enteredSwipeClock, _, _) = try programScenario([swipeB, doublePad], swipe: .controls)
        input(enteredSwipePad, .begin(contact: 1233, control: swipeB.id, position: .zero))
        require(handoff(enteredSwipePad, contact: 1233, to: doublePad.id) &&
                enteredSwipePad.activeTouchpads == [doublePad.id] && enteredSwipePad.state.isNeutral,
                "Swipe can enter a double-tap touchpad for movement without creating a direct tap")
        enteredSwipeClock.time = 10.05; input(enteredSwipePad, .end(contact: 1233))
        require(!eventKinds(enteredSwipePad).contains(.mouseDown(.left)) && enteredSwipePad.pendingTouchpadLocks.isEmpty,
                "A short lift from a swipe-entered double-tap pad neither clicks nor primes its lock gesture")
        enteredSwipeClock.time = 10.1; input(enteredSwipePad, .beginTouchpad(contact: 1234, control: doublePad.id))
        enteredSwipeClock.time = 10.6; enteredSwipePad.tickInput()
        require(enteredSwipePad.lockedTouchpads.isEmpty && enteredSwipePad.pendingTouchpadLocks.isEmpty,
                "The next direct touch cannot become a second-tap lock using a prior swipe entry")
        input(enteredSwipePad, .end(contact: 1234))
        enteredSwipeClock.time = 11; input(enteredSwipePad, .beginTouchpad(contact: 1237, control: doublePad.id))
        enteredSwipeClock.time = 11.05; input(enteredSwipePad, .end(contact: 1237))
        enteredSwipeClock.time = 11.1; input(enteredSwipePad, .beginTouchpad(contact: 1239, control: doublePad.id))
        enteredSwipeClock.time = 11.5; enteredSwipePad.tickInput()
        input(enteredSwipePad, .end(contact: 1239))
        enteredSwipePad.clearPracticeHistory()
        enteredSwipeClock.time = 11.7; input(enteredSwipePad, .begin(contact: 1242, control: swipeB.id, position: .zero))
        let enteredLockedPad = handoff(enteredSwipePad, contact: 1242, to: doublePad.id)
        enteredSwipeClock.time = 11.75; input(enteredSwipePad, .end(contact: 1242))
        require(enteredLockedPad && enteredSwipePad.lockedTouchpads == [doublePad.id] &&
                enteredSwipePad.practiceState.heldMouseButtons == [.left] && eventKinds(enteredSwipePad).isEmpty,
                "Swipe entry and lift preserve an already established double-tap pad lock without an unlock edge")

        let (toggleSwipe, toggleSwipeClock, _, _) = try programScenario([togglePad, swipeB], swipe: .controls)
        input(toggleSwipe, .beginTouchpad(contact: 1235, control: togglePad.id))
        require(handoff(toggleSwipe, contact: 1235, to: swipeB.id) &&
                toggleSwipe.pendingTouchpadLocks == [togglePad.id] && toggleSwipe.state.buttons == [.b],
                "A toggle-pad handoff preserves its intentional pending lock while entering the next button")
        toggleSwipeClock.time = 10.8; toggleSwipe.tickInput()
        require(toggleSwipe.lockedTouchpads == [togglePad.id] && toggleSwipe.practiceState.heldMouseButtons == [.left] &&
                toggleSwipe.state.buttons == [.b],
                "The preserved toggle-pad deadline can lock independently after Swipe departure")
        input(toggleSwipe, .beginTouchpad(contact: 1236, control: togglePad.id))
        require(toggleSwipe.lockedTouchpads.isEmpty && toggleSwipe.practiceState.heldMouseButtons.isEmpty &&
                toggleSwipe.state.buttons == [.b], "A direct pad touch unlocks it without releasing the swiped button owner")

        let pendingSwipeHold = ProfileControl(name: "Pending Swipe hold", actions: [.y],
                                              buttonBehavior: .init(holdToggle: true, holdMilliseconds: 500))
        let (holdSwipe, holdSwipeClock, _, _) = try programScenario([pendingSwipeHold, swipeB], swipe: .controls)
        input(holdSwipe, .begin(contact: 1238, control: pendingSwipeHold.id, position: .zero))
        holdSwipeClock.time = 10.6
        require(handoff(holdSwipe, contact: 1238, to: swipeB.id) && holdSwipe.state.buttons == [.b] &&
                holdSwipe.latchedControls.isEmpty, "Swipe departure cancels an unobserved hold deadline before it can latch")

        let sharedMouseA = ProfileControl(name: "Shared mouse A", payload: "MOUSE_LEFT_DOWN, X360A")
        let sharedMouseB = ProfileControl(name: "Shared mouse B", payload: "MOUSE_LEFT_DOWN, X360B")
        let independentMouse = ProfileControl(name: "Independent mouse", payload: "MOUSE_LEFT_DOWN")
        let (sharedSwipe, _, _, _) = try programScenario([sharedMouseA, sharedMouseB, independentMouse], swipe: .controls)
        input(sharedSwipe, .begin(contact: 1240, control: sharedMouseA.id, position: .zero))
        input(sharedSwipe, .begin(contact: 1241, control: independentMouse.id, position: .zero))
        sharedSwipe.clearPracticeHistory()
        require(handoff(sharedSwipe, contact: 1240, to: sharedMouseB.id) && sharedSwipe.state.buttons == [.b] &&
                sharedSwipe.practiceState.heldMouseButtons == [.left] && eventKinds(sharedSwipe).isEmpty,
                "Atomic Swipe preserves a shared resolved mouse hold without a false up/down edge")
        input(sharedSwipe, .cancel(contact: 1240))
        require(sharedSwipe.practiceState.heldMouseButtons == [.left] && sharedSwipe.state.isNeutral,
                "Canceling the swiped contact preserves an independent mouse owner")
        input(sharedSwipe, .end(contact: 1241))
        require(sharedSwipe.practiceState.heldMouseButtons.isEmpty && eventKinds(sharedSwipe) == [.mouseUp(.left)],
                "The final independent owner produces the single resolved release")

        let swipeWait = ProfileControl(name: "Swipe wait", payload: "X360A, WAIT_200, X360Y")
        for cleanup in ["release all", "background", "editing", "settings", "profile change"] {
            let (cleanupSwipe, cleanupSwipeClock, _, _) = try programScenario([swipeA, swipeWait, togglePad], swipe: .controls)
            input(cleanupSwipe, .begin(contact: 1250, control: swipeA.id, position: .zero))
            _ = handoff(cleanupSwipe, contact: 1250, to: swipeWait.id)
            input(cleanupSwipe, .beginTouchpad(contact: 1251, control: togglePad.id))
            input(cleanupSwipe, .end(contact: 1251))
            let cleanupEpoch = cleanupSwipe.inputEpoch
            switch cleanup {
            case "release all": cleanupSwipe.releaseAll()
            case "background": cleanupSwipe.setForeground(false); cleanupSwipe.setForeground(true)
            case "editing": cleanupSwipe.beginLayoutEditing(); cleanupSwipe.cancelLayoutEditing()
            case "settings": cleanupSwipe.prepareSettings(); cleanupSwipe.finishSettings()
            default: _ = cleanupSwipe.createProfile(name: "After Swipe", standardControls: true)
            }
            cleanupSwipeClock.time = 12
            cleanupSwipe.tickInput(epoch: cleanupEpoch)
            require(!handoff(cleanupSwipe, contact: 1250, to: togglePad.id, epoch: cleanupEpoch) &&
                    cleanupSwipe.state.isNeutral && cleanupSwipe.practiceState == .neutral &&
                    cleanupSwipe.pendingTouchpadLocks.isEmpty && cleanupSwipe.lockedTouchpads.isEmpty,
                    "\(cleanup) invalidates a swiped contact, WAIT and pending lock before stale callbacks can revive them")
        }
        let (modalSwipe, _, _, _) = try programScenario([swipeA, swipeB], swipe: .controls)
        modalSwipe.prepareSettings()
        require(!modalSwipe.handleInput(.begin(contact: 1260, control: swipeA.id, position: .zero), epoch: modalSwipe.inputEpoch) &&
                !handoff(modalSwipe, contact: 1260, to: swipeB.id),
                "The Settings gate reports rejected begins and handoffs instead of committing a canvas route")
        modalSwipe.finishSettings(); modalSwipe.beginLayoutEditing()
        require(!handoff(modalSwipe, contact: 1261, to: swipeB.id) && modalSwipe.state.isNeutral,
                "The profile draft cannot receive swipe input")
        modalSwipe.cancelLayoutEditing()

        let swipeMixed = ProfileControl(name: "Mixed swipe", payload: "X360B, RT:0.5, W, MOUSE_LEFT_DOWN")
        let (bridgeSwipe, bridgeSwipeClock, bridgeSwipeLink, _) = try programScenario([swipeA, swipeMixed, swipeB], swipe: .controls)
        _ = activateBridge(bridgeSwipe, bridgeSwipeLink)
        input(bridgeSwipe, .begin(contact: 1270, control: swipeA.id, position: .zero))
        require(handoff(bridgeSwipe, contact: 1270, to: swipeMixed.id) && bridgeSwipe.state.buttons == [.b] &&
                bridgeSwipeLink.sent.last?.state?.buttons == [.b] &&
                pressureIs(bridgeSwipe.practiceState.rightTrigger, 0.5) && bridgeSwipe.practiceState.heldKeys == [.w],
                "A swiped mixed payload sends only supported controller state to the bridge")
        let swipeWire = String(data: try BridgeCodec.encode(bridgeSwipeLink.sent.last!), encoding: .utf8)!
        require(!swipeWire.contains("heldKeys") && !swipeWire.contains("MOUSE") && !swipeWire.contains("swipe"),
                "SCX1 packets never gain desktop actions or local Swipe configuration")
        let beforeSwipeExpiry = bridgeSwipeLink.sent.count
        bridgeSwipeClock.time = 10.81
        require(!handoff(bridgeSwipe, contact: 1270, to: swipeB.id) && !bridgeSwipe.isReady &&
                bridgeSwipe.state.isNeutral && bridgeSwipe.practiceState == .neutral &&
                bridgeSwipeLink.sent.count == beforeSwipeExpiry,
                "The bridge lease expires before a new swipe owner can produce output")

        // Pages are runtime navigation over one atomic profile draft, never transport commands.
        let pageHold = ProfileControl(name: "Latched A", actions: [.a], buttonBehavior: .init(holdToggle: true, holdMilliseconds: 50))
        let pageStick = ProfileControl(kind: .leftStick, stickBehavior: .init(autoCenter: false))
        let pagePad = ProfileControl(kind: .touchpad, touchpadBehavior: .init(clickMode: .toggle))
        let pageItems = [pageHold, pageStick, pagePad]
        var paged = try ControllerProfile(name: "Paged", controls: pageItems,
            portrait: pageItems.map { .init(id: $0.id, position: .init(x: 0.25, y: 0.4)) },
            landscape: pageItems.map { .init(id: $0.id, position: .init(x: 0.6, y: 0.7)) })
        let homePage = paged.homePageID
        let drivingPage = try paged.addPage(name: "Driving")
        let goPage = ProfileControl(name: "Drive", kind: .pageButton, pageNavigation: .goTo(drivingPage))
        let returnPage = ProfileControl(name: "Return", kind: .pageButton, pageNavigation: .back)
        let homeButton = ProfileControl(name: "Home", kind: .pageButton)
        let drivingB = ProfileControl(name: "Driving B", actions: [.b])
        try paged.addControl(goPage, toPage: homePage)
        try paged.addControl(homeButton, toPage: homePage)
        try paged.addControl(returnPage, toPage: drivingPage)
        try paged.addControl(drivingB, toPage: drivingPage)
        let pageDefaults = freshDefaults()
        pageDefaults.set(try ControllerProfileLibraryCodec.encode(.init(activeProfileID: paged.id, profiles: [paged])),
                         forKey: ProfileControllerViewModel.libraryKey)
        let pageClock = ProfileCheckClock(); let pageLink = ProfileCheckTransport()
        let pageModel = makeModel(pageDefaults, link: pageLink, clock: pageClock)
        require(pageModel.currentPageID == homePage && pageModel.currentPageControls.count == 5,
                "Startup shows Home with only its controls")
        let pageSavedBytes = pageDefaults.data(forKey: ProfileControllerViewModel.libraryKey)
        input(pageModel, .begin(contact: 1400, control: pageHold.id, position: .zero))
        pageClock.time += 0.06; pageModel.tickInput(); input(pageModel, .end(contact: 1400))
        input(pageModel, .begin(contact: 1401, control: pageStick.id, position: .init(x: 0.4, y: 0.8)))
        input(pageModel, .end(contact: 1401))
        input(pageModel, .beginTouchpad(contact: 1402, control: pagePad.id)); input(pageModel, .end(contact: 1402))
        pageClock.time += 0.76; pageModel.tickInput()
        require(pageModel.latchedControls.contains(pageHold.id) && pageModel.retainedSticks.contains(pageStick.id) &&
                pageModel.lockedTouchpads.contains(pagePad.id), "Page transition fixture owns held button, stick and pad")
        let oldPageEpoch = pageModel.inputEpoch
        input(pageModel, .begin(contact: 1403, control: goPage.id, position: .zero))
        require(pageModel.currentPageID == drivingPage && pageModel.inputEpoch != oldPageEpoch &&
                pageModel.currentPageControls.count == 2, "Direct page button changes visible page and input epoch")
        require(pageModel.state.isNeutral && pageModel.practiceState == .neutral && pageModel.latchedControls.isEmpty &&
                pageModel.retainedSticks.isEmpty && pageModel.lockedTouchpads.isEmpty && pageModel.pendingTouchpadLocks.isEmpty,
                "Changing pages releases every held owner and pending timer")
        require(!pageModel.handleInput(.begin(contact: 1404, control: pageHold.id, position: .zero), epoch: oldPageEpoch),
                "Old page callbacks cannot activate the replacement page")
        require(!pageModel.handleInput(.begin(contact: 1404, control: pageHold.id, position: .zero), epoch: pageModel.inputEpoch) &&
                pageModel.state.isNeutral, "Hidden controls cannot activate through a current-epoch event")
        require(!pageModel.hasDesktopOutputs && !pageModel.hasPointerOutputs,
                "Capability display follows the visible page")
        require(pageDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == pageSavedBytes,
                "Page navigation never persists current page or live state")
        input(pageModel, .accessibilityActivate(returnPage.id))
        require(pageModel.currentPageID == homePage, "Accessible Return page button visits the previous page")
        input(pageModel, .begin(contact: 1405, control: pageHold.id, position: .zero))
        pageClock.time += 0.06; pageModel.tickInput(); input(pageModel, .end(contact: 1405))
        let samePageEpoch = pageModel.inputEpoch
        input(pageModel, .accessibilityActivate(homeButton.id))
        require(pageModel.currentPageID == homePage && pageModel.inputEpoch == samePageEpoch &&
                pageModel.state.buttons == [.a], "Same-page navigation leaves independent held input untouched")
        pageModel.selectPage(drivingPage)
        require(pageModel.currentPageID == drivingPage && pageModel.state.isNeutral,
                "Page picker changes page and releases held input")
        let restartedPages = makeModel(pageDefaults)
        require(restartedPages.currentPageID == homePage && restartedPages.state.isNeutral,
                "Relaunch uses saved Home, not the previously visited page")

        pageModel.beginLayoutEditing()
        var pageDraft = pageModel.profile
        let aimingPage = try pageDraft.addPage(name: "Aiming")
        pageModel.savePages(pageDraft, selectedPageID: aimingPage)
        require(pageModel.currentPageID == aimingPage && pageModel.profile.pages.count == 3,
                "Page manager Done updates only the whole-profile draft")
        let aimingControl = pageModel.addControl(kind: .button)!
        require(pageModel.profile.pageID(containing: aimingControl) == aimingPage,
                "Adding a control places it on the selected edit page")
        pageModel.moveControl(aimingControl, toPage: homePage)
        require(pageModel.profile.pageID(containing: aimingControl) == homePage,
                "Moving between pages preserves the control identity")
        pageModel.cancelLayoutEditing()
        require(pageModel.library.activeProfile == paged && pageModel.profile.pages.count == 2 &&
                pageModel.profile.control(for: aimingControl) == nil && pageModel.currentPageID == drivingPage,
                "Parent Cancel restores every page/control and the previously selected page")
        pageModel.beginLayoutEditing(); pageDraft = pageModel.profile
        try pageDraft.setHomePage(drivingPage)
        pageModel.savePages(pageDraft, selectedPageID: drivingPage)
        let draftButton = pageModel.profile.control(for: drivingB.id)!
        pageModel.duplicateControl(draftButton, toPage: homePage)
        require(pageModel.profile.pages.first { $0.id == homePage }!.controlIDs.count == 6,
                "Copy control may place the independent copy on a different page")
        pageModel.saveLayoutEditing()
        let pageRestart = makeModel(pageDefaults)
        require(pageRestart.profile.homePageID == drivingPage && pageRestart.currentPageID == drivingPage &&
                pageRestart.profile.controls.count == 8, "Save persists pages, Home and independent copied controls")
        require(pageRestart.duplicateProfile(paged.id), "Complete paged profile can be duplicated")
        let originalPaged = pageRestart.library.profiles.first { $0.id == paged.id }!
        let clonedPaged = pageRestart.profile
        require(Set(originalPaged.pages.map(\.id)).isDisjoint(with: Set(clonedPaged.pages.map(\.id))) &&
                Set(originalPaged.controls.map(\.id)).isDisjoint(with: Set(clonedPaged.controls.map(\.id))),
                "Duplicating a paged profile gives fresh page and control IDs")
        require(clonedPaged.controls.compactMap { $0.pageNavigation?.targetPageID }.allSatisfy {
            clonedPaged.page(for: $0) != nil
        }, "Duplicated navigation targets stay inside the new profile")
        let pageBackup = pageRestart.exportProfiles()!
        let importedPages = makeModel(freshDefaults()); let importSelection = importedPages.library.activeProfileID
        require(importedPages.importProfiles(pageBackup) && importedPages.library.activeProfileID == importSelection,
                "Paged native backup import preserves the destination selection")
        require(importedPages.library.profiles.dropFirst().allSatisfy { profile in
            profile.controls.compactMap { $0.pageNavigation?.targetPageID }.allSatisfy { profile.page(for: $0) != nil }
        }, "Imported navigation targets are remapped to their imported pages")

        let pageBridgeDefaults = freshDefaults()
        pageBridgeDefaults.set(try ControllerProfileLibraryCodec.encode(.init(activeProfileID: paged.id, profiles: [paged])),
                               forKey: ProfileControllerViewModel.libraryKey)
        let pageBridgeLink = ProfileCheckTransport(); let pageBridgeClock = ProfileCheckClock()
        let pageBridge = makeModel(pageBridgeDefaults, link: pageBridgeLink, clock: pageBridgeClock)
        _ = activateBridge(pageBridge, pageBridgeLink)
        let bridgeOpensBeforePages = pageBridgeLink.opens
        pageBridge.selectPage(drivingPage)
        input(pageBridge, .begin(contact: 1410, control: drivingB.id, position: .zero))
        require(pageBridge.state.buttons == [.b] && pageBridgeLink.sent.last?.state?.buttons == [.b],
                "Visible second-page button can send a supported bridge action")
        input(pageBridge, .begin(contact: 1411, control: returnPage.id, position: .zero))
        require(pageBridge.currentPageID == homePage && pageBridge.isReady && pageBridge.state.isNeutral &&
                pageBridgeLink.sent.last?.state?.isNeutral == true && pageBridgeLink.opens == bridgeOpensBeforePages,
                "Page navigation sends neutral without dropping or reopening a ready bridge connection")

        // Physical travel must survive the app event adapter, retention, save and migration.
        var advancedStick = ProfileControl(name: "Extended stick", kind: .leftStick)
        advancedStick.stickBehavior.autoCenter = false
        advancedStick.stickBehavior.stickPlusEnabled = true
        advancedStick.stickBehavior.directions[.up] = .init(normalControls: [.x], boostControls: [.leftStickClick], superBoostControls: [.a])
        advancedStick.stickResponse = .init(mode: .linear, sensitivity: 0.5)
        advancedStick.extendedBoost.enabled = true
        advancedStick.extendedBoost.mode = .addOuterStage
        advancedStick.extendedBoost.directions[.up] = .init(outerThreshold: 1.25, outerPayload: "X360B,W")
        let advancedButton = ProfileControl(name: "Separate B", kind: .button, actions: [.b])
        var advancedProfile = try ControllerProfile(name: "Advanced sticks", controls: [], swipeMode: .controls)
        try advancedProfile.addControl(advancedStick, toPage: advancedProfile.homePageID)
        try advancedProfile.addControl(advancedButton, toPage: advancedProfile.homePageID)
        let advancedDefaults = freshDefaults()
        advancedDefaults.set(try ControllerProfileLibraryCodec.encode(.init(activeProfileID: advancedProfile.id, profiles: [advancedProfile])), forKey: ProfileControllerViewModel.libraryKey)
        let advancedClock = ProfileCheckClock()
        let advancedModel = makeModel(advancedDefaults, clock: advancedClock)
        input(advancedModel, .beginStick(contact: 1500, control: advancedStick.id, travel: .init(y: 0.8)))
        require(advancedModel.state.leftStick.y == 0.4 && advancedModel.state.buttons == [.a],
                "Advanced event uses physical stage distance independently of analog sensitivity")
        require(advancedModel.stickPositions[advancedStick.id]?.y == 0.8, "Visible knob tracks physical travel before response shaping")
        input(advancedModel, .moveStick(contact: 1500, travel: .init(y: 1.25)))
        require(advancedModel.state.buttons == [.a], "Outer stage uses a strict above-threshold boundary")
        input(advancedModel, .moveStick(contact: 1500, travel: .init(y: 1.3)))
        require(advancedModel.state.leftStick.y == 0.5 && advancedModel.state.buttons == [.b] && advancedModel.practiceState.heldKeys == [.w],
                "Beyond-edge travel replaces Super with the mixed outer payload")
        require(advancedModel.stickPositions[advancedStick.id]?.y == 1, "Visible knob stays at the rim for beyond-edge travel")
        input(advancedModel, .end(contact: 1500))
        require(advancedModel.retainedSticks == [advancedStick.id] && advancedModel.state.buttons == [.b] &&
                advancedModel.practiceState.heldKeys == [.w], "Retained stick preserves its physical outer stage after normal lift")
        input(advancedModel, .begin(contact: 1501, control: advancedButton.id, position: .zero))
        advancedModel.recenterSticks()
        require(advancedModel.state.leftStick == .zero && advancedModel.state.buttons == [.b] && advancedModel.practiceState.heldKeys.isEmpty,
                "Re-center clears extended stages while preserving independent button owners")
        input(advancedModel, .end(contact: 1501))
        input(advancedModel, .beginStick(contact: 1502, control: advancedStick.id, travel: .init(y: 1.4)))
        input(advancedModel, .cancel(contact: 1502))
        require(advancedModel.state.isNeutral && advancedModel.practiceState == .neutral && advancedModel.retainedSticks.isEmpty,
                "Contact cancellation cannot retain a beyond-edge stick stage")
        input(advancedModel, .beginStick(contact: 1503, control: advancedStick.id, travel: .init(y: 1.4)))
        advancedModel.setForeground(false); advancedModel.setForeground(true)
        require(advancedModel.state.isNeutral && advancedModel.practiceState == .neutral,
                "Leaving and returning clears advanced stick output")

        advancedModel.beginLayoutEditing()
        var changedAdvanced = advancedModel.profile.control(for: advancedStick.id)!
        changedAdvanced.stickResponse = .init(mode: .perAxis, sensitivity: 2)
        changedAdvanced.extendedBoost.mode = .replaceThresholds
        changedAdvanced.extendedBoost.directions[.up] = .init(regularThreshold: 1.2, superThreshold: 1.6)
        advancedModel.saveControl(changedAdvanced)
        advancedModel.cancelLayoutEditing()
        require(advancedModel.profile.control(for: advancedStick.id) == advancedStick, "Cancel restores all advanced settings")
        advancedModel.beginLayoutEditing(); advancedModel.saveControl(changedAdvanced); advancedModel.saveLayoutEditing()
        let advancedReload = makeModel(advancedDefaults)
        require(advancedReload.profile.control(for: advancedStick.id) == changedAdvanced && advancedReload.state.isNeutral,
                "Advanced curve and all four direction distances persist without live input")
        input(advancedReload, .beginStick(contact: 1504, control: advancedStick.id, travel: .init(y: 0.25)))
        require(advancedReload.state.leftStick.y == 0.5 && advancedReload.state.buttons == [.x], "Per-axis curve reaches the expected output in the real model")
        input(advancedReload, .moveStick(contact: 1504, travel: .init(y: 1.4)))
        require(advancedReload.state.buttons == [.leftStick], "Replacement Boost may be positioned beyond the edge")
        input(advancedReload, .moveStick(contact: 1504, travel: .init(y: 1.7)))
        require(advancedReload.state.buttons == [.a], "Replacement Super may be positioned farther beyond the edge")
        let handoffAccepted = advancedReload.handleInput(.handoffTravel(contact: 1504, to: advancedButton.id,
            departingTravel: .init(y: 1.8), arrivingTravel: .zero, finalPadDeltas: []), epoch: advancedReload.inputEpoch)
        require(handoffAccepted && advancedReload.state.buttons == [.a, .b], "Raw handoff reports acceptance and retains the departing physical stage")
        input(advancedReload, .end(contact: 1504)); advancedReload.releaseAll()
        require(advancedReload.state.isNeutral && advancedReload.practiceState == .neutral, "Release all clears advanced handoff and retention")

        var versionSixObject = try JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(.init(activeProfileID: advancedProfile.id, profiles: [advancedProfile]))) as! [String: Any]
        versionSixObject["version"] = 6
        versionSixObject.removeValue(forKey: "androidSources")
        var versionSixProfiles = versionSixObject["profiles"] as! [[String: Any]]
        for index in versionSixProfiles.indices {
            versionSixProfiles[index].removeValue(forKey: "androidSources")
            var controls = versionSixProfiles[index]["controls"] as! [[String: Any]]
            for controlIndex in controls.indices {
                for key in ["touchAim", "buttonAim", "buttonDirectional", "controlWidth", "controlHeight"] { controls[controlIndex].removeValue(forKey: key) }
                controls[controlIndex].removeValue(forKey: "stickResponse")
                controls[controlIndex].removeValue(forKey: "extendedBoost")
            }
            versionSixProfiles[index]["controls"] = controls
        }
        versionSixObject["profiles"] = versionSixProfiles
        let versionSixBytes = try JSONSerialization.data(withJSONObject: legacyJSON(versionSixObject), options: [.sortedKeys])
        let versionSixDefaults = freshDefaults(); versionSixDefaults.set(versionSixBytes, forKey: ProfileControllerViewModel.libraryKey)
        let versionSixModel = makeModel(versionSixDefaults)
        require(versionSixModel.canEditLayout && versionSixModel.profile.controls.allSatisfy {
            $0.stickResponse == .init() && $0.extendedBoost == .init()
        }, "Format6 migrates to neutral advanced defaults")
        require(versionSixDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == versionSixBytes,
                "Loading an old profile does not rewrite it")
        versionSixModel.beginLayoutEditing(); versionSixModel.saveLayoutEditing()
        require(versionSixDefaults.data(forKey: "controller.profiles.before-format-6") == versionSixBytes,
                "First upgraded save preserves exact format6 recovery bytes")

        // The app adapter must preserve advanced pointer paths, occupancy and visual state.
        var gestureButton = ProfileControl(name: "Drag actions", kind: .button, actions: [.a], controlWidth: 180, controlHeight: 100)
        gestureButton.buttonDirectional.enabled = true
        gestureButton.buttonDirectional.directions[.right] = .init(firstDistance: 48, secondDistance: 96,
                                                                  firstPayload: "X360B", secondPayload: "X360X")
        var aimButton = ProfileControl(name: "Aim on lift", kind: .button, payload: "X360Y", controlWidth: 180, controlHeight: 100)
        aimButton.buttonAim.enabled = true
        aimButton.buttonAim.payloadTiming = .sendOnRelease
        aimButton.buttonAim.releaseDelayMilliseconds = 100
        aimButton.buttonAim.cancelOnBoundaryExit = true
        aimButton.buttonAim.tuning = .init(output: .rightStick, fullDisplacement: 108, deadzone: 8)
        let competingStick = ProfileControl(name: "Right stick", kind: .rightStick)
        var gestureProfile = try ControllerProfile(name: "Advanced buttons", swipeMode: .controls)
        for control in [gestureButton, aimButton, competingStick] { try gestureProfile.addControl(control, toPage: gestureProfile.homePageID) }
        let gestureDefaults = freshDefaults()
        gestureDefaults.set(try ControllerProfileLibraryCodec.encode(.init(activeProfileID: gestureProfile.id, profiles: [gestureProfile])), forKey: ProfileControllerViewModel.libraryKey)
        let gestureClock = ProfileCheckClock()
        let gestureModel = makeModel(gestureDefaults, clock: gestureClock)
        func buttonPoint(_ x: Double = 90, _ y: Double = 50) -> ButtonPointerSample { .init(x: x, y: y, width: 180, height: 100) }
        require(gestureModel.handleInput(.beginButton(contact: 1600, control: gestureButton.id, sample: buttonPoint()), epoch: gestureModel.inputEpoch),
                "Advanced button start reports actual capture acceptance")
        require(gestureModel.state.buttons == [.a], "Directional button starts its base output")
        input(gestureModel, .moveButtonBatch(contact: 1600, samples: [buttonPoint(138)]))
        require(gestureModel.state.buttons == [.a, .b] && gestureModel.buttonDirectionalSelections[gestureButton.id]?.stage == 1,
                "Directional first stage reaches output and published visual state")
        input(gestureModel, .moveButtonBatch(contact: 1600, samples: [buttonPoint(186)]))
        require(gestureModel.state.buttons == [.a, .b, .x] && gestureModel.buttonDirectionalSelections[gestureButton.id]?.stage == 2,
                "Directional second stage is cumulative in the app model")
        require(!gestureModel.handleInput(.beginButton(contact: 1601, control: gestureButton.id, sample: buttonPoint()), epoch: gestureModel.inputEpoch),
                "Duplicate advanced-button touch is not accepted by UIKit routing")
        input(gestureModel, .cancel(contact: 1601))
        require(gestureModel.state.buttons == [.a, .b, .x], "Canceling an ignored touch preserves the real advanced owner")
        input(gestureModel, .endButton(contact: 1600, finalSamples: [buttonPoint(141)]))
        require(gestureModel.state.isNeutral, "Atomic final button path and lift release all directional leases")

        input(gestureModel, .beginButton(contact: 1602, control: aimButton.id, sample: buttonPoint()))
        input(gestureModel, .moveButtonBatch(contact: 1602, samples: [buttonPoint(148)]))
        require(gestureModel.state.rightStick.x == 0.5 && gestureModel.state.buttons.isEmpty,
                "Aim on release moves the stick without prematurely sending the button")
        require(gestureModel.buttonAimStates[aimButton.id] != nil && gestureModel.buttonFeedbackGeneration > 0,
                "Aim visual state and haptic hints are published")
        require(!gestureModel.handleInput(.beginStick(contact: 1603, control: competingStick.id, travel: .init(x: -1)), epoch: gestureModel.inputEpoch),
                "A stick cannot adopt a channel already captured by Button Aim")
        input(gestureModel, .cancel(contact: 1603))
        require(gestureModel.state.rightStick.x == 0.5, "Canceling a rejected stick does not clear Aim ownership")
        input(gestureModel, .endButton(contact: 1602, finalSamples: [buttonPoint(148)]))
        require(gestureModel.state.buttons.isEmpty && gestureModel.buttonAimStates[aimButton.id] == .waitingToFire,
                "Deliberate lift starts the requested release delay")
        gestureClock.time += 0.11; gestureModel.tickInput()
        require(gestureModel.state.buttons == [.y], "The release action fires after its delay")
        gestureClock.time += 0.10; gestureModel.tickInput()
        require(gestureModel.state.isNeutral, "The finite release action ends without a stuck button")
        input(gestureModel, .beginButton(contact: 1604, control: aimButton.id, sample: buttonPoint()))
        input(gestureModel, .endButton(contact: 1604, finalSamples: [buttonPoint(181), buttonPoint()]))
        gestureClock.time += 0.11; gestureModel.tickInput()
        require(gestureModel.state.isNeutral, "An out-and-back final path cancels release action before any due timer")
        input(gestureModel, .beginButton(contact: 1605, control: aimButton.id, sample: buttonPoint()))
        input(gestureModel, .endButton(contact: 1605, finalSamples: [buttonPoint()]))
        gestureModel.setForeground(false); gestureModel.setForeground(true)
        gestureClock.time += 1; gestureModel.tickInput()
        require(gestureModel.state.isNeutral && gestureModel.buttonAimStates.isEmpty,
                "Background interruption cancels pending aim release and clears its displayed state")
        gestureModel.beginLayoutEditing()
        var mouseAim = aimButton; mouseAim.buttonAim.tuning.output = .mouse
        gestureModel.saveControl(mouseAim); gestureModel.saveLayoutEditing()
        require(gestureModel.hasPointerOutputs && gestureModel.hasDesktopOutputs,
                "Mouse Aim reserves visible pointer telemetry even without a touchpad")
        let gestureReload = makeModel(gestureDefaults)
        require(gestureReload.profile.control(for: aimButton.id) == mouseAim && gestureReload.profile.control(for: gestureButton.id) == gestureButton,
                "Advanced settings and independent dimensions survive save and reload")

        // Android imports preserve immutable originals separately from executable native copies.
        do {
            let qaRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleController.AndroidVMChecks." + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: qaRoot) }
            func androidModel(_ defaults: UserDefaults, folder: String) -> ProfileControllerViewModel {
                let clock = ProfileCheckClock(), transport = ProfileCheckTransport()
                return ProfileControllerViewModel(defaults: defaults, transport: transport, clock: { clock.time },
                    automaticTimer: false, persistSettings: true, androidArchiveDirectory: qaRoot.appendingPathComponent(folder, isDirectory: true))
            }
            let androidBytes = Data(#" {"formatVersion":10,"homePageId":"home","pages":[{"id":"home","name":"Imported","controls":[{"id":"a","type":"BUTTON","x":20,"y":30,"w":120,"h":80,"payload":"X360A","name":"A"},{"id":"sensor","type":"FUTURE_SENSOR","x":200,"y":30,"w":120,"h":80,"payload":"TOUCH_AIM","touchAimAppliedCalibrationId":"preserve-me"}]}],"future":{"integer":9007199254740993,"nested":[true,null,"keep"]}} "#.utf8)
            let originalDefaults = freshDefaults(), originalModel = androidModel(originalDefaults, folder: "original")
            let beforeLibrary = originalModel.library, beforeBytes = originalDefaults.data(forKey: ProfileControllerViewModel.libraryKey)!
            let preview = try AndroidImportPreview.prepare(androidBytes, displayName: "Source.json")
            require(preview.plan.convertedControlCount == 1 && preview.plan.archivedOnlyControlCount == 1,
                    "Android preview distinguishes playable and archived-only controls")
            require(originalModel.library == beforeLibrary && originalDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == beforeBytes &&
                    !FileManager.default.fileExists(atPath: qaRoot.appendingPathComponent("original").path),
                    "Preparing an Android preview performs no archive or profile writes")
            require(originalModel.importAndroid(preview), "Confirmed Android import adds its supported native copy")
            require(originalModel.library.activeProfileID == beforeLibrary.activeProfileID && originalModel.library.profiles[0] == beforeLibrary.profiles[0],
                    "Android import preserves the selected profile and every existing control")
            let originals = originalModel.androidOriginals()
            require(originals.count == 1 && originalModel.exportAndroidOriginal(originals[0]) == androidBytes,
                    "Android original export retains exact whitespace, unknown integers and unsupported calibration")
            let imported = originalModel.library.profiles.last!
            require(imported.controls.count == 1 && imported.androidSources[0].controls[0].nativeID == imported.controls[0].id &&
                    imported.androidSources[0].controls[0].sourcePath == "/pages/0/controls/0",
                    "Imported native control and source-path binding refer to the same new UUID")
            let beforeEditedExport = originalDefaults.data(forKey: ProfileControllerViewModel.libraryKey)
            let editedReview = await originalModel.prepareEditedAndroidExport(imported.id)
            require(editedReview?.preview.canExport == true && editedReview?.preview.data == androidBytes,
                    "Untouched Android edited export is byte-exact and available through the app model")
            require(originalDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == beforeEditedExport &&
                    originalModel.exportAndroidOriginal(originals[0]) == androidBytes && originalModel.library.activeProfileID == beforeLibrary.activeProfileID,
                    "Edited export preparation preserves the library, selection and immutable original")
            let noSourceReview = await originalModel.prepareEditedAndroidExport(beforeLibrary.activeProfileID)
            require(noSourceReview == nil, "Native-only profile cannot masquerade as an edited Android source")
            originalModel.selectProfile(imported.id); originalModel.beginLayoutEditing()
            var changedAndroidButton = imported.controls[0]; changedAndroidButton.payload = "X360B"
            originalModel.saveControl(changedAndroidButton); originalModel.saveLayoutEditing()
            let changedReview = await originalModel.prepareEditedAndroidExport(imported.id)
            let changedText = String(data: changedReview?.preview.data ?? Data(), encoding: .utf8) ?? ""
            require(changedReview?.preview.canExport == true && changedText.contains("X360B") && changedText.contains("9007199254740993") && changedText.contains("preserve-me"),
                    "App export patches an edited action and retains unknown number and archived sensor record")
            require(originalModel.exportAndroidOriginal(originals[0]) == androidBytes, "Edited output never overwrites the source archive")
            originalModel.beginLayoutEditing(); originalModel.saveControl(imported.controls[0]); originalModel.saveLayoutEditing()
            originalModel.selectProfile(beforeLibrary.activeProfileID)
            let repeated = try AndroidImportPreview.prepare(androidBytes, displayName: "Same bytes again.json")
            require(originalModel.importAndroid(repeated), "The same Android file can be imported again after preview")
            require(originalModel.androidOriginals().count == 1 && originalModel.library.androidSources.count == 1,
                    "Repeated imports deduplicate source bytes rather than consuming another archive slot")
            let copies = Array(originalModel.library.profiles.suffix(2))
            require(copies[0].id != copies[1].id && copies[0].controls[0].id != copies[1].controls[0].id && copies[0].name != copies[1].name,
                    "Repeated Android imports create independent, uniquely named native copies")
            require(copies.allSatisfy { $0.androidSources[0].archiveID == originals[0].id && $0.androidSources[0].controls[0].nativeID == $0.controls[0].id },
                    "Repeated copies share immutable source bytes but keep independent source bindings")
            let portableBytes = originalModel.exportProfiles()!
            let portable = try AndroidPortableBackup.decode(portableBytes)
            require(portable.archives.count == 1 && portable.archives[0].originalData == androidBytes,
                    "Portable backup carries the exact Android original once for all imported copies")
            let fresh = androidModel(freshDefaults(), folder: "restored"), freshSelection = fresh.library.activeProfileID
            require(fresh.importProfiles(portableBytes), "A portable backup imports into a fresh archive store")
            require(fresh.library.activeProfileID == freshSelection && fresh.library.profiles.count == 4 && fresh.androidOriginals().count == 1,
                    "Portable restoration keeps the destination selection and restores one shared source archive")
            require(fresh.exportAndroidOriginal(fresh.androidOriginals()[0]) == androidBytes,
                    "Portable restoration can export the unchanged Android original")
            require(fresh.importProfiles(portableBytes) && fresh.androidOriginals().count == 1,
                    "Repeated portable restoration deduplicates originals across copied profiles")
            require(fresh.library.profiles.filter { !$0.androidSources.isEmpty }.allSatisfy { profile in
                profile.androidSources[0].controls.allSatisfy { binding in profile.controls.contains { $0.id == binding.nativeID } }
            }, "Portable clone source bindings follow remapped native control IDs")

            // Reset preserves recoverable source files; all-profiles export includes them explicitly.
            originalModel.restoreProfiles()
            require(originalModel.library.profiles.count == 1 && originalModel.library.androidSources.isEmpty && originalModel.androidOriginals().count == 1,
                    "Restore profiles resets the native library without deleting Android originals")
            let afterRestore = try AndroidPortableBackup.decode(originalModel.exportProfiles()!)
            require(afterRestore.archives.count == 1 && afterRestore.archives[0].originalData == androidBytes,
                    "A fresh-library backup also includes recoverable originals left by restore")
            let restoreCopy = androidModel(freshDefaults(), folder: "restore-copy")
            let afterRestoreBytes = try afterRestore.encodedData()
            require(restoreCopy.importProfiles(afterRestoreBytes) && restoreCopy.androidOriginals().count == 1,
                    "Recoverable unreferenced originals survive backup and restoration")

            // Corruption cannot silently produce a native-only backup that loses an original.
            let corruptDefaults = freshDefaults(), corruptModel = androidModel(corruptDefaults, folder: "corrupt")
            require(corruptModel.importAndroid(preview), "Corruption fixture imports successfully before damage")
            let corruptReference = corruptModel.androidOriginals()[0]
            let corruptBefore = corruptDefaults.data(forKey: ProfileControllerViewModel.libraryKey)!
            let corruptPath = qaRoot.appendingPathComponent("corrupt").appendingPathComponent(corruptReference.id.uuidString.lowercased()).appendingPathComponent("original.json")
            try Data("{}".utf8).write(to: corruptPath)
            require(corruptModel.exportProfiles() == nil && corruptModel.exportAndroidOriginal(corruptReference) == nil,
                    "A checksum failure blocks both portable and original export rather than dropping source data")
            require(corruptDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == corruptBefore &&
                    corruptModel.library.profiles.count == 2, "Archive corruption does not overwrite native saved profiles")
            let corruptedRestart = androidModel(corruptDefaults, folder: "corrupt")
            require(corruptedRestart.canEditLayout && corruptedRestart.library == corruptModel.library && corruptedRestart.state.isNeutral,
                    "Native profiles still load neutrally when their separate original needs recovery")

            // Profile-count and input-size failure leave all saved data and archive paths untouched.
            let fullDefaults = freshDefaults()
            let fullProfiles = try (0..<32).map { try ControllerProfile(name: "Capacity \($0)") }
            let fullLibrary = try ControllerProfileLibrary(activeProfileID: fullProfiles[0].id, profiles: fullProfiles)
            let fullBytes = try ControllerProfileLibraryCodec.encode(fullLibrary)
            fullDefaults.set(fullBytes, forKey: ProfileControllerViewModel.libraryKey)
            let fullModel = androidModel(fullDefaults, folder: "full")
            require(!fullModel.importAndroid(preview) && fullModel.library == fullLibrary &&
                    fullDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == fullBytes,
                    "Android profile-capacity failure leaves the existing 32-profile library unchanged")
            require(!FileManager.default.fileExists(atPath: qaRoot.appendingPathComponent("full").path),
                    "Profile capacity is checked before creating an Android source archive")
            var oversizedRejected = false
            do { _ = try AndroidImportPreview.prepare(Data(repeating: 32, count: AndroidProfileDocument.maximumBytes + 1), displayName: "Too large.json") }
            catch { oversizedRejected = true }
            require(oversizedRejected, "Android preview rejects a file over 25 MiB before any import")

            // The merged native 2 MiB budget is independent of the much larger original-file budget.
            let fatControls = (0..<64).map { index in ProfileControl(name: "Large \(index)", payload: String(repeating: " ", count: 7_990) + "X360A") }
            let fatPositions = fatControls.map { ProfilePlacement(id: $0.id, position: .init(x: 0.5, y: 0.5)) }
            let fatProfile = try ControllerProfile(name: "Large source", controls: fatControls, portrait: fatPositions, landscape: fatPositions)
            var bigLibrary = try ControllerProfileLibrary(activeProfileID: fatProfile.id, profiles: [fatProfile])
            while bigLibrary.profiles.count < 31 {
                var candidate = bigLibrary; candidate.profiles.append(try fatProfile.cloned())
                if (try? ControllerProfileLibraryCodec.encode(candidate)) == nil { break }
                bigLibrary = candidate
            }
            let bigBytes = try ControllerProfileLibraryCodec.encode(bigLibrary), bigDefaults = freshDefaults()
            bigDefaults.set(bigBytes, forKey: ProfileControllerViewModel.libraryKey)
            let bigModel = androidModel(bigDefaults, folder: "big-native")
            let incomingLarge = try ControllerProfileLibraryCodec.encode(.init(activeProfileID: fatProfile.id, profiles: [fatProfile]))
            let bigEpoch = bigModel.inputEpoch
            require(!bigModel.importProfiles(incomingLarge) && bigModel.library == bigLibrary &&
                    bigDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == bigBytes && bigModel.inputEpoch == bigEpoch,
                    "Merged native-size overflow rejects before resetting inputs or overwriting the saved library")

            // Read authentic formats7–19 without rewriting their bytes, preserving exact upgrade recovery.
            let sourceForMigration = fresh.library
            for oldVersion in 7...19 {
                var fields = try JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(sourceForMigration)) as! [String: Any]
                fields["version"] = oldVersion
                if oldVersion < 8 { fields.removeValue(forKey: "androidSources") }
                var savedProfiles = fields["profiles"] as! [[String: Any]]
                for i in savedProfiles.indices {
                    if oldVersion < 8 { savedProfiles[i].removeValue(forKey: "androidSources") }
                    var controls = savedProfiles[i]["controls"] as! [[String: Any]]
                    for j in controls.indices {
                        if oldVersion < 11 { controls[j].removeValue(forKey: "touchAim") }
                        if oldVersion < 9 { for key in ["buttonDirectional", "buttonAim", "controlWidth", "controlHeight"] { controls[j].removeValue(forKey: key) } }
                    }
                    if oldVersion == 8 || oldVersion == 9, var sources = savedProfiles[i]["androidSources"] as? [[String: Any]] {
                        for k in sources.indices {
                            sources[k].removeValue(forKey: "exportBaseline")
                            for field in ["controls", "pages"] {
                                if var bindings = sources[k][field] as? [[String: Any]] {
                                    for b in bindings.indices { bindings[b].removeValue(forKey: "exportID") }
                                    sources[k][field] = bindings
                                }
                            }
                        }
                        savedProfiles[i]["androidSources"] = sources
                    }
                    savedProfiles[i]["controls"] = controls
                }
                fields["profiles"] = savedProfiles
                let oldBytes = try JSONSerialization.data(withJSONObject: legacyJSON(fields), options: [.sortedKeys]), oldDefaults = freshDefaults()
                oldDefaults.set(oldBytes, forKey: ProfileControllerViewModel.libraryKey)
                let oldModel = androidModel(oldDefaults, folder: "restored")
                require(oldModel.canEditLayout && oldModel.state.isNeutral && oldDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == oldBytes,
                        "Format\(oldVersion) loads without rewriting bytes or restoring live input")
                require(oldVersion == 7 ? oldModel.library.androidSources.isEmpty : oldModel.library.androidSources == sourceForMigration.androidSources,
                        "Format\(oldVersion) handles Android metadata with its authentic schema")
                oldModel.beginLayoutEditing(); oldModel.saveLayoutEditing()
                require(oldDefaults.data(forKey: "controller.profiles.before-format-\(oldVersion)") == oldBytes,
                        "First upgraded format\(oldVersion) save preserves exact recovery bytes")
            }
        }

        // TouchAim remains direct-only and exposes sensor state through the actual app model.
        var sensor = ProfileControl(name: "Sensor", kind: .touchAim)
        sensor.touchAim.aim.output = .rightStick
        sensor.touchAim.threeStage.smoothing = 1
        sensor.touchAim.threeStage.low = .init(threshold: 2, payload: "X360A", action: .hold)
        sensor.touchAim.threeStage.medium = .init(threshold: 4, payload: "W", action: .hold)
        sensor.touchAim.threeStage.high = .init(threshold: 6, payload: "RT:0.8", action: .hold)
        let independentSensorButton = ProfileControl(name: "Independent", kind: .button, actions: [.b])
        var sensorProfile = try ControllerProfile(name: "TouchAim checks", swipeMode: .controls)
        for c in [sensor, independentSensorButton] { try sensorProfile.addControl(c, toPage: sensorProfile.homePageID) }
        let sensorDefaults = freshDefaults(), sensorClock = ProfileCheckClock()
        sensorDefaults.set(try ControllerProfileLibraryCodec.encode(.init(activeProfileID: sensorProfile.id, profiles: [sensorProfile])), forKey: ProfileControllerViewModel.libraryKey)
        let sensorModel = makeModel(sensorDefaults, clock: sensorClock)
        func sensorSample(_ radius: Double?, _ elapsed: Double = 0, _ x: Double = 110) -> TouchAimSample {
            .init(pointer: .init(x: x, y: 80, width: 220, height: 160), metrics: .init(majorRadius: radius), elapsed: elapsed)
        }
        require(sensor.resolvedWidth == 220 && sensor.resolvedHeight == 160 && sensorModel.hasDesktopOutputs,
                "New TouchAim defaults to a rectangular surface and advertises its configured desktop action")
        let acceptedMissing = sensorModel.handleInput(.beginTouchAim(contact: 1900, control: sensor.id, sample: sensorSample(nil)), epoch: sensorModel.inputEpoch)
        input(sensorModel, .cancel(contact: 1900))
        require(!acceptedMissing && sensorModel.state.isNeutral && sensorModel.touchAimStates[sensor.id] == .unavailable && sensorModel.touchAimIssues[sensor.id] != nil,
                "Unavailable sensor start rejects capture while preserving a visible diagnosis after UI cancellation")
        input(sensorModel, .begin(contact: 1901, control: independentSensorButton.id, position: .zero))
        let acceptedSensor = sensorModel.handleInput(.beginTouchAim(contact: 1902, control: sensor.id, sample: sensorSample(3)), epoch: sensorModel.inputEpoch)
        require(acceptedSensor && sensorModel.state.buttons == [.a, .b] && sensorModel.activeTouchAims.contains(sensor.id) && sensorModel.touchAimIssues[sensor.id] == nil,
                "A valid fresh touch owns its low-stage action while keeping the independent button")
        sensorClock.time += 0.1
        input(sensorModel, .moveTouchAimBatch(contact: 1902, samples: [sensorSample(7, 0.1, 180)]))
        require(sensorModel.touchAimStates[sensor.id] == .high && sensorModel.touchAimScores[sensor.id] == 7 &&
                sensorModel.practiceState.heldKeys.contains(.w) && pressureIs(sensorModel.practiceState.rightTrigger, 0.8) && sensorModel.state.rightStick.x > 0,
                "Sensor movement reaches the app's stage, score, pressure, key and analog output")
        input(sensorModel, .end(contact: 1902))
        require(sensorModel.state.buttons == [.b] && sensorModel.state.rightStick == .zero && sensorModel.practiceState.rightTrigger == 0 &&
                sensorModel.practiceState.heldKeys.isEmpty && sensorModel.activeTouchAims.isEmpty,
                "Normal TouchAim lift clears its own outputs and preserves an independent button")
        input(sensorModel, .accessibilityActivate(sensor.id))
        require(sensorModel.state.buttons == [.b] && sensorModel.activeTouchAims.isEmpty, "Accessibility activation cannot synthesize a sensor measurement")
        input(sensorModel, .beginTouchAim(contact: 1903, control: sensor.id, sample: sensorSample(7)))
        let oldSensorEpoch = sensorModel.inputEpoch
        sensorModel.setForeground(false); sensorModel.setForeground(true)
        require(sensorModel.state.isNeutral && sensorModel.touchAimStates.isEmpty && sensorModel.touchAimScores.isEmpty && sensorModel.touchAimIssues.isEmpty,
                "App interruption releases TouchAim and clears all ephemeral sensor telemetry")
        require(!sensorModel.handleInput(.moveTouchAimBatch(contact: 1903, samples: [sensorSample(7, 0.2, 190)]), epoch: oldSensorEpoch),
                "A stale sensor callback cannot revive input after app interruption")
        sensorModel.beginLayoutEditing()
        let addedSensorID = sensorModel.addControl(kind: .touchAim)!
        require(sensorModel.profile.control(for: addedSensorID)?.resolvedWidth == 220, "Editor adds a separate TouchAim with the intended default size")
        require(sensorModel.profile.control(for: addedSensorID)?.touchAim.requiresLocalSetup == true,
                "A fresh iPhone TouchAim requires local threshold setup before its sensor actions can run")
        sensorModel.cancelLayoutEditing()
        require(sensorModel.profile.control(for: addedSensorID) == nil, "Cancel discards an added TouchAim with the whole profile draft")
        sensorModel.beginLayoutEditing()
        var mouseSensor = sensor; mouseSensor.touchAim.aim.output = .mouse
        sensorModel.saveControl(mouseSensor); sensorModel.saveLayoutEditing()
        require(sensorModel.hasPointerOutputs, "Mouse TouchAim reserves the visible Practice pointer header")
        let sensorReload = makeModel(sensorDefaults)
        require(sensorReload.profile.control(for: sensor.id) == mouseSensor && sensorReload.touchAimStates.isEmpty && sensorReload.state.isNeutral,
                "TouchAim configuration survives reload without live readings or actions")

        // Library-level presets survive canceled controller drafts and import independently.
        do {
        var localPresets = SettingsPresetLibrary.empty
        let localPreset = try SettingsPreset.capture(mouseSensor, category: .touchAimManual, name: "My touch settings", at: 100)
        try localPresets.save(localPreset)
        sensorModel.beginLayoutEditing()
        var unsavedSensor = mouseSensor; unsavedSensor.name = "Unsaved edit"
        sensorModel.saveControl(unsavedSensor)
        let savedBeforePreset = sensorModel.library.activeProfile, draftBeforePreset = sensorModel.profile
        require(sensorModel.saveSettingsPresets(localPresets) && sensorModel.profile == draftBeforePreset &&
                sensorModel.library.activeProfile == savedBeforePreset,
                "Saving reusable settings keeps both the saved controller and its current draft intact")
        sensorModel.cancelLayoutEditing()
        require(sensorModel.profile == savedBeforePreset && sensorModel.library.settingsPresets == localPresets,
                "Canceling layout edits does not undo an explicit reusable-settings save")
        require(makeModel(sensorDefaults).library.settingsPresets == localPresets,
                "Reusable settings survive an actual model reload")
        var calibratedSensor = ProfileControl(kind: .touchAim)
        calibratedSensor.touchAim.mode = .calibratedTwoState
        calibratedSensor.touchAim.calibration = .init(transforms: [.init(metric: .majorRadius, center: 2, scale: 1)], quality: .good, validationCompleted: true)
        var calibratedProfile = try ControllerProfile(name: "Saved calibration")
        try calibratedProfile.addControl(calibratedSensor, toPage: calibratedProfile.homePageID)
        var calibratedLibrary = try ControllerProfileLibrary(activeProfileID: calibratedProfile.id, profiles: [calibratedProfile])
        calibratedLibrary.settingsPresets = localPresets
        let selectedBeforeImport = sensorModel.profile.id
        let calibratedBackup = try ControllerProfileLibraryCodec.encode(calibratedLibrary)
        require(sensorModel.importProfiles(calibratedBackup),
                "Native backup with controls and reusable settings imports through the actual app model")
        let importedCalibration = sensorModel.library.profiles.last!.controls[0].touchAim
        require(importedCalibration.requiresLocalSetup && importedCalibration.calibration?.validationCompleted == false &&
                importedCalibration.mode == .manualTwoState && sensorModel.profile.id == selectedBeforeImport,
                "Imported sensor calibration preserves evidence but gates output until local setup without changing selection")
        require(sensorModel.library.settingsPresets.entries.count == 2 &&
                sensorModel.library.settingsPresets.entries.contains(localPreset) &&
                Set(sensorModel.library.settingsPresets.entries.map(\.id)).count == 2,
                "Preset import keeps the local entry and gives its imported copy an independent identity")

        // Profile options are one draft; global holds, fixed macros and local Release all reach the app engine.
        let macro = ProfileControl(name: "Walk", payload: "LS:UP50,X360A")
        let localRelease = ProfileControl(name: "Release", payload: "RELEASE_ALL")
        let ordinaryStick = ProfileControl(kind: .rightStick)
        let (optionsModel, optionsClock, _, optionsDefaults) = try programScenario([macro, localRelease, ordinaryStick])
        optionsModel.beginLayoutEditing()
        var options = optionsModel.profile; options.globalHoldEnabled = true
        _ = try options.setAllAutoCenter(false)
        optionsModel.saveProfileOptions(options)
        require(optionsModel.profile.globalHoldEnabled && optionsModel.profile.control(for: ordinaryStick.id)?.stickBehavior.autoCenter == false,
                "Profile options apply global Hold and Snap policy to the live draft")
        optionsModel.cancelLayoutEditing()
        require(!optionsModel.profile.globalHoldEnabled && optionsModel.profile.control(for: ordinaryStick.id)?.stickBehavior.autoCenter == true,
                "Parent Cancel restores Hold and Snap together")
        optionsModel.beginLayoutEditing(); optionsModel.saveProfileOptions(options); optionsModel.saveLayoutEditing()
        require(makeModel(optionsDefaults).profile.globalHoldEnabled, "Global Hold persists with the saved profile")
        input(optionsModel, .begin(contact: 2000, control: macro.id, position: .zero)); input(optionsModel, .end(contact: 2000))
        require(optionsModel.state.buttons == [.a] && optionsModel.state.leftStick == .init(y: 0.5) && optionsModel.latchedControls.contains(macro.id),
                "An ordinary fixed-stick button latches its analog and digital actions under global Hold")
        let beforeLocalReleaseEpoch = optionsModel.inputEpoch
        input(optionsModel, .begin(contact: 2001, control: localRelease.id, position: .zero))
        optionsClock.time += 1; optionsModel.tickInput()
        require(optionsModel.state.isNeutral && optionsModel.inputEpoch > beforeLocalReleaseEpoch && optionsModel.latchedControls.isEmpty,
                "A local Release all button clears holds and invalidates old app callbacks")
        require(!optionsModel.handleInput(.begin(contact: 2002, control: macro.id, position: .zero), epoch: beforeLocalReleaseEpoch),
                "A stale callback cannot restart a fixed macro after Release all")

        // Floating edits use measured geometry and whole-draft cancellation; live rings publish into the same model.
        let floatingA = ProfileControl(name: "Floating A", actions: [.a]), floatingB = ProfileControl(name: "Independent B", actions: [.b])
        let (floatingModel, floatingClock, _, floatingDefaults) = try programScenario([floatingA, floatingB])
        let measurement = FloatingCanvasSnapshot(width: 700, height: 900, frames: [floatingA.id: .init(x: 60, y: 100, width: 60, height: 60), floatingB.id: .init(x: 200, y: 100, width: 60, height: 60)])
        floatingModel.recordCanvasSnapshot(measurement, profile: floatingModel.profile, pageID: floatingModel.currentPageID, orientation: .portrait)
        require(floatingModel.floatingCanvasSnapshots[.portrait] == measurement, "The editor accepts the current page's actual measured canvas")
        floatingModel.beginLayoutEditing(); let plainFloatingProfile = floatingModel.profile
        var floatingDraft = plainFloatingProfile
        _ = try floatingDraft.convertToFloatingButtons(on: floatingDraft.homePageID, memberIDs: [floatingA.id], kind: .singleButton, name: "Floating A", snapshots: [.portrait: measurement])
        floatingModel.saveFloatingDraft(floatingDraft)
        require(floatingModel.profile.pages[0].floatingButtonZones.count == 1 && floatingModel.floatingCanvasSnapshots.isEmpty,
                "Floating changes stay in the layout draft and invalidate measurements from the old profile")
        floatingModel.cancelLayoutEditing()
        require(floatingModel.profile == plainFloatingProfile, "Cancel restores the original controls and removes the draft floating zone")
        floatingModel.beginLayoutEditing()
        var ringProfile = floatingModel.profile, ringConfig = FloatingRingConfig()
        ringConfig.boost1.enabled = true; ringConfig.boost1.payload = "X360A,W"
        let ring = FloatingRingZone(portraitGeometry: .init(canvasWidth: 700, canvasHeight: 900, zone: .init(x: 0, y: 0, width: 700, height: 900)), config: ringConfig)
        ringProfile.pages[0].floatingRingZones = [ring]
        floatingModel.saveFloatingDraft(ringProfile); floatingModel.saveLayoutEditing()
        require(floatingModel.hasDesktopOutputs && floatingModel.hasPointerOutputs,
                "Floating-ring outputs participate in visible Practice capability summaries")
        let ringSession = UUID(), ringEpoch = floatingModel.inputEpoch
        input(floatingModel, .begin(contact: 2101, control: floatingB.id, position: .zero))
        let ringAccepted = floatingModel.handleInput(.beginFloatingRing(contact: 2100, zoneID: ring.id, sessionID: ringSession,
            point: .init(x: 300, y: 300), usable: measurement.usable), epoch: ringEpoch)
        require(ringAccepted && floatingModel.floatingRingStates[ring.id]?.visible == true,
                "The app model accepts a ring capture and publishes its summoned geometry")
        let ringState = floatingModel.floatingRingStates[ring.id]!
        floatingClock.time += 0.1
        input(floatingModel, .moveFloatingRing(contact: 2100, sessionID: ringSession, samples: [.init(point: .init(
            x: ringState.placement.origin.x + ringState.geometry.center.x + 130,
            y: ringState.placement.origin.y + ringState.geometry.center.y), elapsed: 0.1)]))
        require(floatingModel.state.leftStick.x == 1 && floatingModel.state.buttons == [.a, .b] && floatingModel.practiceState.heldKeys.contains(.w),
                "Ring movement and boost share normal gamepad and desktop output while preserving independent input")
        input(floatingModel, .floatingRingAction(zoneID: ring.id, sessionID: ringSession, action: .finish))
        require(floatingModel.state.buttons == [.b] && floatingModel.state.leftStick == .zero && floatingModel.practiceState.heldKeys.isEmpty,
                "Floating Finish clears only that ring and leaves an independent held button")
        floatingModel.releaseAll()
        require(floatingModel.floatingRingStates.isEmpty && !floatingModel.handleInput(.moveFloatingRing(contact: 2100, sessionID: ringSession, samples: []), epoch: ringEpoch),
                "Release all clears ring telemetry and fences old UIKit sessions")
        let ringReload = makeModel(floatingDefaults)
        require(ringReload.profile.pages[0].floatingRingZones == [ring] && ringReload.floatingRingStates.isEmpty && ringReload.state.isNeutral,
                "Ring settings persist across reload while summoned state and held actions do not")

        // Display changes are app-local, release live input and never serialize temporary editor orientation.
        let libraryBeforeDisplay = floatingDefaults.data(forKey: ProfileControllerViewModel.libraryKey)
        input(floatingModel, .begin(contact: 2110, control: floatingB.id, position: .zero))
        let displayEpoch = floatingModel.inputEpoch
        let display = ControllerPresentationPreferences(theme: .light, playOrientation: .landscape)
        require(floatingModel.savePresentation(display, editorOrientation: .portrait) && floatingModel.state.isNeutral && floatingModel.inputEpoch > displayEpoch,
                "Display changes release active controls before requesting rotation")
        require(floatingModel.requestedOrientation == .landscape && floatingModel.editorOrientation == .automatic &&
                floatingDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == libraryBeforeDisplay,
                "Play orientation is app-local and does not rewrite the controller library")
        floatingModel.beginLayoutEditing()
        require(floatingModel.requestedOrientation == .automatic, "A new edit session starts with automatic orientation")
        _ = floatingModel.savePresentation(display, editorOrientation: .portrait)
        require(floatingModel.requestedOrientation == .portrait, "Editor orientation temporarily overrides the saved Play choice")
        floatingModel.cancelLayoutEditing()
        let displayReload = makeModel(floatingDefaults)
        require(floatingModel.requestedOrientation == .landscape && displayReload.presentation == display && displayReload.editorOrientation == .automatic,
                "Leaving Edit restores Play orientation and reload keeps only saved display preferences")
        let displayJSON = try JSONSerialization.jsonObject(with: floatingDefaults.data(forKey: ProfileControllerViewModel.presentationKey)!) as! [String: Any]
        require(Set(displayJSON.keys) == ["version", "theme", "playOrientation"], "Temporary editor orientation never enters saved display data")
        let badDisplayDefaults = freshDefaults(), badDisplayBytes = Data(#"{"version":99,"theme":"future","playOrientation":"future"}"#.utf8)
        badDisplayDefaults.set(badDisplayBytes, forKey: ProfileControllerViewModel.presentationKey)
        let badDisplayModel = makeModel(badDisplayDefaults)
        require(badDisplayModel.presentationIssue != nil && badDisplayDefaults.data(forKey: ProfileControllerViewModel.presentationKey) == badDisplayBytes && badDisplayModel.canEditLayout,
                "Unreadable display settings are preserved without blocking unrelated controller editing")
        _ = badDisplayModel.savePresentation(.default, editorOrientation: .automatic)
        require(badDisplayDefaults.dictionaryRepresentation().contains { $0.key.hasPrefix("controller.presentation.recovery.") && ($0.value as? Data) == badDisplayBytes },
                "Explicitly saving display settings retains exact unreadable recovery bytes")

        // Batch deletion validates the current library and saves a single recoverable change.
        let bulkDefaults = freshDefaults(), bulkModel = makeModel(bulkDefaults)
        let firstBulkID = bulkModel.profile.id
        _ = bulkModel.createProfile(name: "Unused", standardControls: false)
        let secondBulkID = bulkModel.profile.id
        _ = bulkModel.createProfile(name: "Keep selected", standardControls: false)
        let keptBulkID = bulkModel.profile.id
        _ = bulkModel.saveSettingsPresets(localPresets)
        let beforeBulk = bulkDefaults.data(forKey: ProfileControllerViewModel.libraryKey)
        require(!bulkModel.deleteProfiles([keptBulkID]) && !bulkModel.deleteProfiles([UUID()]) &&
                bulkDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == beforeBulk,
                "Batch deletion rejects active or stale profile IDs without writing")
        require(bulkModel.deleteProfiles([firstBulkID, secondBulkID]) && bulkModel.library.profiles.map(\.id) == [keptBulkID] &&
                bulkModel.library.settingsPresets == localPresets,
                "Batch deletion preserves the selected profile and all reusable settings")
        require(bulkDefaults.dictionaryRepresentation().contains { $0.key.hasPrefix("controller.profiles.before-batch-delete.") && ($0.value as? Data) == beforeBulk },
                "Batch deletion retains the exact complete pre-deletion library as recovery")
        require(makeModel(bulkDefaults).library == bulkModel.library, "Batch-deleted library reloads with the same selected profile")
        }

        // SCX2 profile transitions must retire queued input from the old page.
        let scx2Defaults = freshDefaults()
        scx2Defaults.set(try ControllerProfileLibraryCodec.encode(.init(activeProfileID: paged.id, profiles: [paged])), forKey: ProfileControllerViewModel.libraryKey)
        let scx2Link = ProfileSCX2Transport(), scx2Clock = ProfileCheckClock()
        let scx2Model = ProfileControllerViewModel(defaults: scx2Defaults, transport: scx2Link,
            clock: { scx2Clock.time }, automaticTimer: false)
        require(scx2Model.bridgeProtocol == .scx2 && scx2Model.portText == "42736", "Profile model exposes the new bridge default")
        func connectSCX2Profile() {
            scx2Model.host = "192.168.1.80"; scx2Model.setMode(.bridge); scx2Model.connect()
            let hello = scx2Link.sent.last!
            scx2Link.reply(.init(kind: .ready, session: hello.session,
                boot: .init(bytes: Array(repeating: 5, count: 16)), challenge: .init(bytes: Array(repeating: 9, count: 16)), hidReady: true))
        }
        connectSCX2Profile()
        require(!scx2Model.controlsEnabled && !scx2Model.isReady,
                "Profile controls stay paused until USB-completed neutral acknowledgement")
        let startupNeutral = scx2Link.sent.last!
        require(startupNeutral.sequence == 1 && startupNeutral.state?.isNeutral == true, "Profile connection begins with neutral sequence1")
        scx2Link.acknowledge(startupNeutral)
        require(scx2Model.controlsEnabled && scx2Model.isReady, "Matching neutral completion enables the profile")
        scx2Model.selectPage(drivingPage)
        require(scx2Model.currentPageID == drivingPage && !scx2Model.isReady && !scx2Model.controlsEnabled &&
                scx2Link.closed.last?.kind == .stop, "SCX2 page picker stops its previous queued session")
        connectSCX2Profile(); scx2Link.acknowledge(scx2Link.sent.last!)
        input(scx2Model, .begin(contact: 1800, control: drivingB.id, position: .zero))
        let outstandingDown = scx2Link.sent.last!
        require(outstandingDown.state?.buttons == [.b], "Second page emits its supported action after reconnect")
        input(scx2Model, .end(contact: 1800)) // Release is queued behind the unacknowledged press.
        let beforePageStopEpoch = scx2Model.inputEpoch
        input(scx2Model, .begin(contact: 1801, control: returnPage.id, position: .zero))
        let afterPageStopCount = scx2Link.sent.count
        require(scx2Model.currentPageID == homePage && !scx2Model.isReady && scx2Model.state.isNeutral &&
                scx2Model.inputEpoch > beforePageStopEpoch && scx2Link.closed.last?.kind == .stop,
                "Page button retires the SCX2 queue and clears app owners before showing Home")
        scx2Link.acknowledge(outstandingDown)
        require(scx2Link.sent.count == afterPageStopCount && scx2Model.state.isNeutral,
                "Late old-page acknowledgement cannot flush queued input into the new page")
        connectSCX2Profile(); scx2Link.acknowledge(scx2Link.sent.last!)
        scx2Model.releaseAll()
        require(!scx2Model.controlsEnabled && !scx2Model.isReady && scx2Model.state.isNeutral,
                "SCX2 Release all pauses controls during automatic neutral resynchronization")
        scx2Model.beginLayoutEditing()
        let localStopID = scx2Model.addControl(kind: .button)!
        var localStopControl = scx2Model.profile.control(for: localStopID)!
        localStopControl.payload = "RELEASE_ALL"; scx2Model.saveControl(localStopControl)
        let queuedActionID = scx2Model.addControl(kind: .button)!
        scx2Model.saveLayoutEditing()
        connectSCX2Profile(); scx2Link.acknowledge(scx2Link.sent.last!)
        input(scx2Model, .begin(contact: 2200, control: queuedActionID, position: .zero))
        let queuedAction = scx2Link.sent.last!
        input(scx2Model, .end(contact: 2200))
        let localStopEpoch = scx2Model.inputEpoch
        input(scx2Model, .accessibilityActivate(localStopID))
        let afterLocalStopCount = scx2Link.sent.count
        require(!scx2Model.isReady && scx2Model.state.isNeutral && scx2Model.inputEpoch > localStopEpoch && scx2Link.closed.last?.kind == .stop,
                "A movable Release all button retires the SCX2 queue through the app connection path")
        scx2Link.acknowledge(queuedAction)
        require(scx2Link.sent.count == afterLocalStopCount && scx2Model.state.isNeutral,
                "An acknowledgement arriving after local Release all cannot flush its queued release or revive output")
        scx2Model.setBridgeProtocol(.scx1)
        require(scx2Model.bridgeProtocol == .scx1 && scx2Model.portText == "42735", "Profile settings proxy switches the matching default port")

        try runStickPlusRepeatClientChecks(require: { require($0, $1) }, freshDefaults: freshDefaults)
        try runAndroidPresetClientChecks(require: { require($0, $1) }, freshDefaults: freshDefaults)
        try runCameraClientChecks(require: { require($0, $1) }, freshDefaults: freshDefaults)
        try runFloatingActionClientChecks(require: { require($0, $1) }, freshDefaults: freshDefaults)
        try runRecoveryClientChecks(require: { require($0, $1) }, freshDefaults: freshDefaults)
        try runStarterClientChecks(require: { require($0, $1) }, freshDefaults: freshDefaults)
        try runMacroClientChecks(require: { require($0, $1) }, freshDefaults: freshDefaults)
        try runOrientationClientChecks(require: { require($0, $1) }, freshDefaults: freshDefaults)
        try await runFloatingRestorationClientChecks(require: { require($0, $1) }, freshDefaults: freshDefaults)

        if failures.isEmpty {
            print("PASS: \(checks) profile app client checks on macOS with fake transport and clock.")
        } else {
            print("FAIL: \(failures.count) of \(checks) profile app client checks failed.")
            exit(1)
        }
        print("These checks do not validate UIKit, physical touch, real networking, USB or Xbox hardware.")
    }
}

// Exercise persisted per-instance Stick+ repeat through the actual app adapter.
// Timings below use a deterministic fake clock; no game-specific sprint behavior is assumed.
@MainActor
private func runStickPlusRepeatClientChecks(require: (Bool, String) -> Void,
                                           freshDefaults: () -> UserDefaults) throws {
    var stick = ProfileControl(name: "Repeating movement", kind: .leftStick,
                               stickPlusRepeatIntervalMilliseconds: 200)
    stick.stickBehavior.autoCenter = false
    stick.stickBehavior.stickPlusEnabled = true
    stick.stickBehavior.boostThreshold = 0.5
    stick.stickBehavior.superBoostThreshold = 0.95
    stick.stickBehavior.directions[.up] = .init(boostControls: [.leftStickClick], superBoostControls: [.a])
    let independentA = ProfileControl(name: "Separate A", actions: [.a])
    let independentB = ProfileControl(name: "Separate B", actions: [.b])
    var profile = try ControllerProfile(name: "Repeat test")
    for control in [stick, independentA, independentB] { try profile.addControl(control, toPage: profile.homePageID) }
    let otherPage = try profile.addPage(name: "Other page")
    let other = try ControllerProfile(name: "Untouched profile")
    let library = try ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile, other])
    let bytes = try ControllerProfileLibraryCodec.encode(library)
    func defaultsForRepeat() -> UserDefaults {
        let defaults = freshDefaults(); defaults.set(bytes, forKey: ProfileControllerViewModel.libraryKey)
        return defaults
    }
    func model(_ defaults: UserDefaults, _ clock: ProfileCheckClock,
               transport: ProfileCheckTransport? = nil) -> ProfileControllerViewModel {
        ProfileControllerViewModel(defaults: defaults, transport: transport ?? ProfileCheckTransport(),
                                   clock: { clock.time }, automaticTimer: false)
    }
    func send(_ model: ProfileControllerViewModel, _ event: ProfileInputEvent) {
        model.handleInput(event, epoch: model.inputEpoch)
    }
    func fullForward(_ model: ProfileControllerViewModel, contact: Int = 8000) {
        send(model, .beginStick(contact: contact, control: stick.id, travel: .init(y: 1)))
    }

    // An authentic format19 document must load without either enabling repeat or rewriting the user's library.
    var legacyObject = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    legacyObject["version"] = 19
    var legacyProfiles = legacyObject["profiles"] as! [[String: Any]]
    for i in legacyProfiles.indices {
        var controls = legacyProfiles[i]["controls"] as! [[String: Any]]
        for j in controls.indices {
            controls[j].removeValue(forKey: "stickPlusRepeatIntervalMilliseconds")
            controls[j].removeValue(forKey: "macroModeEnabled")
        }
        legacyProfiles[i]["controls"] = controls
    }
    legacyObject["profiles"] = legacyProfiles
    let legacyBytes = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
    let legacyDefaults = freshDefaults(), legacyClock = ProfileCheckClock()
    let earlierRecovery = Data("exact older recovery bytes".utf8)
    legacyDefaults.set(legacyBytes, forKey: ProfileControllerViewModel.libraryKey)
    legacyDefaults.set(earlierRecovery, forKey: "controller.profiles.before-format-5")
    let migrated = model(legacyDefaults, legacyClock)
    var legacyProfile = profile
    legacyProfile.controls[legacyProfile.controls.firstIndex { $0.id == stick.id }!].stickPlusRepeatIntervalMilliseconds = nil
    require(migrated.canEditLayout && migrated.library.profiles == [legacyProfile, other] && migrated.profile.id == profile.id,
            "Format19 load preserves both profiles, IDs, geometry and actions with repeat disabled")
    require(migrated.state.isNeutral && migrated.retainedSticks.isEmpty &&
            legacyDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == legacyBytes,
            "Format19 loading is neutral and leaves original saved bytes untouched")
    let exportedMigration = try ControllerProfileLibraryCodec.decode(migrated.exportProfiles()!)
    require(exportedMigration.version == ControllerProfileLibrary.currentVersion && exportedMigration.profiles == [legacyProfile, other] &&
            legacyDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == legacyBytes &&
            legacyDefaults.data(forKey: "controller.profiles.before-format-19") == nil,
            "Export upgrades only its returned document; it neither enables repeat nor rewrites format19 storage")
    migrated.beginLayoutEditing()
    var changed = migrated.profile.control(for: stick.id)!
    changed.stickPlusRepeatIntervalMilliseconds = 200
    migrated.saveControl(changed)
    require(migrated.profile.control(for: stick.id)?.stickPlusRepeatIntervalMilliseconds == 200 &&
            legacyDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == legacyBytes,
            "Control Done changes repeat only in the whole-profile draft")
    migrated.cancelLayoutEditing()
    require(migrated.profile == legacyProfile && legacyDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == legacyBytes,
            "Layout Cancel discards repeat without changing the saved original or other profile")
    migrated.beginLayoutEditing(); migrated.saveControl(changed); migrated.saveLayoutEditing()
    let migratedReload = model(legacyDefaults, legacyClock)
    require(migratedReload.profile == profile && migratedReload.library.profiles == [profile, other] && migratedReload.state.isNeutral,
            "Layout Save persists only the selected repeat change and reloads both profiles neutrally")
    require(legacyDefaults.data(forKey: "controller.profiles.before-format-19") == legacyBytes &&
            legacyDefaults.data(forKey: "controller.profiles.before-format-5") == earlierRecovery,
            "First format20 save preserves exact format19 bytes and older recovery documents")

    // Live and retained Stick+ stages drive a repeating digital action without pulsing the analog channel.
    let liveDefaults = defaultsForRepeat(), liveClock = ProfileCheckClock(), live = model(liveDefaults, liveClock)
    fullForward(live)
    require(live.state.buttons == [.a] && live.state.leftStick.y == 1,
            "Configured Stick+ repeat starts A immediately while holding full analog movement")
    send(live, .end(contact: 8000))
    liveClock.time += 0.05; live.tickInput()
    require(live.state.buttons.isEmpty && live.state.leftStick.y == 1 && live.retainedSticks == [stick.id],
            "A retained stick reaches its first repeat OFF edge without losing analog movement")
    liveClock.time += 0.15; live.tickInput()
    require(live.state.buttons == [.a] && live.retainedSticks == [stick.id],
            "A normal lift keeps the configured 200 ms repeat cycle active")
    require(liveDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == bytes && model(liveDefaults, liveClock).state.isNeutral,
            "Runtime repeat phases and retained input never enter saved profile data or restart held")
    send(live, .beginStick(contact: 8001, control: stick.id, travel: .init(y: 0.2)))
    require(live.state.buttons.isEmpty && abs(live.state.leftStick.y - 0.2) < 0.0001,
            "Pulling back to an empty stage stops A immediately while retaining the requested movement")
    liveClock.time += 1; live.tickInput()
    require(live.state.buttons.isEmpty, "A stale repeat deadline cannot revive a departed stage")
    send(live, .moveStick(contact: 8001, travel: .init(y: 1)))
    require(live.state.buttons == [.a], "Explicitly returning to the repeat stage starts a fresh immediate press")
    send(live, .begin(contact: 8002, control: independentA.id, position: .zero))
    liveClock.time += 0.05; live.tickInput()
    require(live.state.buttons == [.a], "Repeat OFF does not release A owned by an independent ordinary button")
    send(live, .end(contact: 8002))
    require(live.state.buttons.isEmpty && live.state.leftStick.y == 1,
            "Releasing the independent A during repeat OFF reveals the real gap without losing movement")
    send(live, .begin(contact: 8003, control: independentB.id, position: .zero))
    live.recenterSticks()
    require(live.state.leftStick == .zero && live.state.buttons == [.b] && live.retainedSticks.isEmpty,
            "Re-center stops the repeat and its analog movement while preserving separate B")
    liveClock.time += 2; live.tickInput()
    require(live.state.buttons == [.b], "Later timer work cannot restore repeat after Re-center")
    send(live, .end(contact: 8003))

    // Repetition applies only to digital controller actions, not simultaneous pressure or desktop holds.
    var mixedProfile = profile, mixedStick = stick
    mixedStick.directionPayloads[.up] = .init(superBoostPayload: "X360A,RT:0.4,W")
    mixedProfile.controls[mixedProfile.controls.firstIndex { $0.id == stick.id }!] = mixedStick
    let mixedDefaults = freshDefaults(), mixedClock = ProfileCheckClock()
    mixedDefaults.set(try ControllerProfileLibraryCodec.encode(.init(activeProfileID: mixedProfile.id, profiles: [mixedProfile])),
                      forKey: ProfileControllerViewModel.libraryKey)
    let mixed = model(mixedDefaults, mixedClock)
    fullForward(mixed); mixedClock.time += 0.05; mixed.tickInput()
    require(!mixed.state.buttons.contains(.a) && mixed.state.leftStick.y == 1 &&
            mixed.practiceState.rightTrigger == 0.4 && mixed.practiceState.heldKeys == [.w],
            "Stick+ repeat OFF leaves configured trigger pressure, held keyboard output and analog movement sustained")
    mixed.releaseAll()
    require(mixed.practiceState == .neutral && mixed.state.isNeutral,
            "Release all clears repeat together with the same stage's pressure and desktop outputs")

    // Every lifecycle reset must retire both the retained stage and any callback carrying its old epoch.
    for cleanup in ["release all", "background", "editing", "settings", "page", "profile", "mode"] {
        let defaults = defaultsForRepeat(), clock = ProfileCheckClock(), cleanupModel = model(defaults, clock)
        fullForward(cleanupModel); send(cleanupModel, .end(contact: 8000))
        let oldEpoch = cleanupModel.inputEpoch
        switch cleanup {
        case "release all": cleanupModel.releaseAll()
        case "background": cleanupModel.setForeground(false); cleanupModel.setForeground(true)
        case "editing": cleanupModel.beginLayoutEditing(); cleanupModel.cancelLayoutEditing()
        case "settings": cleanupModel.prepareSettings(); cleanupModel.finishSettings()
        case "page": cleanupModel.selectPage(otherPage)
        case "profile": _ = cleanupModel.selectProfile(other.id)
        default: cleanupModel.setMode(.bridge); cleanupModel.setMode(.practice)
        }
        require(cleanupModel.state.isNeutral && cleanupModel.retainedSticks.isEmpty && cleanupModel.inputEpoch != oldEpoch,
                "\(cleanup) releases retained repeat and advances its callback epoch")
        clock.time += 10
        cleanupModel.tickInput(epoch: oldEpoch)
        let staleAccepted = cleanupModel.handleInput(.beginStick(contact: 8004, control: stick.id, travel: .init(y: 1)), epoch: oldEpoch)
        cleanupModel.tickInput()
        require(!staleAccepted && cleanupModel.state.isNeutral && cleanupModel.retainedSticks.isEmpty,
                "\(cleanup) prevents stale input and both old/current timer ticks from reviving repeat")
        require(cleanupModel.library.profiles == library.profiles,
                "\(cleanup) keeps every saved profile's repeat configuration and geometry unchanged")
    }
    let cancelClock = ProfileCheckClock(), cancelModel = model(defaultsForRepeat(), cancelClock)
    fullForward(cancelModel); send(cancelModel, .cancel(contact: 8000))
    cancelClock.time += 1; cancelModel.tickInput()
    require(cancelModel.state.isNeutral && cancelModel.retainedSticks.isEmpty,
            "Canceling a live repeat gesture does not retain it or synthesize a later press")

    // Saved mode changes preserve repeat as a dormant option; Cancel restores the original complete control.
    let modeDefaults = defaultsForRepeat(), modeClock = ProfileCheckClock(), modeModel = model(modeDefaults, modeClock)
    for directional in [false, true] {
        var dormant = stick
        dormant.stickBehavior.stickPlusEnabled = false
        dormant.directionalEnabled = directional
        modeModel.beginLayoutEditing(); modeModel.saveControl(dormant)
        require(modeModel.profile.control(for: stick.id)?.stickPlusRepeatIntervalMilliseconds == 200 &&
                modeDefaults.data(forKey: ProfileControllerViewModel.libraryKey) == bytes,
                "Changing to \(directional ? "Directional" : "Analog") mode keeps repeat only in the unsaved draft")
        modeModel.cancelLayoutEditing()
        require(modeModel.profile == profile, "Canceling a mode change restores original Stick+ and repeat settings together")
        modeModel.beginLayoutEditing(); modeModel.saveControl(dormant); modeModel.saveLayoutEditing()
        let reload = model(modeDefaults, modeClock)
        require(reload.profile.control(for: stick.id) == dormant,
                "Saved \(directional ? "Directional" : "Analog") mode retains the dormant per-control interval")
        fullForward(reload); modeClock.time += 0.05; reload.tickInput()
        require(directional ? (reload.state.leftStick == .zero && reload.state.buttons == [.a]) :
                    (reload.state.leftStick.y == 1 && reload.state.buttons.isEmpty),
                "Repeat remains inactive in \(directional ? "Directional" : "plain Analog") mode")
        reload.releaseAll()
        modeModel.beginLayoutEditing(); modeModel.saveControl(stick); modeModel.saveLayoutEditing()
    }
    modeModel.beginLayoutEditing()
    var disabled = stick; disabled.stickPlusRepeatIntervalMilliseconds = nil
    modeModel.saveControl(disabled); modeModel.saveLayoutEditing()
    let disabledReload = model(modeDefaults, modeClock)
    fullForward(disabledReload); modeClock.time += 0.25; disabledReload.tickInput()
    require(disabledReload.state.buttons == [.a] && disabledReload.profile.control(for: stick.id)?.stickPlusRepeatIntervalMilliseconds == nil,
            "Saving repeat OFF restores an ordinary sustained stage action after reload")
    disabledReload.releaseAll()

    // Additive native imports preserve the user's existing profiles and selection while remapping every new owner.
    let importDefaults = defaultsForRepeat(), importClock = ProfileCheckClock(), imported = model(importDefaults, importClock)
    importDefaults.set(earlierRecovery, forKey: "controller.profiles.before-format-5")
    fullForward(imported); send(imported, .end(contact: 8000))
    let incoming = try ControllerProfileLibraryCodec.encode(.init(activeProfileID: profile.id, profiles: [profile]))
    let importEpoch = imported.inputEpoch
    require(imported.importProfiles(incoming), "Native format20 backup containing repeat imports as an additive profile")
    let added = imported.library.profiles.last!
    require(imported.library.profiles.count == 3 && Array(imported.library.profiles.prefix(2)) == library.profiles &&
            imported.library.activeProfileID == profile.id && added.id != profile.id,
            "Repeat import preserves both original profiles and selection with a fresh imported profile identity")
    require(Set(added.controls.map(\.id)).isDisjoint(with: Set(profile.controls.map(\.id))) &&
            added.controls.first(where: { $0.kind.isStick })?.stickPlusRepeatIntervalMilliseconds == 200,
            "Imported repeat controls keep configuration under independent fresh owner IDs")
    require(imported.state.isNeutral && imported.retainedSticks.isEmpty && imported.inputEpoch != importEpoch &&
            importDefaults.data(forKey: "controller.profiles.before-format-5") == earlierRecovery,
            "Successful import stops live repeat and preserves unrelated older recovery bytes")
    importClock.time += 1; imported.tickInput(epoch: importEpoch); imported.tickInput()
    require(imported.state.isNeutral, "Neither old nor current timer work revives repeat after import")
    let afterImport = try ControllerProfileLibraryCodec.decode(imported.exportProfiles()!)
    require(afterImport.profiles == imported.library.profiles && afterImport.activeProfileID == profile.id &&
            model(importDefaults, importClock).state.isNeutral,
            "Repeat import/export roundtrip preserves saved profiles and always restarts neutral")

    // Receiver lease validity still wins before a late digital-repeat timer can emit another press.
    let bridgeDefaults = defaultsForRepeat(), bridgeClock = ProfileCheckClock(), link = ProfileCheckTransport()
    let bridge = model(bridgeDefaults, bridgeClock, transport: link)
    bridge.setBridgeProtocol(.scx1); bridge.setMode(.bridge)
    bridge.host = "192.168.1.80"; bridge.portText = "42735"; bridge.connect()
    let session = link.sent.last!.session
    link.reply(.init(kind: .ready, session: session, sequence: 0, hidReady: true))
    fullForward(bridge); send(bridge, .end(contact: 8000))
    require(link.sent.last?.state?.buttons == [.a] && link.sent.last?.state?.leftStick.y == 1,
            "Bridge emits supported repeated A with the same full analog movement")
    let bridgeEpoch = bridge.inputEpoch, sentBeforeExpiry = link.sent.count
    bridgeClock.time += 0.8; bridge.tickInput(epoch: bridgeEpoch)
    require(!bridge.isReady && bridge.state.isNeutral && bridge.retainedSticks.isEmpty &&
            link.sent.count == sentBeforeExpiry && link.closed.last?.kind == .stop,
            "Expired bridge lease stops repeat before a delayed timer publishes another controller state")
    bridgeClock.time += 2; bridge.tickInput(epoch: bridgeEpoch); bridge.tickInput()
    require(link.sent.count == sentBeforeExpiry && bridge.state.isNeutral,
            "An expired repeat session cannot resume sending from subsequent timer callbacks")
}
