import Foundation

public struct FloatingControlError: Error, Equatable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// UIKit-point coordinates: +X right, +Y down. No screen scale or Android density is assumed.
public struct FloatingPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isValid: Bool { x.isFinite && y.isFinite && abs(x) <= 131_072 && abs(y) <= 131_072 }
}

public struct FloatingRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && abs(x) <= 65_536 && abs(y) <= 65_536 &&
        width > 0 && height > 0 && width <= 65_536 && height <= 65_536
    }
    public var center: FloatingPoint { .init(x: x + width / 2, y: y + height / 2) }
    public func contains(_ point: FloatingPoint) -> Bool {
        isValid && point.isValid && point.x >= x && point.y >= y && point.x <= x + width && point.y <= y + height
    }
    public func contains(_ other: FloatingRect) -> Bool {
        other.isValid && contains(.init(x: other.x, y: other.y)) &&
        contains(.init(x: other.x + other.width, y: other.y + other.height))
    }
    public func translated(x offsetX: Double, y offsetY: Double) -> FloatingRect {
        .init(x: x + offsetX, y: y + offsetY, width: width, height: height)
    }
    public func validate() throws {
        guard isValid else { throw FloatingControlError("Floating rectangles need finite coordinates and positive dimensions.") }
    }
    private enum CodingKeys: String, CodingKey { case x, y, width, height }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["x", "y", "width", "height"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width); height = try c.decode(Double.self, forKey: .height)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width); try c.encode(height, forKey: .height)
    }
}

/// Only the activation region scales with the saved canvas. Member target sizes do not.
public struct FloatingZoneGeometry: Codable, Equatable, Sendable {
    public var canvasWidth: Double
    public var canvasHeight: Double
    public var zone: FloatingRect
    public init(canvasWidth: Double, canvasHeight: Double, zone: FloatingRect) {
        self.canvasWidth = canvasWidth; self.canvasHeight = canvasHeight; self.zone = zone
    }
    public func validate() throws {
        try zone.validate()
        guard canvasWidth.isFinite, canvasHeight.isFinite, (0...65_536).contains(canvasWidth),
              (0...65_536).contains(canvasHeight) else { throw FloatingControlError("Saved floating canvas dimensions are invalid.") }
    }
    public func resolved(canvasWidth width: Double, canvasHeight height: Double) throws -> FloatingRect {
        try validate()
        guard width.isFinite, height.isFinite, (1...65_536).contains(width), (1...65_536).contains(height) else {
            throw FloatingControlError("The current floating canvas has no usable size.")
        }
        let sx = canvasWidth > 0 ? width / canvasWidth : 1
        let sy = canvasHeight > 0 ? height / canvasHeight : 1
        let result = FloatingRect(x: zone.x * sx, y: zone.y * sy, width: zone.width * sx, height: zone.height * sy)
        try result.validate(); return result
    }
    private enum CodingKeys: String, CodingKey { case canvasWidth, canvasHeight, zone }
    public init(from decoder: Decoder) throws {
        try profileKeys(decoder, ["canvasWidth", "canvasHeight", "zone"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canvasWidth = try c.decode(Double.self, forKey: .canvasWidth)
        canvasHeight = try c.decode(Double.self, forKey: .canvasHeight)
        zone = try c.decode(FloatingRect.self, forKey: .zone); try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(canvasWidth, forKey: .canvasWidth); try c.encode(canvasHeight, forKey: .canvasHeight)
        try c.encode(zone, forKey: .zone)
    }
}

public struct FloatingPlacement: Equatable, Sendable {
    public let origin: FloatingPoint
    public let grabOffset: FloatingPoint
}

public enum FloatingGeometry {
    /// Refuse an arrangement that does not fit. Never shrink target sizes or spacing.
    public static func place(width: Double, height: Double, anchor: FloatingPoint,
                             touch: FloatingPoint, usable: FloatingRect) -> FloatingPlacement? {
        guard width.isFinite, height.isFinite, width > 0, height > 0, usable.isValid,
              anchor.isValid, touch.isValid, width <= usable.width, height <= usable.height else { return nil }
        let desired = FloatingPoint(x: touch.x - anchor.x, y: touch.y - anchor.y)
        let origin = FloatingPoint(x: min(max(desired.x, usable.x), usable.x + usable.width - width),
                                   y: min(max(desired.y, usable.y), usable.y + usable.height - height))
        let offset = FloatingPoint(x: desired.x - origin.x, y: desired.y - origin.y)
        guard origin.isValid, offset.isValid else { return nil }
        return .init(origin: origin, grabOffset: offset)
    }
    public static func bounds(of members: [FloatingRect]) -> FloatingRect? {
        guard let first = members.first, members.allSatisfy(\.isValid) else { return nil }
        let x = members.map(\.x).min() ?? first.x
        let y = members.map(\.y).min() ?? first.y
        let maxX = members.map { $0.x + $0.width }.max()!
        let maxY = members.map { $0.y + $0.height }.max()!
        let result = FloatingRect(x: x, y: y, width: maxX - x, height: maxY - y)
        return result.isValid ? result : nil
    }
}

/// A clamped summon that starts over Finish must leave before entering intentionally.
public struct FloatingFinishEntryGuard: Equatable, Sendable {
    public private(set) var eligible: Bool
    public init(initiallyInside: Bool = false) { eligible = !initiallyInside }
    public mutating func observe(inside: Bool) -> Bool {
        if !inside { eligible = true; return false }
        return eligible
    }
}
