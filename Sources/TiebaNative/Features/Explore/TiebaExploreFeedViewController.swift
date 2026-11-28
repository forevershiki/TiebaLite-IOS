// 发现 tab 的「推荐 / 关注」信息流段（原 src/components/explore/FeedContent.tsx）：
// 数据 TiebaFeedAPI（proto），列表 = TiebaKindListContentView 的 feed 行，
// 点赞/分享/屏蔽作者/不感兴趣/长文展开/图片菜单全在原生。
import UIKit

final class TiebaExploreFeedViewController: UIViewController, TiebaTabReselectable {
  /// 快照键用的分段名（String 原始值：键里要拼进 KV）。
  enum Segment: String {
    case personalized
    case concern
  }

  private let segment: Segment
  private let list = TiebaKindListContentView()
  /// 整页发布驱动（页键 = explore-<rec|concern>-<seq>）：测量在后台，旧页后到
  /// 不覆盖新页。
  private lazy var driver = TiebaRowPageDriver(
    list: list,
    keyPrefix: "explore-\(segment == .personalized ? "rec" : "concern")"
  )
  private let stateView = TiebaStateContentView()
  private let pill = TiebaPhotoBrowserPillView()
  /// 供发现页 chrome 收缩的只读滚动位置；更新只做一次标量赋值与阈值通知。
  private(set) var chromeScrollOffsetY: CGFloat = 0
  var onChromeScrollChange: ((CGFloat) -> Void)?
  private var needsTopAnchorAfterRefresh = false
  private var topAnchorGeneration = 0
  private weak var observedListScrollView: UIScrollView?

  /// FeedItem 形状（{type, threadInfo}），index 与列表行一一对应。
  private var items: [[String: Any]] = []
  private var expandedIds: Set<String> = []
  private var likeMirror = TiebaFeedAgreeState()
  private var itemsAccountKey = ""
  private var hiddenForums: [String: Set<TiebaThreadCardTarget.ForumTarget>] = [:]
  private var pageTag = ""
  private var page = 1
  private var hasMore = false
  private var isLoading = false
  private var isLoadingMore = false
  private var replyVerificationTask: Task<Void, Never>?
  private var replyVerification = TiebaThreadCardTarget.VerificationGate()
  private var isUserRefresh = false
  private var lastLoadedAt = Date.distantPast
  private var lastRowSignature = ""
  private nonisolated(unsafe) var prefToken: NSObjectProtocol?

  deinit {
    if let prefToken { NotificationCenter.default.removeObserver(prefToken) }
  }

  private var isLoggedIn: Bool { !TiebaBackgroundSnapshot.shared.bduss.isEmpty }

  init(segment: Segment) {
    self.segment = segment
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - 生命周期

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    applyPalette()
    list.isHidden = true
    applyEntrancePreference()
    // 本页实例常驻（explore 三个子页）：设置页改了值不会重走 viewDidLoad，
    // 订阅偏好广播即时生效（token 随 deinit 释放）。
    prefToken = TiebaPreferenceChange.observe(key: "entranceAnimation") { [weak self] in
      MainActor.assumeIsolated { self?.applyEntrancePreference() }
    }
    // 底栏重复点击走 tabReselected（用户口径：先回顶不刷新，顶部再按才刷新）。
    stateView.isHidden = true
    stateView.isDark = TiebaChromeTheme.current.dark
    stateView.tintColor = TiebaExploreSurface.brandForeground
    // 信息流骨架：thread 卡片、半数带图（原 FeedContent.tsx variant="thread" count={8}）
    stateView.skeletonVariant = .thread
    stateView.skeletonInsets = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
    stateView.onButtonPress = { [weak self] id in self?.handleStateButton(id) }
    list.onListEvent = { [weak self] event in self?.handleEvent(event) }
    list.onScroll = { [weak self] scrollView in
      guard let self else { return }
      self.observedListScrollView = scrollView
      self.chromeScrollOffsetY = scrollView.contentOffset.y
      self.onChromeScrollChange?(scrollView.contentOffset.y)
    }
    list.contentOffsetWillCommit = { scrollView, target in
      // 只在落点已经贴顶时做一次轻吸附；不抢惯性，也不改分页触发。
      let top = -scrollView.adjustedContentInset.top
      if target.y > top, target.y - top < 30 {
        target.y = top
      }
    }
    for subview in [list, stateView, pill] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      list.topAnchor.constraint(equalTo: view.topAnchor),
      list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: view.topAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
      pill.widthAnchor.constraint(lessThanOrEqualToConstant: TiebaLayout.floatingMaxWidth),
    ])
    itemsAccountKey = TiebaPageCache.currentAccountKey()
    if let seed = seedItems() {
      items = seed
      publishFresh()
      showList()
    } else {
      showState(.loading)
    }
    // 首屏数据：冷启动一律照拉（SWR 快照只是先画出来，随后被真数据替换）。
    reload()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyInsets()
    captureListScrollViewIfNeeded()
    // 行宽契约 = 列表宽 − 2×horizontalInset（内缩含内容列居中留白）。
    driver.updateWidth(list.bounds.width - list.horizontalInset * 2)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    cancelReplyVerification()
  }

  override func willMove(toParent parent: UIViewController?) {
    super.willMove(toParent: parent)
    if parent == nil { cancelReplyVerification() }
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    applyInsets()
  }

  private func applyInsets() {
    // Issue #4（顶栏遮挡）：这里原来是常量 `TiebaExploreSurface.pageTopInset`（= 8）。
    //
    // 本页的列表 `topAnchor == view.topAnchor`（全屏出血，内容从屏幕最顶开始画），
    // 所以静止位必须自己把**状态栏 + 导航栏**的高度让出来。写死 8 的后果是：
    // contentOffset 停在 -8，第一张卡片的顶边落在屏幕顶端 —— 正好压在玻璃导航栏下面，
    // 也就是用户报的"最上面的帖子被顶栏遮挡"。
    //
    // 为什么下拉刷新看起来正常：`UIRefreshControl` 在刷新期间会把 inset 临时撑大
    // （约 60pt），内容被顶下来，正好躲过栏；刷新结束 inset 收回，遮挡重新出现，
    // 只是那时用户已经不看第一行了。所以这不是两个 bug，是同一个静止位算错。
    //
    // 口径与同仓其它全屏列表一致（Forum:193 / Topic:117 / UserSocial:76 / Subposts:306
    // 都是 `view.safeAreaInsets.top`）；本页保留原来的 8pt 呼吸感，加在安全区之上。
    list.contentInsetTop = view.safeAreaInsets.top + TiebaExploreSurface.pageTopInset
    list.contentInsetBottom = view.safeAreaInsets.bottom + TiebaExploreSurface.pageBottomExtra
  }

  /// 主题变化（含跟随系统时的实时切换）→ 重取主题重刷自绘色（页面底色/列表色板/页头）。
  func screenThemeDidChange() {
    applyPalette()
  }

  private func applyPalette() {
    var palette = TiebaSimpleRowPalette.default
    palette.base = TiebaExploreSurface.palette()
    list.palette = palette
  }

  /// 入场动画开关（现读偏好；批次判定在列表内，见 endEntranceBatch）。
  private func applyEntrancePreference() {
    list.entranceAnimationEnabled = TiebaPreferenceSnapshot.bool("entranceAnimation", default: true)
  }

  // MARK: - 外部驱动（tab 根屏）

  /// 聚焦（tab 选中 / 从二级页返回 / 回前台）：**一律不拉网络**。
  /// 用户口径：列表不因聚焦自动刷新、更不该让人丢阅读位置；新数据只由显式动作拉
  /// （下拉刷新、底栏重选、错误页重试）。这里只做零网络的本地回推。
  func handleFocus() {
    guard segment != .concern || isLoggedIn else { return }
    // 偏好（字号/隐藏媒体/时间格式/屏蔽词）可能已变：行指纹变了才整页重测。
    republishIfPreferencesChanged()
    if list.isHidden, !items.isEmpty { showList() }
  }

  /// 段被切到前台：页数据可能已被其它列表整页挤出度量缓存，按行数复查。
  func handleBecameVisible() {
    guard !items.isEmpty else { return }
    if TiebaKindRowPages.shared.rowCount(pageKey: driver.pageKey) != items.count {
      publishFresh()
    }
  }

  /// 底栏重复点击（用户口径）：不在顶部 → 只回顶，不刷新；已在顶部 → 顶部
  /// 展示刷新动画并重拉。
  func tabReselected() {
    guard list.isAtTop else {
      list.scrollToTop(animated: UIAccessibility.isReduceMotionEnabled == false)
      return
    }
    TiebaSceneHaptics.fire("press")
    isUserRefresh = true
    needsTopAnchorAfterRefresh = true
    list.beginRefreshing()
    reload()
  }

  // MARK: - 状态

  private var emptyState: TiebaState {
    .empty(
      image: "tray",
      text: "暂无内容",
      secondary: segment == .personalized ? "去关注一些贴吧获取推荐" : "暂无关注动态",
      retryTitle: "刷新"
    )
  }

  private func showState(_ state: TiebaState, animated: Bool = false) {
    let wasShowingList = list.isHidden == false
    let shouldAnimate = animated
      && wasShowingList
      && UIAccessibility.isReduceMotionEnabled == false
      && view.window != nil
    stateView.state = state
    stateView.isHidden = false
    if shouldAnimate {
      stateView.alpha = 0
      TiebaAnimation.animate(
        curve: .easeOut,
        duration: TiebaAnimationDuration.stateChange,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: {
          self.list.alpha = 0
          self.stateView.alpha = 1
        },
        completion: { _ in
          self.list.isHidden = true
          self.list.alpha = 1
          self.stateView.alpha = 1
        }
      )
    } else {
      list.isHidden = true
      list.alpha = 1
      stateView.alpha = 1
    }
  }

  private func handleStateButton(_ id: String) {
    if id == "login" {
      TiebaNavigator.shared.navigate(.login)
      return
    }
    reload()
  }

  private func showList() {
    // 数据到手 ≠ 行能画：整页测量在后台跑，提前让位就是状态视图先消失、正文空白。
    list.revealWhenReady { [weak self] in
      guard let self else { return }
      let fromState = self.stateView.isHidden == false
      self.list.isHidden = false
      self.scheduleTopAnchorAfterRefresh()
      let shouldAnimate = fromState
        && UIAccessibility.isReduceMotionEnabled == false
        && self.view.window != nil
      guard shouldAnimate else {
        self.stateView.isHidden = true
        self.stateView.alpha = 1
        self.list.alpha = 1
        self.list.transform = .identity
        return
      }
      self.list.alpha = 0
      self.list.transform = CGAffineTransform(translationX: 0, y: 6)
      self.stateView.alpha = 1
      TiebaAnimation.animate(
        curve: .easeOut,
        duration: TiebaAnimationDuration.stateChange,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: {
          self.list.alpha = 1
          self.list.transform = .identity
          self.stateView.alpha = 0
        },
        completion: { _ in
          self.stateView.isHidden = true
          self.stateView.alpha = 1
          self.list.alpha = 1
          self.list.transform = .identity
          self.scheduleTopAnchorAfterRefresh()
        }
      )
    }
  }

  /// 刷新成功后的可验证 top anchor：立即锁一次，等新行布局后再锁两次。
  /// 不触碰分页/缓存；只在由 tab 重按或顶部下拉触发的刷新里启用。
  private func scheduleTopAnchorAfterRefresh() {
    guard needsTopAnchorAfterRefresh else { return }
    topAnchorGeneration += 1
    let generation = topAnchorGeneration
    let lockTop = { [weak self] in
      guard let self, self.topAnchorGeneration == generation else { return }
      self.list.scrollToTop(animated: false)
      if let scrollView = self.observedListScrollView {
        TiebaExploreRefreshAnchor.lock(scrollView)
      }
    }
    lockTop()
    DispatchQueue.main.async { [weak self] in
      guard let self, self.topAnchorGeneration == generation else { return }
      // 新行高度/header inset 落地后再锁定；这是一次刷新收尾，不在滚动热路径。
      self.view.layoutIfNeeded()
      self.list.layoutIfNeeded()
      self.captureListScrollViewIfNeeded()
      lockTop()
      DispatchQueue.main.async { [weak self] in
        guard let self, self.topAnchorGeneration == generation else { return }
        self.captureListScrollViewIfNeeded()
        lockTop()
        #if DEBUG
        if let scrollView = self.observedListScrollView {
          TiebaExploreRefreshAnchor.logIfClipped(context: "explore-feed.refresh", scrollView: scrollView)
        }
        #endif
        self.cancelPendingTopAnchorRefresh()
      }
    }
  }

  private func cancelPendingTopAnchorRefresh() {
    topAnchorGeneration += 1
    needsTopAnchorAfterRefresh = false
  }

  private func captureListScrollViewIfNeeded() {
    guard observedListScrollView == nil else { return }
    observedListScrollView = Self.firstScrollView(in: list)
  }

  private static func firstScrollView(in view: UIView) -> UIScrollView? {
    if let scrollView = view as? UIScrollView { return scrollView }
    for subview in view.subviews {
      if let scrollView = firstScrollView(in: subview) { return scrollView }
    }
    return nil
  }

  // MARK: - 数据

  private func reload() {
    cancelReplyVerification()
    guard !isLoading else {
      cancelPendingTopAnchorRefresh()
      list.endRefreshing()
      return
    }
    if segment == .concern, !isLoggedIn {
      cancelPendingTopAnchorRefresh()
      list.endRefreshing()
      showState(.login(text: "请先登录", secondary: "登录后查看关注动态"), animated: true)
      return
    }
    let account = TiebaPageCache.currentAccountKey()
    if itemsAccountKey != account {
      itemsAccountKey = account
      items.removeAll()
      hasMore = false
    }
    let (observer, validate) = observeActionAccount(account)
    isLoading = true
    if items.isEmpty { showState(.loading) }
    Task { @MainActor in
      defer {
        NotificationCenter.default.removeObserver(observer)
        isLoading = false
        isUserRefresh = false
        list.endRefreshing()
      }
      do {
        let result = try await fetch(page: 1)
        try validate()
        pageTag = result.pageTag
        items = locallyVisible(result.items, account: account)
        hasMore = result.hasMore
        page = 2
        lastLoadedAt = Date()
        isLoadingMore = false
        // 首屏成功即写 SWR 快照（下次冷启动首帧就有内容，且是新鲜的——旧实现
        // 只读不写，读到的是几个月前的死数据）。
        TiebaFeedAPI.saveSnapshot(result.items, segment: segment.rawValue, accountKey: account)
        publishFresh()
        if items.isEmpty {
          cancelPendingTopAnchorRefresh()
          showState(emptyState, animated: true)
        } else {
          list.footerState = hasMore ? .more : .none
          showList()
        }
        if isUserRefresh { TiebaSceneHaptics.fire("action-success") }
      } catch {
        cancelPendingTopAnchorRefresh()
        guard (try? validate()) != nil else {
          if items.isEmpty { showState(emptyState, animated: false) }
          return
        }
        if items.isEmpty {
          showState(.error(message: error.localizedDescription), animated: true)
        } else {
          pill.showResult(success: false, text: "加载失败")
        }
        if isUserRefresh { TiebaSceneHaptics.fire("action-fail") }
      }
    }
  }

  private func loadMore() {
    guard hasMore, !isLoading, !isLoadingMore, page > 1 else { return }
    let account = TiebaPageCache.currentAccountKey()
    guard itemsAccountKey == account else { return }
    let (observer, validate) = observeActionAccount(account)
    isLoadingMore = true
    list.footerState = .loading
    Task { @MainActor in
      // [用户口径 2026-10-06] 正常态（.more）不显示「加载更多」药丸（触底即自动加载，
      // 见 TiebaKindFooterState）；只有这次翻页失败才留一颗可点的「重试」。
      var didFail = false
      defer {
        NotificationCenter.default.removeObserver(observer)
        isLoadingMore = false
        list.footerState = didFail ? .retry : (hasMore ? .more : .none)
      }
      do {
        let result = try await fetch(page: page)
        try validate()
        page += 1
        // 游标必须跟着翻页走：userLike 是 pageTag 游标分页，fetch 按 page == 1 ? "" : pageTag
        // 组请求体——只回写首屏那一份游标，第 3 页起会永远重发第 2 页的游标（走查 D9-1）。
        // 推荐段不用游标（按 page 翻页），原样赋值无副作用。
        pageTag = result.pageTag
        hasMore = result.hasMore
        items.append(contentsOf: locallyVisible(result.items, account: account))
        publishFresh()
      } catch {
        guard (try? validate()) != nil else { return }
        didFail = true
        pill.showResult(success: false, text: "加载失败")
      }
    }
  }

  private struct FetchResult {
    var items: [[String: Any]] = []
    var hasMore = false
    var pageTag = ""
  }

  private func fetch(page: Int) async throws -> FetchResult {
    let filterAds = TiebaPreferenceSnapshot.bool("filterAdThreads", default: true)
    let loadType = page == 1 ? 1 : 2
    var result = FetchResult()
    switch segment {
    case .personalized:
      let page1 = try await TiebaFeedAPI.personalized(loadType: loadType, page: page)
      result.items = TiebaFeedFilter.visible(page1.items, filterAds: filterAds)
      result.hasMore = page1.hasMore
    case .concern:
      guard isLoggedIn else { return result }
      let page1 = try await TiebaFeedAPI.userLike(
        pageTag: page == 1 ? "" : pageTag,
        loadType: loadType
      )
      result.items = TiebaFeedFilter.visible(page1.items, filterAds: filterAds)
      result.hasMore = page1.hasMore
      result.pageTag = page1.pageTag
    }
    // 行下标必须与 items 一一对应：丢掉没有 threadInfo 的项。
    result.items = result.items.filter { $0["threadInfo"] is [String: Any] }
    return result
  }

  /// 首屏 seed：分段自己的 SWR 快照（推荐/关注各一份、按账号键控；写入侧见
  /// reload 的 page=1 成功分支）。空/过期/解析失败即无 seed。
  private func seedItems() -> [[String: Any]]? {
    let snapshot = TiebaFeedAPI.cachedSnapshot(segment: segment.rawValue)
    guard !snapshot.isEmpty else { return nil }
    let filtered = TiebaFeedFilter.visible(
      snapshot,
      filterAds: TiebaPreferenceSnapshot.bool("filterAdThreads", default: true)
    ).filter { $0["threadInfo"] is [String: Any] }
    return filtered.isEmpty ? nil : filtered
  }

  // MARK: - 发布

  /// 行指纹只含影响测量的偏好（宽度由 driver 自己看守，不再入指纹）。
  private func rowSignature() -> String {
    let options = TiebaFeedRowBuilder.Options.current()
    return "\(options.fontScale)#\(options.hideMedia)#\(options.showIpLocation)"
      + "#\(options.showBothUsername)#\(options.timestampStyle)#\(expandedIds.count)"
  }

  private func republishIfPreferencesChanged() {
    guard !items.isEmpty, rowSignature() != lastRowSignature else { return }
    publishFresh()
  }

  /// 换新页键（数据/展开态变了，整页重测），并记下当时的行指纹。
  /// 系统字形/字号实时改变：重建行模型（含 UIFontMetrics 字号）并重推当前页。
  func contentSizeDidChange() {
    guard isViewLoaded else { return }
    TiebaTypography.invalidateForSystemContentSizeCategoryChange()
    publishFresh()
  }

  private func publishFresh() {
    lastRowSignature = rowSignature()
    driver.publish(fresh: true, makeRows: { [weak self] in self?.makeRows() ?? [] })
  }

  /// 同页原地重测（点赞态/展开长文，不跳滚动位置）。
  /// 同步指纹：展开态也计入 rowSignature，不同步的话「展开→离开再回来」会被误判成偏好变更
  /// 而走 fresh 发布（换页键 → 整页销毁重建，位图与图片全部重贴）。
  /// 放宽为 internal：同模块的 TiebaTopicViewController 复用这一份"原地重推"实现
  ///（话题页与动态页的行模型同构），跨文件调用 private 编不过。
  func publishInPlace() {
    lastRowSignature = rowSignature()
    driver.publish(fresh: false, makeRows: { [weak self] in self?.makeRows() ?? [] })
  }

  private func makeRows() -> [[String: Any]] {
    var options = TiebaFeedRowBuilder.Options.current()
    options.closeMenuOptions = ["dislike", "block", "block-forum", "copy-title"]
    options.imageContextMenu = true
    // 卡片长按菜单（分享帖子/复制帖子内容/不感兴趣/屏蔽作者）：四个动作的接线就在
    // 本页 handleMenuAction —— 行字典开关与页面处理必须同生同灭（见 TiebaFeedRowModel）。
    options.cardContextMenu = true
    return items.map { item in
      guard var thread = item["threadInfo"] as? [String: Any] else { return [:] }
      let id = TiebaSimpleRowParser.string(thread["id"]) ?? ""
      if !likeMirror.isEmpty, itemsAccountKey == TiebaPageCache.currentAccountKey(),
         let target = TiebaThreadCardTarget.agreeTarget(thread, personalized: segment == .personalized),
         let desired = likeMirror.desired(for: target, account: itemsAccountKey) {
        Self.setLike(desired, in: &thread)
      }
      return TiebaFeedRowBuilder.make(
        thread: thread,
        options: options,
        expanded: expandedIds.contains(id)
      )
    }
  }

  // MARK: - 事件

  private func handleEvent(_ event: TiebaKindListEvent) {
    switch event {
    case .rowTap(let index, let region, let actionIndex):
      handleRowTap(index: index, region: region, actionIndex: actionIndex)
    case .menuAction(let index, let action):
      handleMenuAction(index: index, action: action)
    case .mediaAction(let index, _, let action, let url, let originURL):
      handleMediaAction(index: index, action: action, url: url, originURL: originURL)
    case .reachEnd, .footerTap:
      loadMore()
    case .refreshRequested:
      TiebaSceneHaptics.fire("press")
      isUserRefresh = true
      needsTopAnchorAfterRefresh = list.isAtTop
      reload()
    default:
      break
    }
  }

  private func thread(at index: Int) -> [String: Any]? {
    guard items.indices.contains(index) else { return nil }
    return items[index]["threadInfo"] as? [String: Any]
  }

  private func value(_ thread: [String: Any], _ key: String) -> String {
    TiebaSimpleRowParser.string(thread[key]) ?? ""
  }

  private func handleRowTap(index: Int, region: String, actionIndex: Int?) {
    guard let thread = thread(at: index) else { return }
    switch region {
    case "avatar":
      let uid = value(thread, "authorId")
      guard !uid.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(.user(uid: uid))
    case "chip":
      let forum = TiebaViewModelMapper.forumIdentity(thread)
      guard !forum.name.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(.forum(name: forum.name, forumId: forum.id))
    case "showMore":
      let id = value(thread, "id")
      guard !id.isEmpty, expandedIds.insert(id).inserted else { return }
      TiebaSceneHaptics.fire("toggle")
      // 只改了一行的展开态：换页键会让全部行标识失效 → 整页 reload 重建（位图/图片全重贴）。
      // 与话题页的展开和本页点赞一致，走同页键 diff。
      publishInPlace()
    case "action":
      switch actionIndex {
      case 0: openThread(thread)
      case 1: shareThread(thread)
      case 2: toggleLike(thread)
      default: break
      }
    case "media":
      // 真图点击已由原生查看器直开；到这里的只有视频 poster（进帖）。
      guard !hasImageMedia(thread) else { return }
      openThread(thread)
    case "quote":
      openThread(thread, reference: true)
    default:
      openThread(thread)
    }
  }

  private func handleMenuAction(index: Int, action: String) {
    guard let thread = thread(at: index) else { return }
    switch action {
    case "share":
      // 长按卡片菜单的「分享帖子」：与操作栏分享同一份实现（同一入口，不另写一套）。
      shareThread(thread)
    case "copy-content":
      copyPostContent(thread)
    case "dislike":
      presentDislikeSheet(thread)
    case "block":
      blockAuthor(thread)
    case "block-forum":
      blockForum(thread)
    case "copy-title":
      let title = value(thread, "title")
      guard !title.isEmpty else { return }
      TiebaClipboard.setString(title)
    default:
      break
    }
  }

  /// 行内图片长按菜单（保存照片 / 分享照片）：url 优先 originURL（空串按缺省，
  /// 与旧 payload 判读同）。
  private func handleMediaAction(index: Int, action: String, url: String?, originURL: String?) {
    guard let thread = thread(at: index) else { return }
    let source = (originURL.flatMap { $0.isEmpty ? nil : $0 }) ?? url ?? ""
    guard !source.isEmpty else { return }
    let forumName = value(thread, "forumName")
    if action == "save-image" {
      TiebaFeedImageActions.save(url: source, forumName: forumName, presenter: self)
    } else {
      TiebaFeedImageActions.share(
        url: source,
        forumName: forumName,
        presenter: self,
        sourceRect: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1)
      )
    }
  }

  // MARK: - 动作

  private enum CardReadAction {
    case open
    case share(title: String)
  }

  private func openThread(_ thread: [String: Any], reference: Bool = false) {
    resolveThreadAction(thread, reference: reference, action: .open)
  }

  private func resolveThreadAction(_ thread: [String: Any], reference: Bool = false, action: CardReadAction) {
    cancelReplyVerification()
    let opening = TiebaThreadCardTarget.opening(thread, personalized: segment == .personalized, reference: reference)
    #if DEBUG
    let source: TiebaReplyRoutingDiagnostics.Source = segment == .personalized ? .personalized : .concern
    let tap: TiebaReplyRoutingDiagnostics.Tap?
    if case .open = action {
      tap = TiebaReplyRoutingDiagnostics.card(thread, target: opening.target, source: source, rule: opening.rule)
    } else {
      tap = nil
    }
    #endif
    guard let target = opening.target else {
      pill.showResult(success: false, text: opening.rule.unresolvedMessage)
      return
    }
    let complete = { @MainActor [weak self] (verified: Bool) in
      if case .share(let title) = action {
        guard let self, let url = TiebaThreadCardTarget.shareURL(for: target, verifiedReply: verified, opening: opening.rule) else { return }
        TiebaSceneHaptics.fire("press")
        TiebaShareSheet.present(text: title.isEmpty ? url : "\(title)\n\(url)", from: self)
        return
      }
      TiebaSceneHaptics.fire("press")
      #if DEBUG
      TiebaReplyRoutingDiagnostics.$navigationTap.withValue(tap) {
        _ = TiebaNavigator.shared.navigate(target.route())
      }
      #else
      _ = TiebaNavigator.shared.navigate(target.route())
      #endif
    }
    guard opening.rule.requiresExactReply else {
      complete(false)
      return
    }

    let account = TiebaPageCache.currentAccountKey()
    let ticket = replyVerification.begin(accountKey: account)
    pill.show(text: "正在定位回复", progress: nil)
    replyVerificationTask = Task { @MainActor [weak self] in
      // Observe synchronously on the posting thread, including an A → B → A switch.
      let sessionChanged = TiebaMutex(false)
      let observer = NotificationCenter.default.addObserver(
        forName: TiebaSession.didChangeNotification, object: nil, queue: nil
      ) { _ in sessionChanged.withLock { $0 = true } }
      defer { NotificationCenter.default.removeObserver(observer) }
      guard TiebaPageCache.currentAccountKey() == account, !Task.isCancelled else {
        self?.finishReplyVerification(ticket, invalidated: true)
        return
      }

      let sort = TiebaThreadViewController.defaultReplySort
      let verify = { @MainActor in
        try await TiebaThreadAPI.verifyReply(
          threadId: target.threadId, postId: target.postId, forumId: target.forumId, sort: sort, accountKey: account
        )
      }
      #if DEBUG
      let attempt = tap.map(TiebaReplyRoutingDiagnostics.PageAttempt.init)
      #endif
      do {
        #if DEBUG
        let verified = try await TiebaReplyRoutingDiagnostics.$pageAttempt.withValue(attempt) { try await verify() }
        #else
        let verified = try await verify()
        #endif
        guard self?.finishReplyVerification(ticket, invalidated: sessionChanged.withLock { $0 }) == true else { return }
        switch action {
        case .open:
          #if DEBUG
          attempt?.verifiedForNavigation()
          #endif
          TiebaThreadAPI.$openingReplyPage.withValue(verified) { complete(true) }
        case .share:
          complete(true)
        }
      } catch {
        guard let self, self.finishReplyVerification(
          ticket, invalidated: error is CancellationError || sessionChanged.withLock { $0 }
        ) else { return }
        #if DEBUG
        attempt?.saveFailure(verifyingReply: true, error: error)
        #endif
        self.pill.showResult(success: false, text: TiebaThreadCardTarget.unresolvedReplyMessage)
      }
    }
  }

  @discardableResult
  private func finishReplyVerification(_ ticket: TiebaThreadCardTarget.VerificationGate.Ticket, invalidated: Bool) -> Bool {
    guard let allowed = replyVerification.finish(
      ticket, accountKey: TiebaPageCache.currentAccountKey(), invalidated: invalidated || Task.isCancelled,
      isVisible: viewIfLoaded?.window != nil && view.isUserInteractionEnabled
    ) else { return false }
    replyVerificationTask = nil
    pill.hide()
    return allowed
  }

  private func cancelReplyVerification() {
    replyVerification.cancel()
    guard let replyVerificationTask else { return }
    replyVerificationTask.cancel()
    self.replyVerificationTask = nil
    pill.hide()
  }

  private func shareThread(_ thread: [String: Any]) {
    guard itemsAccountKey == TiebaPageCache.currentAccountKey() else { return }
    resolveThreadAction(thread, action: .share(title: value(thread, "title")))
  }

  /// 复制帖子内容（长按卡片菜单）：标题 + 正文纯文本，**不含图片**。
  /// 取段与拼接的唯一定义在 TiebaFeedRowInteraction.postPlainText（吧页共用）。
  private func copyPostContent(_ thread: [String: Any]) {
    let text = TiebaFeedRowInteraction.postPlainText(thread)
    guard !text.isEmpty else { return }
    TiebaClipboard.setString(text)
    TiebaSceneHaptics.fire("action-success")
    pill.showResult(success: true, text: "已复制帖子内容")
  }

  private func toggleLike(_ thread: [String: Any]) {
    guard isLoggedIn else {
      TiebaNavigator.shared.navigate(.login)
      return
    }
    guard let target = TiebaThreadCardTarget.agreeTarget(thread, personalized: segment == .personalized) else {
      pill.showResult(success: false, text: "无法确认点赞对象，请在帖子详情中操作")
      return
    }
    let account = TiebaPageCache.currentAccountKey()
    guard itemsAccountKey == account else { return }
    let next = !Self.likeCount(in: thread).liked
    guard let ticket = likeMirror.begin(target: target, account: account, desired: next) else { return }
    TiebaSceneHaptics.fire("like")
    publishInPlace()
    let (observer, validate) = observeActionAccount(account)
    Task { @MainActor in
      defer {
        NotificationCenter.default.removeObserver(observer)
        if likeMirror.finish(ticket), itemsAccountKey == TiebaPageCache.currentAccountKey() {
          publishInPlace()
        }
      }
      do {
        let likePostId = try await TiebaThreadActionAPI.setFeedAgree(target, agree: next, validateSession: validate)
        try validate()
        if itemsAccountKey == account { commitLike(next, target: target, firstPostId: likePostId) }
        TiebaSceneHaptics.fire("action-success")
        pill.showResult(success: true, text: next ? "点赞成功" : "已取消点赞")
      } catch is CancellationError {
        return
      } catch {
        guard (try? validate()) != nil else { return }
        TiebaSceneHaptics.fire("action-fail")
        pill.showResult(success: false, text: next ? "点赞失败，请稍后重试" : "取消点赞失败，请稍后重试")
      }
    }
  }

  private func commitLike(_ liked: Bool, target: TiebaThreadCardTarget.AgreeTarget, firstPostId: String) {
    for index in items.indices {
      guard var row = items[index]["threadInfo"] as? [String: Any],
            let peer = TiebaThreadCardTarget.agreeTarget(row, personalized: segment == .personalized),
            peer.threadId == target.threadId, peer.replyAnchor == target.replyAnchor,
            peer.firstPostId == nil || peer.firstPostId == firstPostId
      else { continue }
      Self.setLike(liked, in: &row)
      items[index]["threadInfo"] = row
    }
  }

  private static func likeCount(in row: [String: Any]) -> TiebaFeedAgreeState.Count {
    .init(liked: TiebaSimpleRowParser.bool(row["hasAgree"]) ?? false, count: TiebaSimpleRowParser.double(row["zanNum"]) ?? 0)
  }

  private static func setLike(_ liked: Bool, in row: inout [String: Any]) {
    let result = likeCount(in: row).setting(liked)
    row["hasAgree"] = result.liked
    row["zanNum"] = result.count
  }

  private func observeActionAccount(_ account: String) -> (NSObjectProtocol, @Sendable () throws -> Void) {
    let sessionChanged = TiebaMutex(false)
    let observer = NotificationCenter.default.addObserver(
      forName: TiebaSession.didChangeNotification, object: nil, queue: nil
    ) { _ in sessionChanged.withLock { $0 = true } }
    return (observer, {
      try Task.checkCancellation()
      guard TiebaPageCache.currentAccountKey() == account, !sessionChanged.withLock({ $0 }) else { throw CancellationError() }
    })
  }

  private func blockAuthor(_ thread: [String: Any]) {
    let uid = value(thread, "authorId")
    guard !uid.isEmpty else { return }
    let name = value(thread, "authorNameShow").isEmpty
      ? value(thread, "authorName")
      : value(thread, "authorNameShow")
    let user = TiebaBlockedUser(
      id: String(Int(Date().timeIntervalSince1970 * 1000)),
      uid: uid,
      username: name.isEmpty ? nil : name
    )
    do {
      try TiebaBlockStore.add(user: user)
    } catch {
      TiebaSceneHaptics.fire("action-fail")
      return
    }
    TiebaSceneHaptics.fire("action-success")
    items.removeAll { item in
      guard let info = item["threadInfo"] as? [String: Any] else { return false }
      return value(info, "authorId") == uid
    }
    if items.isEmpty {
      showState(emptyState, animated: true)
    } else {
      publishFresh()
    }
  }

  private func hasImageMedia(_ thread: [String: Any]) -> Bool {
    let media = thread["mediaList"] as? [[String: Any]] ?? []
    return media.contains { ($0["type"] as? String ?? "image") == "image" }
  }

  // MARK: - 屏蔽吧

  private func blockForum(_ thread: [String: Any]) {
    let account = TiebaPageCache.currentAccountKey()
    guard itemsAccountKey == account, let forum = TiebaThreadCardTarget.ForumTarget(thread) else {
      pill.showResult(success: false, text: "无法确认要隐藏的贴吧")
      return
    }
    hiddenForums[account, default: []].insert(forum)
    items = locallyVisible(items, account: account)
    updateAfterRemovingRows()
    pill.showResult(success: true, text: "已在本页隐藏这个吧")
    if let target = TiebaThreadCardTarget.forumFeedback(thread, personalized: segment == .personalized) {
      sendFeedback(target, ids: TiebaDislikeSheetViewController.forumReasonId, account: account) { [weak self] sent in
        if sent { self?.pill.showResult(success: true, text: "已隐藏这个吧并提交推荐反馈") }
      }
    }
  }

  private func locallyVisible(_ rows: [[String: Any]], account: String) -> [[String: Any]] {
    guard let hidden = hiddenForums[account], !hidden.isEmpty else { return rows }
    return rows.filter { item in
      guard let row = item["threadInfo"] as? [String: Any],
            let forum = TiebaThreadCardTarget.ForumTarget(row) else { return true }
      return !hidden.contains(where: { $0.matches(forum) })
    }
  }

  private func updateAfterRemovingRows() {
    if items.isEmpty { showState(emptyState, animated: true) }
    publishFresh()
  }

  // MARK: - 不感兴趣

  private func presentDislikeSheet(_ thread: [String: Any]) {
    let account = TiebaPageCache.currentAccountKey()
    guard itemsAccountKey == account,
          let target = TiebaThreadCardTarget.recommendationFeedback(thread, personalized: segment == .personalized)
    else {
      pill.showResult(success: false, text: "这条动态的推荐反馈目标暂无法确认")
      return
    }
    let cardId = value(thread, "id")
    let postId = value(thread, "postId")
    guard !cardId.isEmpty else { return }
    TiebaSceneHaptics.fire("sheet-present")
    let sheet = TiebaDislikeSheetViewController { [weak self] ids in
      guard let self, TiebaPageCache.currentAccountKey() == account else { return }
      self.sendFeedback(target, ids: ids, account: account) { [weak self] sent in
        guard let self else { return }
        guard sent else {
          self.pill.showResult(success: false, text: "提交失败，请稍后重试")
          return
        }
        self.pill.showResult(success: true, text: "已减少此类内容推荐")
        let matches: ([String: Any]) -> Bool = { item in
          guard let row = item["threadInfo"] as? [String: Any] else { return false }
          return self.value(row, "id") == cardId && self.value(row, "postId") == postId
        }
        guard let index = self.items.firstIndex(where: matches) else { return }
        self.list.collapseRowThen(atIndex: index) { [weak self] in
          guard let self, self.itemsAccountKey == account, TiebaPageCache.currentAccountKey() == account else { return }
          self.items.removeAll(where: matches)
          self.updateAfterRemovingRows()
        }
      }
    }
    present(sheet, animated: true)
  }

  private func sendFeedback(
    _ target: TiebaThreadCardTarget.FeedbackTarget, ids: String, account: String,
    completion: @escaping @MainActor (Bool) -> Void
  ) {
    let (observer, validate) = observeActionAccount(account)
    Task { @MainActor in
      defer { NotificationCenter.default.removeObserver(observer) }
      do {
        try await TiebaFeedAPI.submitDislike(
          threadId: target.threadId, dislikeIds: ids, forumId: target.forumId, validateSession: validate
        )
        try validate()
        TiebaSceneHaptics.fire("action-success")
        completion(true)
      } catch {
        guard (try? validate()) != nil else { return }
        TiebaSceneHaptics.fire("action-fail")
        completion(false)
      }
    }
  }
}

// MARK: - 不感兴趣原因面板

/// 多选原因 sheet（原 FeedContent 的 BottomSheet）：系统 insetGrouped 列表 +
/// checkmark 附件 + 提交按钮，detent = medium。
final class TiebaDislikeSheetViewController: UIViewController {
  private struct Reason {
    let id: String
    let title: String
  }

  /// 对齐 Kotlin DislikeReason；接口未透出 dislikeResource 时的兜底列表。
  private static let reasons: [Reason] = [
    Reason(id: "1", title: "内容质量差"),
    Reason(id: "2", title: "标题党"),
    Reason(id: "3", title: "重复推荐"),
    Reason(id: "4", title: "内容不适"),
    Reason(id: "5", title: "广告太多"),
    Reason(id: TiebaDislikeSheetViewController.forumReasonId, title: "不想看这个吧"),
  ]

  /// 「不想看这个吧」的服务端理由 id：卡片菜单的「屏蔽吧」一键提交它
  /// （上面那条文案与这里必须同指一个 id，服务端按它停止推荐这个吧）。
  static let forumReasonId = "7"

  private let onSubmit: (String) -> Void
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let submitButton = UIButton(type: .system)
  private var selected: Set<String> = []

  init(onSubmit: @escaping (String) -> Void) {
    self.onSubmit = onSubmit
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
    if let sheet = sheetPresentationController {
      sheet.detents = [.medium()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TiebaListAppearance.pageBackground
    table.dataSource = self
    table.delegate = self
    table.backgroundColor = .clear
    table.register(UITableViewCell.self, forCellReuseIdentifier: "reason")
    // 降级：.prominentGlass() 是 iOS 26 起；17 退回经典 filled（标题/图标/胶囊逐值不变）。
    var config: UIButton.Configuration =
      if #available(iOS 26.0, *) { .prominentGlass() } else { .filled() }
    config.title = "提交"
    config.image = UIImage(systemName: "hand.thumbsdown.fill")
    config.imagePadding = 8
    config.cornerStyle = .capsule
    config.buttonSize = .large
    submitButton.configuration = config
    submitButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      TiebaSceneHaptics.fire("action-success")
      onSubmit(selected.isEmpty ? "1" : selected.sorted().joined(separator: ","))
      dismiss(animated: true)
    }, for: .touchUpInside)
    let header = UILabel()
    header.text = "我们会减少这类内容的推荐"
    header.font = TiebaSimpleText.uiFont(style: .footnote)
    header.textColor = TiebaExploreSurface.readableSecondary
    header.textAlignment = .center
    header.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
    table.tableHeaderView = header
    for subview in [table, submitButton] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      table.topAnchor.constraint(equalTo: view.topAnchor),
      table.bottomAnchor.constraint(equalTo: submitButton.topAnchor, constant: -8),
      submitButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      submitButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      submitButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])
    title = "不感兴趣"
  }
}

extension TiebaDislikeSheetViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    Self.reasons.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "reason", for: indexPath)
    let reason = Self.reasons[indexPath.row]
    var content = cell.defaultContentConfiguration()
    content.text = reason.title
    cell.contentConfiguration = content
    cell.accessoryType = selected.contains(reason.id) ? .checkmark : .none
    cell.tintColor = TiebaChromeTheme.current.tint
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    let reason = Self.reasons[indexPath.row]
    if !selected.insert(reason.id).inserted { selected.remove(reason.id) }
    TiebaSceneHaptics.fire("toggle")
    tableView.reloadRows(at: [indexPath], with: .none)
  }
}
