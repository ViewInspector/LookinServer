#if SHOULD_COMPILE_LOOKIN_SERVER

//
//  LKS_SwiftUIInspector.swift
//  LookinServer
//
//  SwiftUI 运行时快照的跨语言节点模型。
//  https://lookin.work
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI

/// SwiftUI 视图树中的一个节点
@objc public class LKS_SwiftUIViewNode: NSObject {

    /// 简洁的类型名，例如 "VStack"、"Text"
    @objc public var typeName: String = ""

    /// 完整的类型名，例如 "VStack<TupleView<(Text, Text)>>"
    @objc public var fullTypeName: String = ""

    /// 视图携带的值，例如 Text 的文本内容、Toggle 的开关状态
    @objc public var valueDescription: String?

    /// 视图上的 modifier，例如 "padding"
    @objc public var modifierDescription: String?

    @objc public var frameInHost: CGRect = .zero
    @objc public var hasGeometry: Bool = false
    @objc public var geometryDescription: String = "Unavailable"
    @objc public var attributeDescription: String?

    /// 子视图
    @objc public var children: [LKS_SwiftUIViewNode] = []

    public override var description: String {
        var result = self.typeName
        if let modifier = self.modifierDescription {
            result += ".\(modifier)"
        }
        if let value = self.valueDescription {
            result += " - \(value)"
        }
        return result
    }
}

/// Compatibility entry points. Runtime capture never evaluates a business body.
@MainActor @objc public class LKS_SwiftUIInspector: NSObject {
    @objc(isSwiftUIHostingView:)
    public static func isSwiftUIHostingView(_ object: AnyObject) -> Bool {
        guard let object = object as? NSObject else { return false }
        return LKS_SwiftUIRuntime.supports(object)
    }
    @objc(swiftUIViewTreeOfHostingView:)
    public static func swiftUIViewTree(ofHostingView object: AnyObject) -> LKS_SwiftUIViewNode? {
        guard let object = object as? NSObject else { return nil }
        return LKS_SwiftUIRuntime.capture(object)
    }
}
#endif
#endif
