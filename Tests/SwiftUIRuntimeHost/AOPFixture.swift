// Deliberately contains no Lookin imports, markers, conformances or debug modifiers.
// The build phase instruments a compilation copy; tests exercise these original sources.
import SwiftUI
import Observation

@MainActor final class AOPPublishedModel: ObservableObject {
    @Published var title = "Published initial"
    @Published var number = 4 { didSet { setterCalls += 1 } }
    private(set) var setterCalls = 0
    private var secret = "Private initial"
    let immutable = "Constant model field"
    var summary: String { "\(title)|\(number)|\(secret)|\(setterCalls)" }
}

@available(iOS 17.0, *)
@Observable @MainActor final class AOPObservableModel {
    var title = "Observed initial"
    var enabled = true
}

struct AOPValueModel {
    var score = 7
    let code = "Fixed code"
}

@available(iOS 17.0, *)
struct AOPUnboundFixture: View {
    @State private var counter = 13
    @State private var neverRendered = 44
    @State private var showChild = true
    @State private var value = AOPValueModel()
    @StateObject private var published = AOPPublishedModel()
    @State private var observed = AOPObservableModel()
    var body: some View {
        VStack {
            Text(verbatim: "COUNTER=\(counter);VALUE=\(value.score)")
            Text(verbatim: published.summary)
            Text(verbatim: "OBSERVED=\(observed.title)|\(observed.enabled)")
            if showChild { AOPUnboundChild() }
        }
    }
}

struct AOPUnboundChild: View {
    @State private var text = "Unbound child"
    var body: some View { Text(verbatim: "CHILD=\(text)") }
}

struct AOPModelReplacementFixture: View {
    @State private var useAlternate = false
    @StateObject private var first = AOPPublishedModel()
    @StateObject private var second = AOPPublishedModel()
    var body: some View {
        AOPModelBranch(model: useAlternate ? second : first)
    }
}

struct AOPModelBranch: View {
    @ObservedObject var model: AOPPublishedModel
    var body: some View { Text(verbatim: model.title) }
}

struct AOPHashRow: Hashable { var score: Int }

struct AOPEquatableLeaf: View, Equatable {
    var title: String
    var body: some View { Text(verbatim: title) }
}

struct AOPCodableRow: Codable, Identifiable {
    var id: Int
    var name: String
}

@MainActor final class AOPCollectionModel: ObservableObject {
    @Published var values: [Int] = [1] { didSet { writes += 1 } }
    @Published var note: String? = nil
    private(set) var writes = 0
}

@available(iOS 17.0, *)
@Observable @MainActor final class AOPObservedCollectionModel {
    var tags: Set<String> = ["old"]
}

@available(iOS 17.0, *)
struct AOPContainerFixture: View {
    @State private var note: String? = nil
    @State private var flag: Bool? = nil
    @State private var numbers: [Int] = [1, 2]
    @State private var mapping: [String: Int?] = ["old": 1]
    @State private var tags: Set<String> = ["old"]
    @State private var nested: [[Int?]] = [[1, nil]]
    @State private var row: AOPCodableRow? = nil
    @State private var rows: [AOPCodableRow] = [AOPCodableRow(id: 1, name: "One")]
    @State private var plainRows: [AOPValueModel] = [AOPValueModel(score: 2), AOPValueModel(score: 3)]
    @State private var integer: Int64? = nil
    @State private var references: [AOPPublishedModel] = [AOPPublishedModel()]
    @State private var hashRows: Set<AOPHashRow> = [AOPHashRow(score: 2)]
    @StateObject private var published = AOPCollectionModel()
    @State private var observed = AOPObservedCollectionModel()
    var body: some View {
        VStack {
            Text(verbatim: "NOTE=\(note ?? "nil");FLAG=\(flag.map(String.init) ?? "nil")")
            Text(verbatim: "NUMBERS=\(numbers.map(String.init).joined(separator: ","));TAGS=\(tags.sorted().joined(separator: ","))")
            Text(verbatim: "MAP=\(mapping.keys.sorted().map { "\($0):\(mapping[$0]!.map(String.init) ?? "null")" }.joined(separator: ","))")
            Text(verbatim: "NESTED=\(nested.map { $0.map { $0.map(String.init) ?? "null" }.joined(separator: ",") }.joined(separator: ";"))")
            Text(verbatim: "ROW=\(row?.name ?? "nil");INT64=\(integer.map(String.init) ?? "nil")")
            ForEach(rows) { row in Text(verbatim: "ITEM=\(row.id):\(row.name)") }
            Text(verbatim: "PLAIN=\(plainRows.map { String($0.score) }.joined(separator: ","))")
            Text(verbatim: "PUBLISHED=\(published.values.map(String.init).joined(separator: ","))|\(published.note ?? "nil")|\(published.writes)")
            Text(verbatim: "REFERENCE=\(references.first?.title ?? "empty");HASH-ROWS=\(hashRows.map { String($0.score) }.sorted().joined(separator: ","))")
            AOPUnboundChild()
            AOPEquatableLeaf(title: "EQUATABLE=" + (references.first?.title ?? "empty"))
            Text(verbatim: "OBSERVED-TAGS=\(observed.tags.sorted().joined(separator: ","))")
        }
    }
}
