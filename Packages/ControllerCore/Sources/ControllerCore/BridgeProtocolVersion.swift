import Foundation

public enum BridgeProtocolVersion: String, CaseIterable, Codable, Sendable {
    case scx2, scx1, windowsPC

    public var displayName: String {
        switch self {
        case .scx2: "SCX2 • candidate Pico bridge"
        case .scx1: "SCX1 • legacy prototype"
        case .windowsPC: "Windows PC • free receiver"
        }
    }
    public var defaultPort: UInt16 { self == .windowsPC ? 42734 : self == .scx2 ? 42736 : 42735 }
}
