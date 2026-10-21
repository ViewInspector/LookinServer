#if SHOULD_COMPILE_LOOKIN_SERVER && canImport(SwiftUI)
import SwiftUI
import UIKit
import Combine

/// Implemented in Debug compilation copies by Tools/SwiftUIAOP, never in business sources.
@available(iOS 13.0, tvOS 13.0, *)
public protocol LKSInspectableModel {
    @MainActor static func lookinDebugFields(_ access: LKSModelAccess) -> [LKSStateField]
}

@available(iOS 13.0, tvOS 13.0, *)
@MainActor public struct LKSModelAccess {
    let get: () -> Any
    let set: (Any) -> Void

    public func field<Root, Value>(_ name: String, _ keyPath: WritableKeyPath<Root, Value>) -> LKSStateField {
        .binding(name, Binding(get: { (get() as! Root)[keyPath: keyPath] }, set: { value in
            var root = get() as! Root
            // Ordinary stored fields in ObservableObject also need invalidation.
            if let model = root as? any ObservableObject,
               let publisher = model.objectWillChange as? ObservableObjectPublisher { publisher.send() }
            root[keyPath: keyPath] = value // Real Swift setter: preserves @Published, Observation and didSet.
            // Reference mutation must not invoke an unrelated parent property setter.
            if Mirror(reflecting: root).displayStyle != .class { set(root) }
        }))
    }

    public func readOnlyField<Root, Value>(_ name: String, _ keyPath: KeyPath<Root, Value>) -> LKSStateField {
        let value = (get() as! Root)[keyPath: keyPath]
        if Mirror(reflecting: value).displayStyle == .class, Value.self is LKSInspectableModel.Type {
            return .reference(name, value)
        }
        return .readOnly(name, value: { (get() as! Root)[keyPath: keyPath] })
    }
}

@available(iOS 13.0, tvOS 13.0, *)
@MainActor public struct LKSStateField {
    let expand: (AnyObject, String, Int, Set<ObjectIdentifier>, Bool, LKS_AOPExpansionBudget) -> [LKS_LiveBindingField]

    public static func binding<Value>(_ name: String, _ binding: Binding<Value>) -> Self {
        Self { owner, path, depth, visited, inheritedIdentity, budget in
            guard budget.remaining > 0 else { return [] }
            budget.remaining -= 1
            let title = path.isEmpty ? name : path + (name.hasPrefix("[") ? "" : ".") + name
            let value = binding.wrappedValue
            if let container = Value.self as? LKS_DebugContainer.Type {
                let identity: AnyObject
                if inheritedIdentity { identity = owner }
                else if let location = LKS_BindingReflection.child(binding, "location"),
                        let locationID = LKS_BindingReflection.identity(location) { identity = locationID }
                else { identity = owner }
                var result: [LKS_LiveBindingField]
                if let field = binding.lookinField(title: title) {
                    let root = LKS_LiveBindingField(identity: identity, valueType: field.valueType, title: field.title,
                                                   kind: field.kind, options: field.options, read: field.read, write: field.write)
                    root.identityPath = title
                    result = [root]
                } else { result = readOnly(name, value: { binding.wrappedValue }).expand(owner, path, depth, visited, true, budget) }
                guard depth < 8, let snapshot = LKS_ContainerSnapshot.key(value) else { return result }
                let access = LKSModelAccess(get: { binding.wrappedValue }, set: {
                    if let value = $0 as? Value { binding.wrappedValue = value }
                })
                for child in container.lookinChildren(access) {
                    let fields = child.expand(identity, title, depth + 1, visited, true, budget)
                    for field in fields { field.identityPath += "|snapshot:" + snapshot }
                    result += fields
                }
                return result
            }
            if let type = Value.self as? LKSInspectableModel.Type {
                let isReference = Mirror(reflecting: value).displayStyle == .class
                let identity: AnyObject
                if isReference { identity = value as AnyObject }
                else if inheritedIdentity { identity = owner }
                else if let location = LKS_BindingReflection.child(binding, "location"),
                        let locationID = LKS_BindingReflection.identity(location) { identity = locationID }
                else { identity = owner }
                var next = visited
                guard depth < 8, !isReference || next.insert(ObjectIdentifier(identity)).inserted else {
                    return readOnly(name, value: { "Recursive model or depth limit reached" }).expand(owner, path, depth, visited, true, budget)
                }
                let access = LKSModelAccess(get: { binding.wrappedValue }, set: {
                    if let value = $0 as? Value { binding.wrappedValue = value }
                })
                return type.lookinDebugFields(access).prefix(128).flatMap {
                    $0.expand(identity, title, depth + 1, next, true, budget)
                }
            }
            guard let field = binding.lookinField(title: title) else {
                return readOnly(name, value: { binding.wrappedValue }).expand(owner, path, depth, visited, true, budget)
            }
            if inheritedIdentity {
                let wrapped = LKS_LiveBindingField(identity: owner, valueType: field.valueType, title: title,
                                                  kind: field.kind, options: field.options, read: field.read, write: field.write)
                wrapped.identityPath = title
                return [wrapped]
            }
            return [field]
        }
    }

    /// Reference models are mutable through their own property setters. Value types need a Binding.
    public static func reference<Value>(_ name: String, _ value: Value) -> Self {
        guard Mirror(reflecting: value).displayStyle == .class else { return .readOnly(name, value: { value }) }
        return .binding(name, Binding(get: { value }, set: { _ in }))
    }

    public static func readOnly<Value>(_ name: String, value: @escaping () -> Value) -> Self {
        Self { owner, path, _, _, _, _ in
            let title = (path.isEmpty ? name : path + "." + name) + " (read-only)"
            let field = LKS_LiveBindingField(identity: owner, valueType: String(reflecting: Value.self), title: title,
                                            kind: "string", options: [], read: {
                String(String(describing: value()).prefix(4096)) as NSString
            }, write: { _ in "This field is read-only or its type is not supported by the editor." })
            field.identityPath = title
            field.editable = false
            return [field]
        }
    }
}

@available(iOS 13.0, tvOS 13.0, *)
@MainActor public struct LKSStateScope<Content: View>: View {
    @State private var revision: UInt = 0
    private let fields: () -> [LKSStateField]
    private let content: () -> Content
    public init(fields: @escaping () -> [LKSStateField], @ViewBuilder content: @escaping () -> Content) {
        self.fields = fields; self.content = content
    }
    public var body: some View {
        let _ = revision
        content().background(LKSStateProbe(fields: fields, invalidate: { revision &+= 1 }).frame(width: 0, height: 0))
    }
}

@available(iOS 13.0, tvOS 13.0, *)
@MainActor public struct LKSStateProbe: UIViewRepresentable {
    private let fields: () -> [LKSStateField]
    private let invalidate: (() -> Void)?
    public init(fields: @escaping () -> [LKSStateField], invalidate: (() -> Void)? = nil) {
        self.fields = fields; self.invalidate = invalidate
    }
    public func makeUIView(context: Context) -> UIView {
        let view = LKS_AOPProbeView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.backgroundColor = .clear
        view.fields = fields
        view.invalidate = invalidate
        LKS_SwiftUIAOP.probes.add(view)
        return view
    }
    public func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? LKS_AOPProbeView)?.fields = fields
        (uiView as? LKS_AOPProbeView)?.invalidate = invalidate
    }
    public static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        (uiView as? LKS_AOPProbeView)?.fields = nil
        (uiView as? LKS_AOPProbeView)?.invalidate = nil
    }
}

@MainActor final class LKS_AOPExpansionBudget { var remaining = 2048 }

@MainActor final class LKS_AOPProbeView: UIView {
    var fields: (() -> [LKSStateField])?
    var invalidate: (() -> Void)?
    override var intrinsicContentSize: CGSize { .zero }
}

@MainActor enum LKS_SwiftUIAOP {
    static let probes = NSHashTable<LKS_AOPProbeView>.weakObjects()
    @available(iOS 13.0, tvOS 13.0, *)
    static func invalidate(_ host: UIView) {
        for probe in probes.allObjects where probe.window != nil {
            var ancestor = probe.superview
            while let view = ancestor, !LKS_SwiftUIRuntime.supports(view) { ancestor = view.superview }
            if ancestor === host { probe.invalidate?() }
        }
    }
    @available(iOS 13.0, tvOS 13.0, *)
    static func fields(in host: UIView) -> [LKS_LiveBindingField] {
        var result: [LKS_LiveBindingField] = []
        let budget = LKS_AOPExpansionBudget()
        for probe in probes.allObjects where probe.window != nil {
            // Use the nearest hosting view, so nested hosts don't expose each other's fields.
            var ancestor = probe.superview
            while let view = ancestor, !LKS_SwiftUIRuntime.supports(view) { ancestor = view.superview }
            guard ancestor === host else { continue }
            for field in probe.fields?().prefix(128) ?? [] {
                result += field.expand(probe, "", 0, [], false, budget)
                if result.count >= 512 || budget.remaining <= 0 {
                    let notice = LKSStateField.readOnly("Inspection limit", value: { "Truncated at 512 fields or 2048 model visits." })
                    return Array(result.prefix(511)) + notice.expand(probe, "", 0, [], false, budget)
                }
            }
        }
        return result
    }
}
#endif
