import Foundation

extension AndroidEditedPatcher {
    func matchesFloatingBaseline(_ baseline: AndroidSourceExportBaseline) throws -> Bool {
        let templates = profile.pages.flatMap(AndroidFloatingConversion.templates)
        guard templates.count == baseline.zones.count, source.zones.count == templates.count,
              source.zones.allSatisfy({ $0.exportID == nil }) else { return false }
        let sourceControls = original.profiles.flatMap(\.pages).flatMap(\.controls)
        let ids = Dictionary(uniqueKeysWithValues: source.controls.compactMap { b in sourceControls.first { $0.sourcePath == b.sourcePath }.map { (b.nativeID, $0.sourceID) } })
        for template in templates {
            guard let binding = source.zones.first(where: { $0.nativeID == template.id }),
                  let saved = baseline.zones.first(where: { $0.sourcePath == binding.sourcePath }),
                  let page = profile.pages.first(where: { AndroidFloatingConversion.templates($0).contains { $0.id == template.id } }),
                  source.pages.first(where: { $0.nativeID == page.id })?.sourcePath == saved.pageSourcePath,
                  try AndroidFloatingConversion.projection(template, controlIDs: ids) == AndroidJSONValue.decodingValue(saved.projectionData) else { return false }
        }
        return true
    }
    mutating func patchedFloatingZones(_ page: ProfilePage, originalPage: AndroidSourcePage?, baseline: AndroidSourceExportBaseline,
                                      copyingPage: Bool) throws -> [AndroidJSONValue] {
        let allPages = original.profiles.first { $0.sourcePath == source.sourceProfilePath }?.pages ?? []
        var sourceZones: [String: AndroidJSONValue] = [:]
        for item in allPages { for (index, value) in (item.value["floatingZones"]?.arrayValue ?? []).enumerated() { sourceZones[item.sourcePath + "/floatingZones/\(index)"] = value } }
        let templates = AndroidFloatingConversion.templates(page)
        var generated: [UUID: AndroidJSONValue] = [:], usedIDs = Set<String>()
        let controlsByPath = Dictionary(uniqueKeysWithValues: allPages.flatMap(\.controls).map { ($0.sourcePath, $0) })
        for template in templates {
            let binding = source.zones.first { $0.nativeID == template.id }
            let saved = binding.flatMap { b in baseline.zones.first { $0.sourcePath == b.sourcePath } }
            var originalValue = binding.flatMap { sourceZones[$0.sourcePath] }
            var prior = try saved.map { try AndroidJSONValue.decodingValue($0.projectionData) }
            let copied = binding?.exportID != nil || copyingPage
            let newID = binding?.exportID ?? originalValue?["id"]?.stringValue ?? template.id.uuidString
            guard usedIDs.insert(newID).inserted, !controlIDs.values.contains(newID) else { throw AndroidArchiveError("An exported floating identity collides with another record.") }
            let projection = try AndroidFloatingConversion.projection(template, controlIDs: controlIDs)
            if let originalValue, prior != nil, originalValue["kind"] != projection["kind"] {
                block("Changing an imported floating zone's type needs explicit conversion of its dormant source settings.", path: binding?.sourcePath ?? "")
                generated[template.id] = originalValue; continue
            }
            if copied, let originalZone = originalValue {
                var remap: [String: String] = [:]
                if case let .button(zone) = template {
                    for id in zone.memberIDs {
                        guard let b = source.controls.first(where: { $0.nativeID == id }), let old = controlsByPath[b.sourcePath], let next = controlIDs[id] else {
                            throw AndroidArchiveError("A copied floating member has no preserved source identity.")
                        }
                        if let previous = remap[old.sourceID], previous != next { throw AndroidArchiveError("A copied zone has ambiguous duplicate source members.") }
                        remap[old.sourceID] = next
                    }
                }
                var protected = Set(remap.keys)
                if let oldID = originalZone["id"]?.stringValue { protected.insert(oldID) }
                if let oldPage = originalPage?.sourceID { protected.insert(oldPage) }
                if hasUnknownFloatingReference(originalZone, known: prior ?? projection, identities: protected, root: true) {
                    block("A copied floating template contains unknown identity references. The original is preserved; edited export will not guess their targets.", path: binding?.sourcePath ?? "")
                }
                originalValue = try remappingFloatingMembers(originalZone, using: remap)
                prior = try prior.map { try remappingFloatingMembers($0, using: remap) }
            }
            let patched = try patchFloatingKnown(original: originalValue, previous: prior, current: projection, path: binding?.sourcePath ?? "")
            generated[template.id] = try patched.androidReplacing(["id"], with: .string(newID))
            if originalValue == nil || copied { changed += 1; warn("The edited Android file includes a floating template with a fresh identity.", path: binding?.sourcePath ?? "") }
        }
        var result: [AndroidJSONValue] = [], emitted = Set<UUID>()
        for (index, old) in (originalPage?.value["floatingZones"]?.arrayValue ?? []).enumerated() {
            let path = originalPage!.sourcePath + "/floatingZones/\(index)"
            if let template = templates.first(where: { value in
                source.zones.contains { $0.nativeID == value.id && $0.sourcePath == path && (copyingPage || $0.exportID == nil) }
            }) {
                result.append(generated[template.id]!); emitted.insert(template.id)
            } else if baseline.zones.contains(where: { $0.sourcePath == path }) {
                changed += 1
                warn("The edited copy removes one converted floating template, including fields attached to that record. Its full data remains in the unchanged original.", path: path)
            } else {
                if copyingPage { block("A copied page contains an archived-only floating template. Its unknown references cannot be safely copied.", path: path) }
                if let id = old["id"]?.stringValue, usedIDs.contains(id) || controlIDs.values.contains(id) { throw AndroidArchiveError("A new floating identity collides with an archived-only record.") }
                result.append(old)
            }
        }
        for template in templates where !emitted.contains(template.id) { result.append(generated[template.id]!) }
        return result
    }
    private func hasUnknownFloatingReference(_ original: AndroidJSONValue, known: AndroidJSONValue, identities: Set<String>, root: Bool = false) -> Bool {
        func contains(_ value: AndroidJSONValue) -> Bool {
            switch value {
            case let .string(value): identities.contains(value)
            case let .array(values): values.contains(where: contains)
            case let .object(value): value.members.contains { identities.contains($0.name) || contains($0.value) }
            default: false
            }
        }
        if let object = original.objectValue {
            return object.members.contains { member in
                if root && member.name == "id" { return false }
                guard let projection = known[member.name] else { return contains(member.value) }
                return hasUnknownFloatingReference(member.value, known: projection, identities: identities)
            }
        }
        if case let .array(values) = original, let projected = known.arrayValue {
            return values.enumerated().contains { index, value in index < projected.count ? hasUnknownFloatingReference(value, known: projected[index], identities: identities) : contains(value) }
        }
        return false
    }
    private func remappingFloatingMembers(_ value: AndroidJSONValue, using ids: [String: String]) throws -> AndroidJSONValue {
        var value = value
        if let members = value["memberIds"]?.arrayValue { value = try value.androidReplacing(["memberIds"], with: .array(members.map { .string(ids[$0.stringValue ?? ""] ?? $0.stringValue ?? "") })) }
        if let start = value["startMemberId"]?.stringValue { value = try value.androidReplacing(["startMemberId"], with: .string(ids[start] ?? start)) }
        for key in ["portraitMemberGeometry", "landscapeMemberGeometry", "portraitRestorationGeometry", "landscapeRestorationGeometry"] {
            if let object = value[key]?.objectValue {
                let renamed = object.members.map { AndroidJSONObject.Member(name: ids[$0.name] ?? $0.name, value: $0.value) }
                guard Set(renamed.map(\.name)).count == renamed.count else { throw AndroidArchiveError("Floating geometry identity remapping would collide.") }
                value = try value.androidReplacing([key], with: .object(.init(members: renamed)))
            }
        }
        return value
    }
    /// Recursive known-field patch. Unknown siblings survive at every object depth. Array
    /// objects retain their attached unknown data by stable ID, or reject ambiguous structure.
    private mutating func patchFloatingKnown(original: AndroidJSONValue?, previous: AndroidJSONValue?, current: AndroidJSONValue, path: String) throws -> AndroidJSONValue {
        if let original, current == previous { return original }
        if original == nil { changed += 1; return current }
        if let object = current.objectValue {
            guard original == nil || original?.objectValue != nil else {
                if original == .null { changed += 1; return current }
                throw AndroidArchiveError("A floating field cannot be patched without replacing unknown structure.")
            }
            var result = original ?? .object(.init(members: []))
            for member in object.members {
                if current[member.name] == previous?[member.name], original?[member.name] == nil { continue }
                let next = try patchFloatingKnown(original: original?[member.name], previous: previous?[member.name], current: member.value, path: path + "/" + member.name)
                result = try result.androidReplacing([member.name], with: next)
            }
            // A deleted member's known geometry entry is an explicit native edit. Unknown
            // siblings outside that owned entry remain in the source map.
            for old in previous?.objectValue?.members ?? [] where current[old.name] == nil {
                result = result.androidRemoving([old.name]); changed += 1
                warn("An edited floating member entry was removed; its original remains in the unchanged export.", path: path + "/" + old.name)
            }
            return result
        }
        if case let .array(values) = current, values.contains(where: { $0.objectValue != nil }) {
            let old = original?.arrayValue ?? [], prior = previous?.arrayValue ?? []
            guard values.count == prior.count, values.count == old.count || original == nil,
                  values.enumerated().allSatisfy({ index, value in value["id"] == prior[index]["id"] }) else {
                throw AndroidArchiveError("Changing floating knob count, order or identity needs an explicit source merge. Keep the existing knob slots for edited Android export.")
            }
            return .array(try values.enumerated().map { index, value in try patchFloatingKnown(original: index < old.count ? old[index] : nil, previous: prior[index], current: value, path: path + "/\(index)") })
        }
        changed += 1; return current
    }
}
