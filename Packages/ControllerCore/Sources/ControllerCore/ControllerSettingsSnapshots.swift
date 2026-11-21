import Foundation

/// Detached settings only. Applying a preset never changes control identity or placement.
public enum StickPresetApplyScope: String, Codable, CaseIterable, Sendable { case settingsOnly, settingsAndMode }
public enum ButtonAimPresetApplyScope: String, Codable, CaseIterable, Sendable { case tuningOnly, complete }
public enum StickPresetMode: String, Codable, CaseIterable, Sendable { case directional, stickPlus }
public struct SettingsPresetError: Error, LocalizedError, Equatable, Sendable {
    public let message:String
    public init(_ message:String) { self.message=message }
    public var errorDescription:String? { message }
}

public struct StickDirectionalPreset: Codable, Equatable, Sendable {
    public var mode: StickPresetMode
    public var boostThreshold: Double
    public var superBoostThreshold: Double
    public var directions: [StickDirection: StickDirectionMapping]
    public var directionPayloads: [StickDirection: StickDirectionPayloads]
    public var extendedBoost: ExtendedBoostSettings
    public var stickPlusEdgeRearmHysteresis: Double?
    public init(mode: StickPresetMode, boostThreshold: Double, superBoostThreshold: Double, directions: [StickDirection: StickDirectionMapping], directionPayloads: [StickDirection: StickDirectionPayloads], extendedBoost: ExtendedBoostSettings = .init(), stickPlusEdgeRearmHysteresis: Double? = nil) {
        self.mode=mode
        self.boostThreshold=boostThreshold
        self.superBoostThreshold=superBoostThreshold
        self.directions=directions
        self.directionPayloads=directionPayloads
        self.extendedBoost=extendedBoost
        self.stickPlusEdgeRearmHysteresis=stickPlusEdgeRearmHysteresis
    }

    public static func capture(_ control:ProfileControl)throws->Self {
        try control.validate()
        guard control.kind.isStick,control.directionalEnabled != control.stickBehavior.stickPlusEnabled else { throw SettingsPresetError("Save directional settings from a Directional or Stick+ control.") }
        let b=control.stickBehavior
        let result=Self(mode:control.directionalEnabled ? .directional:.stickPlus,boostThreshold:b.boostThreshold,superBoostThreshold:b.superBoostThreshold,directions:b.directions,directionPayloads:control.directionPayloads,extendedBoost:control.extendedBoost,stickPlusEdgeRearmHysteresis:control.stickPlusEdgeRearmHysteresis)
        try result.validate();return result
    }
    public func validate()throws {
        let b=StickBehavior(boostThreshold:boostThreshold,superBoostThreshold:superBoostThreshold,directions:directions)
        let control=ProfileControl(kind:.leftStick,stickBehavior:b,directionPayloads:directionPayloads,extendedBoost:extendedBoost,stickPlusEdgeRearmHysteresis:stickPlusEdgeRearmHysteresis)
        try control.validate()
    }
    public func apply(to target:inout ProfileControl,scope:StickPresetApplyScope)throws {
        try validate();try target.validate();guard target.kind.isStick else { throw SettingsPresetError("Directional presets apply to sticks only.") }
        var next=target
        next.stickBehavior.boostThreshold=boostThreshold;next.stickBehavior.superBoostThreshold=superBoostThreshold
        next.stickBehavior.directions=directions;next.directionPayloads=directionPayloads;next.extendedBoost=extendedBoost
        next.stickPlusEdgeRearmHysteresis=stickPlusEdgeRearmHysteresis
        if scope == .settingsAndMode { next.directionalEnabled=mode == .directional;next.stickBehavior.stickPlusEnabled=mode == .stickPlus }
        try next.validate();target=next
    }

    private enum CodingKeys:String,CodingKey { case mode, boostThreshold, superBoostThreshold, directions, directionPayloads, extendedBoost, stickPlusEdgeRearmHysteresis }
    public init(from decoder:Decoder)throws {
        try profileKeys(decoder,["mode","boostThreshold","superBoostThreshold","directions","directionPayloads","extendedBoost"],optional:["stickPlusEdgeRearmHysteresis"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        mode=try c.decode(StickPresetMode.self,forKey:.mode)
        boostThreshold=try c.decode(Double.self,forKey:.boostThreshold)
        superBoostThreshold=try c.decode(Double.self,forKey:.superBoostThreshold)
        let directionsValues=try c.decode([String: StickDirectionMapping].self,forKey:.directions)
        guard Set(directionsValues.keys)==Set(StickDirection.allCases.map(\.rawValue)) else { throw SettingsPresetError("Every direction must appear exactly once.") }
        directions=Dictionary(uniqueKeysWithValues:directionsValues.map { (StickDirection(rawValue:$0.key)!,$0.value) })
        let directionPayloadsValues=try c.decode([String: StickDirectionPayloads].self,forKey:.directionPayloads)
        guard Set(directionPayloadsValues.keys)==Set(StickDirection.allCases.map(\.rawValue)) else { throw SettingsPresetError("Every direction must appear exactly once.") }
        directionPayloads=Dictionary(uniqueKeysWithValues:directionPayloadsValues.map { (StickDirection(rawValue:$0.key)!,$0.value) })
        extendedBoost=try c.decode(ExtendedBoostSettings.self,forKey:.extendedBoost)
        stickPlusEdgeRearmHysteresis=try c.decodeIfPresent(Double.self,forKey:.stickPlusEdgeRearmHysteresis)
        try validate()
    }
    public func encode(to encoder:Encoder)throws {
        try validate();var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(mode,forKey:.mode)
        try c.encode(boostThreshold,forKey:.boostThreshold)
        try c.encode(superBoostThreshold,forKey:.superBoostThreshold)
        try c.encode(Dictionary(uniqueKeysWithValues:directions.map { ($0.key.rawValue,$0.value) }),forKey:.directions)
        try c.encode(Dictionary(uniqueKeysWithValues:directionPayloads.map { ($0.key.rawValue,$0.value) }),forKey:.directionPayloads)
        try c.encode(extendedBoost,forKey:.extendedBoost)
        try c.encodeIfPresent(stickPlusEdgeRearmHysteresis,forKey:.stickPlusEdgeRearmHysteresis)
    }
}

public struct ButtonAimPreset: Codable, Equatable, Sendable {
    public var actions: Set<ControllerControlID>
    public var payload: String?
    public var buttonBehavior: ButtonBehavior
    public var settings: ButtonAimSettings
    public init(actions: Set<ControllerControlID> = [], payload: String? = nil, buttonBehavior: ButtonBehavior = .init(), settings: ButtonAimSettings = .init()) {
        self.actions=actions
        self.payload=payload
        self.buttonBehavior=buttonBehavior
        self.settings=settings
    }

    public static func capture(_ control:ProfileControl)throws->Self {
        try control.validate();guard control.kind == .button else { throw SettingsPresetError("Button Aim presets apply to buttons only.") }
        let result=Self(actions:control.actions,payload:control.payload,buttonBehavior:control.buttonBehavior,settings:control.buttonAim)
        try result.validate();return result
    }
    public func validate()throws {
        var s=settings;s.enabled=true
        try ProfileControl(actions:actions,buttonBehavior:buttonBehavior,payload:payload,buttonAim:s).validate()
    }
    public func apply(to target:inout ProfileControl,scope:ButtonAimPresetApplyScope)throws {
        try validate();try target.validate();guard target.kind == .button else { throw SettingsPresetError("Button Aim presets apply to buttons only.") }
        var next=target
        if scope == .complete { next.buttonAim=settings;next.actions=actions;next.payload=payload;next.buttonBehavior=buttonBehavior }
        else { next.buttonAim.tuning=settings.tuning;next.buttonAim.alternate.tuning=settings.alternate.tuning }
        next.buttonAim.enabled=true;next.autoTapEnabled=false;next.macroModeEnabled=false
        try next.validate();target=next
    }

    private enum CodingKeys:String,CodingKey { case actions, payload, buttonBehavior, settings }
    public init(from decoder:Decoder)throws {
        try profileKeys(decoder,["actions","payload","buttonBehavior","settings"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let values=try c.decode([ControllerControlID].self,forKey:.actions)
        actions=Set(values)
        guard actions.count==values.count else { throw SettingsPresetError("Preset actions contain duplicates.") }
        payload=try c.decodeIfPresent(String.self,forKey:.payload)
        buttonBehavior=try c.decode(ButtonBehavior.self,forKey:.buttonBehavior)
        settings=try c.decode(ButtonAimSettings.self,forKey:.settings)
        try validate()
    }
    public func encode(to encoder:Encoder)throws {
        try validate();var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(actions.sorted{$0.rawValue<$1.rawValue},forKey:.actions)
        try c.encode(payload,forKey:.payload)
        try c.encode(buttonBehavior,forKey:.buttonBehavior)
        try c.encode(settings,forKey:.settings)
    }
}

public struct TouchAimManualPreset: Codable, Equatable, Sendable {
    public var mode: TouchAimMode
    public var metric: TouchAimMetric
    public var metricScale: Double
    public var aim: ButtonAimTuning
    public var threeStage: TouchAimThreeStageSettings?
    public var twoState: TouchAimTwoStateSettings?
    public init(mode: TouchAimMode, metric: TouchAimMetric, metricScale: Double, aim: ButtonAimTuning, threeStage: TouchAimThreeStageSettings? = nil, twoState: TouchAimTwoStateSettings? = nil) {
        self.mode=mode
        self.metric=metric
        self.metricScale=metricScale
        self.aim=aim
        self.threeStage=threeStage
        self.twoState=twoState
    }

    public static func capture(_ control:ProfileControl)throws->Self {
        try control.validate();guard control.isTouchAim,control.touchAim.mode != .calibratedTwoState else { throw SettingsPresetError("Save a manual preset from a manual Touch Aim control. Calibrations have their own library.") }
        guard !control.touchAim.requiresLocalSetup else { throw SettingsPresetError("Complete local Touch Aim setup before saving these manual settings as a preset.") }
        let s=control.touchAim
        let result=Self(mode:s.mode,metric:s.metric,metricScale:s.metricScale,aim:s.aim,threeStage:s.mode == .manualThreeStage ? s.threeStage:nil,twoState:s.mode == .manualTwoState ? s.twoState:nil)
        try result.validate();return result
    }
    public func validate()throws {
        guard (mode == .manualThreeStage && threeStage != nil && twoState == nil) || (mode == .manualTwoState && twoState != nil && threeStage == nil) else { throw SettingsPresetError("A manual Touch Aim preset must contain exactly its selected manual mode.") }
        try TouchAimSettings(mode:mode,metric:metric,metricScale:metricScale,aim:aim,threeStage:threeStage ?? .init(),twoState:twoState ?? .init()).validate()
    }
    public func apply(to target:inout ProfileControl)throws {
        try validate();try target.validate();guard target.isTouchAim else { throw SettingsPresetError("Manual Touch Aim presets apply to Touch Aim controls only.") }
        var next=target
        next.touchAim.mode=mode;next.touchAim.metric=metric;next.touchAim.metricScale=metricScale;next.touchAim.aim=aim
        if let threeStage { next.touchAim.threeStage=threeStage };if let twoState { next.touchAim.twoState=twoState }
        next.touchAim.calibration=nil
        try next.validate();target=next
    }

    private enum CodingKeys:String,CodingKey { case mode, metric, metricScale, aim, threeStage, twoState }
    public init(from decoder:Decoder)throws {
        try profileKeys(decoder,["mode","metric","metricScale","aim","threeStage","twoState"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        mode=try c.decode(TouchAimMode.self,forKey:.mode)
        metric=try c.decode(TouchAimMetric.self,forKey:.metric)
        metricScale=try c.decode(Double.self,forKey:.metricScale)
        aim=try c.decode(ButtonAimTuning.self,forKey:.aim)
        threeStage=try c.decodeIfPresent(TouchAimThreeStageSettings.self,forKey:.threeStage)
        twoState=try c.decodeIfPresent(TouchAimTwoStateSettings.self,forKey:.twoState)
        try validate()
    }
    public func encode(to encoder:Encoder)throws {
        try validate();var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(mode,forKey:.mode)
        try c.encode(metric,forKey:.metric)
        try c.encode(metricScale,forKey:.metricScale)
        try c.encode(aim,forKey:.aim)
        try c.encode(threeStage,forKey:.threeStage)
        try c.encode(twoState,forKey:.twoState)
    }
}

public struct FloatingBoostPreset: Codable, Equatable, Sendable {
    public var boost1: RingBoostSettings
    public var boost2: RingBoostSettings
    public var aim: RingAimSettings?
    public var knobActions: [RingFireSettings]?
    public init(boost1: RingBoostSettings, boost2: RingBoostSettings, aim: RingAimSettings? = nil, knobActions: [RingFireSettings]? = nil) {
        self.boost1=boost1
        self.boost2=boost2
        self.aim=aim
        self.knobActions=knobActions
    }

    public static func capture(_ config:FloatingRingConfig,includeAimActions:Bool=false,bank:RingBoostBank?=nil)throws->Self {
        try config.validate()
        guard bank != nil || config.boostBanks?.enabled != true else { throw SettingsPresetError("Choose movement or aim when saving separate boost actions.") }
        let selected = bank.map { config.seededBoostBanks()[$0] }
        let result=Self(boost1:selected?.boost1 ?? config.boost1,boost2:selected?.boost2 ?? config.boost2,aim:includeAimActions ? config.aim:nil,knobActions:includeAimActions ? config.knobs.map(\.fire):nil)
        try result.validate();return result
    }
    public func validate()throws {
        try boost1.validate();try boost2.validate()
        guard boost1.activationDelayMilliseconds==0,!boost1.skipDelayOnDirectTouch,boost2.distance>boost1.distance,boost1.directOuterDistance<=boost2.directInnerDistance else { throw SettingsPresetError("Saved Boost stages must remain ordered; only Boost 2 can delay activation.") }
        guard (aim == nil) == (knobActions == nil) else { throw SettingsPresetError("Saved ring aim settings and action slots must appear together.") }
        if let aim,let knobActions { try aim.validate();guard (1...3).contains(knobActions.count) else { throw SettingsPresetError("Ring aim presets need one to three action slots.") };for action in knobActions { try action.validate() } }
    }
    public func applyBoostSettings(to target:inout FloatingRingConfig,bank:RingBoostBank?=nil)throws {
        try validate();try target.validate();var next=target
        if let bank {
            var banks = next.seededBoostBanks(), selected = banks[bank]
            let firstEnabled = selected.boost1.enabled, secondEnabled = selected.boost2.enabled
            selected.boost1 = boost1; selected.boost1.enabled = firstEnabled
            selected.boost2 = boost2; selected.boost2.enabled = secondEnabled
            banks[bank] = selected; next.boostBanks = banks
        } else {
            guard target.boostBanks?.enabled != true else { throw SettingsPresetError("Choose movement or aim when applying separate boost actions.") }
            next.boost1=boost1;next.boost1.enabled=target.boost1.enabled
            next.boost2=boost2;next.boost2.enabled=target.boost2.enabled
        }
        try next.validate();target=next
    }
    public func applyAimActions(to target:inout FloatingRingConfig)throws {
        try validate();try target.validate()
        guard let aim,let knobActions,knobActions.count==target.knobs.count else { throw SettingsPresetError("The saved ring aim action count must match the target's knob count.") }
        var next=target;next.aim=aim;next.aim.enabled=target.aim.enabled
        for i in next.knobs.indices { next.knobs[i].fire=knobActions[i] }
        try next.validate();target=next
    }

    private enum CodingKeys:String,CodingKey { case boost1, boost2, aim, knobActions }
    public init(from decoder:Decoder)throws {
        try profileKeys(decoder,["boost1","boost2","aim","knobActions"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        boost1=try c.decode(RingBoostSettings.self,forKey:.boost1)
        boost2=try c.decode(RingBoostSettings.self,forKey:.boost2)
        aim=try c.decodeIfPresent(RingAimSettings.self,forKey:.aim)
        knobActions=try c.decodeIfPresent([RingFireSettings].self,forKey:.knobActions)
        try validate()
    }
    public func encode(to encoder:Encoder)throws {
        try validate();var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(boost1,forKey:.boost1)
        try c.encode(boost2,forKey:.boost2)
        try c.encode(aim,forKey:.aim)
        try c.encode(knobActions,forKey:.knobActions)
    }
}

