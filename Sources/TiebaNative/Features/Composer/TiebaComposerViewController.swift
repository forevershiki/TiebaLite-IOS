import ImageIO
import PhotosUI
import UniformTypeIdentifiers
import UIKit

@MainActor
enum TiebaComposer {
  static let preference = "experimentalComposer"
  static let floorDidReceiveReply = Notification.Name("TiebaComposerFloorDidReceiveReply")
  static var enabled: Bool { TiebaPreferences.bool(preference, default: false) }
  static func identity() -> TiebaComposerIdentity? {
    guard let account = TiebaSession.currentAccount() else { return nil }
    let result = TiebaComposerIdentity(
      uid: account.uid, bduss: account.bduss, stoken: account.sToken, nickname: account.displayName
    )
    return result.isValid ? result : nil
  }

  static let submission = TiebaComposerSubmission(transport: TiebaComposerTransport(
    send: { try await TiebaHttpClient.shared.sendComposerForm(url: $0, headers: $1, body: $2) },
    signLogin: { TiebaSigner.signParams($0) },
    now: { Int64(Date().timeIntervalSince1970 * 1_000) }
  ))

  private static var openDrafts: Set<String> = []

  static func barItem(_ title: String, action: @escaping () -> Void) -> UIBarButtonItem {
    let item = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), style: .plain, target: nil, action: nil)
    item.primaryAction = UIAction { _ in action() }
    item.accessibilityLabel = title
    item.tintColor = TiebaChromeTheme.current.navTint
    return item
  }

  static func present(
    from presenter: UIViewController, target: TiebaComposerTarget,
    onCheck: @escaping () -> Void,
    onSuccess: @escaping (TiebaComposerDestination) -> Void
  ) {
    guard presenter.presentedViewController == nil else { return }
    guard enabled else { inform(.disabled, from: presenter); return }
    guard let identity = identity() else {
      let alert = UIAlertController(title: "请先登录", message: TiebaComposerFailure.login.errorDescription, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "取消", style: .cancel))
      alert.addAction(UIAlertAction(title: "前往登录", style: .default) { _ in TiebaNavigator.shared.navigate(.login) })
      presenter.present(alert, animated: true)
      return
    }
    do {
      let key = try TiebaComposerDraftStore.key(accountID: identity.uid, target: target)
      guard !openDrafts.contains(key) else { inform(.busy, from: presenter); return }
      let state = try TiebaComposerEditorState(store: .live, accountID: identity.uid, target: target)
      let editor = TiebaComposerViewController(
        state: state, onCheck: onCheck, onSuccess: onSuccess,
        onClose: { _ = openDrafts.remove(key) }
      )
      openDrafts.insert(key)
      let navigation = UINavigationController(rootViewController: editor)
      navigation.modalPresentationStyle = .formSheet
      navigation.isModalInPresentation = true
      navigation.overrideUserInterfaceStyle = TiebaChromeTheme.current.dark ? .dark : .light
      presenter.present(navigation, animated: true)
    } catch {
      inform(error as? TiebaComposerFailure ?? .draft, from: presenter)
    }
  }

  private static func inform(_ failure: TiebaComposerFailure, from presenter: UIViewController) {
    let alert = UIAlertController(title: "无法打开发言编辑器", message: failure.errorDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "确定", style: .default))
    presenter.present(alert, animated: true)
  }
}

extension TiebaThreadPost {
  var composerRecipient: TiebaComposerRecipient {
    TiebaComposerRecipient(
      id: authorId, name: displayName, summary: String(plainText.prefix(120))
    )
  }
}

private final class TiebaComposerViewController: UIViewController, UITextViewDelegate, PHPickerViewControllerDelegate {
  private let state: TiebaComposerEditorState
  private let onCheck: () -> Void
  private let onSuccess: (TiebaComposerDestination) -> Void
  private let onClose: () -> Void
  private let textField = UITextField()
  private let textView = UITextView()
  private let scroll = UIScrollView()
  private let message = UILabel()
  private let attachments = UIStackView()
  private let attachmentButton = UIButton(type: .system)
  private let emoticonButton = UIButton(type: .system)
  private let outcomeButton = UIButton(type: .system)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private lazy var sendItem = UIBarButtonItem(title: "发送", style: .done, target: self, action: #selector(send))
  private lazy var closeItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(closePressed))
  private var submitTask: Task<Void, Never>?
  private var pickerTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var isClosing = false
  private var accountInvalidated = false
  private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

  init(
    state: TiebaComposerEditorState, onCheck: @escaping () -> Void,
    onSuccess: @escaping (TiebaComposerDestination) -> Void, onClose: @escaping () -> Void
  ) {
    self.state = state
    self.onCheck = onCheck
    self.onSuccess = onSuccess
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    guard !isClosing, navigationController?.isBeingDismissed == true else { return }
    isClosing = true
    saveTask?.cancel()
    saveDraft()
    submitTask?.cancel()
    pickerTask?.cancel()
    onClose()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    view.tintColor = TiebaChromeTheme.current.navTint
    navigationItem.leftBarButtonItem = closeItem
    navigationItem.rightBarButtonItem = sendItem
    let target = state.target
    let context: String
    switch target {
    case .topic:
      title = "发布主题"
      context = ""
    case .thread(_, _, let title):
      self.title = "回复主题"
      context = title
    case .floor(_, _, _, let floor, let recipient):
      title = "回复第\(floor)楼"
      context = [recipient.name, recipient.summary].filter { !$0.isEmpty }.joined(separator: "\n")
    case .comment(_, _, _, let floor, _, let recipient):
      title = "回复楼中楼"
      let name = recipient.name.isEmpty ? "贴吧用户" : recipient.name
      context = ["第\(floor)楼 · \(name)", recipient.summary].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 12
    stack.addArrangedSubview(label("目标贴吧 · \(TiebaForumFormat.displayName(target.forum.name))", style: .headline))
    if !context.isEmpty { stack.addArrangedSubview(label(context, style: .subheadline)) }
    if target.showsTitle {
      textField.borderStyle = .roundedRect
      textField.placeholder = "标题"
      textField.accessibilityLabel = "标题"
      textField.font = .preferredFont(forTextStyle: .body)
      textField.adjustsFontForContentSizeCategory = true
      textField.returnKeyType = .next
      textField.addTarget(self, action: #selector(editChanged), for: .editingChanged)
      textField.addAction(UIAction { [weak self] _ in self?.textView.becomeFirstResponder() }, for: .editingDidEndOnExit)
      textField.text = state.draft.title
      textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      stack.addArrangedSubview(textField)
    }
    stack.addArrangedSubview(label("正文", style: .headline))
    textView.text = state.draft.body
    textView.font = .preferredFont(forTextStyle: .body)
    textView.textColor = .label
    textView.adjustsFontForContentSizeCategory = true
    textView.backgroundColor = .secondarySystemGroupedBackground
    textView.layer.cornerRadius = 12
    textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
    textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    textView.accessibilityLabel = "正文"
    textView.delegate = self
    stack.addArrangedSubview(textView)

    if !target.showsTitle {
      attachments.axis = .vertical
      attachments.spacing = 8
      stack.addArrangedSubview(attachments)
      configure(attachmentButton, title: "添加图片", image: "photo.on.rectangle")
      attachmentButton.addAction(UIAction { [weak self] _ in self?.pickPhotos() }, for: .touchUpInside)
      stack.addArrangedSubview(attachmentButton)
    }
    configure(emoticonButton, title: "贴吧表情", image: "face.smiling")
    configureEmoticons()
    emoticonButton.showsMenuAsPrimaryAction = true
    stack.addArrangedSubview(emoticonButton)

    message.font = .preferredFont(forTextStyle: .footnote)
    message.adjustsFontForContentSizeCategory = true
    message.numberOfLines = 0
    stack.addArrangedSubview(message)
    spinner.hidesWhenStopped = true
    stack.addArrangedSubview(spinner)
    configure(outcomeButton, title: "核对发送结果", image: "arrow.clockwise")
    outcomeButton.addAction(UIAction { [weak self] _ in self?.reviewOutcome() }, for: .touchUpInside)
    stack.addArrangedSubview(outcomeButton)

    scroll.keyboardDismissMode = .interactive
    scroll.translatesAutoresizingMaskIntoConstraints = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
    ])
    rebuildAttachments()
    updateControls()
    if state.draft.outcomeUnknown { show(TiebaComposerFailure.unknown.errorDescription, error: true) }

    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: TiebaSession.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.checkAccount() }
      },
      center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.saveDraft() }
      },
    ]
    checkAccount()
  }

  private func configure(_ button: UIButton, title: String, image: String) {
    var config: UIButton.Configuration
    if #available(iOS 26.0, *) { config = .glass() } else { config = .tinted() }
    config.title = title
    config.image = UIImage(systemName: image)
    config.imagePadding = 8
    button.configuration = config
    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
  }

  private func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
    let result = UILabel()
    result.text = text
    result.font = .preferredFont(forTextStyle: style)
    result.adjustsFontForContentSizeCategory = true
    result.numberOfLines = 0
    return result
  }

  private func show(_ text: String?, error: Bool = false) {
    message.text = text
    message.textColor = error ? .systemRed : .secondaryLabel
    message.isHidden = text == nil
    if let text, error { UIAccessibility.post(notification: .announcement, argument: text) }
  }

  private func updateControls() {
    let busy = submitTask != nil || pickerTask != nil
    sendItem.isEnabled = !busy && !state.draft.outcomeUnknown && !accountInvalidated
    textField.isEnabled = !busy
    textView.isEditable = !busy
    attachmentButton.isEnabled = !busy && state.draft.images.count < TiebaComposerDraft.maximumImages
    emoticonButton.isEnabled = !busy
    attachments.isUserInteractionEnabled = !busy
    outcomeButton.isHidden = busy || !state.draft.outcomeUnknown
    closeItem.title = busy ? "取消操作" : "关闭"
    if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
  }

  func textViewDidChange(_ textView: UITextView) { editChanged() }

  @objc private func editChanged() {
    guard !accountInvalidated, !isClosing else { return }
    state.edit(title: textField.text ?? "", body: textView.text ?? "")
    saveTask?.cancel()
    saveTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
      self?.saveDraft()
    }
  }

  private func saveDraft() {
    do { try state.save() }
    catch { show(TiebaComposerFailure.draft.errorDescription, error: true) }
  }

  private func insertEmoticon(_ label: String) {
    textView.becomeFirstResponder()
    textView.insertText("#(\(label))")
    editChanged()
  }

  private func configureEmoticons() {
    let icons = ["呵呵", "哈哈", "滑稽", "笑眼", "太开心", "玫瑰"].compactMap { name in
      TiebaViewModelMapper.emoticonNumber(named: name).map {
        (name, TiebaViewModelMapper.buildEmoticonSrc($0))
      }
    }
    emoticonButton.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in
        let cache = TiebaEmoticonCache.shared
        completion(icons.map { name, src in
          UIAction(title: name, image: cache.image(src: src)?.withRenderingMode(.alwaysOriginal)) { [weak self] _ in
            self?.insertEmoticon(name)
          }
        })
      }
    ])
    TiebaEmoticonCache.shared.load(icons.map { $0.1 }) {}
  }

  private func pickPhotos() {
    let remaining = TiebaComposerDraft.maximumImages - state.draft.images.count
    guard remaining > 0, !accountInvalidated else { return }
    view.endEditing(true)
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = remaining
    configuration.selection = .ordered
    configuration.preferredAssetRepresentationMode = .compatible
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard !results.isEmpty, !accountInvalidated, !isClosing else { return }
    let providers = results.map(\.itemProvider)
    pickerTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.pickerTask = nil
        self.updateControls()
      }
      var images = self.state.draft.images
      var failed = false
      for provider in providers {
        guard !Task.isCancelled, !self.accountInvalidated else { return }
        self.show("正在读取图片")
        do { images.append(try await self.loadImage(provider)) }
        catch { failed = true }
        guard !Task.isCancelled, !self.accountInvalidated else { return }
      }
      self.state.setImages(images)
      self.rebuildAttachments()
      self.show(failed ? "部分图片无法读取，或超过 10 MiB / 尺寸限制。" : nil, error: failed)
      self.saveDraft()
    }
    updateControls()
  }

  private func loadImage(_ provider: NSItemProvider) async throws -> Data {
    let supported = [UTType.jpeg, .png, .gif].map(\.identifier)
    guard let type = supported.first(where: { provider.hasItemConformingToTypeIdentifier($0) })
    else { throw TiebaComposerFailure.upload }
    return try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
        do {
          guard let url,
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= TiebaComposerDraft.maximumImageBytes
          else { throw TiebaComposerFailure.upload }
          let data = try Data(contentsOf: url)
          guard Self.thumbnail(for: data) != nil else { throw TiebaComposerFailure.upload }
          continuation.resume(returning: data)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  private nonisolated static func thumbnail(for data: Data) -> CGImage? {
    guard !data.isEmpty, data.count <= TiebaComposerDraft.maximumImageBytes,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let sourceType = CGImageSourceGetType(source),
      [UTType.jpeg.identifier, UTType.png.identifier, UTType.gif.identifier].contains(sourceType as String),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      (1...20_000).contains(width), (1...20_000).contains(height), width * height <= 80_000_000
    else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 160,
    ] as CFDictionary)
  }

  private func rebuildAttachments() {
    for row in attachments.arrangedSubviews { row.removeFromSuperview() }
    for (index, data) in state.draft.images.enumerated() {
      let preview = UIImageView()
      preview.image = Self.thumbnail(for: data).map { UIImage(cgImage: $0) }
      preview.contentMode = .scaleAspectFill
      preview.clipsToBounds = true
      preview.layer.cornerRadius = 8
      preview.widthAnchor.constraint(equalToConstant: 56).isActive = true
      preview.heightAnchor.constraint(equalToConstant: 56).isActive = true
      let caption = label("图片 \(index + 1)", style: .subheadline)
      let remove = UIButton(type: .system)
      configure(remove, title: "移除", image: "xmark")
      remove.accessibilityLabel = "移除图片 \(index + 1)"
      remove.setContentHuggingPriority(.required, for: .horizontal)
      remove.addAction(UIAction { [weak self] _ in
        guard let self, self.state.draft.images.indices.contains(index) else { return }
        var images = self.state.draft.images
        images.remove(at: index)
        self.state.setImages(images)
        self.rebuildAttachments()
        self.updateControls()
        self.saveDraft()
      }, for: .touchUpInside)
      let row = UIStackView(arrangedSubviews: [preview, caption, remove])
      row.alignment = .center
      row.spacing = 12
      attachments.addArrangedSubview(row)
    }
  }

  @objc private func send() {
    guard submitTask == nil, pickerTask == nil, !accountInvalidated, !isClosing else { return }
    view.endEditing(true)
    saveTask?.cancel()
    let identity = TiebaComposer.identity()
    submitTask = Task { @MainActor in
      defer {
        submitTask = nil
        updateControls()
        if accountInvalidated { finish() }
      }
      do {
        let result = try await state.submit(
          through: TiebaComposer.submission, identity: identity,
          validateSession: { try self.validateSession(identity) },
          progress: { self.showProgress($0) }
        )
        guard !accountInvalidated, TiebaSession.activeUid == state.accountID, !isClosing else { return }
        if !result.draftCleared {
          let alert = UIAlertController(
            title: "发送成功", message: "本地草稿无法清理，请稍后核对并删除草稿。", preferredStyle: .alert
          )
          alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            guard let self else { return }
            self.finish { self.onSuccess(result.destination) }
          })
          present(alert, animated: true)
          return
        }
        finish { self.onSuccess(result.destination) }
      } catch {
        let failure = error as? TiebaComposerFailure ?? .preparation
        show(failure.errorDescription, error: true)
      }
    }
    updateControls()
  }

  private func validateSession(_ original: TiebaComposerIdentity?) throws {
    guard !accountInvalidated, TiebaSession.activeUid == state.accountID,
      let original, let current = TiebaComposer.identity(),
      original.uid == current.uid, original.bduss == current.bduss, original.stoken == current.stoken else {
      throw TiebaComposerFailure.accountChanged
    }
    guard TiebaComposer.enabled else { throw TiebaComposerFailure.disabled }
  }

  private func showProgress(_ progress: TiebaComposerProgress) {
    switch progress {
    case .uploading(let current, let total): show("正在上传第 \(current) / \(total) 张图片")
    case .preparing: show("正在验证登录状态")
    case .sending: show("正在发送")
    }
  }

  private func checkAccount() {
    guard TiebaSession.activeUid != state.accountID || TiebaComposer.identity() == nil else { return }
    guard !accountInvalidated else { return }
    accountInvalidated = true
    scroll.isHidden = true
    saveTask?.cancel()
    saveDraft()
    submitTask?.cancel()
    pickerTask?.cancel()
    updateControls()
    if submitTask == nil { finish() }
  }

  @objc private func closePressed() {
    if let submitTask { submitTask.cancel(); return }
    if let pickerTask { pickerTask.cancel(); return }
    if state.draft.isEmpty { finish(); return }
    let alert = UIAlertController(title: "关闭编辑器", message: nil, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "继续编辑", style: .cancel))
    alert.addAction(UIAlertAction(title: "保留草稿", style: .default) { [weak self] _ in
      guard let self else { return }
      do { try self.state.save(); self.finish() }
      catch { self.show(TiebaComposerFailure.draft.errorDescription, error: true) }
    })
    if !state.draft.outcomeUnknown {
      alert.addAction(UIAlertAction(title: "删除草稿", style: .destructive) { [weak self] _ in
        guard let self else { return }
        do { try self.state.clear(); self.finish() }
        catch { self.show(TiebaComposerFailure.draft.errorDescription, error: true) }
      })
    }
    present(alert, animated: true)
  }

  private func reviewOutcome() {
    let alert = UIAlertController(title: "核对发送结果", message: TiebaComposerFailure.unknown.errorDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "关闭并刷新原页面", style: .default) { [weak self] _ in
      guard let self else { return }
      do { try self.state.save(); self.finish { self.onCheck() } }
      catch { self.show(TiebaComposerFailure.draft.errorDescription, error: true) }
    })
    alert.addAction(UIAlertAction(title: "已发布，清理草稿", style: .destructive) { [weak self] _ in
      guard let self else { return }
      do { try self.state.clear(); self.finish { self.onCheck() } }
      catch { self.show(TiebaComposerFailure.draft.errorDescription, error: true) }
    })
    alert.addAction(UIAlertAction(title: "已核对，允许再次发送", style: .default) { [weak self] _ in
      guard let self else { return }
      do {
        try self.state.setOutcomeUnknown(false)
        self.show(nil)
        self.updateControls()
      } catch { self.show(TiebaComposerFailure.draft.errorDescription, error: true) }
    })
    present(alert, animated: true)
  }

  private func finish(then completion: (() -> Void)? = nil) {
    guard !isClosing else { return }
    isClosing = true
    saveTask?.cancel()
    let release = onClose
    let closingAccount = state.accountID
    let modal = navigationController ?? self
    let presenter = modal.presentingViewController ?? modal
    presenter.dismiss(animated: true) {
      release()
      if TiebaSession.activeUid == closingAccount { completion?() }
    }
  }
}
