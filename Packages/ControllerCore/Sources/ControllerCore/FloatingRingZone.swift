import Foundation

/// A page-owned saved template. Knob IDs are stable slots inside this zone, not global owners.
public struct FloatingRingZone: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var portraitGeometry: FloatingZoneGeometry?
    public var landscapeGeometry: FloatingZoneGeometry?
    public var config: FloatingRingConfig
    public var finishIgnoresSwipes: Bool = false
    public init(id: UUID = UUID(), name: String = "Floating ring", enabled: Bool = true,
                portraitGeometry: FloatingZoneGeometry? = nil, landscapeGeometry: FloatingZoneGeometry? = nil,
                config: FloatingRingConfig = .init()) {
        self.id = id; self.name = name; self.enabled = enabled
        self.portraitGeometry = portraitGeometry; self.landscapeGeometry = landscapeGeometry; self.config = config
    }
    public func geometry(for orientation: ControllerOrientation) -> FloatingZoneGeometry? {
        orientation == .portrait ? portraitGeometry : landscapeGeometry
    }
    public func replacingID(_ id: UUID = UUID()) -> Self { var copy = self; copy.id = id; return copy }
    public func validate() throws {
        guard (1...64).contains(name.count), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              portraitGeometry != nil || landscapeGeometry != nil else {
            throw FloatingControlError("A floating ring needs a name and saved activation geometry.")
        }
        try portraitGeometry?.validate(); try landscapeGeometry?.validate(); try config.validate()
    }
    private enum CodingKeys: String, CodingKey { case id, name, enabled, portraitGeometry, landscapeGeometry, config, finishIgnoresSwipes }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["id", "name", "enabled", "portraitGeometry", "landscapeGeometry", "config"], optional: ["finishIgnoresSwipes"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        finishIgnoresSwipes = try c.decodeIfPresent(Bool.self, forKey: .finishIgnoresSwipes) ?? false
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        portraitGeometry = try c.decodeIfPresent(FloatingZoneGeometry.self, forKey: .portraitGeometry)
        landscapeGeometry = try c.decodeIfPresent(FloatingZoneGeometry.self, forKey: .landscapeGeometry)
        config = try c.decode(FloatingRingConfig.self, forKey: .config); try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        if finishIgnoresSwipes { try c.encode(true, forKey: .finishIgnoresSwipes) }
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(enabled, forKey: .enabled)
        if let portraitGeometry { try c.encode(portraitGeometry, forKey: .portraitGeometry) } else { try c.encodeNil(forKey: .portraitGeometry) }
        if let landscapeGeometry { try c.encode(landscapeGeometry, forKey: .landscapeGeometry) } else { try c.encodeNil(forKey: .landscapeGeometry) }
        try c.encode(config, forKey: .config)
    }
}
