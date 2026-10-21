import XCTest
import SwiftUI
import UIKit
@testable import LookinServerSwift
import LookinServer

final class SwiftUIRuntimeTests: XCTestCase {
    private func rawNode(_ type: String = "SwiftUI.Text", position: [Double]? = [10, 20], size: [Double]? = [80, 30], transform: [String: Any]? = nil) -> [String: Any] {
        var properties: [[String: Any]] = [["id": 0, "attribute": ["type": type, "readableType": type]]]
        if let p = position { properties.append(["id": 3, "attribute": ["value": p]]) }
        if let s = size { properties.append(["id": 4, "attribute": ["value": s]]) }
        if let t = transform { properties.append(["id": 2, "attribute": ["value": t]]) }
        return ["properties": properties, "children": []]
    }

    func testLayoutCoordinatesAndTranslation() throws {
        var parser = LKS_RuntimeTreeParser()
        let node = try XCTUnwrap(parser.parse([rawNode(transform: ["items": [["translation": [5, 7]]], "positionAdjustment": [1, 2]])], parentFrame: .zero, transform: [:], depth: 0).first)
        XCTAssertTrue(node.hasGeometry)
        XCTAssertEqual(node.frameInHost, CGRect(x: 16, y: 29, width: 80, height: 30))
    }

    func testUnknownTransformAndMalformedGeometryDoNotInventBounds() {
        for raw in [rawNode(transform: ["items": [["unsupportedProjection": [1, 2, 3]]]]), rawNode(size: [-1, 20]), rawNode(position: [.infinity, 0]), rawNode(size: nil)] {
            var parser = LKS_RuntimeTreeParser()
            let nodes = parser.parse([raw], parentFrame: CGRect(x: 2, y: 3, width: 10, height: 10), transform: [:], depth: 0)
            XCTAssertFalse(nodes[0].hasGeometry)
        }
    }

    func testSnapshotBudgetReportsTruncation() {
        var parser = LKS_RuntimeTreeParser(remaining: 2)
        XCTAssertEqual(parser.parse([rawNode(), rawNode(), rawNode()], parentFrame: .zero, transform: [:], depth: 0).count, 2)
        XCTAssertTrue(parser.truncated)
    }

    @MainActor func testRuntimeHierarchyDetailRefreshAndHostLifetime() async throws {
        guard !UIApplication.shared.connectedScenes.isEmpty else {
            throw XCTSkip("Run the SwiftUIRuntimeHost scheme for scene-backed runtime and screenshot tests")
        }
        let state = FixtureState()
        var host: UIHostingController<Fixture>? = UIHostingController(rootView: Fixture(state: state))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        window.rootViewController = host
        window.makeKeyAndVisible()
        host?.view.frame = window.bounds
        host?.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = state.bodyCalls
        let tree = try XCTUnwrap(LKS_SwiftUIRuntime.capture(host!.view))
        XCTAssertFalse(tree.children.isEmpty, tree.valueDescription ?? "No runtime tree")
        XCTAssertEqual(state.bodyCalls, before, "Inspecting must not evaluate business body")
        func flatten(_ n: LKS_SwiftUIViewNode) -> [LKS_SwiftUIViewNode] { [n] + n.children.flatMap(flatten) }
        let nodes = flatten(tree)
        XCTAssertTrue(nodes.contains { $0.fullTypeName.hasSuffix(".Text") && $0.hasGeometry })
        XCTAssertTrue(nodes.contains { ($0.attributeDescription ?? "").contains("Row") })
        let items = try XCTUnwrap(LKS_SwiftUIDisplayItemsMaker.displayItems(forHostingView: host!.view))
        let flat = LookinDisplayItem.flatItems(fromHierarchicalItems: items)!
        XCTAssertTrue(flat.allSatisfy(\.shouldCaptureImage), "Layout-less ancestors must not disable descendant previews in existing clients")
        let text = try XCTUnwrap(flat.first { item in
            item.viewObject?.rawClassName() == "Text" && item.attributesGroupList.contains { group in
                group.attrSections.contains { section in
                    section.attributes.contains { $0.displayTitle == "Bounds in HostingView" }
                }
            }
        })
        XCTAssertNotEqual(text.layerObject.oid, 0)
        let object = try XCTUnwrap(NSObject.lks_object(withOid: text.layerObject.oid))
        XCTAssertTrue(LKS_SwiftUIDisplayItemsMaker.isSnapshotObject(object))
        let task = LookinStaticAsyncUpdateTask()
        task.oid = text.layerObject.oid
        task.taskType = .groupScreenshot
        let detail = try XCTUnwrap(LKS_SwiftUIDisplayItemsMaker.detail(for: object, task: task))
        XCTAssertEqual(detail.failureCode, 0)
        XCTAssertNotNil(detail.groupScreenshot, "host=\(host!.view.bounds), window=\(window.bounds), node=\(text.frame), detail=\(String(describing: detail.frameValue))")
        XCTAssertFalse(detail.attributesGroupList.isEmpty)
        LKS_SwiftUIDisplayItemsMaker.populateScreenshots(for: items)
        XCTAssertNotNil(text.groupScreenshot)
        let archived = try NSKeyedArchiver.archivedData(withRootObject: items, requiringSecureCoding: false)
        let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(archived) as? [LookinDisplayItem])
        XCTAssertEqual(decoded.first?.layerObject.oid, items.first?.layerObject.oid)
        let decodedText = LookinDisplayItem.flatItems(fromHierarchicalItems: decoded)?.first { $0.layerObject.oid == text.layerObject.oid }
        XCTAssertNotNil(decodedText?.groupScreenshot)
        for count in [0, 4, 1, 5, 0, 3] {
            state.rows = count
            try await Task.sleep(nanoseconds: 30_000_000)
            host?.view.layoutIfNeeded()
            let calls = state.bodyCalls
            let snapshot = try XCTUnwrap(LKS_SwiftUIRuntime.capture(host!.view))
            XCTAssertFalse(snapshot.children.isEmpty)
            XCTAssertEqual(state.bodyCalls, calls)
        }
        // Existing opaque IDs remain usable for an unchanged path/type snapshot.
        _ = LKS_SwiftUIDisplayItemsMaker.displayItems(forHostingView: host!.view)
        XCTAssertEqual(LKS_SwiftUIDisplayItemsMaker.detail(for: object, task: task)?.failureCode, 0)
        state.rows = 5
        try await Task.sleep(nanoseconds: 200_000_000)
        host?.view.layoutIfNeeded()
        let updated = try XCTUnwrap(LKS_SwiftUIRuntime.capture(host!.view))
        XCTAssertTrue(flatten(updated).contains { ($0.attributeDescription ?? "").contains("Row 4") })
        window.isHidden = true
        window.rootViewController = nil
        host = nil
        XCTAssertEqual(LKS_SwiftUIDisplayItemsMaker.detail(for: object, task: task)?.failureCode, -1)
    }
    @MainActor func testEmbeddedHostingCoordinatesStayLocalWhenMoved() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Run the SwiftUIRuntimeHost scheme for scene-backed coordinate tests")
        }
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        let host = UIHostingController(rootView: Text("Coordinate probe"))
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        host.view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        func textFrame(_ node: LKS_SwiftUIViewNode) -> CGRect? {
            if node.fullTypeName == "SwiftUI.Text", node.hasGeometry { return node.frameInHost }
            return node.children.compactMap(textFrame).first
        }
        let initial = try XCTUnwrap(textFrame(try XCTUnwrap(LKS_SwiftUIRuntime.capture(host.view))))
        host.view.frame.origin = CGPoint(x: 37, y: 220)
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        let moved = try XCTUnwrap(textFrame(try XCTUnwrap(LKS_SwiftUIRuntime.capture(host.view))))
        XCTAssertEqual(moved.minX, initial.minX, accuracy: 0.5)
        // The initial host touches the safe area; use a second fully inset position.
        host.view.frame.origin = CGPoint(x: 57, y: 320)
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        let movedAgain = try XCTUnwrap(textFrame(try XCTUnwrap(LKS_SwiftUIRuntime.capture(host.view))))
        XCTAssertEqual(movedAgain.minX, moved.minX, accuracy: 0.5)
        XCTAssertEqual(movedAgain.minY, moved.minY, accuracy: 0.5)
        XCTAssertTrue(host.view.bounds.contains(movedAgain))
        window.isHidden = true
        window.rootViewController = nil
    }

    @MainActor func testLiveBindingEditsReachStateAndRejectExpiredReferences() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Run the SwiftUIRuntimeHost scheme")
        }
        let window = UIWindow(windowScene: scene)
        var host: UIHostingController<StateWriteFixture>? = UIHostingController(rootView: StateWriteFixture())
        window.rootViewController = host
        window.makeKeyAndVisible()
        host?.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 250_000_000)
        let items = try XCTUnwrap(LKS_SwiftUIDisplayItemsMaker.displayItems(forHostingView: host!.view))
        let attributes = items[0].attributesGroupList.flatMap(\.attrSections).flatMap(\.attributes)
            .filter { $0.customSetterID?.hasPrefix("lookin.swiftui.binding.") == true }
        XCTAssertEqual(attributes.count, 3, "Constant bindings must not become editable")
        let string = try XCTUnwrap(attributes.first { $0.displayTitle.contains("TextField") })
        let number = try XCTUnwrap(attributes.first { $0.displayTitle.contains("Slider") })
        let flag = try XCTUnwrap(attributes.first { $0.displayTitle.contains("Toggle") })
        func submit(_ attribute: LookinAttribute, _ value: Any) -> Bool {
            let request = LookinCustomAttrModification()
            request.customSetterID = attribute.customSetterID
            request.attrType = attribute.attrType
            request.value = value
            return LKS_CustomAttrModificationHandler.handle(request)
        }
        XCTAssertFalse(submit(string, NSNumber(value: 3)))
        XCTAssertFalse(submit(number, NSNumber(value: Double.nan)))
        XCTAssertTrue(submit(string, "Edited from Lookin"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(submit(number, NSNumber(value: 0.75)))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(submit(flag, NSNumber(value: false)))
        try await Task.sleep(nanoseconds: 200_000_000)
        host?.view.layoutIfNeeded()
        func values(_ node: LKS_SwiftUIViewNode) -> String {
            (node.attributeDescription ?? "") + node.children.map(values).joined()
        }
        let tree = try XCTUnwrap(LKS_SwiftUIRuntime.capture(host!.view))
        let rendered = values(tree)
        XCTAssertTrue(rendered.contains("Edited from Lookin"))
        XCTAssertTrue(rendered.contains("STATE=false|Edited from Lookin|0.75"), "Business @State must update, not just control appearance")
        XCTAssertFalse(rendered.contains("VISIBLE_BRANCH"))
        let rootRecord = try XCTUnwrap(NSObject.lks_object(withOid: items[0].layerObject.oid))
        let reload = LookinStaticAsyncUpdateTask()
        reload.oid = items[0].layerObject.oid
        reload.needBasisVisualInfo = true
        reload.needSubitems = true
        reload.taskType = .groupScreenshot
        let detail = try XCTUnwrap(LKS_SwiftUIDisplayItemsMaker.detail(for: rootRecord, task: reload))
        XCTAssertEqual(detail.failureCode, 0)
        XCTAssertNil(detail.groupScreenshot, "The synthetic root has no independent layout geometry")
        let refreshedFlag = detail.attributesGroupList.flatMap(\.attrSections).flatMap(\.attributes)
            .first { $0.customSetterID == flag.customSetterID }
        XCTAssertEqual(refreshedFlag?.value as? NSNumber, NSNumber(value: false))
        XCTAssertFalse(LookinDisplayItem.flatItems(fromHierarchicalItems: detail.subitems)?.contains { item in
            item.attributesGroupList.flatMap(\.attrSections).flatMap(\.attributes)
                .contains { ($0.value as? String)?.contains("VISIBLE_BRANCH") == true }
        } ?? true)
        // Toggle removes the controls. Their old tokens must never write elsewhere.
        XCTAssertFalse(submit(string, "Stale edit"))
        XCTAssertFalse(submit(number, NSNumber(value: 0.5)))
        XCTAssertTrue(submit(flag, NSNumber(value: true)))
        try await Task.sleep(nanoseconds: 200_000_000)
        let updated = LKS_SwiftUIStateEditor.fields(for: host!.view)
        XCTAssertTrue(updated.contains { ($0["value"] as? String) == "Edited from Lookin" })
        window.rootViewController = nil
        host = nil
        XCTAssertFalse(submit(flag, NSNumber(value: false)))
    }

    @MainActor func testTypedRepresentableBindingsValidateEnumAndIntegerWrites() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Run the SwiftUIRuntimeHost scheme")
        }
        let host = UIHostingController(rootView: TypedStateFields())
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 250_000_000)
        let fields = LKS_SwiftUIStateEditor.fields(for: host.view)
        let count = try XCTUnwrap(fields.first { ($0["valueType"] as? String) == "number" }?["identifier"] as? String)
        let choice = try XCTUnwrap(fields.first { ($0["valueType"] as? String) == "enum" }?["identifier"] as? String)
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: NSNumber(value: 1.5), identifier: count))
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: NSNumber(value: Int.max), identifier: count))
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: "unknown", identifier: choice))
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: NSNumber(value: 42), identifier: count))
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: "second", identifier: choice))
        try await Task.sleep(nanoseconds: 100_000_000)
        let updated = LKS_SwiftUIStateEditor.fields(for: host.view)
        XCTAssertEqual(updated.first { ($0["identifier"] as? String) == count }?["value"] as? NSNumber, 42)
        XCTAssertEqual(updated.first { ($0["identifier"] as? String) == choice }?["value"] as? String, "second")
        func labels(_ view: UIView) -> [String] {
            ((view as? UILabel)?.text.map { [$0] } ?? []) + view.subviews.flatMap(labels)
        }
        XCTAssertTrue(labels(host.view).contains("42|second"), "The business representable must receive the new state")
    }

    @MainActor func testEqualValueBindingsKeepIdentityAcrossReorderAndRemoval() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Run the SwiftUIRuntimeHost scheme")
        }
        let state = ReorderedState()
        let host = UIHostingController(rootView: ReorderedFields(state: state))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 250_000_000)
        let fields = LKS_SwiftUIStateEditor.fields(for: host.view)
        XCTAssertEqual(fields.count, 2)
        let first = try XCTUnwrap(fields.first?["identifier"] as? String)
        let second = try XCTUnwrap(fields.last?["identifier"] as? String)
        XCTAssertNotEqual(first, second, "Equal values are distinct writable locations")
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: "First", identifier: first))
        try await Task.sleep(nanoseconds: 100_000_000)
        state.ids.reverse()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: "Second", identifier: second))
        try await Task.sleep(nanoseconds: 100_000_000)
        func rendered(_ node: LKS_SwiftUIViewNode) -> String {
            (node.attributeDescription ?? "") + node.children.map(rendered).joined()
        }
        let snapshot = rendered(try XCTUnwrap(LKS_SwiftUIRuntime.capture(host.view)))
        XCTAssertTrue(snapshot.contains("ROW=1|First"))
        XCTAssertTrue(snapshot.contains("ROW=2|Second"))
        state.ids.removeAll { $0 == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(LKS_SwiftUIStateEditor.modify(value: "Stale", identifier: first))
        XCTAssertNil(LKS_SwiftUIStateEditor.modify(value: "Still second", identifier: second))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(rendered(try XCTUnwrap(LKS_SwiftUIRuntime.capture(host.view))).contains("ROW=2|Still second"))
    }
}

private enum StateChoice: CaseIterable { case first, second }
private struct TypedStateFields: View {
    @State private var count = 1
    @State private var choice = StateChoice.first
    var body: some View { BindingCarrier(count: $count, choice: $choice).frame(height: 30) }
}
private struct BindingCarrier: UIViewRepresentable {
    @Binding var count: Int
    @Binding var choice: StateChoice
    func makeUIView(context: Context) -> UILabel { UILabel() }
    func updateUIView(_ view: UILabel, context: Context) { view.text = "\(count)|\(choice)" }
}

private final class ReorderedState: ObservableObject {
    @Published var ids = [1, 2]
}
private struct ReorderedFields: View {
    @ObservedObject var state: ReorderedState
    var body: some View { VStack { ForEach(state.ids, id: \.self) { StateRow(id: $0) } } }
}
private struct StateRow: View {
    let id: Int
    @State private var text = "Same"
    var body: some View { VStack { TextField("Row", text: $text); Text(verbatim: "ROW=\(id)|\(text)") } }
}

private final class FixtureState: ObservableObject {
    @Published var rows = 3
    var bodyCalls = 0
}
private struct Fixture: View {
    @ObservedObject var state: FixtureState
    var body: some View {
        state.bodyCalls += 1
        return VStack {
            Text("Runtime fixture").padding(12)
            Button("Transition") { state.rows += 1 }
            if state.rows > 2 { Text("Conditional transition") }
            ForEach(0..<state.rows, id: \.self) { Text("Row \($0)") }
        }.padding(20)
    }
}

private struct StateWriteFixture: View {
    @State private var flag = true
    @State private var text = "Before"
    @State private var number = 0.2
    var body: some View {
        VStack {
            Toggle("Show controls", isOn: $flag)
            if flag {
                BoundStateFields(text: $text, number: $number)
                TextField("Constant", text: .constant("Constant"))
                Text("VISIBLE_BRANCH")
            }
            Text(verbatim: "STATE=\(flag)|\(text)|\(number)")
        }.padding()
    }
}

private struct BoundStateFields: View {
    @Binding var text: String
    @Binding var number: Double
    var body: some View {
        VStack { TextField("Text", text: $text); Slider(value: $number) }
    }
}
