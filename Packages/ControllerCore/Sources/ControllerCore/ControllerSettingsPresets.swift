import Foundation

public enum SettingsPresetCategory:String,Codable,CaseIterable,Sendable {
    case stickDirectional,buttonAim,touchAimManual,touchCalibration,floatingBoost,floatingRing
}

/// Tagged, version-independent snapshots. Unknown categories/fields fail before any merge.
public enum SettingsPresetValue:Equatable,Sendable,Codable {
    case stickDirectional(StickDirectionalPreset)
    case buttonAim(ButtonAimPreset)
    case touchAimManual(TouchAimManualPreset)
    case touchCalibration(TouchAimCalibrationProfile)
    case floatingBoost(FloatingBoostPreset)
    case floatingRing(FloatingRingZone)
    public var category:SettingsPresetCategory {
        switch self {
        case .stickDirectional:.stickDirectional;case .buttonAim:.buttonAim;case .touchAimManual:.touchAimManual
        case .touchCalibration:.touchCalibration;case .floatingBoost:.floatingBoost;case .floatingRing:.floatingRing
        }
    }
    /// A library of older presets can still be opened by earlier iPhone releases.
    var requiredWireVersion: Int {
        func version(_ sources: [String], expanded: Bool = false) -> Int {
            if sources.contains(where: { (try? ControllerPayloadProgram.parse($0).autoCenterCommand) != nil }) { return 4 }
            let modifier = sources.map(AndroidTimingFormat.payloadVersion).max() ?? 1
            return modifier >= 17 ? 3 : modifier >= 14 || expanded ? 2 : 1
        }
        switch self {
        case let .stickDirectional(stick):
            if stick.stickPlusEdgeRearmHysteresis != nil { return 4 }
            let directions = stick.directionPayloads.values.flatMap { [$0.normalPayload, $0.boostPayload, $0.superBoostPayload].compactMap { $0 } }
            return version(directions + stick.extendedBoost.directions.values.compactMap(\.outerPayload))
        case let .buttonAim(button):
            return version([button.payload ?? "", button.settings.alternate.payload])
        case let .touchAimManual(touch):
            let stages = touch.threeStage
            let sources = stages.map { [$0.low.payload, $0.medium.payload, $0.high.payload] } ?? []
            let alternate = touch.twoState.map { [$0.aimPayload, $0.shootPayload] } ?? []
            return version(sources + alternate, expanded: stages?.hasStageTuning == true)
        case let .floatingBoost(preset):
            let boosts = [preset.boost1, preset.boost2]
            let fire = preset.knobActions ?? []
            return version(boosts.flatMap { [$0.payload] + $0.directionalPayloads.values } + fire.flatMap { [$0.adsPayload, $0.firePayload] },
                expanded: boosts.contains(where: \.skipDelayOnDirectTouch) || fire.contains { $0.returnFire.startOnBoostEntry })
        case let .floatingRing(zone):
            if zone.config.minimumCommandModifierVersion >= 17 { return 3 }
            return zone.finishIgnoresSwipes || zone.config.hasExpandedRingOptions || zone.config.usesCommandModifiers ? 2 : 1
        case .touchCalibration:
            return 1
        }
    }
    public func validate()throws {
        switch self {
        case let .stickDirectional(value):try value.validate()
        case let .buttonAim(value):try value.validate()
        case let .touchAimManual(value):try value.validate()
        case let .touchCalibration(value):
            try value.validate()
            guard !value.transforms.isEmpty,value.quality == .good || value.quality == .borderline else { throw SettingsPresetError("Save a usable native calibration; unreliable recordings cannot become presets.") }
        case let .floatingBoost(value):try value.validate()
        case let .floatingRing(value):try value.validate()
        }
    }
    public static func captureCalibration(_ profile:TouchAimCalibrationProfile)throws->Self {
        guard profile.isApplicable else { throw SettingsPresetError("Complete local no-output validation before saving this calibration.") }
        return .touchCalibration(profile)
    }
    public func applyCalibration(to target:inout ProfileControl)throws {
        guard case let .touchCalibration(profile)=self,profile.isApplicable else { throw SettingsPresetError("Validate this saved calibration on this phone before applying it.") }
        try target.validate();guard target.isTouchAim else { throw SettingsPresetError("Calibration applies to Touch Aim controls only.") }
        var next=target;next.touchAim.calibration=profile;next.touchAim.mode = .calibratedTwoState
        next.touchAim.requiresLocalSetup=false
        try next.validate();target=next
    }
    public func instantiateRing(name:String?=nil,id:UUID=UUID())throws->FloatingRingZone {
        guard case let .floatingRing(template)=self else { throw SettingsPresetError("Choose a complete floating ring preset.") }
        try template.validate();guard id != template.id else { throw SettingsPresetError("A new ring must have a fresh identity.") }
        var copy=template.replacingID(id)
        if let name { copy.name=name }
        try copy.validate();return copy
    }
    /// This is required for imported presets; ordinary loading of local saved data does not call it.
    public func requiringLocalCalibrationValidation()->Self {
        guard case var .touchCalibration(profile)=self else { return self }
        profile.validationCompleted=false
        return .touchCalibration(profile)
    }
    private enum CodingKeys:String,CodingKey { case category,settings }
    public init(from decoder:Decoder)throws {
        try profileKeys(decoder,["category","settings"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        switch try c.decode(SettingsPresetCategory.self,forKey:.category) {
        case .stickDirectional:self = .stickDirectional(try c.decode(StickDirectionalPreset.self,forKey:.settings))
        case .buttonAim:self = .buttonAim(try c.decode(ButtonAimPreset.self,forKey:.settings))
        case .touchAimManual:self = .touchAimManual(try c.decode(TouchAimManualPreset.self,forKey:.settings))
        case .touchCalibration:self = .touchCalibration(try c.decode(TouchAimCalibrationProfile.self,forKey:.settings))
        case .floatingBoost:self = .floatingBoost(try c.decode(FloatingBoostPreset.self,forKey:.settings))
        case .floatingRing:self = .floatingRing(try c.decode(FloatingRingZone.self,forKey:.settings))
        }
        try validate()
    }
    public func encode(to encoder:Encoder)throws {
        try validate();var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(category,forKey:.category)
        switch self {
        case let .stickDirectional(value):try c.encode(value,forKey:.settings)
        case let .buttonAim(value):try c.encode(value,forKey:.settings)
        case let .touchAimManual(value):try c.encode(value,forKey:.settings)
        case let .touchCalibration(value):try c.encode(value,forKey:.settings)
        case let .floatingBoost(value):try c.encode(value,forKey:.settings)
        case let .floatingRing(value):try c.encode(value,forKey:.settings)
        }
    }
}

public struct SettingsPreset:Identifiable,Codable,Equatable,Sendable {
    public var id:UUID
    public var name:String
    public var createdAtMilliseconds:Int64
    public var updatedAtMilliseconds:Int64
    public var value:SettingsPresetValue
    public var category:SettingsPresetCategory { value.category }
    public init(id:UUID=UUID(),name:String,createdAtMilliseconds:Int64,updatedAtMilliseconds:Int64?=nil,value:SettingsPresetValue) {
        self.id=id;self.name=name;self.createdAtMilliseconds=createdAtMilliseconds
        self.updatedAtMilliseconds=updatedAtMilliseconds ?? createdAtMilliseconds;self.value=value
    }
    public static func capture(_ control:ProfileControl,category:SettingsPresetCategory,name:String,at milliseconds:Int64)throws->Self {
        let value:SettingsPresetValue
        switch category {
        case .stickDirectional:value = .stickDirectional(try .capture(control))
        case .buttonAim:value = .buttonAim(try .capture(control))
        case .touchAimManual:value = .touchAimManual(try .capture(control))
        case .touchCalibration:
            guard control.isTouchAim,let calibration=control.touchAim.calibration else { throw SettingsPresetError("This control has no saved native calibration.") }
            guard !control.touchAim.requiresLocalSetup else { throw SettingsPresetError("Complete local Touch Aim setup before saving this calibration as a preset.") }
            value=try .captureCalibration(calibration)
        case .floatingBoost,.floatingRing:throw SettingsPresetError("Capture floating settings from the selected ring.")
        }
        let preset=Self(name:name.trimmingCharacters(in:.whitespacesAndNewlines),createdAtMilliseconds:milliseconds,value:value)
        try preset.validate();return preset
    }
    public func validate()throws {
        try validateProfileName(name)
        guard name==name.trimmingCharacters(in:.whitespacesAndNewlines),createdAtMilliseconds>=0,
              updatedAtMilliseconds>=createdAtMilliseconds,updatedAtMilliseconds<=253_402_300_799_999 else { throw SettingsPresetError("Preset names must be trimmed and timestamps must be valid and ordered.") }
        try value.validate()
    }
    private enum CodingKeys:String,CodingKey { case id,name,createdAtMilliseconds,updatedAtMilliseconds,value }
    public init(from decoder:Decoder)throws {
        try profileKeys(decoder,["id","name","createdAtMilliseconds","updatedAtMilliseconds","value"])
        let c=try decoder.container(keyedBy:CodingKeys.self)
        id=try c.decode(UUID.self,forKey:.id);name=try c.decode(String.self,forKey:.name)
        createdAtMilliseconds=try c.decode(Int64.self,forKey:.createdAtMilliseconds);updatedAtMilliseconds=try c.decode(Int64.self,forKey:.updatedAtMilliseconds)
        value=try c.decode(SettingsPresetValue.self,forKey:.value);try validate()
    }
    public func encode(to encoder:Encoder)throws {
        try validate();var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(id,forKey:.id);try c.encode(name,forKey:.name);try c.encode(createdAtMilliseconds,forKey:.createdAtMilliseconds)
        try c.encode(updatedAtMilliseconds,forKey:.updatedAtMilliseconds);try c.encode(value,forKey:.value)
    }
}

public struct SettingsPresetLibrary:Codable,Equatable,Sendable {
    public static let currentVersion=4
    public static let maximumPerCategory=64
    public var version:Int
    public var entries:[SettingsPreset]
    public init(version:Int=currentVersion,entries:[SettingsPreset]=[]) { self.version=version;self.entries=entries }
    public static let empty=SettingsPresetLibrary()
    var wireVersion: Int { entries.map { $0.value.requiredWireVersion }.max() ?? 1 }
    public func validate()throws {
        guard version==Self.currentVersion else { throw SettingsPresetError("This settings library version is not supported. Keep the original file unchanged.") }
        guard entries.count<=Self.maximumPerCategory*SettingsPresetCategory.allCases.count,Set(entries.map(\.id)).count==entries.count else { throw SettingsPresetError("Settings library IDs must be unique and bounded.") }
        var names:[SettingsPresetCategory:Set<String>]=[:]
        for entry in entries {
            try entry.validate();let key=Self.nameKey(entry.name)
            guard names[entry.category,default:[]].insert(key).inserted,names[entry.category]!.count<=Self.maximumPerCategory else { throw SettingsPresetError("Each category allows up to 64 presets with distinct names.") }
        }
    }
    public func orderedEntries(in category:SettingsPresetCategory?=nil)->[SettingsPreset] {
        entries.filter{category == nil || $0.category==category}.sorted {
            $0.updatedAtMilliseconds == $1.updatedAtMilliseconds ? $0.id.uuidString<$1.id.uuidString:$0.updatedAtMilliseconds>$1.updatedAtMilliseconds
        }
    }
    public func entry(_ id:UUID)->SettingsPreset? { entries.first{$0.id==id} }
    public mutating func save(_ entry:SettingsPreset)throws {
        try validate();try entry.validate();var next=self
        if let index=next.entries.firstIndex(where:{$0.id==entry.id}) {
            let previous=next.entries[index]
            guard entry.category==previous.category,entry.createdAtMilliseconds==previous.createdAtMilliseconds,entry.updatedAtMilliseconds>=previous.updatedAtMilliseconds else { throw SettingsPresetError("Replacing a preset must preserve its category and creation time and cannot move its update time backward.") }
            next.entries[index]=entry
        } else { next.entries.append(entry) }
        try next.validate();_ = try SettingsPresetLibraryCodec.encode(next);self=next
    }
    public mutating func rename(_ id:UUID,to name:String,at milliseconds:Int64)throws {
        guard var value=entry(id) else { throw SettingsPresetError("The selected preset no longer exists.") }
        value.name=name.trimmingCharacters(in:.whitespacesAndNewlines);value.updatedAtMilliseconds=milliseconds
        try save(value)
    }
    public mutating func replaceValue(_ id:UUID,with value:SettingsPresetValue,at milliseconds:Int64)throws {
        guard var entry=entry(id) else { throw SettingsPresetError("The selected preset no longer exists.") }
        entry.value=value;entry.updatedAtMilliseconds=milliseconds;try save(entry)
    }
    public mutating func delete(_ id:UUID)throws {
        try validate();guard entry(id) != nil else { throw SettingsPresetError("The selected preset no longer exists.") }
        var next=self;next.entries.removeAll{$0.id==id};try next.validate();self=next
    }
    /// Merge always creates independent preset IDs and names. It never overwrites local settings.
    @discardableResult public mutating func merge(_ imported:Self,at milliseconds:Int64)throws->[UUID:UUID] {
        try validate();try imported.validate();var next=self,mapping:[UUID:UUID]=[:]
        for source in imported.entries {
            var entry=source;entry.id=UUID();entry.createdAtMilliseconds=milliseconds;entry.updatedAtMilliseconds=milliseconds
            entry.value=entry.value.requiringLocalCalibrationValidation()
            let occupied=Set(next.entries.filter{$0.category==entry.category}.map{Self.nameKey($0.name)})
            var number=2
            while occupied.contains(Self.nameKey(entry.name)) {
                let suffix=" (\(number))";entry.name=String(source.name.prefix(64-suffix.count))+suffix;number+=1
            }
            try next.save(entry);mapping[source.id]=entry.id
        }
        try next.validate();self=next;return mapping
    }
    public func requiringLocalCalibrationValidation()throws->Self {
        try validate();var next=self
        for index in next.entries.indices { next.entries[index].value=next.entries[index].value.requiringLocalCalibrationValidation() }
        try next.validate();return next
    }
    private static func nameKey(_ name:String)->String { name.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX")) }
    private enum CodingKeys:String,CodingKey { case version,entries }
    public init(from decoder:Decoder)throws {
        try profileKeys(decoder,["version","entries"]);let c=try decoder.container(keyedBy:CodingKeys.self)
        let sourceVersion=try c.decode(Int.self,forKey:.version)
        guard (1...Self.currentVersion).contains(sourceVersion) else { throw SettingsPresetError("This settings library version is not supported.") }
        version=Self.currentVersion
        entries=try c.decode([SettingsPreset].self,forKey:.entries);try validate()
        guard sourceVersion >= wireVersion else { throw SettingsPresetError("These saved actions require settings library version \(wireVersion).") }
    }
    public func encode(to encoder:Encoder)throws {
        try validate();var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(wireVersion,forKey:.version);try c.encode(entries,forKey:.entries)
    }
}

public enum SettingsPresetLibraryCodec {
    public static let maximumBytes=2*1024*1024
    public static func encode(_ library:SettingsPresetLibrary)throws->Data {
        try library.validate();let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(library);guard data.count<=maximumBytes else { throw SettingsPresetError("The settings library exceeds 2 MiB.") };return data
    }
    public static func decode(_ data:Data)throws->SettingsPresetLibrary {
        guard !data.isEmpty,data.count<=maximumBytes else { throw SettingsPresetError("The settings library is empty or exceeds 2 MiB.") }
        return try JSONDecoder().decode(SettingsPresetLibrary.self,from:data)
    }
}

extension ControllerProfile {
    /// Import-only normalization; never apply this to ordinary loading of saved local profiles.
    /// Keep calibration evidence while requiring a fresh local validation before sensor-driven use.
    public func requiringLocalTouchCalibrationValidation()throws->Self {
        try validate();var next=self
        for index in next.controls.indices {
            if next.controls[index].touchAim.calibration != nil {
                next.controls[index].touchAim.calibration!.validationCompleted=false
                next.controls[index].touchAim.requiresLocalSetup=true
            }
            if next.controls[index].touchAim.mode == .calibratedTwoState {
                next.controls[index].touchAim.requiresLocalSetup=true
                next.controls[index].touchAim.mode = .manualTwoState
            }
        }
        try next.validate();return next
    }
}

extension ControllerProfileLibrary {
    public func requiringLocalTouchCalibrationValidation()throws->Self {
        try validate();var next=self
        next.profiles=try next.profiles.map { try $0.requiringLocalTouchCalibrationValidation() }
        next.settingsPresets=try next.settingsPresets.requiringLocalCalibrationValidation()
        try next.validate();return next
    }
}
