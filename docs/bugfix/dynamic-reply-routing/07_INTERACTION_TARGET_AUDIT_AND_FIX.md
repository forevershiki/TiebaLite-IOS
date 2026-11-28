# Dynamic Reply Routing Phase 6 互动坐标审计

工作区分支为 `feat/full-interaction`，基线为 `c8c6d5d187d7a1391357252e2257c43796578004`。Phase 5.1 的动态回复导航已由用户在 iPhone 验证。Phase 6 的结论来自已有服务端证据、当前源码、公开客户端和 Windows 静态检查。

## 问题与证据等级

| 等级 | 结论 |
| --- | --- |
| P0 | 未发现已发生的错误写入或隐私泄露。本轮没有发送真实写请求 |
| P1 | 旧分享直接调用 `card`，绕过个性化回复的严格核验。已确认失效样本会由此生成外层 ID 链接。话题和热榜的旧分享也直接使用列表 ID，现改为各自已有的导航目标 |
| P1 | 旧推荐卡红心通过 `interaction` 使用外层 KZ，可能以该坐标查询首楼或构造写请求。已知失效样本的新卡片链路在发请求前拒绝不明点赞对象。旧客户端实际写入结果缺少证据 |
| P2 | 变换后的推荐卡片尚未确认红心归属和反馈 `tid`。分享暂用已核验的主题 URL。页面局部隐藏、连点和换号仍需真机回归 |
| P2 | 话题、用户主页和详情底栏部分旧点赞仍有首楼缺失回退，热榜的旧推荐反馈用列表 ID。这些调用链没有个性化失效样本的归属证据，详见入口审计 |
| P3 | Markdown 受仓库忽略规则约束。已有未跟踪的 `docs/ci/__pycache__/` 保留在工作区 |

上一阶段匿名只读对照证明，外层 `2100000009798432` 与同一个 PID 请求返回业务码 4，省略 FID 后仍是 4。原帖 `11230786026` 和 PID `154184058416` 返回业务码 0 且回包含两个坐标，携带或省略 `1937070` 均成功。该证据确立了这一条卡片的导航和分享坐标，也排除了 FID 是该样本失败的原因。外层数字在其他卡片上的普遍语义、红心对象和推荐反馈身份仍缺证据。本轮沿用历史结果。 [上一轮审计](06_PERSONALIZED_REPLY_EDGE_CASE_AUDIT.md)

## 字段溯源

| 身份或状态 | Protobuf 来源 | 应用中的用途 |
| --- | --- | --- |
| 卡片 | `PersonalizedResponseData.threadList` #2 中的 `ThreadInfo.id` #1，`int64` | Mapper 输出 `id`，缺失时使用明确的主题字段。列表、展开、菜单定位沿用卡片身份 |
| 主题候选 | `ThreadInfo.threadId` #2，`int64` | 映射到独立的 `threadId`。标准卡交给现有解析器，特殊个性化回复走 Phase 5.1 的候选判定及核验 |
| 回复候选 | `ThreadInfo.post_id` #52，`int64` | 映射为 `postId`。详情定位和严格核验使用 PID，独立于首楼 |
| 首楼 | `ThreadInfo.firstPostId` #40，`int64`，或详情响应中的一楼 `Post.id` #1，`uint64` | 帖级红心和详情收藏。动态写入链路拒绝把等于 KZ 的占位值当作首楼。需要查询时核对回包主题，首楼来源冲突则拒绝 |
| 贴吧 | `ThreadInfo.forumId` #27，`forumName` #28，`forumInfo` #155 | 显示用贴吧身份与 `routingForumId` 分开。路由 FID 冲突时置空。本页隐藏优先比较 FID，缺少 FID 时比较完整吧名 |
| 引用或转发 | `ThreadInfo.origin_thread_info` #141，`is_share_thread` #143。嵌套 `OriginThreadInfo.tid` #5 为字符串，`fid` #7 和 `pid` #25 为 `int64` | 映射独立嵌套身份。引文或转发按已有规则分享被引用主题。特殊回复用自己的 PID 做只读核验 |
| 卡片红心 | `ThreadInfo.agreeNum` #124，`agree` #126，嵌套 `Agree.agreeNum` #1 和 `hasAgree` #2 | Mapper 给 UI 的 `zanNum`、`hasAgree`。变换卡的这份状态属于哪个写对象仍需证据 |
| 详情楼层红心 | `Post.agree` #37 | 详情按显式楼层的 `Post.id` 更新状态 |
| 推荐元数据 | `PersonalizedResponseData.threadPersonalized` #7 的 `tid` #1，`uint64`，`dislikeResource` #5，`extra` #6。另有 `ThreadInfo.dislikeInfo` #120 | 推荐理由和记录线索。当前 iOS 推荐映射取 `threadList`，未将该元数据的 `tid` 验证为变换卡的写入坐标 |

原始编号来自仓库 descriptor 和生成代码。 [描述文件](../../../Sources/TiebaNative/Proto/proto-descriptors.json) · [推荐响应](../../../Sources/TiebaNative/Proto/Generated/Personalized.pb.swift) · [投影](../../../Sources/TiebaNative/Core/Proto/TiebaViewModelMapper.swift)

## 互动调用链及请求对照

### 分享

操作栏和长按菜单统一进入 `shareThread → resolveThreadAction → opening`。明确主题、普通回复或可解析引用直接取主题 KZ。歧义个性化回复复用 `verifyReply → pb/page`。首次定位 `pn=0`，回包主题及目标 PID 均须匹配。核验失败时留在当前页并提示。成功后使用原来的标题、分享文案及系统面板。导航独自消费验证后的页面，并沿用原有换号、取消和一次性首屏交接保护。

| 场景 | 旧分享 | 新分享 |
| --- | --- | --- |
| 已确认失效样本 | `https://tieba.baidu.com/p/2100000009798432` | 核验 KZ `11230786026`、PID `154184058416`、省略 FID 后分享 `https://tieba.baidu.com/p/11230786026` |
| 普通主题和普通回复 | 主题 URL | 主题 URL，无额外分享读取 |
| 引用和转发 | 已识别的引用目标 | 保留所引用主题的 URL |
| 歧义坐标核验失败 | 可能显示外层主题链接 | 不生成链接并反馈失败 |

现有详情分享及 App 深链使用 `?pid=`。这能证明 App 内部支持该参数。公开网页访问未能确认移动网页可靠地滚至目标楼层，所以本轮卡片分享使用主题 URL。 [动态页](../../../Sources/TiebaNative/Features/Explore/TiebaExploreFeedViewController.swift) · [帖子 API](../../../Sources/TiebaNative/Core/Networking/TiebaThreadAPI.swift) · [详情](../../../Sources/TiebaNative/Features/Thread/TiebaThreadViewController.swift)

### 点赞与取消

`toggleLike → agreeTarget → setFeedAgree → 可选 pb/page → setAgree → signedPost → HTTP/业务码 → 提交状态或撤销投影`。帖级表单字段为 `thread_id=KZ`、`post_id=首楼PID`、`obj_type=3`、`agree_type=2`。同一对象的点赞和取消分别发 `op_type=0` 与 `1`。认证沿用登录检查、签名、TBS 续期及可选会话令牌，没有 FID 字段。详情普通楼层使用 `obj_type=1`，楼中楼使用 `obj_type=2`。公开 Android 的推荐和关注流使用帖级接口，详情将主题、楼层和楼中楼分开。历史 Swift/RN 对照和 `af377d5:src/services/api/endpoints/thread.ts` 支持相同表单合同。

旧标准卡本就使用上述字段和传输，但依赖 `interaction` 的外层坐标和首楼查询。已确认样本可能以外层 `2100000009798432` 查首楼，也可能在已知首楼的同类数据中据此构造写入。新实现对该样本拒绝卡片写入并提示在详情操作。可以在详情确认当前楼层和主题后直接使用该楼层红心。严格匹配 KZ/PID 只能证明该楼层可定位，不能证明卡片红心属于它。 [原生动作 API](../../../Sources/TiebaNative/Core/Networking/TiebaThreadActionAPI.swift) · [Android 推荐入口](https://github.com/zzc10086/TiebaLite/blob/9777ba9a05146ac10157a9e942b98129ce929065/app/src/main/java/com/huanchengfly/tieba/post/ui/page/main/explore/personalized/PersonalizedPage.kt#L215) · [Android 详情实现](https://github.com/zzc10086/TiebaLite/blob/9777ba9a05146ac10157a9e942b98129ce929065/app/src/main/java/com/huanchengfly/tieba/post/ui/page/thread/ThreadViewModel.kt#L411)

| 动态类型 | 分享 | 卡片红心 | 推荐反馈 |
| --- | --- | --- | --- |
| 明确主题 | 直接生成主题 URL | 帖级。首楼可信时直接用，缺失时按 KZ 查一楼并核对主题 | 推荐流维持普通主题请求 |
| 独立主题 KZ 和首楼明确的普通回复 | 分享所属主题 | 沿用帖级红心。先核验主题、目标回复和首楼。本次写使用首楼 PID | 回复反馈语义待确认 |
| 个性化歧义回复 | 严格核验单一候选后分享 | 对象归属待确认，停在列表并提示 | 保留在列表并提示 |
| 外层普通主题或回复带无关引文 | 仍由外层卡片决定。点击引文正文按已有引用导航 | 只在外层能满足前两行条件时执行 | 仅明确的普通推荐主题 |
| 明确转发或只有引用目标 | 分享引用主题 | 外层转发与原帖红心归属待确认 | 反馈语义待确认 |
| 楼中楼或缺少足够字段的卡片 | 只有可靠的主题坐标时分享 | 详情的独立楼中楼入口可明确对象。卡片写入需满足已验证的条件 | 反馈语义待确认 |

点赞期间，列表原始数据保留服务端基线。UI 以 `KZ + 回复锚点 + 账号` 投影。重复的同锚点卡片同步，另一回复不跟随。服务端确认后才更新对应行，失败时丢弃投影恢复基线。相同 KZ 的写操作串行准入，旧票据不能清除新状态。账号见证在读详情前、TBS 续期前后、表单分发前、UI 提交前验证，动态响应及缓存保存也绑定发起账号。已经发出的请求由服务端处理，切号校验无法撤回。既有全局 TBS 续期持久化没有纳入本轮接口修改。 [状态与坐标](../../../Sources/TiebaNative/Core/Routing/TiebaThreadCardTarget.swift) · [签名 POST](../../../Sources/TiebaNative/Core/Networking/TiebaSocialAPI.swift)

### 推荐反馈和贴吧隐藏

`presentDislikeSheet → recommendationFeedback → sendFeedback → TiebaFeedAPI.submitDislike → signedPost`。端点为 `POST /c/c/excellent/submitDislike`，请求是签名 URL 编码表单。字段 `dislike_from=homepage`，`dislike` 为 JSON 数组。数组元素包含字符串 `tid`、`dislike_ids`、`fid`、`extra`，以及毫秒整数 `click_time`。服务端成功后按卡片 ID 和卡片 PID 移除行。Android 在普通推荐入口使用外层 `threadId`、论坛 ID，推荐元数据在其 ViewModel 中另以 `ThreadPersonalized.tid` 和卡片 ID 关联。

当前仓库没有该写端点的 Protobuf 请求消息或字段编号。`getDislikeList` 属于读取屏蔽列表的 Protobuf 路径。普通明确主题维持原有表单和坐标策略。回复、转发及关注流中的该推荐反馈现已拦截，待取得可验证的专用 ID 和来源证据。旧反馈写路径可能把歧义外层 ID 交给推荐系统，具体生效对象尚未验证。 [推荐 API](../../../Sources/TiebaNative/Core/Networking/TiebaFeedAPI.swift) · [Android 反馈入口](https://github.com/zzc10086/TiebaLite/blob/9777ba9a05146ac10157a9e942b98129ce929065/app/src/main/java/com/huanchengfly/tieba/post/ui/page/main/explore/personalized/PersonalizedPage.kt#L225)

`blockForum → ForumTarget → 本页按账号隐藏匹配贴吧`。本地过滤对当前页面实例的刷新和分页有效。明确的普通推荐主题且 FID 可信时，另行发送理由 `7`。本页提示分别显示本地隐藏和已提交推荐反馈。缺少服务器目标时不发送反馈。服务器是否长期屏蔽还需授权的实际环境验证。

### 其他入口

| 入口 | 调用及本轮结果 |
| --- | --- |
| 关注动态 | 复用动态页控制器，分享和红心走同一适配。维持既有关注导航来源判定。暂不借用 `homepage` 发送关注卡反馈 |
| 热榜 | 长按通过列表 ID 找行，分享从该行已有导航目标取 KZ。热榜没有直接调用帖级红心的写路径。旧不感兴趣仍按热榜原来的列表 ID 上报，语义需要热榜样本 |
| 话题 | 操作栏分享使用已有导航解析。旧点赞缺少首楼时可能把列表 ID 发作 `post_id`，没有观察到它处理真实个性化回复包装的证据 |
| 用户主页 | 分享已经读取映射后的 `threadId`。旧红心走帖级接口，但允许选择 `postId` 或 KZ 回退。遇到回复型数据可能传错楼层字段，需按主页卡片的心形状态和真实响应另行核验 |
| 详情收藏 | `toggleCollect → setStore`。从已打开详情取得 KZ，一楼从主贴或详情线程字段得出。收藏发 `addstore` 的 `data` 内层 `tid/pid/status`，取消发 `rmstore` 的 `tid`。没有首楼时的历史 `pid=0` 仍待真机覆盖 |
| 详情红心 | 主贴和底栏为帖级，普通楼层和楼中楼为显式对象。底栏缺失首楼时的旧 KZ 回退仍有被服务端拒绝的风险 |

## 自动化覆盖及执行情况

测试追加在 `DynamicReplyRoutingTests.swift`。现有 CI 入口编译实际动态坐标解析、帖子 Protobuf、完整动作 API 和提取的签名发送及反馈方法。只替换认证、签名值、缓存和底层 Transport。记录读取序列化后的 Protobuf、表单及嵌套 JSON，检查请求次数及零写入条件。没有使用用户账号或真实服务端写操作。

| 用例 | 新增或保留的断言 |
| --- | --- |
| S01–S06 | 普通主题、独立回复、引用和转发 URL。失效样本的 `kz/pid/pn` 和 FID 缺席经过序列化验证。严格核验前不生成链接，缺少 PID 的回包被拒，成功后生成原帖链接 |
| L01–L06 | 主题已知首楼、缺首楼单次查询、错主题阻断、普通回复精确核验、首楼冲突、未确认卡片目标及缺少 PID 均阻断写。实际表单校验 `thread_id/post_id/obj_type/agree_type/op_type` 和 FID 缺席 |
| L07–L10 | 模拟业务码 4 只有一次写尝试，失败投影撤销，连续两个票据只序列化一次写，两回复锚点与账号隔离。读取过程中及 TBS 阶段切号均检查零新增写入，旧票据无法清除新账号票据。UIKit 连点和刷新交互仍待真机 |
| F01–F02 | 普通推荐反馈的 JSON、endpoint 及次数，明确主题的 FID 和隐藏理由 7。歧义卡只产生本页贴吧目标，缺 FID 的同名匹配和有 FID 冲突分别覆盖 |
| R01–R04 | 保留原有真机映射数据重建的合成 Protobuf、严格回复核验、普通和引用转发断言。新增收藏及取消的真实表单字段、端点和次数断言 |

Windows 执行以下命令，六组检查均退出 `0`。私信组包括离线 SQLite 检查。Swift 的类型检查、编译和上述测试体执行须由 macOS Runner 完成。

```powershell
python -B docs/bugfix/dynamic-reply-routing/run_dynamic_reply_routing_tests.py --check-sources
python -B docs/bugfix/dynamic-feed-thread/run_dynamic_feed_thread_tests.py --check-sources
python -B docs/bugfix/deep-link/run_deep_link_tests.py --check-sources
python -B docs/bugfix/http-retry/run_retry_tests.py --check-sources
python -B docs/features/composer/run_composer_tests.py --check-sources --suite-only
python -B docs/features/private-message/run_private_message_tests.py --check-sources --suite-only
git diff --check
git --no-pager diff --stat
git status --short
```

另以现有脚本生成实际 `Production.swift` 和 `Tests.swift`，由 Tree-sitter 检查生成文件及修改过的 Swift 源码。静态审计了非 throwing 断言、唯一 `@main`、辅助类型定义和生成 Protobuf 属性。UIKit 及列表字典留在主执行器，异步 API 传递字符串、值类型坐标和 `@Sendable` 账号见证。TaskLocal 延续现有导航和测试注入方式。Debug 仍只记录导航诊断，分享和写入未添加诊断数据，也未改变 Release 条件。Tree-sitter 只验证语法结构。Bazel、IPA 和 Phase 6 真机尚未运行。

## 修改文件和 Git 命令

以下是完整的代码和测试清单。工作区的 Markdown 报告需要显式暂存。命令供审阅批准后执行。

```powershell
Set-Location 'D:\GitHub\TiebaLite-IOS'
git add -- `
  Sources/TiebaNative/Core/Networking/TiebaFeedAPI.swift `
  Sources/TiebaNative/Core/Networking/TiebaSocialAPI.swift `
  Sources/TiebaNative/Core/Networking/TiebaThreadActionAPI.swift `
  Sources/TiebaNative/Core/Routing/TiebaThreadCardTarget.swift `
  Sources/TiebaNative/Features/Explore/TiebaExploreFeedViewController.swift `
  Sources/TiebaNative/Features/Explore/TiebaHotListViewController.swift `
  Sources/TiebaNative/Features/Explore/TiebaTopicViewController.swift `
  docs/bugfix/dynamic-feed-thread/DynamicFeedThreadTests.swift `
  docs/bugfix/dynamic-feed-thread/run_dynamic_feed_thread_tests.py `
  docs/bugfix/dynamic-reply-routing/DynamicReplyRoutingTests.swift `
  docs/bugfix/dynamic-reply-routing/run_dynamic_reply_routing_tests.py
git add -f -- docs/bugfix/dynamic-reply-routing/07_INTERACTION_TARGET_AUDIT_AND_FIX.md
git diff --cached --check
git --no-pager diff --cached --stat
git commit -m "fix: resolve feed interaction targets safely"
git push origin HEAD:feat/full-interaction
```

## 云端和 iPhone 验收

1. 在 fork 的 Actions 中打开 `Build iOS Unsigned IPA`。选择分支 `feat/full-interaction` 和 `Debug`，将 `tag_name` 留空。确认 Checkout SHA 对应本次改动。
2. 查看阶段 B 六组静态检查、C0 macOS Swift 冒烟、C 六组 Swift 真实编译与运行。重点查看回复路由套件完成输出。现有失败门禁要求 B/C 成功后才允许 D/App、E/AppStripped 和 F/上传。
3. 下载 `ipa-<SHA>` Artifact 中的 `TiebaLite-unsigned-<SHA>.ipa`，用现有自签流程安装。保存期限为 30 天。 [构建流程](../../../.github/workflows/build-ipa.yml)
4. 先在推荐中找回已知的 `yy小说吧` 回复样本。操作栏与长按分别分享，确认主题 URL 为 `https://tieba.baidu.com/p/11230786026`。点击卡片仍定位到正确楼层，刷新和分页保持主题。切栏目或离开页面时旧的核验不能弹出面板。
5. 比较普通主题、普通回复、引用及转发。分别验证分享、打开和显示，重点观察同一主题的不同回复。遇到歧义卡，确认红心明确提示，进入详情后可用当前楼层自己的红心。
6. 在用户授权的测试账号和对象上验证普通主题赞、取消、失败回滚、快速连点、刷新与切号。详情分别核对主贴、楼层、楼中楼和收藏/取消。缺首楼与定位失败也应覆盖。
7. 用可确认的普通推荐主题验证不感兴趣及屏蔽贴吧。验证歧义卡只隐藏该吧，切换账号后本地规则隔离，后台反馈有无提交与页面提示一致。

本轮具备进入下一轮 GitHub Actions Debug 构建的条件。Phase 6 的 Swift 6 编译、离线执行、IPA 和 iPhone 验收需要实际运行后确认。
