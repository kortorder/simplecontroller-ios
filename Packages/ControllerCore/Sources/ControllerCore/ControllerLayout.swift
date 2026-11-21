import Foundation

/// Stable saved-layout identifiers. Stick clicks and stick surfaces are independent.
public enum ControllerControlID: String, CaseIterable, Codable, Sendable {
    case a, b, x, y
    case leftBumper, rightBumper, leftTrigger, rightTrigger
    case leftStickClick, rightStickClick, view, menu, guide, share
    case dpadUp, dpadRight, dpadDown, dpadLeft, leftStick, rightStick

    public var isStick: Bool { self == .leftStick || self == .rightStick }
    public var minimumDiameter: Double { isStick ? 104 : 44 }
    public var defaultDiameter: Double { minimumDiameter }

    /// These are logical buttons, not a claim of bridge or Xbox support.
    public var padButton: PadButton? {
        switch self {
        case .leftStickClick: return .leftStick
        case .rightStickClick: return .rightStick
        case .leftStick, .rightStick, .dpadUp, .dpadRight, .dpadDown, .dpadLeft: return nil
        default: return PadButton(rawValue: rawValue)
        }
    }
}

public enum ControllerOrientation: String, Codable, CaseIterable, Sendable {
    case portrait, landscape
}

public enum ControllerLayoutError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidFormat
    case invalidPosition
    case duplicateControls
    case missingControls
    case oversizedData
}

/// Canvas coordinates, with X increasing right and Y increasing down from the top.
/// This Y convention differs from gamepad stick output.
public struct NormalizedControlPosition: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }

    public func clamped() throws -> NormalizedControlPosition {
        guard x.isFinite && y.isFinite else { throw ControllerLayoutError.invalidPosition }
        return .init(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }

    private enum CodingKeys: String, CodingKey { case x, y }
    public init(from decoder: Decoder) throws {
        try requireKeys(decoder, ["x", "y"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        guard isValid else { throw ControllerLayoutError.invalidPosition }
    }
}

public struct ControllerPlacement: Codable, Equatable, Sendable {
    public let id: ControllerControlID
    public let position: NormalizedControlPosition

    public init(id: ControllerControlID, position: NormalizedControlPosition) {
        self.id = id; self.position = position
    }

    private enum CodingKeys: String, CodingKey { case id, position }
    public init(from decoder: Decoder) throws {
        try requireKeys(decoder, ["id", "position"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ControllerControlID.self, forKey: .id)
        position = try values.decode(NormalizedControlPosition.self, forKey: .position)
    }
}

/// Each orientation contains exactly one placement for every control.
/// Array order is persistent drawing order; moving a control brings it to the front.
public struct ControllerLayout: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public private(set) var portrait: [ControllerPlacement]
    public private(set) var landscape: [ControllerPlacement]

    public init(version: Int = currentVersion, portrait: [ControllerPlacement],
                landscape: [ControllerPlacement]) throws {
        self.version = version; self.portrait = portrait; self.landscape = landscape
        try validate()
    }

    public var isValid: Bool { (try? validate()) != nil }

    public func placements(for orientation: ControllerOrientation) -> [ControllerPlacement] {
        orientation == .portrait ? portrait : landscape
    }

    public func placement(for id: ControllerControlID,
                          orientation: ControllerOrientation) -> ControllerPlacement {
        // Construction, decoding, and mutation preserve complete unique IDs.
        placements(for: orientation).first { $0.id == id }!
    }

    public mutating func move(_ id: ControllerControlID, to position: NormalizedControlPosition,
                              orientation: ControllerOrientation) throws {
        let moved = ControllerPlacement(id: id, position: try position.clamped())
        var placements = placements(for: orientation)
        placements.removeAll { $0.id == id }
        placements.append(moved)
        if orientation == .portrait { portrait = placements } else { landscape = placements }
    }

    public func validate() throws {
        guard version == Self.currentVersion else { throw ControllerLayoutError.unsupportedVersion(version) }
        for placements in [portrait, landscape] {
            let ids = placements.map(\.id)
            guard Set(ids).count == ids.count else { throw ControllerLayoutError.duplicateControls }
            guard Set(ids) == Set(ControllerControlID.allCases) else { throw ControllerLayoutError.missingControls }
            guard placements.allSatisfy({ $0.position.isValid }) else { throw ControllerLayoutError.invalidPosition }
        }
    }

    private enum CodingKeys: String, CodingKey { case version, portrait, landscape }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        // Inspect version before newer-version fields: callers must retain the original data.
        guard version == Self.currentVersion else { throw ControllerLayoutError.unsupportedVersion(version) }
        try requireKeys(decoder, ["version", "portrait", "landscape"])
        try self.init(version: version,
                      portrait: values.decode([ControllerPlacement].self, forKey: .portrait),
                      landscape: values.decode([ControllerPlacement].self, forKey: .landscape))
    }

    public static let `default`: ControllerLayout = {
        func placements(_ rows: [(ControllerControlID, Double, Double)], width: Double,
                        height: Double) -> [ControllerPlacement] {
            rows.map { .init(id: $0.0, position: .init(x: $0.1 / width, y: $0.2 / height)) }
        }
        // Reference inner canvas sizes keep 44-point buttons and 104-point sticks apart.
        let portrait: [(ControllerControlID, Double, Double)] = [
            (.leftTrigger, 30, 24), (.leftBumper, 122, 24), (.rightBumper, 215, 24), (.rightTrigger, 307, 24),
            (.view, 30, 78), (.guide, 122, 78), (.share, 215, 78), (.menu, 307, 78),
            (.leftStick, 84, 174), (.rightStick, 253, 174),
            (.leftStickClick, 84, 252), (.rightStickClick, 253, 252),
            (.dpadUp, 84, 306), (.dpadLeft, 30, 354), (.dpadRight, 138, 354), (.dpadDown, 84, 402),
            (.y, 253, 306), (.x, 199, 354), (.b, 307, 354), (.a, 253, 402)
        ]
        let landscape: [(ControllerControlID, Double, Double)] = [
            (.leftTrigger, 26, 22), (.leftBumper, 86, 22), (.view, 146, 22), (.guide, 206, 22),
            (.share, 266, 22), (.menu, 326, 22), (.rightBumper, 386, 22), (.rightTrigger, 446, 22),
            (.leftStick, 64, 122), (.rightStick, 430, 122),
            (.leftStickClick, 130, 186), (.rightStickClick, 364, 186),
            (.dpadUp, 190, 80), (.dpadLeft, 160, 134), (.dpadRight, 218, 134), (.dpadDown, 190, 186),
            (.y, 305, 80), (.x, 276, 134), (.b, 334, 134), (.a, 305, 186)
        ]
        return try! ControllerLayout(portrait: placements(portrait, width: 337, height: 428),
                                     landscape: placements(landscape, width: 494, height: 208))
    }()
}

public enum ControllerLayoutCodec {
    public static let maximumBytes = 32_768

    public static func encode(_ layout: ControllerLayout) throws -> Data {
        try layout.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(layout)
        guard data.count <= maximumBytes else { throw ControllerLayoutError.oversizedData }
        return data
    }

    public static func decode(_ data: Data) throws -> ControllerLayout {
        guard data.count <= maximumBytes else { throw ControllerLayoutError.oversizedData }
        do { return try JSONDecoder().decode(ControllerLayout.self, from: data) }
        catch let error as ControllerLayoutError { throw error }
        catch { throw ControllerLayoutError.invalidFormat }
    }

    /// Returns usable defaults without destroying unreadable or newer layout data.
    /// A persistence layer must retain recoveredData until the user explicitly resets it.
    public static func restore(from data: Data?) -> ControllerLayoutLoadResult {
        guard let data else { return .init(layout: .default, recoveredData: nil, issue: nil) }
        do { return .init(layout: try decode(data), recoveredData: nil, issue: nil) }
        catch {
            return .init(layout: .default, recoveredData: data,
                         issue: (error as? ControllerLayoutError) ?? .invalidFormat)
        }
    }
}

public struct ControllerLayoutLoadResult: Equatable, Sendable {
    public let layout: ControllerLayout
    public let recoveredData: Data?
    public let issue: ControllerLayoutError?
}

private struct LayoutKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireKeys(_ decoder: Decoder, _ expected: Set<String>) throws {
    let values = try decoder.container(keyedBy: LayoutKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == expected else { throw ControllerLayoutError.invalidFormat }
}
