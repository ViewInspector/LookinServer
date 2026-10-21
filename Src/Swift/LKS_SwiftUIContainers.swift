#if SHOULD_COMPILE_LOOKIN_SERVER && canImport(SwiftUI)
import SwiftUI
import Foundation
import CryptoKit

// JSON replacement uses the declared Swift type's Codable implementation, never
// casts JSONSerialization numbers into business values (which loses Int64 precision).
@MainActor enum LKS_DebugJSON {
    static let byteLimit = 65536
    static func encode(_ value: Any) throws -> String {
        if let container = value as? LKS_DebugContainer { return try container.lookinJSON() }
        guard let value = value as? any Encodable else { throw Failure("This value does not conform to Encodable.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= byteLimit, let string = String(data: data, encoding: .utf8) else { throw Failure("JSON exceeds 64 KiB.") }
        return string
    }
    static func compose<C: Collection>(_ values: C, open: String, close: String, sorted: Bool = false,
                                       transform: (C.Element) throws -> String) throws -> String {
        guard values.count <= 4096 else { throw Failure("Collection exceeds 4096 entries.") }
        var parts: [String] = []
        var size = 2
        for value in values {
            let part = try transform(value)
            size += part.utf8.count + 1
            guard size <= byteLimit else { throw Failure("JSON exceeds 64 KiB.") }
            parts.append(part)
        }
        if sorted { parts.sort() }
        return open + parts.joined(separator: ",") + close
    }
    static func equalWhenAvailable(_ expected: Any, _ actual: Any) -> Bool {
        guard let equatable = expected as? any Equatable else { return true }
        func compare<T: Equatable>(_ expected: T, _ actual: Any) -> Bool {
            guard let actual = actual as? T else { return false }
            return expected == actual
        }
        return compare(equatable, actual)
    }
    static func validate(_ data: Data) throws {
        guard data.count <= byteLimit else { throw Failure("JSON exceeds 64 KiB.") }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var remaining = 4096
        func visit(_ value: Any, _ depth: Int) throws {
            remaining -= 1
            guard remaining >= 0, depth <= 32 else { throw Failure("JSON exceeds 4096 values or 32 nesting levels.") }
            if let values = value as? [Any] { for value in values { try visit(value, depth + 1) } }
            else if let values = value as? [String: Any] { for value in values.values { try visit(value, depth + 1) } }
        }
        try visit(object, 0)
    }
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

@available(iOS 13.0, tvOS 13.0, *)
extension Binding {
    @MainActor func lookinJSONField(title: String, identity: AnyObject) -> LKS_LiveBindingField? {
        guard Value.self is LKS_DebugContainer.Type, let decoderType = Value.self as? any Decodable.Type,
              let initial = try? LKS_DebugJSON.encode(wrappedValue),
              let data = initial.data(using: .utf8), (try? LKS_DebugJSON.validate(data)) != nil else { return nil }
        func read() -> NSObject? { (try? LKS_DebugJSON.encode(wrappedValue)) as NSString? }
        return LKS_LiveBindingField(identity: identity, valueType: String(reflecting: Value.self),
                                   title: title + " (JSON)", kind: "string", options: [], read: read) { input in
            guard let text = input as? String, let data = text.data(using: .utf8) else { return "Expected JSON text." }
            do {
                try LKS_DebugJSON.validate(data)
                let decoded = try JSONDecoder().decode(decoderType, from: data)
                guard let value = decoded as? Value else { return "JSON does not match this field's Swift type." }
                let expected = try LKS_DebugJSON.encode(value)
                // Decode/validate the entire replacement before invoking any binding setter.
                self.wrappedValue = value
                let actual = self.wrappedValue
                guard LKS_DebugJSON.equalWhenAvailable(value as Any, actual as Any),
                      try LKS_DebugJSON.encode(actual) == expected else {
                    return "The setter rejected or transformed the JSON value; refresh to read the actual value."
                }
                return nil
            } catch { return "Invalid JSON for \(String(reflecting: Value.self)): \(error)" }
        }
    }
}

@MainActor protocol LKS_DebugContainer {
    func lookinJSON() throws -> String
    @available(iOS 13.0, tvOS 13.0, *)
    static func lookinChildren(_ access: LKSModelAccess) -> [LKSStateField]
}

extension Optional: LKS_DebugContainer {
    @MainActor func lookinJSON() throws -> String {
        switch self { case .none: return "null"; case .some(let value): return try LKS_DebugJSON.encode(value) }
    }
    @available(iOS 13.0, tvOS 13.0, *)
    @MainActor static func lookinChildren(_ access: LKSModelAccess) -> [LKSStateField] {
        let initial = access.get() as! Self
        var result: [LKSStateField] = [.binding("isNil", Binding(get: { (access.get() as! Self) == nil }, set: {
            if $0 { access.set(Self.none as Any) }
            // There is no universal initializer for an arbitrary Wrapped type.
            // JSON replacement can create Codable values; otherwise false is rejected by readback.
        }))]
        if let initial = initial {
            result.append(.binding("value", Binding(get: { (access.get() as! Self) ?? initial }, set: {
                guard (access.get() as! Self) != nil else { return }
                access.set(Self.some($0) as Any)
            })))
        }
        return result
    }
}

extension Array: LKS_DebugContainer {
    @MainActor func lookinJSON() throws -> String {
        try LKS_DebugJSON.compose(self, open: "[", close: "]") { try LKS_DebugJSON.encode($0) }
    }
    @available(iOS 13.0, tvOS 13.0, *)
    @MainActor static func lookinChildren(_ access: LKSModelAccess) -> [LKSStateField] {
        let initial = access.get() as! Self
        return initial.prefix(128).enumerated().map { index, element in
            .binding("[\(index)]", Binding(get: {
                let current = access.get() as! Self
                return current.indices.contains(index) ? current[index] : element
            }, set: {
                var current = access.get() as! Self
                guard current.indices.contains(index) else { return }
                current[index] = $0
                access.set(current)
            }))
        }
    }
}

extension Dictionary: LKS_DebugContainer {
    @MainActor func lookinJSON() throws -> String {
        guard count <= 4096 else { throw LKS_DebugJSON.Failure("Collection exceeds 4096 entries.") }
        // Standard Codable uses JSON objects for String/Int keys, alternating
        // key/value arrays for other keys. Leave custom key encodings to Codable.
        if Key.self == String.self || Key.self == Int.self {
            return try LKS_DebugJSON.compose(self, open: "{", close: "}", sorted: true) { key, value -> String in
                let name = Key.self == String.self ? key as! String : String(key as! Int)
                return try LKS_DebugJSON.encode(name) + ":" + LKS_DebugJSON.encode(value)
            }
        }
        guard let encoded = self as? any Encodable else { throw LKS_DebugJSON.Failure("Dictionary keys or values are not Codable.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(encoded)
        guard data.count <= LKS_DebugJSON.byteLimit else { throw LKS_DebugJSON.Failure("JSON exceeds 64 KiB.") }
        return String(decoding: data, as: UTF8.self)
    }
    @available(iOS 13.0, tvOS 13.0, *)
    @MainActor static func lookinChildren(_ access: LKSModelAccess) -> [LKSStateField] {
        // JSON supports other Codable keys, but child titles require an unambiguous key.
        guard Key.self == String.self || Key.self == Int.self else { return [] }
        let initial = access.get() as! Self
        return initial.keys.sorted { String(describing: $0) < String(describing: $1) }.prefix(128).map { key in
            let label = (try? LKS_DebugJSON.encode(key)) ?? String(describing: key)
            let initialValue = initial[key]!
            return .binding("[\(label)]", Binding(get: { (access.get() as! Self)[key] ?? initialValue }, set: {
                var current = access.get() as! Self
                guard current.keys.contains(key) else { return }
                // updateValue preserves a nil Optional value; subscript assignment can remove a key.
                current.updateValue($0, forKey: key)
                access.set(current)
            }))
        }
    }
}

extension Set: LKS_DebugContainer {
    @MainActor func lookinJSON() throws -> String {
        try LKS_DebugJSON.compose(self, open: "[", close: "]", sorted: true) { try LKS_DebugJSON.encode($0) }
    }
    @available(iOS 13.0, tvOS 13.0, *)
    @MainActor static func lookinChildren(_ access: LKSModelAccess) -> [LKSStateField] {
        let initial = access.get() as! Self
        // Never mutate an in-set reference object's hash through one of its fields.
        guard initial.allSatisfy({ Mirror(reflecting: $0).displayStyle != .class && LKS_ContainerSnapshot.key($0) != nil }) else { return [] }
        let ordered = initial.sorted { LKS_ContainerSnapshot.key($0)! < LKS_ContainerSnapshot.key($1)! }
        return ordered.prefix(128).enumerated().map { index, element in
            var lookup = element
            return .binding("[\(index)]", Binding(get: {
                let current = access.get() as! Self
                return current.firstIndex(of: lookup).map { current[$0] } ?? element
            }, set: { value in
                var current = access.get() as! Self
                guard current.remove(lookup) != nil else { return }
                current.insert(value)
                access.set(current)
                lookup = value
            }))
        }
    }
}

/// Conservative snapshot identity for element editors. Unknown/opaque leaves
/// disable element editing instead of guessing identity from an index or title.
@available(iOS 13.0, tvOS 13.0, *)
@MainActor enum LKS_ContainerSnapshot {
    static func key(_ value: Any) -> String? {
        var budget = 4096
        var bytes = 0
        func visit(_ value: Any, _ depth: Int) -> String? {
            budget -= 1
            guard budget >= 0, depth < 16, bytes < 65536 else { return nil }
            let type = String(reflecting: Swift.type(of: value))
            let mirror = Mirror(reflecting: value)
            let payload: String
            if Swift.type(of: value) is AnyClass { payload = String(describing: ObjectIdentifier(value as AnyObject)) }
            else if value is String || value is Bool || value is Int || value is Int8 || value is Int16 || value is Int32 || value is Int64 || value is UInt || value is UInt8 || value is UInt16 || value is UInt32 || value is UInt64 || value is Double || value is Float || value is CGFloat {
                payload = String(reflecting: value)
            } else if mirror.displayStyle == .enum, let enumType = Swift.type(of: value) as? any CaseIterable.Type,
                      let current = value as? AnyHashable {
                var ordinal: Int?
                var index = 0
                for candidate in enumType.allCases {
                    guard index < 256 else { return nil }
                    if let candidate = candidate as? AnyHashable, candidate == current {
                        guard ordinal == nil else { return nil }
                        ordinal = index
                    }
                    index += 1
                }
                guard let ordinal = ordinal else { return nil }
                payload = "case:\(ordinal)"
            } else if [.optional, .collection, .dictionary, .set, .struct, .tuple].contains(mirror.displayStyle) {
                guard !(value is any CustomReflectable) || value is LKS_DebugContainer else { return nil }
                var parts: [String] = []
                for child in mirror.children {
                    guard let childKey = visit(child.value, depth + 1) else { return nil }
                    parts.append((child.label ?? "") + ":" + childKey)
                }
                if mirror.displayStyle == .dictionary || mirror.displayStyle == .set { parts.sort() }
                payload = parts.joined(separator: ";")
            } else { return nil }
            let result = "\(type.utf8.count):\(type)\(payload.utf8.count):\(payload)"
            bytes += result.utf8.count
            return bytes <= 131072 && result.utf8.count <= 65536 ? result : nil
        }
        guard let snapshot = visit(value, 0) else { return nil }
        return SHA256.hash(data: Data(snapshot.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
