#if SHOULD_COMPILE_LOOKIN_SERVER && canImport(SwiftUI)
import SwiftUI
import UIKit

// Conforming the generic hosting class to our own protocol erases Content without
// unsafe casts, replacing the root view, or evaluating a business View.body.
@available(iOS 13.0, tvOS 13.0, *)
@MainActor private protocol LKS_RuntimeHosting {
    func lookinRuntimeData() -> Data?
}

@available(iOS 13.0, tvOS 13.0, *)
extension _UIHostingView: LKS_RuntimeHosting {
    fileprivate func lookinRuntimeData() -> Data? {
        // _viewDebugData() bypasses SwiftUI's Update.ensure scope and can trap
        // in ViewListTransition even on the main queue. The ObjC debug-provider
        // entry point creates the serialized snapshot inside that scope.
        let selector = NSSelectorFromString("makeViewDebugData")
        guard responds(to: selector),
              let method = class_getInstanceMethod(type(of: self), selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == "@" else { return nil }
        return perform(selector)?.takeUnretainedValue() as? Data
    }
}

@MainActor @objc public class LKS_SwiftUIRuntime: NSObject {
    @objc public static func supports(_ object: NSObject) -> Bool {
        if #available(iOS 13.0, tvOS 13.0, *) { return object is LKS_RuntimeHosting }
        return false
    }

    @objc public static func capture(_ object: NSObject) -> LKS_SwiftUIViewNode? {
        guard #available(iOS 13.0, tvOS 13.0, *),
              let host = object as? UIView, let provider = host as? LKS_RuntimeHosting else { return nil }
        let root = LKS_SwiftUIViewNode()
        root.typeName = "SwiftUI"
        root.fullTypeName = "SwiftUI runtime snapshot"
        root.frameInHost = host.bounds
        root.geometryDescription = "HostingView bounds"
        guard let data = provider.lookinRuntimeData(),
              data.count <= 16 * 1024 * 1024,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !raw.isEmpty else {
            root.valueDescription = "Runtime data unavailable. Restart the app with LookinServer enabled before SwiftUI initializes."
            return root
        }
        var parser = LKS_RuntimeTreeParser()
        // Runtime transforms target the window coordinate space, including the
        // UIKit placement of an embedded HostingView. Normalize once here.
        let windowFrame = host.convert(host.bounds, to: host.window)
        root.children = parser.parse(raw, parentFrame: windowFrame, transform: [:], depth: 0)
        func normalize(_ node: LKS_SwiftUIViewNode) {
            node.frameInHost = host.convert(node.frameInHost, from: host.window)
            node.children.forEach(normalize)
        }
        root.children.forEach(normalize)
        if parser.truncated { root.valueDescription = "Snapshot truncated at 4000 nodes or 128 levels." }
        return root
    }
}

// The underscored debug schema is version dependent. Unknown transforms are
// explicitly unavailable, never silently replaced with fabricated geometry.
struct LKS_RuntimeTreeParser {
    var remaining = 4000
    var truncated = false

    mutating func parse(_ raw: [[String: Any]], parentFrame: CGRect,
                        transform inherited: [String: Any], depth: Int) -> [LKS_SwiftUIViewNode] {
        guard depth < 128 else { truncated = true; return [] }
        var result: [LKS_SwiftUIViewNode] = []
        for entry in raw {
            guard remaining > 0 else { truncated = true; break }
            remaining -= 1
            let properties = entry["properties"] as? [[String: Any]] ?? []
            var attrs: [Int: [String: Any]] = [:]
            for property in properties {
                if let id = property["id"] as? Int, let attr = property["attribute"] as? [String: Any] { attrs[id] = attr }
            }
            let node = LKS_SwiftUIViewNode()
            node.fullTypeName = attrs[0]?["type"] as? String ?? "SwiftUI.Unknown"
            let readable = attrs[0]?["readableType"] as? String ?? node.fullTypeName
            let outerName = readable.split(separator: "<", maxSplits: 1).first.map(String.init) ?? readable
            node.typeName = outerName.components(separatedBy: ".").last ?? outerName
            node.valueDescription = attrs[1].map { Self.describe($0, depth: 0) }
            if (attrs[0]?["flags"] as? Int ?? 0) & 2 != 0 { node.modifierDescription = readable }
            node.frameInHost = parentFrame
            node.geometryDescription = "Inherited coordinate anchor; this node has no independent layout geometry"
            let transform = attrs[2]?["value"] as? [String: Any] ?? inherited
            if let p = Self.pair(attrs[3]?["value"]), let s = Self.pair(attrs[4]?["value"]),
               s.0 >= 0, s.1 >= 0 {
                let rect = CGRect(x: p.0, y: p.1, width: s.0, height: s.1)
                if let converted = Self.convert(rect, transform: transform), Self.valid(converted) {
                    node.frameInHost = converted
                    node.hasGeometry = true
                    node.geometryDescription = "Runtime layout bounds in HostingView coordinates"
                } else {
                    node.geometryDescription = "Unsupported runtime transform or invalid geometry; preview unavailable"
                }
            }
            // Keep full attribute data for inspecting values, modifiers and layout,
            // but bound individual payloads so a large state cannot flood the panel.
            if let value = attrs[1], JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                node.attributeDescription = String(text.prefix(24000))
            }
            node.children = parse(entry["children"] as? [[String: Any]] ?? [],
                                  parentFrame: node.frameInHost, transform: transform, depth: depth + 1)
            result.append(node)
        }
        return result
    }

    static func pair(_ value: Any?) -> (CGFloat, CGFloat)? {
        guard let array = value as? [NSNumber], array.count == 2 else { return nil }
        let a = CGFloat(array[0].doubleValue), b = CGFloat(array[1].doubleValue)
        guard a.isFinite, b.isFinite else { return nil }
        return (a, b)
    }

    static func convert(_ rect: CGRect, transform: [String: Any]) -> CGRect? {
        var offset = CGPoint.zero
        if let adjustment = pair(transform["positionAdjustment"]) {
            offset.x += adjustment.0; offset.y += adjustment.1
        }
        for item in transform["items"] as? [[String: Any]] ?? [] {
            if item.isEmpty { continue }
            if item.count == 1, let translation = pair(item["translation"]) {
                offset.x += translation.0; offset.y += translation.1
            } else {
                // Named coordinate spaces do not move geometry. Other schema keys
                // (affine/projection/scroll transforms) need explicit adapters.
                return nil
            }
        }
        return rect.offsetBy(dx: offset.x, dy: offset.y)
    }

    static func valid(_ r: CGRect) -> Bool {
        [r.minX, r.minY, r.width, r.height].allSatisfy { $0.isFinite && abs($0) <= 100000 }
            && r.width >= 0 && r.height >= 0
    }

    static func describe(_ attr: [String: Any], depth: Int) -> String {
        guard depth < 5 else { return "…" }
        if let value = attr["value"] { return String(String(describing: value).prefix(400)) }
        let children = attr["subattributes"] as? [[String: Any]] ?? []
        return String(children.prefix(12).map {
            let label = $0["name"] as? String ?? $0["readableType"] as? String ?? "value"
            return label + ": " + describe($0, depth: depth + 1)
        }.joined(separator: ", ").prefix(1200))
    }
}
#endif
