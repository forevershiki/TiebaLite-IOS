# Dynamic Reply Routing Phase 5.1 边界修复与回归审计

## 结论与等级

**P1：已修复两条会把未核验的坐标直接带入详情的路径，具备进入下一轮 GitHub Actions Debug 构建的条件。** 真机原样本的正确 KZ/PID 有上一轮匿名对照支持。本轮沿用该证据，验证范围包括 Windows 静态检查、完整差异和生成测试源码。Swift 6 编译与离线执行、Bazel、IPA 和真机行为仍待验证。

| 等级 | 审计结论 |
| --- | --- |
| P0 | 本轮未发现已证实的错误写操作、隐私泄露或其他安全事件。互动检查仅使用源码 |
| P1 | 原帖对象缺失或嵌套 PID 冲突时，旧实现经 `nil → card(row)` 直用外层 KZ。已改为严格核验单一候选，失败时停在列表 |
| P2 | 旧首屏依赖 SQLite 写入成功才可复用核验结果。本轮通过一次性内存交接保证相同首屏可复用，真机滚动和切页仍待验证。卡片分享及互动的旧坐标选择也有已记录的影响 |
| P3 | 仓库忽略 Markdown。提交本报告需显式暂存。开工时已有未跟踪的 Python 字节码目录，未纳入交付 |

审计从 `feat/full-interaction`、HEAD `bfb45acc0392e4e936f1320cfea1652b69577f0a` 开始，继承当时工作区已有的 9 个文件改动。

## 上一轮已确认的真实故障

原真机记录中的外层 `id` 和 `threadId` 均为 `2100000009798432`，`postId=154184058416`，嵌套 `originTid=11230786026`。真机使用外层 KZ 得到业务码 4。上一轮匿名对照使用相同 PID，以 `pn=0` 查询，得出以下结果。

| KZ | PID | 发送 FID | 业务码及回包 |
| --- | --- | --- | --- |
| `2100000009798432` | `154184058416` | `1937070` | 4，真机失败 |
| `11230786026` | `154184058416` | 省略 | 0，主题及目标 PID 均匹配 |
| `11230786026` | `154184058416` | `1937070` | 0，主题及目标 PID 均匹配 |
| `2100000009798432` | `154184058416` | 省略 | 4，匿名对照失败 |

该样本的原帖坐标是 `11230786026 / 154184058416`。两次成功回包的实际 FID 都是 `1937070`。原推荐包未捕获，外层 ID 的普遍语义仍未知。Mapper 可用 `threadId` 补缺失的 `id`，两值相等也不足以判断原包字段存在性。本轮使用这组映射值构建合成 Protobuf 夹具，没有重发线上请求。

## 路由决策与边界

特例限定为推荐流中非明确转发、存在有效顶层 `postId`、映射后的 `id == threadId` 且无有效首楼 ID 的卡片。相等只用于发现该形状的歧义。标题、ID 大小、位数及前缀不参与决策。对形状相同的普通回复，服务端同时确认外层主题与顶层 PID 后仍可进入。仅有不同的嵌套 PID 无法判定它究竟属于无关引用还是数据冲突，因此对可用外层候选执行同一次严格核验。核验失败无法区分这两类，留在列表。

| 场景 | 修复前 | 修复后 |
| --- | --- | --- |
| 普通主题或有独立可信 KZ 的普通回复 | 走通用路由 | 使用通用路由与其坐标 |
| 真机形状，嵌套原帖 KZ 有效，嵌套 PID 缺失或匹配 | 用原帖 KZ 核验 | 用原帖 KZ 核验顶层 PID。FID 取经现有冲突检查的原帖来源，缺失时省略 |
| 整个原帖对象缺失 | 回退到外层 KZ 并直接导航 | 将外层 `threadId` 作为唯一候选，省略 FID，严格核验同一顶层 PID |
| 嵌套 PID 与顶层 PID 不同 | 回退到外层 KZ 并直接导航 | 严格核验外层候选及顶层 PID，省略无法关联的 FID。引用按钮仍可独立打开引用原帖 |
| 嵌套坐标可能属于当前回复，但 KZ 缺失或等于目标 PID | 留在列表 | 留在列表。该已识别分支不会尝试外层 KZ |
| 外层候选等于目标 PID | 普通回退可能失去可靠主题 | 拒绝该候选。若有独立有效且符合当前回复的原帖坐标，则采用原帖核验分支 |
| 显式引用点击、明确转发、其他动态来源 | 走各自原路由 | 保留各自坐标规则 |

### 严格请求、详情复用与账号隔离

- 定位请求复用生产 `pb/page` 的 KZ #4、PID #7 和可选 `forum_id` #56。首屏有效锚点用 `pn=0`，编码按 proto3 规则省略默认值字段 #18。`requiresExactReply` 要求有效锚点，并校验回包的显式主题 ID 与请求 KZ 相同，且帖子列表中包含目标 PID。业务码 0 仍需以上两项证明。在核验分支，业务码 4、锚点缺失及其他失败不会换 KZ、去锚点或用旧缓存兜底。现有传输层有限重试仍由原策略管理。
- 成功核验产生 `VerifiedReplyPage`，经 TaskLocal 传给 Navigator 同步创建的详情控制器。详情首次加载一次性取走它，并核对主题、PID、账号、排序和只看楼主条件。条件相同直接使用验证页，避免相同定位请求重复发送。核验读取可使用已有的、通过同样验证的新鲜缓存。核验自身不另写磁盘缓存，避免作废结果写入缓存。后续下拉刷新走固定 KZ 和原锚点，分页沿用固定 KZ 及下一页码并省略定位 PID。
- 首屏和刷新计算 `pendingPostFocus`，列表快照发布后按目标 PID 找行，再调用 `scrollToPostRow`。Swift 夹具验证交接页含所需锚点，UIKit 的真实滚动和手势由 iPhone 复核。
- 新点击、刷新、动态子页移除和页面离开作废旧任务。结果只有持有当前一次性票据、任务未取消、页面仍可交互且账号匹配时才可导航。核验期间对原有会话通知用同步观察和锁记录作废，账号 A → B → A 也不能接受旧结果。会话变动即使发生在网络请求已发出后，结果也无法交给详情。

### Debug 与互动只读审计

Debug 保留原有开关、字段白名单、映射值、请求坐标和复制最近一次失败入口。新增理由包括缺少原帖或嵌套 PID 不一致、原帖候选缺失或与 PID 相同、为何只核验某个 KZ 及为何省略 FID。失败记录使用固定分类和数字业务码，区分未准备请求、请求已准备但无法确认传输、已收到服务端响应。缓存命中单独标明。成功核验记录已提交导航，详情实际出现由 `viewDidAppear` 单独记录。日志没有扩展到账号、鉴权字段、请求头、内容或服务端错误正文。诊断引用均受 `#if DEBUG` 保护。

| 入口 | 源码证据与影响 |
| --- | --- |
| 推荐卡片点赞 | `toggleLike → interaction → card` 仍可选择外层 `threadId`。原样本没有首楼 ID，代码会先用该 KZ 读取首楼，拿不到首楼可回滚且不调用 `setAgree`。源码未证明已有成功的错误写操作 |
| 卡片分享 | `shareThread → card` 以外层 KZ 拼接主题链接，受同一身份歧义影响 |
| 不感兴趣及屏蔽吧 | `interaction → submitDislike` 会把外层 KZ 放在推荐反馈负载 `tid`。其写接口是否把它当作推荐记录标识缺少线上证据 |
| 收藏 | 推荐卡片行没有收藏入口。详情的 `toggleCollect` 使用详情所持主题坐标，因此经新核验打开后取已验证 KZ |

## 文件清单

| 范围 | 文件与本轮用途 |
| --- | --- |
| 决策 | `Sources/TiebaNative/Core/Routing/TiebaThreadCardTarget.swift`，明确候选及单次导航资格 |
| 请求 | `Sources/TiebaNative/Core/Networking/TiebaThreadAPI.swift`，严格查询入口和一次性页面交接 |
| UIKit | `Sources/TiebaNative/Features/Explore/TiebaExploreFeedViewController.swift`、`Sources/TiebaNative/Features/Thread/TiebaThreadViewController.swift`，核验取消、导航资格、首屏使用和入口诊断 |
| Debug | `Sources/TiebaNative/Core/Routing/TiebaReplyRoutingDiagnostics.swift`，选择理由及原样字段、传输和导航分类 |
| 测试 | `DynamicReplyRoutingTests.swift`、`run_dynamic_reply_routing_tests.py`，扩展夹具、序列化请求断言和接线检查 |
| 工作区继承 | `Sources/TiebaNative/Core/Networking/TiebaFeedAPI.swift` 与 `Sources/TiebaNative/Core/Proto/TiebaSwiftProtoCodec.swift` 中的上一轮快照诊断、wire 标签接入仍在待提交 diff 中 |

## 测试与 Swift 6 专项审计

| 用例 | 夹具或断言 |
| --- | --- |
| T01、T06、T07 | 真实映射值重建的 Protobuf 使用原帖 KZ、顶层 PID、`pn=0`。断言无原帖 FID 时字段缺省，有可信原帖 FID 时正确编码 |
| T02、T03、T05 | 原帖完全缺失时，合法外层通过核验，错误外层的业务码 4 拒绝。现有嵌套对象无 KZ、候选 KZ 等于 PID 均明确拒绝 |
| T04、T08、T09、T10 | 嵌套 PID 冲突时错误外层拒绝。合法普通回复含无关引用及外层 ID 偶然相等仍可验证。显式引用另开原主题、不带当前 PID |
| T11、T12 | 普通主题可使用「回复：」标题并保持主题处理。转发和引用按对应原帖路由 |
| T13、T14、T15 | 业务成功但主题不符、缺少显式主题 ID或找不到目标 PID 均抛错。业务码 4 只观察到该候选的一次带锚点请求，不尝试其他坐标 |
| T16 | 验证页包含锚点，交接限制同账号，离开 TaskLocal 后无法再次读取。夹具断言首屏只需一条请求，刷新 KZ/PID 不变，分页保持 KZ 并省略 PID |
| T17 | 生产同款票据测试涵盖旧点击、重复消费、刷新作废、隐藏页面、换账号与 A → B → A。UIKit 集成由下一轮真机复核 |

- Swift 并发静态审查覆盖了两类 TaskLocal。跨异步传递的是 `Sendable` 的验证页、诊断尝试对象和互斥量。UIKit 导航和界面生命周期由 MainActor 任务处理；账号通知回调只改带锁布尔标记。原始卡片字典在建立候选和脱敏诊断后留在同步作用域。
- 核对了调用链、默认参数、生成的 `Tieba_ThreadInfo`、`Tieba_PbPage_PbPageResponse` 和生成测试依赖。脚本真实生成的 `Tests.swift` 有一个 `@main`，解析通过，65 个 `expect` 的条件均未发现嵌套 `try` 或 `await`。另解析了当前 diff 的 8 个 Swift 文件。Swift 编译器、类型检查和测试程序本轮均未运行。
- Windows 六组 `--check-sources` 已通过，覆盖动态回复、动态帖子、深链、HTTP 重试、发言和私信。已查看完整代码差异并执行 `git diff --check`、`git diff --stat`、`git status --short`。
- 三次内存中的源码变异分别恢复了缺少原帖时的 `return nil`、嵌套 PID 冲突时的 `return nil`，以及严格核验中去锚点降级。Python 接线检查均能检出。Swift 用例对这些变异的真实运行仍待 macOS。

## 下一轮验收

1. 审阅并提交后，在 Actions 手动选择 `feat/full-interaction`、`Debug`，留空 `tag_name`。先检查六组静态检查和 Swift 6 离线测试真实输出，再检查 Bazel `//:App` 和 IPA Artifact。
2. iPhone 安装该 SHA 的 Debug IPA。开启「更多设置 → 调试 → 回复路由诊断」，下拉刷新推荐流并重试原卡。核对 `11230786026 / 154184058416`、首次 `pn=0`、回包成功和滚动到目标楼层，确认详情首屏没有同坐标重复请求。原卡未重新出现时，记录为尚待真机复核。
3. 滚动后下拉刷新并翻页，确认仍是同一主题。对照普通主题、普通回复、引用区域、转发、关注流。测试缺坐标或核验失败时是否留在列表并可复制原因。
4. 对准备核验的卡快速连点另一卡、刷新、切换推荐和关注、切换账号或离开页面。确认旧结果不推进导航。核对 Release 的排除范围可由后续同 SHA 的编译动作和产物验证。

## 审阅后的 Git 命令

以下以 PowerShell 从仓库根目录执行。工作区继承了上一轮全部待交付的代码，因此暂存清单包含两轮的合并差异。报告受 `*.md` 忽略规则影响，单独显式加入。命令仅供审阅后使用。

```powershell
git add -- `
  Sources/TiebaNative/Core/Networking/TiebaFeedAPI.swift `
  Sources/TiebaNative/Core/Networking/TiebaThreadAPI.swift `
  Sources/TiebaNative/Core/Proto/TiebaSwiftProtoCodec.swift `
  Sources/TiebaNative/Core/Routing/TiebaReplyRoutingDiagnostics.swift `
  Sources/TiebaNative/Core/Routing/TiebaThreadCardTarget.swift `
  Sources/TiebaNative/Features/Explore/TiebaExploreFeedViewController.swift `
  Sources/TiebaNative/Features/Thread/TiebaThreadViewController.swift `
  docs/bugfix/dynamic-reply-routing/DynamicReplyRoutingTests.swift `
  docs/bugfix/dynamic-reply-routing/run_dynamic_reply_routing_tests.py
git add -f -- docs/bugfix/dynamic-reply-routing/06_PERSONALIZED_REPLY_EDGE_CASE_AUDIT.md
git diff --cached --check
git diff --cached --stat
git status --short
git commit -m "fix: verify ambiguous personalized reply targets"
git push origin HEAD:feat/full-interaction
```
