// Compile with Xcode's SwiftParser/SwiftSyntax host libraries. No third-party downloads.
import Foundation
import SwiftParser
import SwiftSyntax

struct Edit { let start: Int; let end: Int; let text: String }
final class Instrumenter: SyntaxVisitor {
    var edits: [Edit] = []
    var views = 0
    var models = 0
    var diagnostics: [String] = []
    init() { super.init(viewMode: .sourceAccurate) }

    func properties(_ members: MemberBlockSyntax) -> [(VariableDeclSyntax, PatternBindingSyntax, String)] {
        members.members.flatMap { member -> [(VariableDeclSyntax, PatternBindingSyntax, String)] in
            guard let decl = member.decl.as(VariableDeclSyntax.self),
                  !decl.modifiers.contains(where: { ["static", "class", "lazy"].contains($0.name.text) }) else { return [] }
            return decl.bindings.compactMap { binding in
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
                return (decl, binding, identifier.identifier.trimmedDescription)
            }
        }
    }
    func attributes(_ decl: VariableDeclSyntax) -> Set<String> {
        Set(decl.attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.components(separatedBy: ".").last })
    }
    func stored(_ binding: PatternBindingSyntax) -> Bool {
        guard let block = binding.accessorBlock else { return true }
        switch block.accessors {
        case .accessors(let list): return list.allSatisfy { ["willSet", "didSet"].contains($0.accessorSpecifier.text) }
        default: return false
        }
    }
    func instrument(name: String, inheritance: InheritanceClauseSyntax?, block: MemberBlockSyntax, conformanceOffset: Int, model: Bool) {
        let props = properties(block)
        if block.members.contains(where: { $0.decl.is(IfConfigDeclSyntax.self) }) {
            diagnostics.append("\(name): conditional members are not automatically exposed")
        }
        let isView = inheritance?.inheritedTypes.contains { ["View", "SwiftUI.View"].contains($0.type.trimmedDescription) } == true
        if isView {
            guard let (decl, binding, _) = props.first(where: { $0.2 == "body" }),
                  let body = binding.accessorBlock, binding.typeAnnotation?.type.trimmedDescription.contains("some") == true,
                  decl.bindings.count == 1 else {
                diagnostics.append("Skipped \(name): body must be a single opaque some View property")
                return
            }
            var fields: [String] = []
            for (property, value, key) in props where key != "body" && stored(value) {
                let attrs = attributes(property)
                let title = String(reflecting: name + "." + key.replacingOccurrences(of: "`", with: ""))
                if !attrs.isDisjoint(with: ["State", "Binding", "AppStorage", "SceneStorage"]) {
                    fields.append(".binding(\(title), self.$\(key.replacingOccurrences(of: "`", with: "")))")
                } else if !attrs.isDisjoint(with: ["StateObject", "ObservedObject", "EnvironmentObject", "Environment", "Bindable"]) || attrs.isEmpty {
                    fields.append(".reference(\(title), self.\(key))")
                }
            }
            guard !fields.isEmpty else { return }
            if props.contains(where: { $0.2 == "__lookinOriginalBody" }) {
                diagnostics.append("Skipped \(name): reserved Lookin member already exists")
                return
            }
            var original = decl.trimmedDescription
            let offset = binding.pattern.positionAfterSkippingLeadingTrivia.utf8Offset - decl.positionAfterSkippingLeadingTrivia.utf8Offset
            var bytes = Array(original.utf8)
            bytes.replaceSubrange(offset..<(offset + 4), with: "__lookinOriginalBody".utf8)
            original = String(decoding: bytes, as: UTF8.self)
            if !attributes(decl).contains("ViewBuilder") { original = "@SwiftUI.ViewBuilder\n" + original }
            let access = decl.modifiers.filter { ["public", "package", "internal", "fileprivate", "private"].contains($0.name.text) }.map(\.trimmedDescription).joined(separator: " ")
            let wrapper = """
            \(original)
            \(access) var body: some SwiftUI.View {
                LKSStateScope(fields: {
                    [\(fields.joined(separator: ",\n"))]
                }) { self.__lookinOriginalBody }
            }
            """
            edits.append(Edit(start: decl.positionAfterSkippingLeadingTrivia.utf8Offset, end: decl.endPositionBeforeTrailingTrivia.utf8Offset, text: wrapper))
            _ = body
            views += 1
        } else if model {
            var fields: [String] = []
            for (decl, binding, key) in props where stored(binding) {
                let attrs = attributes(decl)
                if attrs.contains("available") {
                    diagnostics.append("Skipped \(name).\(key): property-specific availability")
                    continue
                }
                // Unknown property wrappers may prohibit writable key paths. Surface them read-only.
                let writable = decl.bindingSpecifier.text == "var" && (attrs.isEmpty || attrs == ["Published"] || attrs == ["ObservationIgnored"])
                fields.append("access.\(writable ? "field" : "readOnlyField")(\(String(reflecting: key.replacingOccurrences(of: "`", with: ""))), \\\(name).\(key))")
            }
            guard !fields.isEmpty, !block.description.contains("lookinDebugFields") else { return }
            let inheritanceEnd = inheritance?.endPositionBeforeTrailingTrivia.utf8Offset ?? conformanceOffset
            edits.append(Edit(start: inheritanceEnd, end: inheritanceEnd, text: inheritance == nil ? ": LKSInspectableModel " : ", LKSInspectableModel"))
            let method = """

                @MainActor public static func lookinDebugFields(_ access: LKSModelAccess) -> [LKSStateField] {
                    [\(fields.joined(separator: ",\n"))]
                }

            """
            edits.append(Edit(start: block.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset, end: block.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset, text: method))
            models += 1
        }
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        instrument(name: node.name.trimmedDescription, inheritance: node.inheritanceClause, block: node.memberBlock, conformanceOffset: (node.genericParameterClause?.endPositionBeforeTrailingTrivia ?? node.name.endPositionBeforeTrailingTrivia).utf8Offset, model: true)
        return .visitChildren
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let model = node.attributes.contains { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription.components(separatedBy: ".").last == "Observable" } || node.inheritanceClause?.inheritedTypes.contains { $0.type.trimmedDescription.components(separatedBy: ".").last == "ObservableObject" } == true
        instrument(name: node.name.trimmedDescription, inheritance: node.inheritanceClause, block: node.memberBlock, conformanceOffset: (node.genericParameterClause?.endPositionBeforeTrailingTrivia ?? node.name.endPositionBeforeTrailingTrivia).utf8Offset, model: model)
        return .visitChildren
    }
}

let args = CommandLine.arguments
if args.count < 4 {
    fputs("Usage: instrument OUTPUT_DIR MODULE SOURCE.swift...\n", stderr)
    exit(2)
}
let directory = URL(fileURLWithPath: args[1]).standardizedFileURL
let module = args[2]
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var roots: [[String: Any]] = []
var report: [[String: Any]] = []
for (index, input) in args.dropFirst(3).enumerated() {
    let sourceURL = URL(fileURLWithPath: input).standardizedFileURL
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let tree = Parser.parse(source: source)
    guard !tree.hasError else { fputs("error: SwiftUI AOP cannot parse \(input)\n", stderr); exit(1) }
    let pass = Instrumenter()
    pass.walk(tree)
    var bytes = Array(source.utf8)
    var previous = bytes.count + 1
    for edit in pass.edits.sorted(by: { $0.start > $1.start }) {
        guard edit.end <= previous else { fputs("error: SwiftUI AOP overlapping transformations in \(input)\n", stderr); exit(1) }
        bytes.replaceSubrange(edit.start..<edit.end, with: edit.text.utf8)
        previous = edit.start
    }
    if !pass.edits.isEmpty {
        let generated = "import SwiftUI\nimport \(module)\n" + String(decoding: bytes, as: UTF8.self)
        guard !Parser.parse(source: generated).hasError else { fputs("error: SwiftUI AOP generated invalid syntax for \(input)\n", stderr); exit(1) }
        let output = directory.appendingPathComponent("\(index)-" + sourceURL.lastPathComponent)
        // Avoid timestamp churn and unnecessary incremental recompilation.
        if (try? String(contentsOf: output, encoding: .utf8)) != generated { try generated.write(to: output, atomically: true, encoding: .utf8) }
        roots.append(["type": "file", "name": sourceURL.path, "external-contents": output.path])
    }
    report.append(["source": sourceURL.path, "views": pass.views, "models": pass.models, "diagnostics": pass.diagnostics])
    for message in pass.diagnostics { fputs("warning: SwiftUI AOP: \(message) in \(input)\n", stderr) }
}
let overlay: [String: Any] = ["version": 0, "case-sensitive": true, "use-external-names": false, "roots": roots]
for (name, object) in [("overlay.json", overlay as Any), ("report.json", report as Any)] {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    let target = directory.appendingPathComponent(name)
    if (try? Data(contentsOf: target)) != data { try data.write(to: target, options: .atomic) }
}
print("SwiftUI AOP: \(roots.count) compilation copies; business sources unchanged. Report: \(directory.path)/report.json")
