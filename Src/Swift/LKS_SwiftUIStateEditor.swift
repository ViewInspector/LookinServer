#if SHOULD_COMPILE_LOOKIN_SERVER && canImport(SwiftUI)
import SwiftUI
import UIKit

// The rendered display list retains installed bindings, unlike the unmounted
// rootView copy. Mirror is only used for discovery; writes use Binding's setter.
// No View.body invocation, ABI offsets, root replacement or business markers.
@available(iOS 13.0, tvOS 13.0, *)
@MainActor protocol LKS_AnyLiveBinding {
    func lookinField(title: String) -> LKS_LiveBindingField?
}

@available(iOS 13.0, tvOS 13.0, *)
extension Binding: LKS_AnyLiveBinding {
    func lookinField(title: String) -> LKS_LiveBindingField? {
        guard let location = LKS_BindingReflection.child(self, "location"),
              let identity = LKS_BindingReflection.identity(location) else { return nil }
        let typeName = String(reflecting: Value.self)
        let enumValues: [Value]
        if let type = Value.self as? any CaseIterable.Type {
            var values: [Value] = []
            for element in type.allCases {
                guard values.count < 256 else { return nil }
                if let value = element as? Value { values.append(value) }
            }
            enumValues = values
        } else { enumValues = [] }
        let enumLabels = enumValues.map { String(describing: $0) }
        let toggle = typeName == "SwiftUI.ToggleState" && Set(enumLabels) == Set(["off", "on", "mixed"])
        let kind: String
        if Value.self == Bool.self || toggle { kind = "bool" }
        else if Value.self == String.self { kind = "string" }
        else if Value.self == Double.self || Value.self == Float.self || Value.self == CGFloat.self || Value.self == Int.self { kind = "number" }
        else if !enumValues.isEmpty && Set(enumLabels).count == enumLabels.count { kind = "enum" }
        else { return lookinJSONField(title: title, identity: identity) }

        func read() -> NSObject? {
            let value = wrappedValue
            if toggle {
                let label = String(describing: value)
                guard label == "on" || label == "off" else { return nil }
                return NSNumber(value: label == "on")
            }
            if kind == "enum" { return String(describing: value) as NSString }
            if let value = value as? String { return value as NSString }
            if let value = value as? Bool { return NSNumber(value: value) }
            // The existing dashboard uses a Double editor; hide integers it cannot represent exactly.
            if let value = value as? Int { return abs(Double(value)) <= 9_007_199_254_740_991 ? NSNumber(value: value) : nil }
            if let value = value as? Double { return value.isFinite ? NSNumber(value: value) : nil }
            if let value = value as? Float { return value.isFinite ? NSNumber(value: value) : nil }
            if let value = value as? CGFloat { return value.isFinite ? NSNumber(value: Double(value)) : nil }
            return nil
        }
        guard read() != nil else { return nil }
        return LKS_LiveBindingField(identity: identity, valueType: typeName, title: title, kind: kind,
                                   options: kind == "enum" ? enumLabels : [], read: read) { input in
            let converted: Value?
            if kind == "bool" {
                guard let number = input as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() || number == 0 || number == 1 else {
                    return "Expected a Boolean value."
                }
                if toggle { converted = enumValues.first { String(describing: $0) == (number.boolValue ? "on" : "off") } }
                else { converted = number.boolValue as? Value }
            } else if kind == "string" {
                guard let string = input as? String, string.utf8.count <= 65536 else { return "Expected a string of at most 64 KiB." }
                converted = string as? Value
            } else if kind == "enum" {
                guard let label = input as? String else { return "Expected an enum case name." }
                converted = enumValues.first { String(describing: $0) == label }
            } else {
                guard let number = input as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                    return "Expected a finite number."
                }
                if Value.self == Int.self {
                    guard abs(number.doubleValue) <= 9_007_199_254_740_991 else { return "Integer exceeds the dashboard's exact numeric range." }
                    converted = Int(exactly: number.doubleValue) as? Value
                }
                else if Value.self == Float.self {
                    let value = Float(number.doubleValue)
                    converted = value.isFinite ? value as? Value : nil
                } else if Value.self == CGFloat.self { converted = CGFloat(number.doubleValue) as? Value }
                else { converted = number.doubleValue as? Value }
            }
            guard let converted = converted else { return "The value is outside this binding's supported type or range." }
            self.wrappedValue = converted
            // Rejected/constant/computed bindings must not report a successful write.
            guard let actual = read() else { return "The binding no longer has a readable value." }
            if kind == "number", let expected = converted as? NSNumber, let number = actual as? NSNumber {
                guard expected == number else { return "The binding rejected or transformed the value; refresh to read its current value." }
            } else if toggle {
                guard (actual as? NSNumber)?.boolValue == (input as? NSNumber)?.boolValue else { return "The binding rejected the value." }
            } else if kind == "enum" {
                guard actual.isEqual(String(describing: converted)) else { return "The binding rejected the enum value." }
            } else {
                guard actual.isEqual(converted) else { return "The binding rejected the value." }
            }
            return nil
        }
    }
}

@MainActor final class LKS_LiveBindingField {
    let identity: AnyObject
    let valueType: String
    var identityPath = ""
    var editable = true
    var key: String { valueType + ":" + String(describing: ObjectIdentifier(identity)) + identityPath }
    let title: String
    let kind: String
    let options: [String]
    let read: () -> NSObject?
    let write: (Any) -> String?
    init(identity: AnyObject, valueType: String, title: String, kind: String, options: [String],
         read: @escaping () -> NSObject?, write: @escaping (Any) -> String?) {
        self.identity = identity; self.valueType = valueType; self.title = title
        self.kind = kind; self.options = options; self.read = read; self.write = write
    }
}

@MainActor enum LKS_BindingReflection {
    static func child(_ value: Any, _ name: String) -> Any? {
        var mirror: Mirror? = Mirror(reflecting: value)
        while let current = mirror {
            if let child = current.children.first(where: { $0.label == name }) { return child.value }
            mirror = current.superclassMirror
        }
        return nil
    }
    static func unwrap(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional ? mirror.children.first?.value : value
    }
    static func identity(_ value: Any) -> AnyObject? {
        var current = value
        for _ in 0..<16 {
            let name = String(reflecting: type(of: current))
            if name.contains("ConstantLocation") { return nil }
            // ScopedLocation forwards to base. Preserve projections/functional
            // locations as distinct identities, even when their value is equal.
            if name.contains("ScopedLocation"), let location = child(current, "location"),
               let base = child(location, "base") { current = base; continue }
            if name.contains("ToggleStateCollectionLocation"), let location = child(current, "location"),
               let base = child(location, "base") {
                let values = Mirror(reflecting: base)
                guard values.displayStyle == .collection, values.children.count == 1,
                      let value = values.children.first?.value else { return nil }
                current = value; continue
            }
            guard Mirror(reflecting: current).displayStyle == .class else { return nil }
            return current as AnyObject
        }
        return nil
    }

    @available(iOS 13.0, tvOS 13.0, *)
    static func fields(in host: UIView) -> [LKS_LiveBindingField] {
        // These stored field names are a version adapter. Fail closed if the
        // schema changes; never fall back to unprotected _viewDebugData().
        var rendererHost: Any = host
        if let base = child(host, "_base") { rendererHost = base }
        guard let graph = child(rendererHost, "viewGraph"),
              let renderer = child(graph, "renderer"),
              let nested = child(renderer, "renderer"), let active = unwrap(nested),
              let list = child(active, "lastList") else { return [] }
        var result: [LKS_LiveBindingField] = []
        var seenObjects = Set<ObjectIdentifier>()
        var seenBindings = Set<String>()
        var budget = 12000
        func visit(_ value: Any, path: String, owner: String?, depth: Int) {
            guard depth < 36, budget > 0, result.count < 128 else { return }
            budget -= 1
            if let binding = value as? LKS_AnyLiveBinding {
                guard let owner = owner else { return }
                let property = owner == "Toggle" ? "isOn" : (owner == "TextField" ? "text" : (owner == "Slider" ? "value" : String(path.split(separator: ".").last ?? "value")))
                guard let field = binding.lookinField(title: owner + "." + property),
                      seenBindings.insert(field.key).inserted else { return }
                result.append(field); return
            }
            if value is UIView || value is UIViewController { return }
            let name = String(reflecting: type(of: value))
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .class && !seenObjects.insert(ObjectIdentifier(value as AnyObject)).inserted { return }
            if name.contains("GraphHost") || name.contains("EnvironmentValues") || name.contains("PropertyList") { return }
            let isLeaf = name.contains(".ViewLeafView<")
            let label: String
            if name.contains("PlatformTextFieldAdaptor") { label = "TextField" }
            else if name.contains("SystemSlider") { label = "Slider" }
            else if name.contains("Switch>") { label = "Toggle" }
            else { label = "View" }
            var cursor: Mirror? = mirror
            while let current = cursor {
                for entry in current.children {
                    let key = entry.label ?? "item"
                    if ["environment", "host", "delegate", "viewGraph", "renderer", "parent", "superview", "_location"].contains(key) { continue }
                    if isLeaf && key != "content" && key != "coordinator" { continue }
                    visit(entry.value, path: isLeaf ? key : path + "." + key,
                          owner: isLeaf ? label : owner, depth: depth + 1)
                }
                cursor = current.superclassMirror
            }
        }
        visit(list, path: "", owner: nil, depth: 0)
        return result
    }
}

@MainActor private final class LKS_BindingSession: NSObject {
    weak var host: UIView?
    var entries: [String: LKS_BindingEntry] = [:]
}
@MainActor private final class LKS_BindingEntry: NSObject {
    let token = "lookin.swiftui.binding." + UUID().uuidString
    weak var session: LKS_BindingSession?
    var field: LKS_LiveBindingField
    init(_ field: LKS_LiveBindingField) { self.field = field }
}

@MainActor @objc public final class LKS_SwiftUIStateEditor: NSObject {
    private static var associationKey: UInt8 = 0
    private static let registry = NSMapTable<NSString, LKS_BindingEntry>.strongToWeakObjects()

    private static func liveFields(in host: UIView) -> [LKS_LiveBindingField] {
        var seen = Set<String>()
        return (LKS_SwiftUIAOP.fields(in: host) + LKS_BindingReflection.fields(in: host)).filter { seen.insert($0.key).inserted }
    }

    @objc(fieldsForHostingView:)
    public static func fields(for object: NSObject) -> [[String: Any]] {
        guard #available(iOS 13.0, tvOS 13.0, *), getenv("LOOKIN_SWIFTUI_DISABLED") == nil,
              let host = object as? UIView, host.window != nil, LKS_SwiftUIRuntime.supports(host) else { return [] }
        let session = (objc_getAssociatedObject(host, &associationKey) as? LKS_BindingSession) ?? LKS_BindingSession()
        session.host = host
        objc_setAssociatedObject(host, &associationKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let live = liveFields(in: host)
        var next: [String: LKS_BindingEntry] = [:]
        var output: [[String: Any]] = []
        for (index, field) in live.enumerated() {
            guard let value = field.read() else { continue }
            let entry = session.entries[field.key] ?? LKS_BindingEntry(field)
            entry.field = field; entry.session = session
            next[field.key] = entry
            registry.setObject(entry, forKey: entry.token as NSString)
            output.append(["identifier": entry.token, "title": "\(index + 1). \(field.title)",
                           "valueType": field.kind, "value": value, "options": field.options, "editable": field.editable])
        }
        for (key, entry) in session.entries where next[key] == nil { registry.removeObject(forKey: entry.token as NSString) }
        session.entries = next
        return output
    }

    @objc(modifyValue:identifier:)
    public static func modify(value: Any, identifier: String) -> String? {
        guard #available(iOS 13.0, tvOS 13.0, *), getenv("LOOKIN_SWIFTUI_DISABLED") == nil,
              let entry = registry.object(forKey: identifier as NSString), let session = entry.session,
              let host = session.host, host.window != nil, entry.field.editable else { return "This SwiftUI binding expired. Refresh the hierarchy." }
        host.layoutIfNeeded()
        // Re-resolve by the retained location identity, never array position or
        // matching current values. Reordered/replaced controls cannot receive an old edit.
        guard let current = liveFields(in: host).first(where: { $0.key == entry.field.key }) else {
            registry.removeObject(forKey: identifier as NSString)
            return "The SwiftUI view, model or binding was replaced. Refresh the hierarchy."
        }
        let error = current.write(value)
        // Refresh even when a real setter transformed the input. The original
        // views are invalidated through Debug @State, preserving child identity.
        LKS_SwiftUIAOP.invalidate(host)
        if let error = error { return error }
        entry.field = current
        host.setNeedsLayout()
        return nil
    }
}
#endif
