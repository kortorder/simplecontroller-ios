import Foundation

/// Saved dimensions in iOS points. Canvas fitting must not rewrite these values.
public struct ProfileControlDimensions: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public func validate(minimum: Double = 44) throws {
        guard minimum.isFinite, (44...1_200).contains(minimum), width.isFinite, height.isFinite,
              (minimum...1_200).contains(width),
              (minimum...1_200).contains(height) else { throw ControllerProfileError.invalidDiameter }
    }
    private enum CodingKeys: String, CodingKey { case width, height }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["width", "height"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Double.self, forKey: .width); height = try c.decode(Double.self, forKey: .height)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
    }
}

/// A nil entry uses the unchanged shared size, including for all pre-format19 profiles.
public struct ProfileOrientationDimensions: Codable, Equatable, Sendable {
    public var portrait: ProfileControlDimensions?
    public var landscape: ProfileControlDimensions?
    public init(portrait: ProfileControlDimensions? = nil, landscape: ProfileControlDimensions? = nil) {
        self.portrait = portrait; self.landscape = landscape
    }
    public var isEmpty: Bool { portrait == nil && landscape == nil }
    public func dimensions(for orientation: ControllerOrientation) -> ProfileControlDimensions? {
        orientation == .portrait ? portrait : landscape
    }
    public mutating func set(_ dimensions: ProfileControlDimensions?, for orientation: ControllerOrientation) {
        if orientation == .portrait { portrait = dimensions } else { landscape = dimensions }
    }
    public func validate(minimum: Double = 44) throws {
        try portrait?.validate(minimum: minimum); try landscape?.validate(minimum: minimum)
    }
    private enum CodingKeys: String, CodingKey { case portrait, landscape }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["portrait", "landscape"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.portrait), c.contains(.landscape) else { throw ControllerProfileError.invalidFormat }
        portrait = try c.decodeIfPresent(ProfileControlDimensions.self, forKey: .portrait)
        landscape = try c.decodeIfPresent(ProfileControlDimensions.self, forKey: .landscape)
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(portrait, forKey: .portrait); try c.encode(landscape, forKey: .landscape)
    }
}

public extension ProfileControl {
    func dimensions(for orientation: ControllerOrientation) -> ProfileControlDimensions {
        orientationDimensions.dimensions(for: orientation) ?? .init(width: resolvedWidth, height: resolvedHeight)
    }
}
