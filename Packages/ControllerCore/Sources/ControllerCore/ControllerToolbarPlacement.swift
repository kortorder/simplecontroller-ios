import Foundation

/// Positions describe travel within the safe screen area, not controller coordinates.
public struct ControllerToolbarAnchor: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x.isFinite ? min(1, max(0, x)) : 0.5
        self.y = y.isFinite ? min(1, max(0, y)) : 0.5
    }
    public var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

public struct ControllerToolbarGeometry: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double
    public let travelX: Double
    public let travelY: Double

    public init(screenWidth: Double, screenHeight: Double, safeTop: Double, safeBottom: Double,
                safeLeft: Double, safeRight: Double, requestedWidth: Double, requestedHeight: Double) {
        func positive(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
        let sw = positive(screenWidth), sh = positive(screenHeight)
        let left = min(sw, positive(safeLeft) + 8), right = min(max(0, sw - left), positive(safeRight) + 8)
        let top = min(sh, positive(safeTop) + 8), bottom = min(max(0, sh - top), positive(safeBottom) + 8)
        let availableWidth = max(0, sw - left - right), availableHeight = max(0, sh - top - bottom)
        width = min(availableWidth, positive(requestedWidth))
        height = min(availableHeight, positive(requestedHeight))
        minX = left + width / 2; minY = top + height / 2
        travelX = max(0, availableWidth - width); travelY = max(0, availableHeight - height)
    }

    public func center(for anchor: ControllerToolbarAnchor) -> (x: Double, y: Double) {
        let bounded = ControllerToolbarAnchor(x: anchor.x, y: anchor.y)
        return (minX + bounded.x * travelX, minY + bounded.y * travelY)
    }

    public func moved(_ anchor: ControllerToolbarAnchor, dx: Double, dy: Double) -> ControllerToolbarAnchor {
        ControllerToolbarAnchor(x: travelX > 0 ? anchor.x + dx / travelX : anchor.x,
                                y: travelY > 0 ? anchor.y + dy / travelY : anchor.y)
    }
}

public struct ControllerToolbarSettings: Equatable, Sendable {
    public var positions: [String: ControllerToolbarAnchor]
    /// Style belongs to a toolbar, while positions belong to each screen orientation.
    public var verticalToolbars: [String: Bool]
    public var topMenuMinimized: Bool
    public var actionsMenuMinimized: Bool
    public init(positions: [String: ControllerToolbarAnchor] = [:], verticalToolbars: [String: Bool] = [:],
                topMenuMinimized: Bool = false, actionsMenuMinimized: Bool = false) {
        self.positions = positions; self.verticalToolbars = verticalToolbars
        self.topMenuMinimized = topMenuMinimized
        self.actionsMenuMinimized = actionsMenuMinimized
    }
}

public struct ControllerToolbarPositionStore {
    public let url: URL
    private let writeFile: (Data, URL) throws -> Void
    private struct Document: Codable {
        var version = 1
        var positions: [String: ControllerToolbarAnchor]
        var verticalToolbars: [String: Bool]?
        var topMenuMinimized: Bool?
        var actionsMenuMinimized: Bool?
    }
    public init(url: URL) {
        self.url = url
        writeFile = { try $0.write(to: $1, options: .atomic) }
    }
    init(url: URL, writeFile: @escaping (Data, URL) throws -> Void) {
        self.url = url; self.writeFile = writeFile
    }

    public func load() throws -> [String: ControllerToolbarAnchor] {
        try loadSettings().positions
    }

    public func loadSettings() throws -> ControllerToolbarSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try decode(Data(contentsOf: url))
    }

    /// Existing callers change only positions; saved toolbar styles survive resets.
    public func save(_ positions: [String: ControllerToolbarAnchor]) throws {
        var settings = (try? loadSettings()) ?? .init()
        settings.positions = positions
        try saveSettings(settings)
    }

    public func saveVertical(_ value: Bool, for toolbarID: String) throws {
        var settings = (try? loadSettings()) ?? .init()
        settings.verticalToolbars[toolbarID] = value
        try saveSettings(settings)
    }

    public func saveTopMenuMinimized(_ value: Bool) throws {
        var settings = (try? loadSettings()) ?? .init()
        settings.topMenuMinimized = value
        try saveSettings(settings)
    }

    public func saveActionsMenuMinimized(_ value: Bool) throws {
        var settings = (try? loadSettings()) ?? .init()
        settings.actionsMenuMinimized = value
        try saveSettings(settings)
    }

    public func saveSettings(_ settings: ControllerToolbarSettings) throws {
        guard valid(settings) else { throw error("Toolbar settings are invalid.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(Document(positions: settings.positions,
            verticalToolbars: settings.verticalToolbars.isEmpty ? nil : settings.verticalToolbars,
            topMenuMinimized: settings.topMenuMinimized ? true : nil,
            actionsMenuMinimized: settings.actionsMenuMinimized ? true : nil))
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        if let previous {
            // Do not silently destroy settings from a newer app or a damaged file.
            if (try? decode(previous)) == nil {
                let recovery = directory.appendingPathComponent("toolbar-positions-recovery-\(UUID().uuidString).json")
                try previous.write(to: recovery, options: .atomic)
                guard try Data(contentsOf: recovery) == previous else { throw error("The previous toolbar settings could not be backed up.") }
            }
        }
        do {
            try writeFile(bytes, url)
            guard try Data(contentsOf: url) == bytes else { throw error("Toolbar positions could not be verified.") }
        } catch {
            if let previous { try? previous.write(to: url, options: .atomic) }
            else { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private func decode(_ bytes: Data) throws -> ControllerToolbarSettings {
        guard bytes.count <= 65_536 else { throw error("Toolbar settings are too large.") }
        let document = try JSONDecoder().decode(Document.self, from: bytes)
        let settings = ControllerToolbarSettings(positions: document.positions, verticalToolbars: document.verticalToolbars ?? [:],
                                                topMenuMinimized: document.topMenuMinimized ?? false,
                                                actionsMenuMinimized: document.actionsMenuMinimized ?? false)
        guard document.version == 1, valid(settings) else {
            throw error("Saved toolbar positions could not be read. Moving a toolbar will keep a recovery copy before saving new positions.")
        }
        return settings
    }
    private func valid(_ settings: ControllerToolbarSettings) -> Bool {
        settings.positions.count <= 32 && settings.verticalToolbars.count <= 32 &&
            settings.positions.allSatisfy { !$0.key.isEmpty && $0.key.count <= 100 && $0.value.isValid } &&
            settings.verticalToolbars.keys.allSatisfy { !$0.isEmpty && $0.count <= 100 }
    }
    private func error(_ message: String) -> NSError { NSError(domain: "ControllerToolbarPositionStore", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
