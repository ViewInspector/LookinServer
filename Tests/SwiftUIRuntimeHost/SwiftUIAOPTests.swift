import XCTest
import SwiftUI
import LookinServer
@testable import LookinServerSwift

final class SwiftUIAOPTests: XCTestCase {
    @MainActor func testUnboundStateAndModelsUseRealSettersAndExpire() async throws {
        guard #available(iOS 17.0, *), let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Requires an iOS 17+ scene-backed host")
        }
        let window = UIWindow(windowScene: scene)
        var host: UIHostingController<AOPUnboundFixture>? = UIHostingController(rootView: AOPUnboundFixture())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 250_000_000)
        func fields() -> [[String: Any]] { LKS_SwiftUIStateEditor.fields(for: host!.view) }
        func find(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(fields().first { ($0["title"] as? String)?.hasSuffix(name) == true }, "Missing \(name). Fields: \(fields())")
        }
        func edit(_ name: String, _ value: Any) throws {
            let field = try find(name)
            let id = try XCTUnwrap(field["identifier"] as? String)
            let request = LookinCustomAttrModification()
            request.customSetterID = id
            request.value = value
            request.attrType = field["valueType"] as? String == "bool" ? .BOOL : (field["valueType"] as? String == "number" ? .double : .nsString)
            XCTAssertTrue(LKS_CustomAttrModificationHandler.handle(request), name)
        }
        try edit("AOPUnboundFixture.counter", 29)
        try edit("AOPUnboundFixture.neverRendered", 88)
        try edit("AOPUnboundFixture.value.score", 31)
        try edit("AOPUnboundFixture.published.title", "Published edited")
        try edit("AOPUnboundFixture.published.number", 9)

        try edit("AOPUnboundFixture.observed.title", "Observation edited")
        try edit("AOPUnboundFixture.observed.enabled", false)
        try edit("AOPUnboundChild.text", "Child edited")
        try await Task.sleep(nanoseconds: 200_000_000)
        host!.view.layoutIfNeeded()
        func rendered(_ node: LKS_SwiftUIViewNode) -> String {
            (node.attributeDescription ?? "") + node.children.map(rendered).joined()
        }
        let text = rendered(try XCTUnwrap(LKS_SwiftUIRuntime.capture(host!.view)))
        XCTAssertTrue(text.contains("COUNTER=29;VALUE=31"), text)
        XCTAssertTrue(text.contains("Published edited|9|Private initial|1"), text)
        XCTAssertTrue(text.contains("OBSERVED=Observation edited|false"), text)
        XCTAssertTrue(text.contains("CHILD=Child edited"), text)
        XCTAssertEqual(try find("AOPUnboundFixture.neverRendered")["value"] as? Int, 88)
        // A non-@Published private field must independently invalidate ObservableObject.
        try edit("AOPUnboundFixture.published.secret", "Private edited")
        try await Task.sleep(nanoseconds: 100_000_000)
        let privateEdit = rendered(try XCTUnwrap(LKS_SwiftUIRuntime.capture(host!.view)))
        XCTAssertTrue(privateEdit.contains("Published edited|9|Private edited|1"), privateEdit)
        let immutable = try find("AOPUnboundFixture.published.immutable (read-only)")
        XCTAssertEqual(immutable["editable"] as? Bool, false)
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: "bad", identifier: immutable["identifier"] as! String))
        let counter = try find("AOPUnboundFixture.counter")["identifier"] as! String
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: Double.nan, identifier: counter))
        let child = try find("AOPUnboundChild.text")["identifier"] as! String
        try edit("AOPUnboundFixture.showChild", false)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: "Removed child", identifier: child))
        window.rootViewController = nil
        host = nil
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: 2, identifier: counter))
    }
}

extension SwiftUIAOPTests {
    @MainActor func testReplacingModelRejectsOldTokenEvenWhileOldModelLives() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw XCTSkip("Requires scene") }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AOPModelReplacementFixture())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        func field(_ title: String) throws -> [String: Any] {
            try XCTUnwrap(LKS_SwiftUIStateEditor.fields(for: host.view).first { ($0["title"] as? String)?.hasSuffix(title) == true })
        }
        let old = try field("AOPModelBranch.model.title")["identifier"] as! String
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: "First model", identifier: old))
        let toggle = try field("AOPModelReplacementFixture.useAlternate")["identifier"] as! String
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: true, identifier: toggle))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: "Stale edit", identifier: old))
        let current = try field("AOPModelBranch.model.title")
        XCTAssertEqual(current["value"] as? String, "Published initial")
        XCTAssertNotEqual(current["identifier"] as? String, old)
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: "Second model", identifier: current["identifier"] as! String))
        XCTAssertEqual(try field("AOPModelReplacementFixture.first.title")["value"] as? String, "First model")
        XCTAssertEqual(try field("AOPModelReplacementFixture.second.title")["value"] as? String, "Second model")
    }
}

extension SwiftUIAOPTests {
    @MainActor func testOptionalAndCollectionsRefreshThroughModificationRequests() async throws {
        guard #available(iOS 17.0, *), let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw XCTSkip("Requires iOS 17+ scene") }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AOPContainerFixture())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        func fields() -> [[String: Any]] { LKS_SwiftUIStateEditor.fields(for: host.view) }
        func field(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(fields().first { ($0["title"] as? String)?.hasSuffix("AOPContainerFixture." + name) == true }, "Missing \(name): \(fields().map { $0["title"]! })")
        }
        func token(_ name: String) throws -> String { try XCTUnwrap(field(name)["identifier"] as? String) }
        func json(_ name: String, _ text: String) throws {
            let request = LookinCustomAttrModification()
            request.customSetterID = try token(name + " (JSON)")
            request.attrType = .nsString
            request.value = text
            XCTAssertTrue(LKS_CustomAttrModificationHandler.handle(request), name)
        }
        func assertRendered(_ expected: [String], absent: [String] = []) async throws {
            try await Task.sleep(nanoseconds: 120_000_000)
            host.view.layoutIfNeeded()
            func values(_ node: LKS_SwiftUIViewNode) -> String { (node.attributeDescription ?? "") + node.children.map(values).joined() }
            let actual = values(try XCTUnwrap(LKS_SwiftUIRuntime.capture(host.view)))
            for text in expected { XCTAssertTrue(actual.contains(text), "Missing \(text): \(actual)") }
            for text in absent { XCTAssertFalse(actual.contains(text), "Unexpected \(text): \(actual)") }
        }
        XCTAssertEqual(try field("note (JSON)")["value"] as? String, "null")
        try json("note", "\"Optional edited\"")
        try json("flag", "false")
        try json("numbers", "[3,1,8]")
        try json("mapping", "{\"nil\":null,\"count\":9}")
        try json("tags", "[\"z\",\"a\",\"a\"]") // Set uses ordinary Swift uniqueness semantics.
        try json("nested", "[[null,9],[2]]")
        try json("row", "{\"id\":7,\"name\":\"Optional row\"}")
        try json("rows", "[{\"id\":2,\"name\":\"Two\"},{\"id\":1,\"name\":\"One changed\"}]")
        try json("integer", "9223372036854775807")
        try json("published.values", "[7,8]")
        try json("published.note", "\"Model optional\"")
        try json("observed.tags", "[\"new\",\"visible\"]")
        try await assertRendered(["NOTE=Optional edited;FLAG=false", "NUMBERS=3,1,8;TAGS=a,z", "MAP=count:9,nil:null", "NESTED=null,9;2", "ROW=Optional row;INT64=9223372036854775807", "ITEM=2:Two", "ITEM=1:One changed", "PUBLISHED=7,8|Model optional|1", "OBSERVED-TAGS=new,visible"])

        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let proof = XCTAttachment(image: image)
        proof.name = "Optional and collections after editing"
        proof.lifetime = .keepAlways
        add(proof)

        // Editing non-Codable business structs still uses generated writable key paths.
        let plain = try token("plainRows[0].score")
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: 17, identifier: plain))
        let dictionaryValue = try token("mapping[\"nil\"] (JSON)")
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: "4", identifier: dictionaryValue))
        try await assertRendered(["PLAIN=17,3", "MAP=count:9,nil:4"])
        // A fresh element edit can set Optional.none without accidentally removing its dictionary key.
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: "null", identifier: try token("mapping[\"nil\"] (JSON)")))
        try await assertRendered(["MAP=count:9,nil:null"])

        // The parent does not observe the nested ObservableObject. Debug invalidation
        // must refresh it while preserving the unrelated child's @State identity.
        let child = try XCTUnwrap(fields().first { ($0["title"] as? String)?.hasSuffix("AOPUnboundChild.text") == true }?["identifier"] as? String)
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: "Identity kept", identifier: child))
        try await assertRendered(["CHILD=Identity kept"])
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: "Nested reference edited", identifier: try token("references[0].title")))
        try await assertRendered(["REFERENCE=Nested reference edited", "EQUATABLE=Nested reference edited", "CHILD=Identity kept"])
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: 19, identifier: try token("hashRows[0].score")))
        try await assertRendered(["HASH-ROWS=19", "CHILD=Identity kept"])
        XCTAssertFalse(fields().contains { ($0["title"] as? String)?.contains("__lookinRefreshVersion") == true })

        let oldElement = try token("numbers[0]")
        let oldRow = try token("rows[0].name")
        let oldWrapped = try token("note.value")
        try json("numbers", "[8,1,3]")
        try json("rows", "[{\"id\":1,\"name\":\"Kept\"}]")
        try json("note", "null")
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: 99, identifier: oldElement))
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: "Wrong row", identifier: oldRow))
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: "Revived", identifier: oldWrapped))
        try await assertRendered(["NOTE=nil", "NUMBERS=8,1,3", "ITEM=1:Kept"], absent: ["ITEM=2:Two", "Wrong row"])
        try json("numbers", "[]")
        try json("mapping", "{}")
        try json("tags", "[]")
        try json("row", "null")
        try json("rows", "[]")
        try await assertRendered(["NUMBERS=;TAGS=", "ROW=nil;", "MAP="], absent: ["ITEM=1:Kept"])

        // Invalid replacements never call the model setter or partially update state.
        let published = try token("published.values (JSON)")
        for invalid in ["[1,\"bad\"]", "[", "null", "[1e999]", "[true]", "[9223372036854775808]", "[" + String(repeating: "0,", count: 4096) + "0]", String(repeating: " ", count: 65537)] {
            XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: invalid, identifier: published), invalid.prefix(50).description)
        }
        XCTAssertEqual(try field("published.values (JSON)")["value"] as? String, "[7,8]")
        try await assertRendered(["PUBLISHED=7,8|Model optional|1"])
        // Read-only container properties never acquire a setter through expansion.
        let item = try XCTUnwrap(LKS_SwiftUIDisplayItemsMaker.displayItems(forHostingView: host.view)?.first)
        XCTAssertTrue(item.attributesGroupList.flatMap(\.attrSections).flatMap(\.attributes).contains { $0.displayTitle.hasSuffix("note (JSON)") && $0.customSetterID != nil })
    }
}

extension SwiftUIAOPTests {
    @MainActor func testContainerCodecValidationAndCanonicalReadback() throws {
        var optional: Bool? = nil
        let boolean = try XCTUnwrap(Binding(get: { optional }, set: { optional = $0 }).lookinField(title: "optional"))
        XCTAssertEqual(boolean.read() as? String, "null")
        XCTAssertNil(boolean.write("false"))
        XCTAssertEqual(optional, false)
        XCTAssertNotNil(boolean.write("0"))
        XCTAssertEqual(optional, false)
        XCTAssertNil(boolean.write("null"))
        XCTAssertNil(optional)
        XCTAssertNil(Binding<Int?>.constant(1).lookinField(title: "constant"))
        let rejecting = try XCTUnwrap(Binding<[Int]>(get: { [1] }, set: { _ in }).lookinField(title: "rejecting"))
        XCTAssertNotNil(rejecting.write("[2]"))

        // JSON null alone cannot distinguish nil from .some(nil). Verify the
        // actual Swift value as well whenever Equatable is available.
        let doubleOptional: Int?? = .some(nil)
        let rejectsNil = try XCTUnwrap(Binding<Int??>(get: { doubleOptional }, set: { _ in }).lookinField(title: "doubleOptional"))
        XCTAssertNotNil(rejectsNil.write("null"))

        var nested: [String: Set<Int>] = ["ids": [2, 1]]
        let collection = try XCTUnwrap(Binding(get: { nested }, set: { nested = $0 }).lookinField(title: "nested"))
        XCTAssertEqual(collection.read() as? String, "{\"ids\":[1,2]}")
        XCTAssertNil(collection.write("{\"other\":[8,4,8],\"ids\":[2,1]}"))
        XCTAssertEqual(nested, ["ids": [1, 2], "other": [4, 8]])
        XCTAssertEqual(collection.read() as? String, "{\"ids\":[1,2],\"other\":[4,8]}")
        let before = nested
        XCTAssertNotNil(collection.write(String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)))
        XCTAssertEqual(nested, before)

        var integer: UInt64? = nil
        let exact = try XCTUnwrap(Binding(get: { integer }, set: { integer = $0 }).lookinField(title: "exact"))
        XCTAssertNil(exact.write("18446744073709551615"))
        XCTAssertEqual(integer, UInt64.max)
        XCTAssertNotNil(exact.write("18446744073709551616"))
        XCTAssertEqual(integer, UInt64.max)
        var integerKeys: [Int: String] = [1: "one"]
        let dictionary = try XCTUnwrap(Binding(get: { integerKeys }, set: { integerKeys = $0 }).lookinField(title: "keys"))
        XCTAssertNil(dictionary.write("{\"-2\":\"negative\",\"7\":\"seven\"}"))
        XCTAssertEqual(integerKeys, [-2: "negative", 7: "seven"])
        XCTAssertThrowsError(try LKS_DebugJSON.encode(Array(repeating: String(repeating: "x", count: 32000), count: 4)))
    }
}
