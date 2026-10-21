# SwiftUI Debug 编译期 AOP

业务 `.swift` 文件不添加 Lookin import、modifier、协议或标记。生成器用 Xcode 自带 SwiftSyntax 解析源文件，在 DerivedSources 写入编译副本，通过 Swift 编译器的 `-vfsoverlay` 选择副本。Release 不使用 overlay，也不生成插桩代码。

## 接入 Xcode target

先将带 Swift 支持的 LookinServer SDK 加入目标。使用 CocoaPods 自带的 `xcodeproj` Ruby gem，或在项目自己的 Ruby/Bundler 环境安装该依赖，然后执行：

```sh
ruby /path/to/LookinServer/Tools/SwiftUIAOP/install.rb /path/to/App.xcodeproj AppTarget
```

CocoaPods 的模块名通常为 `LookinServer`，传入第三个参数；SPM 的 Swift 模块名默认为 `LookinServerSwift`：

```sh
ruby /path/to/LookinServer/Tools/SwiftUIAOP/install.rb /path/to/App.xcodeproj AppTarget LookinServer
```

安装器只修改项目配置：在 Compile Sources 前添加生成阶段，为 **Debug** 添加 overlay 编译参数，并关闭该配置的 User Script Sandboxing。可重复运行，不重复添加阶段/参数。新增 Compile Sources 文件后重新运行安装器。只有名为 Debug 的配置自动启用；自定义 Debug 配置需显式调整脚本条件和对应编译参数。

每个定义业务 View/模型的 target 都需要接入。安装器收集该 target 的显式 Compile Sources 文件；文件系统同步 group、SPM 业务 target、预编译 framework 不会被自动改写。不要将这个脚本直接套在 SDK target 上。

构建后查看 `$(DERIVED_FILE_DIR)/LookinSwiftUIAOP/report.json`：包含每个源文件插桩的 View/模型数量及跳过原因。语法解析失败会让构建失败，原始业务文件保持不变；不会默默使用旧副本继续编译。Xcode/SwiftSyntax 版本来自当前 `DEVELOPER_DIR`。

## 查看、修改

Debug 运行后，在 Lookin 选择 `_UIHostingView` 下的 SwiftUI 根节点，打开 **SwiftUI State & Models**。字段使用 `ViewName.property` / `ViewName.model.field` 的名称。

- `@State` / `@Binding` 不必绑定控件，也不必在界面中使用；同样支持 `@AppStorage` / `@SceneStorage` 的投影绑定。
- 自动连接 `@StateObject`、`@ObservedObject`、`@EnvironmentObject`、`@Environment`、`@Bindable` 中的模型引用，以及 `@State` 中的模型。
- 模型类识别直接声明的 `ObservableObject` 或 `@Observable`；结构体生成可写 KeyPath，嵌套结构体修改通过外层 Binding 写回。
- 模型私有存储字段和 `private(set)` 字段也可暴露，生成代码在类型内部使用原生 KeyPath。写入经过真实 setter，保留 `@Published`、Observation、`willSet` / `didSet`。普通 ObservableObject 字段也会发送刷新通知。
- `let` 和不支持的类型明确标为 read-only；模型的 `let` 引用如果指向已插桩的引用模型，可以查看、修改其内部可写字段。
- 可编辑 Bool、String、有限 Float/Double/CGFloat、±(2^53−1) 范围内的 Int，以及至多 256 个名称唯一的 CaseIterable 枚举。Optional、Array、Dictionary、Set 及其嵌套类型现在有 JSON 整体编辑和已有元素展开，详见下节；其它不支持的类型仍明确只读。

每个插桩 View 通过 SDK 的 `LKSStateScope` 保持一个 Debug 刷新状态；编辑后触发原内容重新求值，不替换 rootView、不改变 child identity，也不往业务类型添加存储属性，因此不破坏其自动合成的 Equatable/Codable。集合内未被外层订阅的引用模型也能正确刷新。

每个插桩 View 通过零尺寸、禁用交互和辅助功能的 UIViewRepresentable 注册已安装 Binding。注册表弱持有探针，每次编辑重新解析当前字段身份。视图移除、模型替换或宿主销毁后，旧 token 不会写入其它对象；不会按标题、顺序或当前值匹配。

递归模型最多 8 层，每个模型最多 128 字段，每个宿主最多 512 字段 / 2048 次遍历。循环引用和触及限制有只读说明。原来的控件 Binding 自动发现仍然可用；未启用 AOP 时也保留这条路径。

## Optional 和集合编辑

在 **SwiftUI State & Models** 中选择带 **(JSON)** 后缀的字段，输入完整 JSON 后按 Return 提交。SDK 按声明的 Swift 类型解码，完成全部校验后才调用一次真正的 Binding/模型 setter，再回读检查实际值。失败会返回具体错误，不会把前半段数据写入业务状态。

| 类型/操作 | 输入示例 |
| --- | --- |
| Optional 清空 | `null` |
| Optional<String> 设置值 | `"hello"`（保留 JSON 双引号） |
| Optional<Bool> 设置值 | `false` |
| 数组增删、替换、重排 | `[3, 1, 8]`；清空为 `[]` |
| Dictionary<String, Int?> | `{"count": 9, "nil": null}`；清空为 `{}` |
| Set<String> | `["z", "a", "a"]`，按 Swift Set 语义去重为 a、z |
| 嵌套 Optional/集合 | `[[null, 9], [2]]` |
| 已有 Codable 模型数组 | `[{"id": 2, "name": "Two"}]` |

`Int64` / `UInt64` 的 JSON 解码直接使用原始文本，支持完整整数范围，不经过桌面 Double 编辑器。Set 的 JSON 回读按内容排序，字典键按序输出；Set 本身不提供有序语义。模型的 JSON 格式遵循它现有的 Codable 实现，不一定等于属性名。

Optional 的 `.value`、Array 的 `[index]`、字符串/整数键字典的 `[key]`、Set 中可安全展开的值类型元素可以继续逐字段编辑。已有非 Codable 结构体和引用模型也能通过生成的 KeyPath 修改字段，无需业务补协议。Set 值类型元素先移除旧值、修改副本再插入，避免破坏哈希；Set 引用元素不开放内部字段写入。

每个元素 token 绑定集合快照摘要。集合发生增删、重排或值变化后，旧元素 token 被拒绝；客户端刷新后重新选择字段。JSON 整体替换是明确的整值赋值操作，不根据旧索引猜测元素身份。字典的 Optional 值设为 null 会保留键；删除键请从整体 JSON 中移除该条目。

整体 JSON 创建/替换要求容器及其成员已有 Codable 能力。**SDK 不替未知模型猜测构造方法，也不会要求业务源文件增加 Codable。** 对于没有构造规则的非 Codable 类型，现有值可以展开修改，Optional 可通过 `.isNil = true` 清空；从 nil 创建实例、向集合添加全新实例仍不可用。`.isNil = false` 不会伪造实例，无法创建时返回错误。

JSON 上限 64 KiB、4096 个值、32 层嵌套；元素展开最多 128 项，仍受总字段/深度预算限制。非法 JSON、错误元素类型、数值越界、非有限数及拒绝/转换输入的 setter 均有错误回读。没有可靠快照身份的元素停止展开，支持 Codable 的整体 JSON 编辑仍可用。

## 明确边界

这是 Debug 编译期 AOP，需要重新编译业务 target，不能让已发布、未插桩的二进制凭空开放全部私有字段。当前处理直接声明 `: View` 且具有 `var body: some View` 的类型。扩展中定义的 body、类型别名/间接 View 协议、宏生成或条件编译块中的成员、仅在单独 extension 中声明的模型协议、继承模型新增字段、计算属性及自定义属性包装器不保证自动展开；应检查生成报告和编译结果。带单独 availability 的模型属性会跳过并报告。

SwiftUI 的状态注册和写入使用 Binding/KeyPath；Binding 的身份校验及原有控件发现仍依赖运行时 location 字段适配。SwiftUI 结构/布局采集继续使用已有版本适配器。当前验收是 Xcode 27.1 / iOS 27.0 模拟器，未验证真机、其它系统或 tvOS。没有添加断点、单步执行或任意 action 调用，仍不能称为覆盖所有 SwiftUI 调试场景的完整调试器。

关闭方式：删除目标上的 **Lookin SwiftUI Debug AOP** build phase 和 Debug `OTHER_SWIFT_FLAGS` 中的 `-vfsoverlay` 及其路径，再 Clean Build。`LOOKIN_SWIFTUI_DISABLED=1` 关闭 SDK 检查/修改入口，但不会移除已经编译进 Debug 的探针。

## 验证

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 Tools/SwiftUIAOP/test_instrumenter.py
```

从仓库根目录运行 `Tests/SwiftUIRuntimeHost` 对应 Xcode 工程测试（完整命令见 Demo README）。AOPFixture.swift 保持没有 Lookin API 的业务形式，宿主工程实际执行生成阶段和 overlay 编译。测试验证未绑定及未显示的状态、嵌套值类型、模型私有字段、Published/Observation、独立普通字段刷新、原生 didSet、只读拒绝、类型校验、移除和模型替换后的引用失效。另验证 Optional 的 nil 往返、Array/Dictionary/Set 增删改与重排、嵌套集合、完整 64 位整数、非 Codable 元素编辑、错误输入不触发模型 setter，以及未订阅引用模型的刷新和子视图状态保留。2026-10-21：12 项宿主测试、2 项生成器测试通过，Debug/Release Demo 构建通过。
