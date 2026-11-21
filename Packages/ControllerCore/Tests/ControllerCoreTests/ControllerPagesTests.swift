import Foundation
import XCTest
@testable import ControllerCore

final class ControllerPagesTests: XCTestCase {
    private func library(_ profile: ControllerProfile) throws -> ControllerProfileLibrary {
        try .init(activeProfileID: profile.id, profiles: [profile])
    }
    func testEveryLegacyVersionMigratesDeterministicMainWithoutChangingExistingData() throws {
        for version in 1...5 {
            var profile = try ControllerProfile.migrating(layout: .default, behaviors: .default)
            profile.swipeMode = version < 5 ? .buttons : .controls
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ControllerProfileLibraryCodec.encode(library(profile))) as? [String: Any])
            object["version"] = version; removeCameraFollowFieldsForPreSeventeenFixture(&object); object.removeValue(forKey:"settingsPresets"); object.removeValue(forKey: "androidSources")
            var profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
            for index in profiles.indices { profiles[index].removeValue(forKey: "globalHoldEnabled") }
            profiles[0].removeValue(forKey: "androidSources"); profiles[0].removeValue(forKey: "pages"); profiles[0].removeValue(forKey: "homePageID")
            if version < 5 { profiles[0].removeValue(forKey: "swipeMode") }
            if version < 2 { profiles[0].removeValue(forKey: "turboEnabled"); profiles[0].removeValue(forKey: "turboIntervalMilliseconds") }
            var controls = try XCTUnwrap(profiles[0]["controls"] as? [[String: Any]])
            for i in controls.indices {
                controls[i].removeValue(forKey: "pageNavigation"); controls[i].removeValue(forKey: "stickResponse"); controls[i].removeValue(forKey: "extendedBoost"); for key in ["buttonDirectional", "buttonAim", "controlWidth", "controlHeight", "touchAim"] { controls[i].removeValue(forKey:key) }
                if version < 5 { controls[i].removeValue(forKey: "swipeActivationEnabled") }
                if version < 4 { for key in ["touchpadWidth", "touchpadHeight", "touchpadBehavior"] { controls[i].removeValue(forKey: key) } }
                if version < 3 { for key in ["directionalEnabled", "directionPayloads"] { controls[i].removeValue(forKey: key) } }
                if version < 2 { for key in ["payload", "autoTapEnabled", "autoTapIntervalMilliseconds"] { controls[i].removeValue(forKey: key) } }
            }
            profiles[0]["controls"] = controls; object["profiles"] = profiles
            let bytes = try JSONSerialization.data(withJSONObject: object)
            let first = try ControllerProfileLibraryCodec.decode(bytes), second = try ControllerProfileLibraryCodec.decode(bytes)
            XCTAssertEqual(first, second); XCTAssertEqual(first.activeProfile, profile)
            XCTAssertEqual(first.activeProfile.pages, [.init(id: profile.id, name: "Main", controlIDs: profile.controls.map(\.id))])
            XCTAssertEqual(first.version, ControllerProfileLibrary.currentVersion)
        }
    }
    func testMembershipHelpersMoveWithoutChangingGeometryAndRemoveAtomically() throws {
        var profile = try ControllerProfile()
        let first = profile.homePageID, second = try profile.addPage(name: "Driving")
        let control = ProfileControl(actions: [.a], buttonBehavior: .init(holdToggle: true))
        try profile.addControl(control, toPage: first, portrait: .init(x: 0.2, y: 0.4), landscape: .init(x: 0.8, y: 0.3))
        let geometry = [profile.portrait, profile.landscape]
        try profile.moveControl(control.id, toPage: second)
        XCTAssertTrue(profile.visibleControlIDs(on: first).isEmpty)
        XCTAssertEqual(profile.controls(on: second), [control]); XCTAssertEqual([profile.portrait, profile.landscape], geometry)
        let before = profile
        XCTAssertThrowsError(try profile.moveControl(control.id, toPage: UUID()))
        XCTAssertEqual(profile, before)
        XCTAssertThrowsError(try profile.addControl(control, toPage: second))
        XCTAssertEqual(profile, before)
        try profile.removeControl(control.id)
        XCTAssertTrue(profile.controls.isEmpty); XCTAssertTrue(profile.portrait.isEmpty); XCTAssertTrue(profile.landscape.isEmpty)
        XCTAssertTrue(profile.pages.allSatisfy { $0.controlIDs.isEmpty })
    }
    func testDeletionRehomesIncomingLinksAndRemovesOnlyDeletedPageMembers() throws {
        var profile = try ControllerProfile()
        let main = profile.homePageID, second = try profile.addPage(name: "Second")
        let go = ProfileControl(kind: .pageButton, pageNavigation: .goTo(second))
        let toggle = ProfileControl(kind: .pageButton, pageNavigation: .toggle(second))
        let other = ProfileControl(actions: [.a])
        try profile.addControl(go, toPage: main); try profile.addControl(toggle, toPage: main)
        try profile.addControl(other, toPage: second); try profile.setHomePage(second)
        try profile.deletePage(second)
        XCTAssertEqual(profile.homePageID, main); XCTAssertEqual(profile.controls.count, 2)
        XCTAssertTrue(profile.controls.allSatisfy { $0.pageNavigation == .home })
        XCTAssertFalse(profile.portrait.contains { $0.id == other.id })
        let before = profile
        XCTAssertThrowsError(try profile.deletePage(main)); XCTAssertEqual(profile, before)
    }
    func testDuplicatePageFreshIDsRemapsSelfLinksAndPreservesExternalLinksAndZOrder() throws {
        var profile = try ControllerProfile()
        let original = profile.homePageID, external = try profile.addPage(name: "External")
        let selfLink = ProfileControl(kind: .pageButton, pageNavigation: .toggle(original))
        let otherLink = ProfileControl(kind: .pageButton, pageNavigation: .goTo(external))
        try profile.addControl(selfLink, toPage: original, portrait: .init(x: 0.2, y: 0.4))
        try profile.addControl(otherLink, toPage: original, portrait: .init(x: 0.8, y: 0.6))
        try profile.move(selfLink.id, to: .init(x: 0.3, y: 0.4), orientation: .portrait)
        let old = profile
        let copied = try profile.duplicatePage(original)
        XCTAssertEqual(profile.page(for: copied)?.name, "Main copy")
        XCTAssertTrue(profile.visibleControlIDs(on: copied).isDisjoint(with: old.visibleControlIDs(on: original)))
        XCTAssertEqual(profile.controls(on: copied).map(\.pageNavigation), [.toggle(copied), .goTo(external)])
        XCTAssertEqual(profile.placements(for: .portrait, on: copied).map(\.position), old.placements(for: .portrait, on: original).map(\.position))
        XCTAssertEqual(profile.controls(on: original), old.controls(on: original))
    }
    func testWholeProfileCloneRewritesEveryIdentityAndNavigationReference() throws {
        var source = try ControllerProfile()
        let second = try source.addPage(name: "Second")
        try source.addControl(.init(kind: .pageButton, pageNavigation: .goTo(second)), toPage: source.homePageID)
        try source.addControl(.init(kind: .pageButton, pageNavigation: .toggle(source.homePageID)), toPage: second)
        try source.setHomePage(second)
        let copy = try source.cloned(name: "Copied")
        XCTAssertNotEqual(copy.id, source.id); XCTAssertEqual(copy.name, "Copied")
        XCTAssertTrue(Set(copy.pages.map(\.id)).isDisjoint(with: source.pages.map(\.id)))
        XCTAssertTrue(Set(copy.controls.map(\.id)).isDisjoint(with: source.controls.map(\.id)))
        XCTAssertEqual(copy.homePageID, copy.pages[1].id)
        XCTAssertEqual(copy.controls[0].pageNavigation, .goTo(copy.pages[1].id))
        XCTAssertEqual(copy.controls[1].pageNavigation, .toggle(copy.pages[0].id))
        XCTAssertEqual(copy.portrait.map(\.position), source.portrait.map(\.position))
        XCTAssertEqual(try ControllerProfileLibraryCodec.decode(ControllerProfileLibraryCodec.encode(library(copy))).activeProfile, copy)
    }
    func testSelectedPageImportRedirectsExternalLinksAndPreservesSource() throws {
        var source = try ControllerProfile()
        let main = source.homePageID, second = try source.addPage(name: "Second")
        for navigation in [ProfilePageNavigation.goTo(main), .toggle(second), .back] {
            try source.addControl(.init(kind: .pageButton, pageNavigation: navigation), toPage: main)
        }
        let original = source
        var destination = try ControllerProfile()
        let copied = try destination.importPage(main, from: source)
        XCTAssertEqual(source, original)
        XCTAssertEqual(destination.controls(on: copied).map(\.pageNavigation), [.goTo(copied), .home, .back])
        XCTAssertEqual(destination.page(for: copied)?.name, "Main copy")
        XCTAssertEqual(destination.pages.count, 2)
    }
    func testPageAndControlLimitsFailBeforeMutating() throws {
        var profile = try ControllerProfile()
        for i in 1..<32 { try profile.addPage(name: "Page \(i)") }
        let fullPages = profile
        XCTAssertThrowsError(try profile.addPage(name: "Extra")); XCTAssertEqual(profile, fullPages)
        XCTAssertThrowsError(try profile.duplicatePage(profile.homePageID)); XCTAssertEqual(profile, fullPages)
        for i in 0..<ControllerProfile.maximumControls { try profile.addControl(.init(name: "Control \(i)"), toPage: profile.homePageID) }
        let fullControls = profile
        XCTAssertThrowsError(try profile.addControl(.init(), toPage: profile.homePageID)); XCTAssertEqual(profile, fullControls)
        let empty = try ControllerProfile()
        XCTAssertThrowsError(try profile.importPage(empty.homePageID, from: empty)); XCTAssertEqual(profile, fullControls)
    }
    func testValidationRejectsMissingDuplicateOrDanglingMembershipAndNavigation() throws {
        var valid = try ControllerProfile()
        let control = ProfileControl(actions: [.a]); try valid.addControl(control, toPage: valid.homePageID)
        var candidate = valid; candidate.pages[0].controlIDs = []
        XCTAssertThrowsError(try candidate.validate())
        candidate = valid; candidate.pages[0].controlIDs.append(control.id)
        XCTAssertThrowsError(try candidate.validate())
        candidate = valid; candidate.pages.append(.init(name: "Other", controlIDs: [control.id]))
        XCTAssertThrowsError(try candidate.validate())
        candidate = valid; candidate.homePageID = UUID()
        XCTAssertThrowsError(try candidate.validate())
        candidate = valid; candidate.pages.append(.init(name: " MAIN "))
        XCTAssertThrowsError(try candidate.validate())
        candidate = valid; candidate.pages.append(candidate.pages[0])
        XCTAssertThrowsError(try candidate.validate())
        XCTAssertThrowsError(try valid.addControl(.init(kind: .pageButton, pageNavigation: .goTo(UUID())), toPage: valid.homePageID))
        XCTAssertEqual(valid.controls, [control])
    }
    func testPageButtonRejectsMixedOutputOrHoldWhileDefaultHomeIsValid() throws {
        XCTAssertNoThrow(try ProfileControl(kind: .pageButton).validate())
        for control in [ProfileControl(kind: .pageButton, actions: [.a]),
                        ProfileControl(kind: .pageButton, payload: "W"),
                        ProfileControl(kind: .pageButton, buttonBehavior: .init(holdToggle: true)),
                        ProfileControl(kind: .pageButton, autoTapEnabled: true),
                        ProfileControl(pageNavigation: .home)] { XCTAssertThrowsError(try control.validate()) }
        let local = ProfileControl(kind: .pageButton)
        XCTAssertFalse(local.acceptsSwipeEntry); XCTAssertTrue(local.hasAnyOutput)
        XCTAssertTrue(local.outputTargets.isEmpty); XCTAssertFalse(local.hasKeyboardOrMouseOutputs)
        XCTAssertThrowsError(try ControllerPayloadProgram.parse("PAGE_HOME"))
    }
    func testFormatSixRejectsMissingUnknownAndMalformedPageFields() throws {
        let valid = try ControllerProfile()
        let bytes = try ControllerProfileLibraryCodec.encode(library(valid))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let profiles = try XCTUnwrap(original["profiles"] as? [[String: Any]])
        for key in ["pages", "homePageID"] {
            var changed = original, values = profiles; values[0].removeValue(forKey: key); changed["profiles"] = values
            XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: changed)))
        }
        var changed = original, values = profiles
        var pages = try XCTUnwrap(values[0]["pages"] as? [[String: Any]])
        pages[0]["unknown"] = true; values[0]["pages"] = pages; changed["profiles"] = values
        XCTAssertThrowsError(try ControllerProfileLibraryCodec.decode(JSONSerialization.data(withJSONObject: changed)))
        for json in ["{\"action\":\"goTo\",\"targetPageID\":null}", "{\"action\":\"future\",\"targetPageID\":null}", "{\"action\":\"home\",\"targetPageID\":\"\(UUID())\"}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(ProfilePageNavigation.self, from: Data(json.utf8)))
        }
    }
}
