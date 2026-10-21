# SwiftUI 运行时检查与状态修改

接入带 Swift 的 LookinServer Debug SDK 后，业务视图无需增加 modifier、协议或标记。SDK 启动时开启 SwiftUI 运行时调试数据，在 `_UIHostingView` 下追加 SwiftUI 节点。没有替换业务 rootView，也不会通过反射主动求值 `View.body`。

## 已接通的能力

- 运行时结构、类型、值和 modifier 属性展示，保留 SwiftUI 内部包装节点。
- 可解析节点的真实布局边界；嵌入 UIKit 时转换成 HostingView 局部坐标。
- 通过现有 Lookin 协议选择节点、获取属性、刷新层级和截图，以及导出包含截图的快照。
- 截图是 HostingView 合成画面的区域裁剪。重叠内容会一起出现，不是独立 SwiftUI 渲染层。
- 节点使用注册过的 OID。相同结构路径和类型在刷新时复用，移除节点或释放宿主后失效；OID 不代表跨 ForEach 重排的业务身份。
- 未知布局变换标为不可用，节点上限 4000、深度上限 128，并显示截断说明。

## 修改真实状态

1. 使用 Debug SDK 启动 App，在 Lookin 连接并展开 `_UIHostingView`。
2. 选择其下的 **SwiftUI 根节点**，在 **SwiftUI State & Models** 属性组编辑字段。
3. `Toggle.isOn` 使用复选框；`Slider.value` 输入数值后回车；`TextField.text` 编辑后按 Return 或点击其它输入字段提交（Tab 会输入制表符）。
4. App 通过真实 `Binding.wrappedValue` setter 更新业务状态和界面。新版客户端自动回读 SwiftUI 子树、属性和截图；原版客户端也能修改，改完点击工具栏刷新。

现在有两条互补路径：Debug AOP 在编译副本里自动注册业务属性，因此未绑定控件的 `@State`、未在界面显示的状态、`@Published` / `@Observable` 模型字段、私有存储字段、嵌套结构体均可查看、修改。原始业务文件无需加标记；Demo 已配置 AOP。详细接入与边界见 [SwiftUIAOP](../../Tools/SwiftUIAOP/README.md)。

未启用 AOP 时，SDK 仍从 display list 自动发现控件持有的已安装 Binding。该路径无需重新编译插桩，但字段名只能根据控件类型显示。AOP 字段使用业务属性名，模型修改走真正的 Swift setter，保留通知和属性观察器。带 `(JSON)` 后缀的 Optional/集合字段支持 `null`、整集合增删替换和重排；已有元素可展开编辑，旧元素引用在集合变化后失效。SDK 刷新作用域保证未被外层订阅的引用模型修改后也能重新绘制，并保留子视图状态。

支持 Bool、String、有限浮点数、Double 编辑器可精确表示范围内的 Int（绝对值不超过 2^53−1），以及至多 256 个名称唯一的 CaseIterable 枚举。字符串输入上限 64 KiB。常量绑定不展示为可写；错误类型、NaN/无穷大、越界及拒绝写入的 setter 返回错误。系统 Toggle 的内部枚举通过类型检查和合法枚举值转换，不使用内存偏移。

每次提交都重新查找当前 Binding，以底层 location 或模型对象及字段路径身份校验，不能按字段位置或值猜测。控件移除、绑定替换或宿主释放后旧引用失效；ForEach 重排不会将旧编辑写入另一个状态。状态快照属性仍然只读，不是修改入口。

## 当前边界

已接通未绑定状态和模型字段的真实修改，但不能宣称覆盖任意类型、任意二进制和所有调试操作。AOP 需要在定义业务 View/模型的 target 中启用并重新编译；Optional、Array、Dictionary、Set 支持 JSON 整体编辑与已有元素展开；创建新的自定义模型需要其现有 Codable 构造规则，其它不支持的类型显示 read-only，预编译模型、计算字段、继承/条件编译等语法的边界见 AOP 文档。Button action、断点和单步执行尚未实现。

绑定发现使用私有存储字段的版本适配：`viewGraph.renderer.renderer.lastList`、ViewLeafView 和 location 包装链。字段缺失时停止发现，不使用不可靠的内存写入；每次最多遍历 12000 个值、36 层、128 个绑定。

依赖系统私有调试入口 `makeViewDebugData` 和 `_UIHostingView`，属于版本适配方案。当前验证环境为 Xcode 27.1 / iOS 27.0 模拟器；其它系统、真机、tvOS 尚未验证。仅支持当前解析器识别的平移变换，不支持的投影/仿射/滚动变换会明确显示不可用。入口缺失或采集数据为空时显示诊断节点，不退回危险的 `_viewDebugData()` 调用。

`_viewDebugData()` 即使在主队列也可能触发 `AGAttribute.syncMainIfReferences` / `ViewListTransition.updateValue` 崩溃。当前改用系统带 SwiftUI 更新保护的序列化入口，并将网络请求处理派发到主队列。

## 集成

SPM 的 LookinServer product 包含 Swift 支持，相关实现仅在 Debug 编译。未绑定状态和模型字段需额外启用 [Debug AOP](../../Tools/SwiftUIAOP/README.md)。CocoaPods 使用带 Swift 的 subspec 并限定 Debug：

```ruby
pod 'LookinServer', :subspecs => ['Swift'], :configurations => ['Debug']
```

需要重新启动 App，保证 SDK 在首个 SwiftUI 图创建前设置 `SWIFTUI_VIEW_DEBUG`。环境变量 `LOOKIN_SWIFTUI_DISABLED=1` 可关闭自动开启、节点采集和状态修改。

`../Swift_SPM_Debug/LookinDemoSwift.xcodeproj` 已指向本地 LookinServer，可直接构建并用 Lookin 连接。

## 回归

2026-10-21：iPhone 18 Pro / iOS 27.0 模拟器上 12 项宿主测试通过（含 Optional/集合的实际修改请求、界面刷新及解码边界验证），另有 2 项生成器测试通过；Debug Demo 和 Release 包构建通过，Release Swift 对象中无状态编辑器符号。使用现有 Lookin 客户端实际修改了 TextField、Slider 和 Toggle，模拟器界面正确更新，关闭 Toggle 后条件分支消失。新版桌面客户端已实际验证文本接着 Toggle 连续编辑、数值修改、自动回读；文本草稿不会被相邻控件的刷新覆盖。

从仓库根目录运行，替换 SIMULATOR_UDID：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project LookinServer/Tests/SwiftUIRuntimeHost/SwiftUIRuntimeHost.xcodeproj \
  -scheme SwiftUIRuntimeHost \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  CODE_SIGNING_ALLOWED=NO test
```

真实 scene 宿主用于验证截图、嵌入坐标、详情请求、快照归档、重复条件分支切换和宿主释放；状态测试经实际自定义属性修改处理器验证业务 @State 更新、子视图 @Binding、只读常量排除、输入校验、详情回读、条件分支移除后的引用失效，两个初始值相同的 ForEach 行重排/移除后的正确写入，以及自定义 UIViewRepresentable 中枚举/整数 Binding 的写入与越界校验。包级逻辑测试没有 scene 时会明确跳过运行时测试，不能替代宿主工程验收。解析器测试另外覆盖平移、非法数据、未知变换和节点预算。

桌面端验证在临时副本安装 Pods 后构建，使用本地 LookinShared；Xcode 27.1 命令行覆盖 `MACOSX_DEPLOYMENT_TARGET=12.0`（当前 SDK 不接受项目原有的 11.0）。未修改项目支持版本、仓库 Podfile/锁文件或覆盖 `/Applications/Lookin.app`。
