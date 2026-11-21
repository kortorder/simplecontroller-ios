import Foundation

public enum ControllerProfileBulkDeletionError: Error, Equatable, Sendable, LocalizedError {
    case emptySelection, activeProfileProtected, unknownProfile
    public var errorDescription: String? {
        switch self {
        case .emptySelection: "Select at least one inactive profile."
        case .activeProfileProtected: "The active profile cannot be deleted in a batch. Switch to a different profile first."
        case .unknownProfile: "A selected profile is no longer available. Refresh the profile list before deleting."
        }
    }
}

public struct ControllerProfileDeletionPlan: Equatable, Sendable {
    public let candidate: ControllerProfileLibrary
    public let deletedProfileIDs: [UUID]
    public let deletedProfileNames: [String]
}

/// Pure, atomic planning. The caller persists once and keeps its existing recovery
/// policy; this helper never deletes Android originals, presets, files or live owners.
public enum ControllerProfileBulkDeletion {
    public static func candidates(in library: ControllerProfileLibrary) -> [ControllerProfile] {
        library.profiles.filter { $0.id != library.activeProfileID }
    }
    public static func prepare(library: ControllerProfileLibrary,
                               selectedIDs: Set<UUID>) throws -> ControllerProfileDeletionPlan {
        try library.validate()
        guard !selectedIDs.isEmpty else { throw ControllerProfileBulkDeletionError.emptySelection }
        guard !selectedIDs.contains(library.activeProfileID) else { throw ControllerProfileBulkDeletionError.activeProfileProtected }
        guard selectedIDs.isSubset(of: Set(library.profiles.map(\.id))) else { throw ControllerProfileBulkDeletionError.unknownProfile }
        let deleted = library.profiles.filter { selectedIDs.contains($0.id) }
        var candidate = library
        candidate.profiles.removeAll { selectedIDs.contains($0.id) }
        try candidate.validate()
        return .init(candidate: candidate, deletedProfileIDs: deleted.map(\.id), deletedProfileNames: deleted.map(\.name))
    }
}
