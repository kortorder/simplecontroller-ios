import Foundation

public enum ProfileControlKind: String, Codable, CaseIterable, Sendable {
    case button, leftStick, rightStick, recenter, touchpad, pageButton, touchAim
    public var isStick: Bool { self == .leftStick || self == .rightStick }
}

public enum ControllerProfileError: Error, Equatable, Sendable {
    case unsupportedVersion(Int), invalidFormat, invalidName, invalidDiameter, invalidActions
    case invalidPosition, duplicateControls, invalidPlacements, tooManyControls
    case invalidProfileCount, duplicateProfiles, missingActiveProfile, unknownControl, oversizedData
    case invalidPageCount, duplicatePages, duplicatePageNames, missingHomePage, unknownPage, invalidPageMembership, invalidNavigation
}

public struct ProfileControl: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProfileControlKind
    public var actions: Set<ControllerControlID>
    public var diameter: Double
    public var buttonBehavior: ButtonBehavior
    public var stickBehavior: StickBehavior
    public var payload: String?
    public var autoTapEnabled: Bool
    public var macroModeEnabled: Bool
    public var doubleTapRepeatEnabled: Bool
    public var centerLeftStickBeforePress: Bool
    public var autoTapIntervalMilliseconds: Int
    public var directionalEnabled: Bool
    public var directionPayloads: [StickDirection: StickDirectionPayloads]
    public var touchpadWidth: Double
    public var touchpadHeight: Double
    public var touchpadBehavior: TouchpadBehavior
    public var swipeActivationEnabled: Bool
    public var pageNavigation: ProfilePageNavigation?
    public var stickResponse: StickResponseSettings
    public var extendedBoost: ExtendedBoostSettings
    public var buttonDirectional: ButtonDirectionalSettings
    public var touchAim: TouchAimSettings
    public var buttonAim: ButtonAimSettings
    public var controlWidth: Double?
    public var controlHeight: Double?
    public var cameraFollowStrengthPercent: Double
    public var excludeFromCameraFollow: Bool
    public var mouseSuppressCameraFollow: Bool
    public var floatingAction: ProfileFloatingActionBinding?
    public var orientationDimensions: ProfileOrientationDimensions
    /// Nil sustains Stick+ controller buttons. Other stage outputs always stay sustained.
    public var stickPlusRepeatIntervalMilliseconds: Int?
    /// Optional inward travel before a finite Stick+ edge can fire again; nil preserves legacy stages.
    public var stickPlusEdgeRearmHysteresis: Double?

    public init(id: UUID = UUID(), name: String? = nil, kind: ProfileControlKind = .button,
                actions: Set<ControllerControlID> = [], diameter: Double? = nil,
                buttonBehavior: ButtonBehavior = .init(), stickBehavior: StickBehavior = .init(),
                payload: String? = nil, autoTapEnabled: Bool = false, autoTapIntervalMilliseconds: Int = 100,
                directionalEnabled: Bool = false, directionPayloads: [StickDirection: StickDirectionPayloads] = Dictionary(
                    uniqueKeysWithValues: StickDirection.allCases.map { ($0, .init()) }),
                touchpadWidth: Double = 220, touchpadHeight: Double = 160, touchpadBehavior: TouchpadBehavior = .init(),
                swipeActivationEnabled: Bool = true, pageNavigation: ProfilePageNavigation? = nil,
                stickResponse: StickResponseSettings = .init(), extendedBoost: ExtendedBoostSettings = .init(),
                buttonDirectional: ButtonDirectionalSettings = .init(), buttonAim: ButtonAimSettings = .init(),
                controlWidth: Double? = nil, controlHeight: Double? = nil, touchAim: TouchAimSettings = .init(),
                cameraFollowStrengthPercent: Double = 100, excludeFromCameraFollow: Bool = false,
                mouseSuppressCameraFollow: Bool = false, floatingAction: ProfileFloatingActionBinding? = nil,
                orientationDimensions: ProfileOrientationDimensions = .init(),
                stickPlusRepeatIntervalMilliseconds: Int? = nil, stickPlusEdgeRearmHysteresis: Double? = nil, macroModeEnabled: Bool = false,
                doubleTapRepeatEnabled: Bool = false, centerLeftStickBeforePress: Bool = false) {
        self.id = id; self.kind = kind; self.actions = actions
        self.name = name ?? (kind == .leftStick ? "Left stick" : kind == .rightStick ? "Right stick" : kind == .recenter ? "Re-center" : kind == .touchpad ? "Touchpad" : kind == .pageButton ? "Page" : kind == .touchAim ? "Touch Aim" : "Button")
        self.diameter = diameter ?? (kind.isStick ? 104 : 44)
        self.buttonBehavior = buttonBehavior; self.stickBehavior = stickBehavior
        self.payload = payload; self.autoTapEnabled = autoTapEnabled
        self.macroModeEnabled = macroModeEnabled
        self.doubleTapRepeatEnabled = doubleTapRepeatEnabled
        self.centerLeftStickBeforePress = centerLeftStickBeforePress
        self.autoTapIntervalMilliseconds = autoTapIntervalMilliseconds
        self.directionalEnabled = directionalEnabled; self.directionPayloads = directionPayloads
        self.touchpadWidth = touchpadWidth; self.touchpadHeight = touchpadHeight; self.touchpadBehavior = touchpadBehavior
        self.swipeActivationEnabled = swipeActivationEnabled
        self.pageNavigation = kind == .pageButton ? (pageNavigation ?? .home) : pageNavigation
        self.stickResponse = stickResponse; self.extendedBoost = extendedBoost
        self.buttonDirectional = buttonDirectional; self.buttonAim = buttonAim
        self.controlWidth = controlWidth; self.controlHeight = controlHeight; self.touchAim = touchAim
        self.cameraFollowStrengthPercent = cameraFollowStrengthPercent
        self.excludeFromCameraFollow = excludeFromCameraFollow; self.mouseSuppressCameraFollow = mouseSuppressCameraFollow
        self.floatingAction = floatingAction; self.orientationDimensions = orientationDimensions
        self.stickPlusRepeatIntervalMilliseconds = stickPlusRepeatIntervalMilliseconds
        self.stickPlusEdgeRearmHysteresis = stickPlusEdgeRearmHysteresis
    }
    public var resolvedWidth: Double { isTouchpad ? touchpadWidth : controlWidth ?? (isTouchAim ? 220 : diameter) }
    public var resolvedHeight: Double { isTouchpad ? touchpadHeight : controlHeight ?? (isTouchAim ? 160 : diameter) }
    public var isAdvancedButton: Bool { kind == .button && (buttonDirectional.enabled || buttonAim.enabled) }
    public var acceptsSwipeEntry: Bool {
        if isAdvancedButton || isTouchAim { return false }
        if isLocalAction { return false }
        return kind != .button || swipeActivationEnabled
    }
    public var isLocalAction: Bool { kind == .recenter || kind == .pageButton || isScrollModeToggle || isReleaseAllAction || isCameraFollowAction || isAutoCenterAction || isFloatingAction }
    public var isFloatingAction: Bool { kind == .button && floatingAction != nil }
    public var isAutoCenterAction: Bool { kind == .button && ((try? payloadProgram().autoCenterCommand) != nil) }
    public var isCameraFollowAction: Bool { kind == .button && ((try? payloadProgram().cameraFollowCommand) != nil) }
    public var isReleaseAllAction: Bool {
        kind == .button && floatingAction == nil && payload?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "RELEASE_ALL"
    }
    public var isTouchAim: Bool { kind == .touchAim }
    public var isTouchpad: Bool { kind == .touchpad }
    public var isScrollModeToggle: Bool { kind == .button && ((try? payloadProgram().isScrollModeToggle) ?? false) }
    public var isDirectional: Bool { kind.isStick && directionalEnabled }
    private var activePrograms: [ControllerPayloadProgram] {
        if isTouchAim {
            if touchAim.requiresLocalSetup { return [] }
            let payloads = touchAim.mode == .manualThreeStage ? [touchAim.threeStage.low.payload,touchAim.threeStage.medium.payload,touchAim.threeStage.high.payload] : [touchAim.twoState.aimPayload,touchAim.twoState.shootPayload]
            return payloads.compactMap { try? advancedButtonProgram($0) }
        }
        if kind == .button {
            var programs = (try? payloadProgram()).map { [$0] } ?? []
            if buttonAim.enabled && buttonAim.alternate.enabled, let alternate = try? advancedButtonProgram(buttonAim.alternate.payload) { programs.append(alternate) }
            if buttonDirectional.enabled {
                for stage in buttonDirectional.directions.values {
                    programs += [stage.firstPayload, stage.secondPayload].compactMap { try? advancedButtonProgram($0) }
                }
            }
            return programs
        }
        guard kind.isStick && (directionalEnabled || stickBehavior.stickPlusEnabled) else { return [] }
        return StickDirection.allCases.flatMap { direction in
            var programs = StickStage.allCases.compactMap { try? stageProgram(direction: direction, stage: $0) }
            if extendedBoost.enabled && extendedBoost.mode == .addOuterStage, let outer = try? outerProgram(direction: direction) { programs.append(outer) }
            return programs
        }
    }
    public var outputTargets: Set<ControllerControlID> {
        var targets = activePrograms.reduce(into: Set<ControllerControlID>()) { $0.formUnion($1.outputTargets) }
        if isTouchAim, let channel = touchAim.aim.output.logicalStick { targets.insert(channel) }
        if buttonAim.enabled {
            let tunings = [buttonAim.tuning] + (buttonAim.alternate.enabled ? [buttonAim.alternate.tuning] : [])
            for tuning in tunings {
                if let channel = tuning.output.logicalStick { targets.insert(channel) }
                if tuning.output == .dpad { targets.formUnion([.dpadUp,.dpadRight,.dpadDown,.dpadLeft]) }
            }
        }
        return targets
    }
    public var hasKeyboardOrMouseOutputs: Bool { isTouchpad || (isTouchAim && touchAim.aim.output.isMouse) || (buttonAim.enabled && (buttonAim.tuning.output.isMouse || (buttonAim.alternate.enabled && buttonAim.alternate.tuning.output.isMouse))) || activePrograms.contains { $0.hasKeyboardOrMouse } }
    public var hasAnyOutput: Bool { isTouchAim || isTouchpad || isLocalAction || buttonAim.enabled || (kind.isStick && !isDirectional) || activePrograms.contains { $0.hasAnyOutput } }
    public func stageProgram(direction: StickDirection, stage: StickStage) throws -> ControllerPayloadProgram {
        guard let overrides = directionPayloads[direction], let mapping = stickBehavior.directions[direction] else {
            throw ControllerPayloadError("Every stick direction must have Normal, Boost and Super settings.")
        }
        let fallback: Set<ControllerControlID>
        switch stage { case .normal: fallback = mapping.normalControls; case .boost: fallback = mapping.boostControls; case .superBoost: fallback = mapping.superBoostControls }
        do {
            let program = try ControllerPayloadProgram.parse(overrides.payload(for: stage) ?? ControllerPayloadProgram.source(for: fallback))
            try program.validateSustained(); return program
        } catch { throw ControllerPayloadError("\(direction.rawValue.capitalized) \(stage.displayName): \(error.localizedDescription)") }
    }
    public func outerProgram(direction: StickDirection) throws -> ControllerPayloadProgram {
        guard let settings = extendedBoost.directions[direction] else { throw ControllerProfileError.invalidFormat }
        guard let payload = settings.outerPayload, !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try stageProgram(direction: direction, stage: .superBoost)
        }
        do { let program = try ControllerPayloadProgram.parse(payload); try program.validateSustained(); return program }
        catch { throw ControllerPayloadError("\(direction.rawValue.capitalized) Outer Boost: \(error.localizedDescription)") }
    }
    public func payloadProgram() throws -> ControllerPayloadProgram {
        try ControllerPayloadProgram.parse(isFloatingAction ? "" : payload ?? ControllerPayloadProgram.source(for: actions))
    }
    public var logicalStick: ControllerControlID? {
        kind == .leftStick ? .leftStick : kind == .rightStick ? .rightStick : nil
    }
    public var minimumDiameter: Double { kind.isStick ? 104 : 44 }
    public func validate() throws {
        try validateProfileName(name)
        if let interval = stickPlusRepeatIntervalMilliseconds {
            guard kind.isStick, (16...1_000).contains(interval) else {
                throw ControllerPayloadError("Stick+ repeat is available on sticks only, with an interval from 16 to 1000 milliseconds.")
            }
        }
        if let hysteresis = stickPlusEdgeRearmHysteresis {
            guard kind.isStick, hysteresis.isFinite, (0...0.25).contains(hysteresis) else {
                throw ControllerPayloadError("Stick+ edge reactivation needs a stick and an inward distance from 0 through 25 percent.")
            }
        }
        if let floatingAction {
            try floatingAction.validate()
            guard kind == .button, pageNavigation == nil, !buttonBehavior.holdToggle, !autoTapEnabled,
                  !buttonDirectional.enabled, !buttonAim.enabled, !buttonAim.alternate.enabled,
                  buttonAim.payloadTiming == .immediate else {
                throw FloatingControlError("Scoped floating actions require an ordinary immediate Button without Hold, AutoTap, Directional, Aim or page navigation.")
            }
        }
        guard cameraFollowStrengthPercent.isFinite, (0...200).contains(cameraFollowStrengthPercent) else {
            throw ControllerPayloadError("Camera Follow strength must be 0 through 200 percent.")
        }
        guard (kind == .pageButton) == (pageNavigation != nil) else { throw ControllerProfileError.invalidNavigation }
        if kind == .pageButton && (buttonBehavior.holdToggle || autoTapEnabled) { throw ControllerProfileError.invalidNavigation }
        guard diameter.isFinite, (minimumDiameter...(kind.isStick ? 300 : 200)).contains(diameter) else {
            throw ControllerProfileError.invalidDiameter
        }
        guard !actions.contains(where: \.isStick), kind == .button || actions.isEmpty else {
            throw ControllerProfileError.invalidActions
        }
        guard (16...1_000).contains(autoTapIntervalMilliseconds) else {
            throw ControllerPayloadError("AutoTap interval must be 16 through 1000 milliseconds.")
        }
        guard kind == .button || (payload == nil && !autoTapEnabled) else {
            throw ControllerPayloadError("Payload and AutoTap settings are available on buttons only.")
        }
        guard touchpadWidth.isFinite, touchpadHeight.isFinite, (44...1_200).contains(touchpadWidth), (44...1_200).contains(touchpadHeight) else {
            throw ControllerPayloadError("Touchpad width and height must each be 44 through 1200 points.")
        }
        try buttonDirectional.validate(); try buttonAim.validate()
        guard kind == .button || (!buttonDirectional.enabled && !buttonAim.enabled) else { throw ControllerPayloadError("Directional buttons and Button Aim are available on buttons only.") }
        for size in [controlWidth, controlHeight].compactMap({ $0 }) {
            guard size.isFinite, (minimumDiameter...1200).contains(size) else { throw ControllerProfileError.invalidDiameter }
        }
        try orientationDimensions.validate(minimum: minimumDiameter)
        if isAdvancedButton {
            if autoTapEnabled { throw ControllerPayloadError("AutoTap cannot be combined with Directional buttons or Button Aim.") }
            if buttonDirectional.enabled && !buttonAim.enabled && buttonBehavior.holdToggle { throw ControllerPayloadError("Directional-only buttons cannot use Hold Toggle. Button Aim can use both.") }
            let base = try advancedButtonProgram(payload ?? ControllerPayloadProgram.source(for: actions))
            if buttonAim.enabled {
                try validateAimCommandTiming(base, default: buttonAim.payloadTiming)
                if buttonAim.alternate.enabled {
                    try validateAimCommandTiming(advancedButtonProgram(buttonAim.alternate.payload), default: buttonAim.alternate.payloadTiming)
                }
            }
            if buttonAim.enabled && buttonAim.alternate.enabled && !base.hasAnyOutput { throw ControllerPayloadError("One-Shot Alternate needs both Base and Alternate payloads.") }
        }
        try touchAim.validate()
        if isTouchAim && buttonBehavior.holdToggle { throw ControllerPayloadError("Touch Aim owns its stages while touched and cannot use Hold Toggle.") }
        try touchpadBehavior.validate()
        let program = try payloadProgram()
        if centerLeftStickBeforePress {
            guard kind == .button, !isLocalAction, !isAdvancedButton else {
                throw ControllerPayloadError("Center left stick before pressing is available on ordinary or Macro Mode buttons.")
            }
        }
        if doubleTapRepeatEnabled {
            guard kind == .button, !isLocalAction, !isAdvancedButton, !macroModeEnabled, !autoTapEnabled,
                  !program.hasModifiers, !program.steps.isEmpty,
                  program.steps.allSatisfy({ step in
                      switch step {
                      case .digital, .keyDown, .mouseDown: return true
                      case let .triggerPressure(_, amount): return amount > 0
                      default: return false
                      }
                  }) else {
                throw ControllerPayloadError("Double-tap repeat needs ordinary button, keyboard, mouse, or trigger presses without timing modifiers, Macro Mode, Auto-Tap or Button Aim.")
            }
        }
        if macroModeEnabled {
            guard kind == .button, !isLocalAction, !isAdvancedButton,
                  !buttonBehavior.holdToggle, !autoTapEnabled else {
                throw ControllerPayloadError("Choose Macro Mode on an ordinary button with Hold Toggle, AutoTap, Button Aim and Directional mode turned off.")
            }
            try program.validateMacroMode()
        }
        if program.autoCenterCommand != nil && (kind != .button || buttonBehavior.holdToggle || autoTapEnabled || isAdvancedButton) {
            throw ControllerPayloadError("Auto-center is a single-tap setting. Turn off Hold Toggle, Auto-Tap, Directional button and Button Aim.")
        }
        if program.cameraFollowCommand != nil && (buttonBehavior.holdToggle || autoTapEnabled || isAdvancedButton) {
            throw ControllerPayloadError("Camera Follow is a direct Practice action. Turn off Hold Toggle, AutoTap, Directional button and Button Aim for this button.")
        }
        if program.isReleaseAll && (buttonBehavior.holdToggle || autoTapEnabled) {
            throw ControllerPayloadError("Release all is immediate. Turn off Hold Toggle and AutoTap for this button.")
        }
        if program.isScrollModeToggle && (buttonBehavior.holdToggle || autoTapEnabled) {
            throw ControllerPayloadError("Scroll mode is a single-tap setting. Turn off Hold Toggle and AutoTap for this button.")
        }
        if autoTapEnabled && buttonBehavior.holdToggle {
            throw ControllerPayloadError("Choose AutoTap or Hold Toggle; they cannot both be enabled.")
        }
        if autoTapEnabled && program.containsLegacyWaitOrPulse {
            throw ControllerPayloadError("AutoTap cannot contain WAIT or timed pulse commands. Use immediate controller actions.")
        }
        guard !directionalEnabled || kind.isStick else { throw ControllerPayloadError("Directional mode is available on sticks only.") }
        guard Set(directionPayloads.keys) == Set(StickDirection.allCases) else { throw ControllerPayloadError("Every stick direction must have payload settings.") }
        for direction in StickDirection.allCases { for stage in StickStage.allCases { _ = try stageProgram(direction: direction, stage: stage) } }
        try buttonBehavior.validate()
        try stickBehavior.validate()
        try stickResponse.validate(); try extendedBoost.validate(sharedSuperThreshold: stickBehavior.superBoostThreshold)
        guard !extendedBoost.enabled || kind.isStick else { throw ControllerPayloadError("Extended Boost is available on sticks only.") }
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, actions, diameter, buttonBehavior, stickBehavior, payload, autoTapEnabled, autoTapIntervalMilliseconds, directionalEnabled, directionPayloads, touchpadWidth, touchpadHeight, touchpadBehavior, swipeActivationEnabled, pageNavigation, stickResponse, extendedBoost, buttonDirectional, buttonAim, controlWidth, controlHeight, touchAim, cameraFollowStrengthPercent, excludeFromCameraFollow, mouseSuppressCameraFollow, floatingAction, orientationDimensions, stickPlusRepeatIntervalMilliseconds, stickPlusEdgeRearmHysteresis, macroModeEnabled, doubleTapRepeatEnabled, centerLeftStickBeforePress
    }
    public init(from decoder: Decoder) throws { try self.init(from: decoder, version: ControllerProfileLibrary.currentVersion) }
    fileprivate init(from decoder: Decoder, version: Int) throws {
        var keys: Set<String> = ["id", "name", "kind", "actions", "diameter", "buttonBehavior", "stickBehavior"]
        if version >= 2 { keys.formUnion(["payload", "autoTapEnabled", "autoTapIntervalMilliseconds"]) }
        if version >= 3 { keys.formUnion(["directionalEnabled", "directionPayloads"]) }
        if version >= 4 { keys.formUnion(["touchpadWidth", "touchpadHeight", "touchpadBehavior"]) }
        if version >= 5 { keys.insert("swipeActivationEnabled") }
        if version >= 6 { keys.insert("pageNavigation") }
        if version >= 7 { keys.formUnion(["stickResponse", "extendedBoost"]) }
        if version >= 9 { keys.formUnion(["buttonDirectional", "buttonAim", "controlWidth", "controlHeight"]) }
        if version >= 11 { keys.insert("touchAim") }
        if version >= 17 { keys.formUnion(["cameraFollowStrengthPercent", "excludeFromCameraFollow", "mouseSuppressCameraFollow"]) }
        if version >= 18 { keys.insert("floatingAction") }
        if version >= 19 { keys.insert("orientationDimensions") }
        if version >= 20 { keys.insert("stickPlusRepeatIntervalMilliseconds") }
        var optional: Set<String> = version >= 22 ? ["macroModeEnabled"] : []
        if version >= 23 { optional.formUnion(["doubleTapRepeatEnabled", "centerLeftStickBeforePress"]) }
        if version >= 24 { optional.insert("stickPlusEdgeRearmHysteresis") }
        try profileKeys(decoder, keys, optional: optional)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(ProfileControlKind.self, forKey: .kind)
        guard version >= 11 || kind != .touchAim else { throw ControllerProfileError.invalidFormat }
        guard version >= 6 || kind != .pageButton else { throw ControllerProfileError.invalidFormat }
        guard version >= 4 || kind != .touchpad else { throw ControllerProfileError.invalidFormat }
        let savedActions = try values.decode([ControllerControlID].self, forKey: .actions)
        guard Set(savedActions).count == savedActions.count else { throw ControllerProfileError.invalidActions }
        actions = Set(savedActions)
        diameter = try values.decode(Double.self, forKey: .diameter)
        buttonBehavior = try values.decode(ButtonBehavior.self, forKey: .buttonBehavior)
        stickBehavior = try values.decode(StickBehavior.self, forKey: .stickBehavior)
        payload = version == 1 ? nil : try values.decodeIfPresent(String.self, forKey: .payload)
        autoTapEnabled = version == 1 ? false : try values.decode(Bool.self, forKey: .autoTapEnabled)
        macroModeEnabled = version < 22 ? false : try values.decodeIfPresent(Bool.self, forKey: .macroModeEnabled) ?? false
        doubleTapRepeatEnabled = version < 23 ? false : try values.decodeIfPresent(Bool.self, forKey: .doubleTapRepeatEnabled) ?? false
        centerLeftStickBeforePress = version < 23 ? false : try values.decodeIfPresent(Bool.self, forKey: .centerLeftStickBeforePress) ?? false
        autoTapIntervalMilliseconds = version == 1 ? 100 : try values.decode(Int.self, forKey: .autoTapIntervalMilliseconds)
        directionalEnabled = version < 3 ? false : try values.decode(Bool.self, forKey: .directionalEnabled)
        if version < 3 { directionPayloads = Dictionary(uniqueKeysWithValues: StickDirection.allCases.map { ($0, .init()) }) }
        else {
            let saved = try values.decode([String: StickDirectionPayloads].self, forKey: .directionPayloads)
            guard Set(saved.keys) == Set(StickDirection.allCases.map(\.rawValue)) else { throw ControllerProfileError.invalidFormat }
            directionPayloads = Dictionary(uniqueKeysWithValues: saved.map { (StickDirection(rawValue: $0.key)!, $0.value) })
        }
        touchpadWidth = version < 4 ? 220 : try values.decode(Double.self, forKey: .touchpadWidth)
        touchpadHeight = version < 4 ? 160 : try values.decode(Double.self, forKey: .touchpadHeight)
        touchpadBehavior = version < 4 ? .init() : try values.decode(TouchpadBehavior.self, forKey: .touchpadBehavior)
        swipeActivationEnabled = version < 5 ? true : try values.decode(Bool.self, forKey: .swipeActivationEnabled)
        pageNavigation = version < 6 ? nil : try values.decodeIfPresent(ProfilePageNavigation.self, forKey: .pageNavigation)
        stickResponse = version < 7 ? .init() : try values.decode(StickResponseSettings.self, forKey: .stickResponse)
        extendedBoost = version < 7 ? .init() : try values.decode(ExtendedBoostSettings.self, forKey: .extendedBoost)
        buttonDirectional = version < 9 ? .init() : try values.decode(ButtonDirectionalSettings.self, forKey: .buttonDirectional)
        buttonAim = version < 9 ? .init() : try values.decode(ButtonAimSettings.self, forKey: .buttonAim)
        controlWidth = version < 9 ? nil : try values.decodeIfPresent(Double.self, forKey: .controlWidth)
        controlHeight = version < 9 ? nil : try values.decodeIfPresent(Double.self, forKey: .controlHeight)
        touchAim = version < 11 ? .init() : try .init(from: values.superDecoder(forKey: .touchAim), libraryVersion: version)
        cameraFollowStrengthPercent = version < 17 ? 100 : try values.decode(Double.self, forKey: .cameraFollowStrengthPercent)
        excludeFromCameraFollow = version < 17 ? false : try values.decode(Bool.self, forKey: .excludeFromCameraFollow)
        mouseSuppressCameraFollow = version < 17 ? false : try values.decode(Bool.self, forKey: .mouseSuppressCameraFollow)
        if version >= 18 && !values.contains(.floatingAction) { throw ControllerProfileError.invalidFormat }
        floatingAction = version < 18 ? nil : try values.decodeIfPresent(ProfileFloatingActionBinding.self, forKey: .floatingAction)
        orientationDimensions = version < 19 ? .init() : try values.decode(ProfileOrientationDimensions.self, forKey: .orientationDimensions)
        stickPlusRepeatIntervalMilliseconds = version < 20 ? nil : try values.decodeIfPresent(Int.self, forKey: .stickPlusRepeatIntervalMilliseconds)
        stickPlusEdgeRearmHysteresis = version < 24 ? nil : try values.decodeIfPresent(Double.self, forKey: .stickPlusEdgeRearmHysteresis)
        if version < 21 && (touchAim.threeStage.hasStageTuning || usesCommandModifiers) {
            throw ControllerProfileError.invalidFormat
        }
        if version < 22 && minimumCommandModifierVersion >= 17 { throw ControllerProfileError.invalidFormat }
        if version < 24 && authoredPayloads.contains(where: { (try? ControllerPayloadProgram.parse($0).autoCenterCommand) != nil }) {
            throw ControllerProfileError.invalidFormat
        }
        try validate()
    }
    private var usesCommandModifiers: Bool { minimumCommandModifierVersion >= 14 }
    private var minimumCommandModifierVersion: Int { authoredPayloads.map(AndroidTimingFormat.payloadVersion).max() ?? 1 }
    var authoredPayloads: [String] {
        var actions = [payload ?? "", buttonAim.alternate.payload, touchAim.twoState.aimPayload, touchAim.twoState.shootPayload,
                       touchAim.threeStage.low.payload, touchAim.threeStage.medium.payload, touchAim.threeStage.high.payload]
        actions += buttonDirectional.directions.values.flatMap { [$0.firstPayload, $0.secondPayload] }
        actions += directionPayloads.values.flatMap { [$0.normalPayload, $0.boostPayload, $0.superBoostPayload].compactMap { $0 } }
        actions += extendedBoost.directions.values.compactMap(\.outerPayload)
        return actions
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(kind, forKey: .kind)
        try values.encode(actions.sorted { $0.rawValue < $1.rawValue }, forKey: .actions)
        try values.encode(diameter, forKey: .diameter)
        try values.encode(buttonBehavior, forKey: .buttonBehavior)
        try values.encode(stickBehavior, forKey: .stickBehavior)
        try values.encode(payload, forKey: .payload)
        try values.encode(autoTapEnabled, forKey: .autoTapEnabled)
        if macroModeEnabled { try values.encode(true, forKey: .macroModeEnabled) }
        if doubleTapRepeatEnabled { try values.encode(true, forKey: .doubleTapRepeatEnabled) }
        if centerLeftStickBeforePress { try values.encode(true, forKey: .centerLeftStickBeforePress) }
        try values.encode(autoTapIntervalMilliseconds, forKey: .autoTapIntervalMilliseconds)
        try values.encode(directionalEnabled, forKey: .directionalEnabled)
        try values.encode(Dictionary(uniqueKeysWithValues: directionPayloads.map { ($0.key.rawValue, $0.value) }), forKey: .directionPayloads)
        try values.encode(touchpadWidth, forKey: .touchpadWidth); try values.encode(touchpadHeight, forKey: .touchpadHeight)
        try values.encode(touchpadBehavior, forKey: .touchpadBehavior)
        try values.encode(swipeActivationEnabled, forKey: .swipeActivationEnabled)
        try values.encode(pageNavigation, forKey: .pageNavigation)
        try values.encode(stickResponse, forKey: .stickResponse); try values.encode(extendedBoost, forKey: .extendedBoost)
        try values.encode(buttonDirectional, forKey: .buttonDirectional); try values.encode(buttonAim, forKey: .buttonAim)
        try values.encode(controlWidth, forKey: .controlWidth); try values.encode(controlHeight, forKey: .controlHeight)
        try values.encode(touchAim, forKey: .touchAim)
        try values.encode(cameraFollowStrengthPercent, forKey: .cameraFollowStrengthPercent)
        try values.encode(excludeFromCameraFollow, forKey: .excludeFromCameraFollow)
        try values.encode(mouseSuppressCameraFollow, forKey: .mouseSuppressCameraFollow)
        try values.encode(floatingAction, forKey: .floatingAction)
        try values.encode(orientationDimensions, forKey: .orientationDimensions)
        try values.encode(stickPlusRepeatIntervalMilliseconds, forKey: .stickPlusRepeatIntervalMilliseconds)
        try values.encodeIfPresent(stickPlusEdgeRearmHysteresis, forKey: .stickPlusEdgeRearmHysteresis)
    }
}

public struct ProfilePlacement: Codable, Equatable, Sendable {
    public var id: UUID
    public var position: NormalizedControlPosition
    public init(id: UUID, position: NormalizedControlPosition) { self.id = id; self.position = position }
    private enum CodingKeys: String, CodingKey { case id, position }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["id", "position"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        position = try values.decode(NormalizedControlPosition.self, forKey: .position)
    }
    public func encode(to encoder: Encoder) throws {
        guard position.isValid else { throw ControllerProfileError.invalidPosition }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(position, forKey: .position)
    }
}

/// Editable drafts must be validated before publishing, persisting or applying to an engine.
public struct ControllerProfile: Identifiable, Codable, Equatable, Sendable {
    public static let maximumControls = 128
    public var id: UUID
    public var name: String
    public var controls: [ProfileControl]
    public var portrait: [ProfilePlacement]
    public var landscape: [ProfilePlacement]
    public var turboEnabled: Bool
    public var turboIntervalMilliseconds: Int
    public var swipeMode: ProfileSwipeMode
    public var globalHoldEnabled: Bool
    public var pages: [ProfilePage]
    public var homePageID: UUID
    public var androidSources: [AndroidProfileSourceReference]
    public init(id: UUID = UUID(), name: String = "My Controller", controls: [ProfileControl] = [],
                portrait: [ProfilePlacement] = [], landscape: [ProfilePlacement] = [],
                turboEnabled: Bool = false, turboIntervalMilliseconds: Int = 16, swipeMode: ProfileSwipeMode = .off,
                globalHoldEnabled: Bool = false,
                pages: [ProfilePage]? = nil, homePageID: UUID? = nil,
                androidSources: [AndroidProfileSourceReference] = []) throws {
        self.id = id; self.name = name; self.controls = controls
        self.portrait = portrait; self.landscape = landscape
        self.turboEnabled = turboEnabled; self.turboIntervalMilliseconds = turboIntervalMilliseconds
        self.swipeMode = swipeMode
        self.globalHoldEnabled = globalHoldEnabled
        self.pages = pages ?? [.init(id: id, name: "Main", controlIDs: controls.map(\.id))]
        self.homePageID = homePageID ?? self.pages.first?.id ?? id
        self.androidSources = androidSources
        try validate()
    }
    public func placements(for orientation: ControllerOrientation) -> [ProfilePlacement] {
        orientation == .portrait ? portrait : landscape
    }
    public func control(for id: UUID) -> ProfileControl? { controls.first { $0.id == id } }
    public mutating func move(_ id: UUID, to position: NormalizedControlPosition,
                              orientation: ControllerOrientation) throws {
        try validate()
        guard control(for: id) != nil else { throw ControllerProfileError.unknownControl }
        let moved = ProfilePlacement(id: id, position: try position.clamped())
        var placements = placements(for: orientation)
        placements.removeAll { $0.id == id }; placements.append(moved)
        if orientation == .portrait { portrait = placements } else { landscape = placements }
    }
    public func validate() throws {
        try validateProfileName(name)
        guard (10...1_000).contains(turboIntervalMilliseconds) else { throw ControllerPayloadError("Turbo interval must be 10 through 1000 milliseconds.") }
        guard controls.count <= Self.maximumControls else { throw ControllerProfileError.tooManyControls }
        let ids = Set(controls.map(\.id))
        guard ids.count == controls.count else { throw ControllerProfileError.duplicateControls }
        for control in controls { try control.validate() }
        guard (1...Self.maximumPages).contains(pages.count) else { throw ControllerProfileError.invalidPageCount }
        let pageIDs = Set(pages.map(\.id))
        guard pageIDs.count == pages.count else { throw ControllerProfileError.duplicatePages }
        guard Set(pages.map { normalizedPageName($0.name) }).count == pages.count else { throw ControllerProfileError.duplicatePageNames }
        guard pageIDs.contains(homePageID) else { throw ControllerProfileError.missingHomePage }
        guard androidSources.count <= 96 else { throw AndroidArchiveError("Too many Android source references in one profile.") }
        var sourceKeys: Set<Data> = []
        for source in androidSources {
            guard sourceKeys.insert(Data((source.archiveID.uuidString + "|" + source.sourceProfilePath).utf8)).inserted else {
                throw AndroidArchiveError("Duplicate Android profile source reference.")
            }
            try source.validate(pageIDs: pageIDs, controlIDs: ids)
        }
        for page in pages { try page.validate() }
        let zoneIDs = pages.flatMap { $0.floatingButtonZones.map(\.id) + $0.floatingRingZones.map(\.id) }
        guard Set(zoneIDs).count == zoneIDs.count, Set(zoneIDs).isDisjoint(with: ids), Set(zoneIDs).isDisjoint(with: pageIDs) else {
            throw FloatingControlError("Floating zone IDs must be unique across this profile and separate from pages and controls.")
        }
        let buttonIDs = Set(controls.filter { $0.kind == .button }.map(\.id))
        for page in pages {
            let members = Set(page.controlIDs)
            try FloatingButtonZone.validate(page.floatingButtonZones, pageControlIDs: members, buttonIDs: buttonIDs.intersection(members))
        }
        let members = pages.flatMap(\.controlIDs)
        guard members.count == ids.count, Set(members) == ids else { throw ControllerProfileError.invalidPageMembership }
        for control in controls {
            if let target = control.pageNavigation?.targetPageID, !pageIDs.contains(target) { throw ControllerProfileError.invalidNavigation }
            if let binding = control.floatingAction, case let .zone(target) = binding.target,
               pages.contains(where: { $0.floatingButtonZones.contains(where: { $0.id == target }) }), binding.action != .finish {
                throw FloatingControlError("Floating button groups support Finish only. Choose a ring for other scoped actions.")
            }
        }
        for placements in [portrait, landscape] {
            let placementIDs = placements.map(\.id)
            guard Set(placementIDs).count == placementIDs.count, Set(placementIDs) == ids else {
                throw ControllerProfileError.invalidPlacements
            }
            guard placements.allSatisfy({ $0.position.isValid }) else { throw ControllerProfileError.invalidPosition }
        }
    }
    /// Converts the existing 20 controls without losing orientation order or per-control settings.
    public static func migrating(layout: ControllerLayout, behaviors: ControllerBehaviors,
                                 name: String = "My Controller") throws -> ControllerProfile {
        try layout.validate(); try behaviors.validate()
        let ids = Dictionary(uniqueKeysWithValues: ControllerControlID.allCases.map { ($0, UUID()) })
        let controls = ControllerControlID.allCases.map { legacy in
            ProfileControl(id: ids[legacy]!, name: legacy.displayName,
                           kind: legacy == .leftStick ? .leftStick : legacy == .rightStick ? .rightStick : .button,
                           actions: legacy.isStick ? [] : [legacy], diameter: legacy.defaultDiameter,
                           buttonBehavior: behaviors.button(for: legacy), stickBehavior: behaviors.stick(for: legacy))
        }
        func placements(_ orientation: ControllerOrientation) -> [ProfilePlacement] {
            layout.placements(for: orientation).map { .init(id: ids[$0.id]!, position: $0.position) }
        }
        return try ControllerProfile(name: name, controls: controls,
                                     portrait: placements(.portrait), landscape: placements(.landscape), swipeMode: .buttons)
    }
    private enum CodingKeys: String, CodingKey { case id, name, controls, portrait, landscape, turboEnabled, turboIntervalMilliseconds, swipeMode, globalHoldEnabled, pages, homePageID, androidSources }
    public init(from decoder: Decoder) throws { try self.init(from: decoder, version: ControllerProfileLibrary.currentVersion) }
    fileprivate init(from decoder: Decoder, version: Int) throws {
        var keys: Set<String> = ["id", "name", "controls", "portrait", "landscape"]
        if version >= 2 { keys.formUnion(["turboEnabled", "turboIntervalMilliseconds"]) }
        if version >= 5 { keys.insert("swipeMode") }
        if version >= 6 { keys.formUnion(["pages", "homePageID"]) }
        if version >= 8 { keys.insert("androidSources") }
        if version >= 13 { keys.insert("globalHoldEnabled") }
        try profileKeys(decoder, keys)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var savedControls = try values.nestedUnkeyedContainer(forKey: .controls)
        var controls: [ProfileControl] = []
        while !savedControls.isAtEnd {
            guard controls.count < (version < 24 ? 64 : Self.maximumControls) else { throw ControllerProfileError.tooManyControls }
            controls.append(try ProfileControl(from: savedControls.superDecoder(), version: version))
        }
        var androidSources: [AndroidProfileSourceReference] = []
        if version >= 8 {
            var sources = try values.nestedUnkeyedContainer(forKey: .androidSources)
            while !sources.isAtEnd { androidSources.append(try .init(from: sources.superDecoder(), libraryVersion: version)) }
        }
        var pages: [ProfilePage]?
        if version >= 6 {
            var savedPages = try values.nestedUnkeyedContainer(forKey: .pages)
            pages = []
            while !savedPages.isAtEnd { pages?.append(try ProfilePage(from: savedPages.superDecoder(), libraryVersion: version)) }
        }
        try self.init(id: values.decode(UUID.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      controls: controls, portrait: values.decode([ProfilePlacement].self, forKey: .portrait),
                      landscape: values.decode([ProfilePlacement].self, forKey: .landscape),
                      turboEnabled: version == 1 ? false : values.decode(Bool.self, forKey: .turboEnabled),
                      turboIntervalMilliseconds: version == 1 ? 16 : values.decode(Int.self, forKey: .turboIntervalMilliseconds),
                      swipeMode: version < 5 ? .buttons : values.decode(ProfileSwipeMode.self, forKey: .swipeMode),
                      globalHoldEnabled: version < 13 ? false : values.decode(Bool.self, forKey: .globalHoldEnabled),
                      pages: pages,
                      homePageID: version < 6 ? nil : values.decode(UUID.self, forKey: .homePageID),
                      androidSources: androidSources)
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(name, forKey: .name)
        try values.encode(controls, forKey: .controls)
        try values.encode(portrait, forKey: .portrait); try values.encode(landscape, forKey: .landscape)
        try values.encode(turboEnabled, forKey: .turboEnabled)
        try values.encode(turboIntervalMilliseconds, forKey: .turboIntervalMilliseconds)
        try values.encode(swipeMode, forKey: .swipeMode)
        try values.encode(globalHoldEnabled, forKey: .globalHoldEnabled)
        try values.encode(pages, forKey: .pages); try values.encode(homePageID, forKey: .homePageID)
        try values.encode(androidSources, forKey: .androidSources)
    }
}

public struct ControllerProfileLibrary: Codable, Equatable, Sendable {
    public static let currentVersion = 24
    public var version: Int
    public var activeProfileID: UUID
    public var profiles: [ControllerProfile]
    public var androidSources: [AndroidSourceArchiveReference]
    public var settingsPresets: SettingsPresetLibrary
    public init(version: Int = currentVersion, activeProfileID: UUID, profiles: [ControllerProfile],
                androidSources: [AndroidSourceArchiveReference] = [], settingsPresets: SettingsPresetLibrary = .empty) throws {
        self.version = version; self.activeProfileID = activeProfileID; self.profiles = profiles
        self.androidSources = androidSources; self.settingsPresets = settingsPresets
        try validate()
    }
    public static let `default`: ControllerProfileLibrary = {
        var profile = try! ControllerProfile.migrating(layout: .default, behaviors: .default)
        profile.swipeMode = .off
        return try! ControllerProfileLibrary(activeProfileID: profile.id, profiles: [profile])
    }()
    /// Call validate() after editing a draft and before reading this invariant-backed property.
    public var activeProfile: ControllerProfile { profiles.first { $0.id == activeProfileID }! }
    public func validate() throws {
        guard version == Self.currentVersion else { throw ControllerProfileError.unsupportedVersion(version) }
        guard (1...32).contains(profiles.count) else { throw ControllerProfileError.invalidProfileCount }
        let ids = Set(profiles.map(\.id))
        guard ids.count == profiles.count else { throw ControllerProfileError.duplicateProfiles }
        guard ids.contains(activeProfileID) else { throw ControllerProfileError.missingActiveProfile }
        guard androidSources.count <= AndroidProfileArchiveStore.maximumArchiveCount,
              Set(androidSources.map(\.id)).count == androidSources.count,
              Set(androidSources.map(\.sha256)).count == androidSources.count,
              androidSources.reduce(0, { $0 + $1.byteCount }) <= AndroidProfileArchiveStore.maximumTotalBytes else {
            throw AndroidArchiveError("Invalid Android source archive library.")
        }
        for source in androidSources { try source.validate() }
        let archives = Set(androidSources.map(\.id))
        guard profiles.allSatisfy({ Set($0.androidSources.map(\.archiveID)).isSubset(of: archives) }) else {
            throw AndroidArchiveError("A profile references an Android source missing from the library.")
        }
        for profile in profiles { try profile.validate() }
        try settingsPresets.validate()
    }
    private enum CodingKeys: String, CodingKey { case version, activeProfileID, profiles, androidSources, settingsPresets }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(version) else { throw ControllerProfileError.unsupportedVersion(version) }
        var keys:Set<String>=["version","activeProfileID","profiles"]
        if version>=8 { keys.insert("androidSources") };if version>=14 { keys.insert("settingsPresets") }
        try profileKeys(decoder,keys)
        var savedProfiles = try values.nestedUnkeyedContainer(forKey: .profiles)
        var profiles: [ControllerProfile] = []
        while !savedProfiles.isAtEnd { profiles.append(try ControllerProfile(from: savedProfiles.superDecoder(), version: version)) }
        try self.init(activeProfileID: values.decode(UUID.self, forKey: .activeProfileID), profiles: profiles,
                      androidSources: version < 8 ? [] : values.decode([AndroidSourceArchiveReference].self, forKey: .androidSources),
                      settingsPresets: version < 14 ? .empty : values.decode(SettingsPresetLibrary.self, forKey: .settingsPresets))
        if version < 21 && settingsPresets.wireVersion > 1 { throw ControllerProfileError.invalidFormat }
        if version < 22 && settingsPresets.wireVersion > 2 { throw ControllerProfileError.invalidFormat }
        if version < 24 && settingsPresets.wireVersion > 3 { throw ControllerProfileError.invalidFormat }
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(activeProfileID, forKey: .activeProfileID)
        try values.encode(profiles, forKey: .profiles)
        try values.encode(androidSources, forKey: .androidSources)
        try values.encode(settingsPresets, forKey: .settingsPresets)
    }
}

public enum ControllerProfileLibraryCodec {
    /// Previous releases used this bound for the whole collection, not each profile.
    /// Keep it available for a one-time exact recovery copy when storage grows.
    public static let legacyMaximumBytes = 2 * 1_024 * 1_024
    public static let maximumBytes = 16 * 1_024 * 1_024
    public static func encode(_ library: ControllerProfileLibrary) throws -> Data {
        try library.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(library)
        guard data.count <= maximumBytes else { throw ControllerProfileError.oversizedData }
        return data
    }
    public static func decode(_ data: Data) throws -> ControllerProfileLibrary {
        guard data.count <= maximumBytes else { throw ControllerProfileError.oversizedData }
        do { return try JSONDecoder().decode(ControllerProfileLibrary.self, from: data) }
        catch let error as ControllerProfileError { throw error }
        catch { throw ControllerProfileError.invalidFormat }
    }
}

public extension ControllerControlID {
    var shortLabel: String {
        switch self {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .leftBumper: "LB"
        case .rightBumper: "RB"
        case .leftTrigger: "LT"
        case .rightTrigger: "RT"
        case .leftStickClick: "LS"
        case .rightStickClick: "RS"
        case .view: "View"
        case .menu: "Menu"
        case .guide: "Xbox"
        case .share: "Share"
        case .dpadUp: "↑"
        case .dpadRight: "→"
        case .dpadDown: "↓"
        case .dpadLeft: "←"
        case .leftStick: "Left stick"
        case .rightStick: "Right stick"
        }
    }
    var displayName: String {
        switch self {
        case .leftBumper: "Left bumper"
        case .rightBumper: "Right bumper"
        case .leftTrigger: "Left trigger"
        case .rightTrigger: "Right trigger"
        case .leftStickClick: "Left stick click"
        case .rightStickClick: "Right stick click"
        case .dpadUp: "D-pad up"
        case .dpadRight: "D-pad right"
        case .dpadDown: "D-pad down"
        case .dpadLeft: "D-pad left"
        default: shortLabel
        }
    }
}

func validateProfileName(_ name: String) throws {
    guard (1...64).contains(name.count), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ControllerProfileError.invalidName
    }
}
private struct ProfileKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
func profileKeys(_ decoder: Decoder, _ expected: Set<String>, optional: Set<String> = []) throws {
    let values = try decoder.container(keyedBy: ProfileKey.self)
    let actual = Set(values.allKeys.map(\.stringValue))
    guard expected.isSubset(of: actual), actual.isSubset(of: expected.union(optional)) else { throw ControllerProfileError.invalidFormat }
}
