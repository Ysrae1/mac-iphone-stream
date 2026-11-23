import UIKit
import AVFoundation

private final class FloatingMenuControlView: UIView {
    let contentView = UIView()
    private let material: UIVisualEffectView
    var transitionSourceView: UIView { material }
    private var expanded = false
    private var hostedContent: UIView?
    private var hostedSize = CGSize.zero
    private var animator: UIViewPropertyAnimator?
    var isTransitioning: Bool { animator != nil }

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            material = UIVisualEffectView(effect: glass)
        } else {
            material = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        }
        super.init(frame: frame)
        material.isUserInteractionEnabled = false
        material.clipsToBounds = true; material.layer.cornerCurve = .continuous
        material.contentView.clipsToBounds = true
        if #available(iOS 26.0, *) { material.cornerConfiguration = .capsule(maximumRadius: 26) }
        addSubview(material); addSubview(contentView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        material.frame = expanded ? bounds : VideoGeometry.floatingMenuVisualFrame(in: bounds)
        if #unavailable(iOS 26.0) { material.layer.cornerRadius = min(26, material.bounds.width / 2) }
        material.contentView.layer.cornerRadius = min(26, min(material.bounds.width, material.bounds.height) / 2)
        material.contentView.layer.cornerCurve = .continuous
        contentView.frame = bounds
        if let hostedContent {
            hostedContent.bounds = CGRect(origin: .zero, size: hostedSize)
            hostedContent.center = CGPoint(x: material.bounds.midX, y: material.bounds.midY)
        }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        expanded ? UIBezierPath(roundedRect: bounds, cornerRadius: 26).contains(point) : VideoGeometry.floatingMenuContains(point, in: bounds)
    }
    func attachSettings(_ view: UIView, size: CGSize) {
        hostedContent = view; hostedSize = size
        view.bounds = CGRect(origin: .zero, size: size)
        view.alpha = 0; view.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
        material.contentView.addSubview(view)
        view.layoutIfNeeded(); layoutIfNeeded()
    }
    func morph(expanded target: Bool, to targetFrame: CGRect, animated: Bool, completion: @escaping () -> Void = {}) {
        // The same native effect view survives both directions, as in Tendies Studio.
        if let active = animator {
            active.stopAnimation(false); active.finishAnimation(at: .current); animator = nil
        }
        contentView.isUserInteractionEnabled = !target
        contentView.accessibilityElementsHidden = target
        material.isUserInteractionEnabled = target
        let changes = {
            self.expanded = target
            self.frame = targetFrame; self.setNeedsLayout(); self.layoutIfNeeded()
            self.contentView.alpha = target ? 0 : 1
            self.hostedContent?.alpha = target ? 1 : 0
            self.hostedContent?.transform = target ? .identity : CGAffineTransform(scaleX: 1.08, y: 1.08)
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else { changes(); completion(); return }
        let animation = UIViewPropertyAnimator(duration: 0.28, dampingRatio: target ? 0.86 : 1, animations: changes)
        animator = animation
        animation.addCompletion { [weak self, weak animation] position in
            guard let self, self.animator === animation else { return }
            self.animator = nil
            if position == .end { completion() }
        }
        animation.startAnimation()
    }
    func removeSettings() { hostedContent?.removeFromSuperview(); hostedContent = nil }
}

final class StreamViewController: UIViewController, UITextFieldDelegate, UIPopoverPresentationControllerDelegate, UIGestureRecognizerDelegate {
    private let videoLayer = AVSampleBufferDisplayLayer()
    private let videoContainer = UIView()
    private let touchSurface = TouchSurfaceView()
    private let session = SessionController()
    private let transport = TransportCoordinator()
    private enum EntryMode: Int { case certificate, qr, address }
    private let entryControl = UISegmentedControl(items: ["证书连接", "扫码连接", "地址连接"])
    private let entryHint = UILabel()
    private var entryMode = EntryMode.certificate
    private var scannedLink: String?
    private var qrPairedHost: TrustedMac?
    private var addressPairedHost: TrustedMac?
    private let scanButton = UIButton(type: .system)
    private let addressRow = UIStackView()
    private let pairAddressButton = UIButton(type: .system)
    private let connectionVisual = UIView()
    private let connectionLogo = UIImageView()
    private var embeddedScanner: QRCodeScannerViewController?
    // The isolated layout harness can render the scanner without requesting a camera.
    var enablesCameraCapture = true
    var previewTrustedMacs: [TrustedMac]?
    private let routes = TransportCoordinator.Route.allCases
    private let routeControl = UISegmentedControl(items: TransportCoordinator.Route.allCases.map(\.title))
    private var preparingTransport = false
    private var activeRoute = TransportCoordinator.Route.lan
    private let connectPanel = UIView()
    private let connectionContent = UIView()
    private let connectionColumns = UIView()
    private let connectionBrand = UIStackView()
    private let connectionForm = UIStackView()
    private var connectionBrandDetails: [UIView] = []
    private let trustedMacSelection = TrustedMacSelectionView()
    private var connectionLayoutWidth: NSLayoutConstraint?
    private var connectionBrandWidth: NSLayoutConstraint?
    private var connectionFormWidth: NSLayoutConstraint?
    private var connectionBrandX: NSLayoutConstraint?
    private var connectionFormX: NSLayoutConstraint?
    private var connectionBrandY: NSLayoutConstraint?
    private var connectionFormY: NSLayoutConstraint?
    private var connectionLogoWidth: NSLayoutConstraint?
    private var connectionLogoHeight: NSLayoutConstraint?
    private let linkField = ConnectionLinkTextField()
    private let messageLabel = UILabel()
    private let connectButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private var profileText = ""
    private let controls = FloatingMenuControlView(frame: .zero)
    private var menuPosition = FloatingMenuPosition()
    private var menuDragStart = CGPoint.zero
    private var menuIsDragging = false
    private var settingsController: StreamSettingsViewController?
    private var settingsDismissControl: UIControl?
    private var settingsClosing = false
    private lazy var menuPan = UIPanGestureRecognizer(target: self, action: #selector(dragMenu(_:)))
    private var connecting = false
    private var fullBleed = true
    private var geometryRequestCount = 0
    private var geometryRequestError: [String: Any]?
    private var lastOrientationSnapshot: Data?
    private var canFillScreen: Bool {
        let rect = touchSurface.clientRect, video = touchSurface.videoSize
        return VideoGeometry.aspectMatches(client: CGSize(width: video.width * rect.width, height: video.height * rect.height), screen: view.bounds.size)
    }

    override var prefersStatusBarHidden: Bool { connecting }
    override var prefersHomeIndicatorAutoHidden: Bool { connecting }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { connecting ? .all : [] }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { connecting ? .landscape : .allButUpsideDown }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        view.tintColor = StreamTheme.accent
        videoLayer.videoGravity = .resizeAspect
        videoContainer.clipsToBounds = true
        view.addSubview(videoContainer)
        videoContainer.layer.addSublayer(videoLayer)
        touchSurface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(touchSurface)
        NSLayoutConstraint.activate([
            touchSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            touchSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            touchSurface.topAnchor.constraint(equalTo: view.topAnchor),
            touchSurface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        buildConnectionPanel()
        buildControls()
        touchSurface.onFrame = { [weak self] in self?.session.submit($0) }
        session.onState = { [weak self] in self?.statusLabel.text = $0 }
        session.onReady = { [weak self] ready in
            self?.touchSurface.acceptsTouches = ready && UIApplication.shared.applicationState == .active
        }
        session.onVideoSize = { [weak self] size in
            guard let self else { return }
            if self.touchSurface.videoSize != size { self.touchSurface.videoSize = size; self.view.setNeedsLayout() }
        }
        session.onClientRect = { [weak self] rect in
            guard let self else { return }
            if self.touchSurface.clientRect != rect { self.touchSurface.clientRect = rect; self.view.setNeedsLayout() }
        }
        session.onDisconnected = { [weak self] message in self?.showConnection(message: message) }
        transport.onState = { [weak self] message in
            guard let self, self.preparingTransport else { return }
            self.showConnectionMessage(message)
        }
        transport.onReady = { [weak self] connection in
            guard let self, self.preparingTransport else { return }
            self.setPreparingTransport(false)
            self.beginSession(connection)
        }
        transport.onFailure = { [weak self] message in
            guard let self else { return }
            if self.connecting { self.session.disconnect(reason: .transportFailure, message: message) }
            else { self.showConnection(message: message) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(resignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted), name: AVAudioSession.interruptionNotification, object: nil)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateConnectionPanelLayout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let safe = VideoGeometry.symmetricSafeBounds(bounds: view.bounds, systemSafeArea: view.safeAreaLayoutGuide.layoutFrame)
        let canvasBounds = fullBleed && canFillScreen ? view.bounds : safe
        // TouchSurface spans the whole view: preserve this offset, never assume origin (0,0).
        touchSurface.safeBounds = view.convert(canvasBounds, to: touchSurface)
        let presentation = VideoGeometry.croppedPresentation(video: touchSurface.videoSize, bounds: canvasBounds, clientRect: touchSurface.clientRect)
        videoContainer.frame = presentation.viewport
        videoLayer.frame = presentation.layer
        if settingsController != nil {
            if !controls.isTransitioning && !settingsClosing {
                let source = VideoGeometry.floatingMenuFrame(bounds: view.bounds, safeArea: view.safeAreaLayoutGuide.layoutFrame, position: menuPosition)
                controls.frame = VideoGeometry.floatingSettingsFrame(bounds: view.bounds, safeArea: view.safeAreaLayoutGuide.layoutFrame, source: source)
            }
        } else if !menuIsDragging {
            controls.frame = VideoGeometry.floatingMenuFrame(bounds: view.bounds, safeArea: view.safeAreaLayoutGuide.layoutFrame,
                                                            position: menuPosition)
        }
        CATransaction.commit()
        updateViewportProfile(canvasBounds: canvasBounds)
        recordOrientationSnapshot(event: "layout")
    }
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        touchSurface.releaseAll()
        session.releaseTouches()
        view.setNeedsLayout()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        // Finish an in-flight drag in the old coordinate space before applying the new safe area.
        menuPan.isEnabled = false; menuPan.isEnabled = true
        touchSurface.releaseAll()
        session.releaseTouches()
        closeStreamSettings(animated: false)
        super.viewWillTransition(to: size, with: coordinator)
    }
    private func buildConnectionPanel() {
        connectPanel.translatesAutoresizingMaskIntoConstraints = false
        connectPanel.backgroundColor = StreamTheme.background
        view.addSubview(connectPanel)
        NSLayoutConstraint.activate([
            connectPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor), connectPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            connectPanel.topAnchor.constraint(equalTo: view.topAnchor), connectPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let mark = connectionVisual
        connectionLogo.image = UIImage(named: "ConnectionLogo")
        connectionLogo.tintColor = StreamTheme.accent; connectionLogo.contentMode = .scaleAspectFill
        connectionLogo.translatesAutoresizingMaskIntoConstraints = false
        mark.addSubview(connectionLogo)
        NSLayoutConstraint.activate([
            connectionLogo.leadingAnchor.constraint(equalTo: mark.leadingAnchor),
            connectionLogo.trailingAnchor.constraint(equalTo: mark.trailingAnchor),
            connectionLogo.topAnchor.constraint(equalTo: mark.topAnchor),
            connectionLogo.bottomAnchor.constraint(equalTo: mark.bottomAnchor)
        ])
        mark.clipsToBounds = true; mark.layer.cornerCurve = .continuous
        connectionLogoWidth = mark.widthAnchor.constraint(equalToConstant: 240)
        connectionLogoHeight = mark.heightAnchor.constraint(equalToConstant: 240)
        connectionLogoWidth?.priority = UILayoutPriority(999)
        connectionLogoHeight?.priority = UILayoutPriority(999)
        connectionLogoWidth?.isActive = true; connectionLogoHeight?.isActive = true
        let title = UILabel()
        title.text = "Mac iPhone Stream"; title.font = .systemFont(ofSize: 30, weight: .bold); title.textAlignment = .center
        let subtitle = UILabel()
        subtitle.text = "串流 Mac 窗口与声音"
        subtitle.textColor = .secondaryLabel; subtitle.font = .systemFont(ofSize: 16); subtitle.textAlignment = .center
        subtitle.numberOfLines = 2
        linkField.placeholder = "粘贴 Mac 配对地址"
        linkField.borderStyle = .none
        linkField.backgroundColor = StreamTheme.surface
        linkField.layer.cornerRadius = 14; linkField.layer.cornerCurve = .continuous
        linkField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        linkField.keyboardType = .URL; linkField.autocapitalizationType = .none
        linkField.autocorrectionType = .no; linkField.spellCheckingType = .no
        linkField.textContentType = .URL
        linkField.clearButtonMode = .whileEditing; linkField.returnKeyType = .done; linkField.delegate = self
        linkField.addTarget(self, action: #selector(addressEdited), for: .editingChanged)
        let left = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        linkField.leftView = left; linkField.leftViewMode = .always
        let linkHeight = linkField.heightAnchor.constraint(equalToConstant: 48)
        linkHeight.priority = UILayoutPriority(999); linkHeight.isActive = true
        linkField.accessibilityLabel = "Mac 配对地址"
        entryControl.selectedSegmentIndex = EntryMode.certificate.rawValue
        entryControl.selectedSegmentTintColor = StreamTheme.accent
        entryControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        entryControl.addTarget(self, action: #selector(entryChanged), for: .valueChanged)
        entryControl.accessibilityLabel = "连接信息来源"
        entryHint.font = .systemFont(ofSize: 12)
        entryHint.textColor = .secondaryLabel; entryHint.numberOfLines = 2
        entryHint.textAlignment = .center
        let hintHeight = entryHint.heightAnchor.constraint(equalToConstant: 32)
        hintHeight.priority = UILayoutPriority(999); hintHeight.isActive = true
        routeControl.selectedSegmentIndex = 0
        routeControl.selectedSegmentTintColor = StreamTheme.accent
        routeControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        routeControl.addTarget(self, action: #selector(routeChanged), for: .valueChanged)
        routeControl.accessibilityLabel = "串流通道"
        routeControl.accessibilityHint = routeBenefit
        var config = UIButton.Configuration.filled()
        config.title = "连接串流"; config.baseBackgroundColor = StreamTheme.accent; config.baseForegroundColor = .black
        config.cornerStyle = .large; config.buttonSize = .large
        connectButton.configuration = config
        connectButton.addTarget(self, action: #selector(connectPressed), for: .touchUpInside)
        var scanConfig = UIButton.Configuration.tinted()
        scanConfig.title = "重新扫描"; scanConfig.image = UIImage(systemName: "qrcode.viewfinder")
        scanConfig.imagePadding = 6; scanConfig.baseForegroundColor = StreamTheme.accent
        scanConfig.baseBackgroundColor = StreamTheme.accent
        scanConfig.cornerStyle = .large; scanConfig.buttonSize = .large
        scanButton.configuration = scanConfig
        scanButton.addTarget(self, action: #selector(scanPressed), for: .touchUpInside)
        var pairConfig = UIButton.Configuration.tinted()
        pairConfig.title = "配对 Mac"; pairConfig.baseForegroundColor = StreamTheme.accent
        pairConfig.baseBackgroundColor = StreamTheme.accent; pairConfig.cornerStyle = .large
        pairAddressButton.configuration = pairConfig
        pairAddressButton.addTarget(self, action: #selector(pairAddressPressed), for: .touchUpInside)
        pairAddressButton.widthAnchor.constraint(equalToConstant: 100).isActive = true
        addressRow.axis = .horizontal; addressRow.spacing = 10
        addressRow.addArrangedSubview(linkField); addressRow.addArrangedSubview(pairAddressButton)
        [scanButton, pairAddressButton, connectButton].forEach { button in
            let height = button.heightAnchor.constraint(equalToConstant: 48)
            height.priority = UILayoutPriority(999); height.isActive = true
        }
        trustedMacSelection.previewHosts = previewTrustedMacs
        trustedMacSelection.onManage = { [weak self] in self?.manageTrustedMacs() }
        trustedMacSelection.reloadHosts()
        let hostsHeight = trustedMacSelection.heightAnchor.constraint(equalToConstant: 90)
        hostsHeight.priority = UILayoutPriority(999); hostsHeight.isActive = true
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabel; messageLabel.textAlignment = .center; messageLabel.numberOfLines = 3
        messageLabel.isHidden = true
        [mark, title, subtitle].forEach { connectionBrand.addArrangedSubview($0) }
        connectionBrand.axis = .vertical; connectionBrand.alignment = .center; connectionBrand.spacing = 12
        connectionBrand.setCustomSpacing(6, after: title)
        connectionBrandDetails = [mark, subtitle]
        [entryControl, entryHint, trustedMacSelection, scanButton, addressRow, routeControl, messageLabel, connectButton].forEach { connectionForm.addArrangedSubview($0) }
        connectionForm.axis = .vertical; connectionForm.spacing = 10
        let routeGap: CGFloat = 16
        [scanButton, addressRow, routeControl].forEach {
            connectionForm.setCustomSpacing(routeGap, after: $0)
        }
        [title, subtitle, messageLabel].forEach { $0.setContentHuggingPriority(.required, for: .vertical) }
        connectionBrand.translatesAutoresizingMaskIntoConstraints = false
        connectionForm.translatesAutoresizingMaskIntoConstraints = false
        connectionColumns.addSubview(connectionBrand)
        connectionColumns.addSubview(connectionForm)
        connectionColumns.translatesAutoresizingMaskIntoConstraints = false
        connectionContent.translatesAutoresizingMaskIntoConstraints = false
        connectPanel.addSubview(connectionContent)
        connectionContent.addSubview(connectionColumns)
        connectionLayoutWidth = connectionColumns.widthAnchor.constraint(equalToConstant: 740)
        connectionBrandWidth = connectionBrand.widthAnchor.constraint(equalToConstant: 290)
        connectionFormWidth = connectionForm.widthAnchor.constraint(equalToConstant: 414)
        connectionBrandX = connectionBrand.centerXAnchor.constraint(equalTo: connectionColumns.centerXAnchor, constant: -225)
        connectionFormX = connectionForm.centerXAnchor.constraint(equalTo: connectionColumns.centerXAnchor, constant: 163)
        connectionBrandY = connectionBrand.centerYAnchor.constraint(equalTo: connectionColumns.centerYAnchor)
        connectionFormY = connectionForm.centerYAnchor.constraint(equalTo: connectionColumns.centerYAnchor)
        [connectionLayoutWidth, connectionBrandWidth, connectionFormWidth, connectionBrandX, connectionFormX, connectionBrandY, connectionFormY].forEach { $0?.isActive = true }
        NSLayoutConstraint.activate([
            connectionContent.leadingAnchor.constraint(equalTo: connectPanel.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            connectionContent.trailingAnchor.constraint(equalTo: connectPanel.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            connectionContent.topAnchor.constraint(equalTo: connectPanel.safeAreaLayoutGuide.topAnchor, constant: 16),
            connectionContent.bottomAnchor.constraint(equalTo: connectPanel.keyboardLayoutGuide.topAnchor, constant: -16),
            connectionColumns.centerXAnchor.constraint(equalTo: connectionContent.centerXAnchor),
            connectionColumns.topAnchor.constraint(equalTo: connectionContent.topAnchor),
            connectionColumns.bottomAnchor.constraint(equalTo: connectionContent.bottomAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: connectionBrand.widthAnchor),
            subtitle.widthAnchor.constraint(lessThanOrEqualTo: connectionBrand.widthAnchor)
        ])
        let dismissKeyboard = UITapGestureRecognizer(target: self, action: #selector(dismissConnectionKeyboard))
        dismissKeyboard.cancelsTouchesInView = false
        dismissKeyboard.delegate = self
        connectPanel.addGestureRecognizer(dismissKeyboard)
        updateEntryHint()
        updateEntryVisibility(compact: false)
    }
    private func updateConnectionPanelLayout() {
        guard connectionContent.bounds.width > 0 else { return }
        let available = connectionContent.bounds.size
        let sideBySide = available.width >= 500
        let totalWidth = min(available.width, sideBySide ? 800 : 460)
        let gap: CGFloat = sideBySide ? 36 : 20
        let formWidth = sideBySide ? min(460, (totalWidth - gap) * 0.58) : totalWidth
        let brandWidth = sideBySide ? totalWidth - gap - formWidth : totalWidth
        connectionLayoutWidth?.constant = totalWidth
        connectionBrandWidth?.constant = brandWidth
        connectionFormWidth?.constant = formWidth
        connectionBrandX?.constant = sideBySide ? -(formWidth + gap) / 2 : 0
        connectionFormX?.constant = sideBySide ? (brandWidth + gap) / 2 : 0
        let compact = available.height < (sideBySide ? 220 : 500)
        // Keep the link and its actions above a landscape keyboard. The selected
        // route is retained and returns with the explanatory text after editing.
        let keyboardVisible = connectPanel.keyboardLayoutGuide.layoutFrame.height > connectPanel.safeAreaInsets.bottom + 1
        let editingInShortSpace = keyboardVisible && available.height < (sideBySide ? 190 : 300)
        connectionBrand.isHidden = !sideBySide && compact
        connectionBrandDetails.forEach { $0.isHidden = sideBySide && compact }
        updateEntryVisibility(compact: editingInShortSpace)
        routeControl.isHidden = editingInShortSpace
        messageLabel.isHidden = editingInShortSpace || messageLabel.text?.isEmpty != false
        let visualLimit: CGFloat = entryMode == .qr ? 280 : 180
        let logoSize = max(48, min(visualLimit, min(brandWidth, sideBySide ? available.height - 84 : 160)))
        connectionLogoWidth?.constant = logoSize
        connectionLogoHeight?.constant = logoSize
        connectionVisual.layer.cornerRadius = entryMode == .qr ? min(24, logoSize * 0.09) : logoSize * 0.223
        if sideBySide || connectionBrand.isHidden {
            connectionBrandY?.constant = 0
            connectionFormY?.constant = 0
        } else {
            let brandHeight = connectionBrand.systemLayoutSizeFitting(CGSize(width: brandWidth, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
            let formHeight = connectionForm.systemLayoutSizeFitting(CGSize(width: formWidth, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
            connectionBrandY?.constant = -(formHeight + gap) / 2
            connectionFormY?.constant = (brandHeight + gap) / 2
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view?.isDescendant(of: linkField) != true
    }
    @objc private func dismissConnectionKeyboard() { view.endEditing(true) }
    private func showConnectionMessage(_ text: String?, error: Bool = false) {
        messageLabel.text = text
        messageLabel.textColor = error ? .systemOrange : .secondaryLabel
        messageLabel.isHidden = text?.isEmpty != false
    }
    private var selectedRoute: TransportCoordinator.Route {
        let index = routeControl.selectedSegmentIndex
        return routes.indices.contains(index) ? routes[index] : .lan
    }
    private var routeBenefit: String {
        switch activeRoute {
        case .lan: return "同一网络即可无线串流，连接方便。"
        case .usb: return "数据线传输，减少无线干扰；请先连接并信任 Mac。"
        }
    }
    private func updateEntryHint() {
        switch entryMode {
        case .certificate: entryHint.text = "配对一次，以后免扫码；无需开始串流。"
        case .qr:
            if let host = qrPairedHost { entryHint.text = "已与“\(host.name)”配对，随时连接串流。" }
            else { entryHint.text = scannedLink == nil ? "扫描主机配对码，无需开始串流。" : "已读取串流链接，点“连接串流”开始。" }
        case .address:
            entryHint.text = addressPairedHost.map { "已与“\($0.name)”配对，随时连接串流。" } ?? "无需相机，粘贴地址即可配对主机。"
        }
        entryHint.textColor = .secondaryLabel
    }
    private func updateEntryVisibility(compact: Bool) {
        entryControl.isHidden = compact; entryHint.isHidden = compact
        trustedMacSelection.isHidden = compact || entryMode != .certificate
        scanButton.isHidden = compact || entryMode != .qr
        addressRow.isHidden = entryMode != .address
    }
    @objc private func entryChanged() {
        guard !connecting, !preparingTransport else {
            entryControl.selectedSegmentIndex = entryMode.rawValue; return
        }
        view.endEditing(true)
        view.layoutIfNeeded()
        let previousRadius = connectionVisual.layer.presentation()?.cornerRadius ?? connectionVisual.layer.cornerRadius
        entryMode = EntryMode(rawValue: entryControl.selectedSegmentIndex) ?? .certificate
        if entryMode == .qr {
            ensureEmbeddedScanner()
            scannedLink = nil; qrPairedHost = nil
            embeddedScanner?.setActive(true)
            embeddedScanner?.restartScanning()
        } else { embeddedScanner?.setActive(false) }
        if entryMode == .certificate { trustedMacSelection.reloadHosts() }
        updateEntryHint(); updateEntryVisibility(compact: false)
        showConnectionMessage(nil)
        updateConnectionPanelLayout()
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.32
        let corners = CABasicAnimation(keyPath: "cornerRadius")
        corners.fromValue = previousRadius; corners.toValue = connectionVisual.layer.cornerRadius
        corners.duration = duration; corners.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        connectionVisual.layer.add(corners, forKey: "connectionModeCorners")
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.connectionLogo.alpha = self.entryMode == .qr ? 0 : 1
            self.embeddedScanner?.view.alpha = self.entryMode == .qr ? 1 : 0
            self.view.layoutIfNeeded()
        }
    }
    private func ensureEmbeddedScanner() {
        guard embeddedScanner == nil else { return }
        let scanner = QRCodeScannerViewController()
        scanner.embedded = true
        scanner.captureEnabled = enablesCameraCapture
        scanner.onAccepted = { [weak self] link in
            guard let self, self.entryMode == .qr, !self.connecting, !self.preparingTransport else { return }
            if let invitation = try? PairingInvitation(text: link) {
                self.scannedLink = nil
                self.pair(invitation, source: .qr)
            } else {
                self.scannedLink = link
                self.updateEntryHint()
            }
        }
        addChild(scanner)
        scanner.view.alpha = 0
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        connectionVisual.addSubview(scanner.view)
        NSLayoutConstraint.activate([
            scanner.view.leadingAnchor.constraint(equalTo: connectionVisual.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo: connectionVisual.trailingAnchor),
            scanner.view.topAnchor.constraint(equalTo: connectionVisual.topAnchor),
            scanner.view.bottomAnchor.constraint(equalTo: connectionVisual.bottomAnchor)
        ])
        scanner.didMove(toParent: self)
        embeddedScanner = scanner
    }
    private func buildControls() {
        controls.layer.cornerCurve = .circular; controls.clipsToBounds = false
        controls.alpha = 0.9
        view.addSubview(controls)
        let menu = UIButton(type: .system)
        menu.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        menu.tintColor = .white; menu.accessibilityLabel = "打开串流设置"
        menu.accessibilityHint = "可拖动悬浮按钮，松手后贴住最近的屏幕左右边缘并避开屏幕遮挡"
        menu.translatesAutoresizingMaskIntoConstraints = false
        menu.imageView?.contentMode = .scaleAspectFit
        menu.addTarget(self, action: #selector(showStreamSettings), for: .touchUpInside)
        controls.contentView.addSubview(menu)
        // Only this control owns the gesture; the sibling game surface never receives this contact.
        menuPan.maximumNumberOfTouches = 1
        menuPan.cancelsTouchesInView = true
        menu.addGestureRecognizer(menuPan)
        NSLayoutConstraint.activate([
            menu.leadingAnchor.constraint(equalTo: controls.contentView.leadingAnchor),
            menu.trailingAnchor.constraint(equalTo: controls.contentView.trailingAnchor),
            menu.topAnchor.constraint(equalTo: controls.contentView.topAnchor),
            menu.bottomAnchor.constraint(equalTo: controls.contentView.bottomAnchor)
        ])
        controls.isHidden = true
    }
    @objc private func dragMenu(_ gesture: UIPanGestureRecognizer) {
        let safeArea = view.safeAreaLayoutGuide.layoutFrame
        switch gesture.state {
        case .began:
            if let visibleFrame = controls.layer.presentation()?.frame {
                controls.layer.removeAllAnimations()
                controls.frame = visibleFrame
            }
            menuDragStart = controls.center
            menuIsDragging = true
            fallthrough
        case .changed:
            let translation = gesture.translation(in: view)
            controls.frame = VideoGeometry.floatingMenuFrame(bounds: view.bounds, safeArea: safeArea,
                center: CGPoint(x: menuDragStart.x + translation.x, y: menuDragStart.y + translation.y))
        case .ended, .cancelled:
            menuIsDragging = false
            menuPosition = VideoGeometry.floatingMenuPosition(bounds: view.bounds, safeArea: safeArea, center: controls.center)
            let frame = VideoGeometry.floatingMenuFrame(bounds: view.bounds, safeArea: safeArea, position: menuPosition)
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25,
                           delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]) {
                self.controls.frame = frame
            }
        default: break
        }
    }
    @objc private func showStreamSettings() {
        guard !menuIsDragging, settingsController == nil, presentedViewController == nil else { return }
        touchSurface.acceptsTouches = false
        session.releaseTouches()
        let panel = StreamSettingsViewController(statusText: statusLabel.text ?? "已连接",
            routeTitle: activeRoute.title, fullBleed: fullBleed, canFillScreen: canFillScreen, profileText: profileText)
        panel.profileProvider = { [weak self] in self?.profileText ?? "" }
        panel.onFillChange = { [weak self] enabled in
            guard let self, self.canFillScreen else { return }
            self.fullBleed = enabled
            self.touchSurface.releaseAll(); self.session.releaseTouches(); self.view.setNeedsLayout()
        }
        panel.onContinue = { [weak self] in self?.closeStreamSettings() }
        panel.onDisconnect = { [weak self] in self?.closeStreamSettings(disconnect: true) }
        let source = VideoGeometry.floatingMenuFrame(bounds: view.bounds, safeArea: view.safeAreaLayoutGuide.layoutFrame, position: menuPosition)
        let target = VideoGeometry.floatingSettingsFrame(bounds: view.bounds, safeArea: view.safeAreaLayoutGuide.layoutFrame, source: source)
        let dismissControl = UIControl(frame: view.bounds)
        dismissControl.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dismissControl.isMultipleTouchEnabled = true
        dismissControl.accessibilityLabel = "关闭串流设置"
        dismissControl.addAction(UIAction { [weak self] _ in self?.closeStreamSettings() }, for: .touchUpInside)
        view.insertSubview(dismissControl, belowSubview: controls)
        settingsDismissControl = dismissControl; settingsController = panel
        menuPan.isEnabled = false
        addChild(panel)
        panel.view.accessibilityViewIsModal = true
        controls.attachSettings(panel.view, size: target.size)
        panel.didMove(toParent: self)
        controls.morph(expanded: true, to: target, animated: true)
    }
    private func closeStreamSettings(animated: Bool = true, disconnect: Bool = false) {
        guard let panel = settingsController, !settingsClosing else { return }
        settingsClosing = true
        panel.view.isUserInteractionEnabled = false
        let target = VideoGeometry.floatingMenuFrame(bounds: view.bounds, safeArea: view.safeAreaLayoutGuide.layoutFrame, position: menuPosition)
        controls.morph(expanded: false, to: target, animated: animated) { [weak self, weak panel] in
            guard let self else { return }
            panel?.willMove(toParent: nil)
            self.controls.removeSettings(); panel?.removeFromParent()
            self.settingsDismissControl?.removeFromSuperview(); self.settingsDismissControl = nil
            self.settingsController = nil; self.settingsClosing = false; self.menuPan.isEnabled = true
            if disconnect { self.exitPressed() } else { self.resumeAfterSettings() }
        }
    }
    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        controller.presentedViewController is StreamSettingsViewController ? .none : .automatic
    }
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        adaptivePresentationStyle(for: controller)
    }
    func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
        resumeAfterSettings()
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { resumeAfterSettings() }
    private func resumeAfterSettings() {
        touchSurface.acceptsTouches = session.isReady && connecting && UIApplication.shared.applicationState == .active
    }
    private func updateViewportProfile(canvasBounds: CGRect) {
        guard let scene = view.window?.windowScene else { return }
        let screen = scene.screen
        let insets = view.safeAreaInsets
        let pixels = VideoGeometry.evenPixelCanvas(points: canvasBounds.size, nativeScale: screen.nativeScale)
        let direction = view.bounds.width > view.bounds.height ? "横向视图" : "纵向视图"
        let sceneBounds = sceneGeometryBounds(scene)
        let text = String(format: "%@有效画布 %.1f × %.1f pt · nativeScale %.3g\n建议采集分辨率 %.0f × %.0f（偶数像素）\n安全边距 上%.1f 左%.1f 下%.1f 右%.1f pt\n系统场景 %.1f × %.1f pt · orientation %@\n保守模式左右画面边距取系统两侧较大值；比例匹配时默认铺满。旋转后自动更新。", direction, canvasBounds.width, canvasBounds.height, screen.nativeScale, pixels.width, pixels.height, insets.top, insets.left, insets.bottom, insets.right, sceneBounds.width, sceneBounds.height, sceneOrientationName(sceneOrientation(scene)))
        if profileText != text { profileText = text }
    }
    @objc private func manageTrustedMacs() { presentTrustedMacs(automaticallyStart: false) }
    private func presentTrustedMacs(automaticallyStart: Bool, preferredHostID: String? = nil,
                                   invitation: PairingInvitation? = nil,
                                   onPaired: ((TrustedMac) -> Void)? = nil) {
        guard !connecting, !preparingTransport, presentedViewController == nil else { return }
        view.endEditing(true)
        let hosts = TrustedMacViewController(style: .insetGrouped)
        if let previewTrustedMacs {
            hosts.previewHosts = previewTrustedMacs
            hosts.enablesDiscovery = false
        }
        hosts.managesTrustOnly = !automaticallyStart
        hosts.invitation = invitation
        hosts.preferredHostID = preferredHostID ?? trustedMacSelection.selectedHostID
        hosts.automaticallyStartSingleHost = automaticallyStart
        hosts.onDismiss = { [weak self] in self?.trustedMacSelection.reloadHosts(); self?.updateEntryHint() }
        hosts.onPaired = { [weak self, weak hosts] host in
            guard let self else { return }
            self.trustedMacSelection.selectedHostID = host.hostID
            self.trustedMacSelection.reloadHosts()
            onPaired?(host)
            if invitation != nil { hosts?.navigationController?.dismiss(animated: true) }
        }
        hosts.onConnection = { [weak self] link in
            guard let self, !self.connecting, !self.preparingTransport else { return }
            self.trustedMacSelection.reloadHosts()
            self.connectUsing(link)
        }
        let navigation = UINavigationController(rootViewController: hosts)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        present(navigation, animated: true)
    }
    private func pair(_ invitation: PairingInvitation, source: EntryMode) {
        guard !connecting, !preparingTransport, presentedViewController == nil else { return }
        embeddedScanner?.setActive(false)
        showConnectionMessage(nil)
        presentTrustedMacs(automaticallyStart: false, invitation: invitation) { [weak self] host in
            guard let self else { return }
            switch source {
            case .qr: self.qrPairedHost = host
            case .address: self.addressPairedHost = host
            case .certificate: break
            }
            self.updateEntryHint()
        }
    }
    @objc private func addressEdited() {
        addressPairedHost = nil
        updateEntryHint(); showConnectionMessage(nil)
    }
    @objc private func pairAddressPressed() {
        guard !connecting, !preparingTransport, entryMode == .address else { return }
        view.endEditing(true)
        do { pair(try PairingInvitation(text: linkField.text ?? ""), source: .address) }
        catch { showConnectionMessage(error.localizedDescription, error: true) }
    }
    @objc private func scanPressed() {
        guard !connecting, !preparingTransport, entryMode == .qr else { return }
        ensureEmbeddedScanner()
        scannedLink = nil; qrPairedHost = nil; updateEntryHint(); showConnectionMessage(nil)
        embeddedScanner?.setActive(true)
        embeddedScanner?.restartScanning()
    }
    private func requestLandscapeForConnection() {
        #if !targetEnvironment(macCatalyst)
        guard let scene = view.window?.windowScene else { return }
        geometryRequestCount += 1
        geometryRequestError = nil
        recordOrientationSnapshot(event: "landscape-requested")
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                let error = error as NSError
                self.geometryRequestError = ["domain": error.domain, "code": error.code]
                self.recordOrientationSnapshot(event: "landscape-request-denied")
                self.statusLabel.text = "系统未接受横屏请求"
            }
        }
        #endif
    }

    func sceneGeometryDidChange(event: String) {
        guard isViewLoaded else { return }
        recordOrientationSnapshot(event: event, force: event == "scene-active")
        view.setNeedsLayout()
    }

    private func sceneGeometryBounds(_ scene: UIWindowScene) -> CGRect {
        if #available(iOS 26.0, *) { return scene.effectiveGeometry.coordinateSpace.bounds }
        return scene.coordinateSpace.bounds
    }

    private func sceneOrientation(_ scene: UIWindowScene) -> UIInterfaceOrientation {
        if #available(iOS 26.0, *) { return scene.effectiveGeometry.interfaceOrientation }
        return scene.interfaceOrientation
    }
    private func sceneOrientationName(_ orientation: UIInterfaceOrientation) -> String {
        switch orientation {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        default: return "unknown"
        }
    }

    private func recordOrientationSnapshot(event: String, force: Bool = false) {
        guard let window = viewIfLoaded?.window, let scene = window.windowScene else { return }
        func rect(_ value: CGRect) -> [String: CGFloat] {
            ["x": value.origin.x, "y": value.origin.y, "width": value.width, "height": value.height]
        }
        func transform(_ value: CGAffineTransform) -> [CGFloat] {
            [value.a, value.b, value.c, value.d, value.tx, value.ty]
        }
        // Report system geometry separately from content geometry. In resizable iPhone
        // Mirroring on iOS 27, portrait can be valid even when the scene is wide.
        // Neither this enum nor a wide root view alone proves that the outer window rotated.
        var snapshot: [String: Any] = [
            "schema": 1,
            "sceneSessionRole": scene.session.role.rawValue,
            "systemVersion": UIDevice.current.systemVersion,
            "streamingRequested": connecting,
            "controllerOrientationMask": supportedInterfaceOrientations.rawValue,
            "sceneOrientation": sceneOrientationName(sceneOrientation(scene)),
            "sceneBoundsPoints": rect(sceneGeometryBounds(scene)),
            "windowBoundsPoints": rect(window.bounds),
            "rootViewBoundsPoints": rect(view.bounds),
            "rootViewFramePoints": rect(view.frame),
            "screenBoundsPoints": rect(scene.screen.bounds),
            "rootViewTransform": transform(view.transform),
            "windowTransform": transform(window.transform),
            "videoLayerTransformIsIdentity": CATransform3DIsIdentity(videoLayer.transform),
            "sceneActivationState": scene.activationState.rawValue,
            "geometryRequestCount": geometryRequestCount,
            "lastGeometryRequestError": geometryRequestError ?? [:]
        ]
        // Only persist changed values; layout can run repeatedly while a stream is active.
        guard let state = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              force || state != lastOrientationSnapshot else { return }
        lastOrientationSnapshot = state
        snapshot["event"] = event
        snapshot["recordedAtUnixSeconds"] = Date().timeIntervalSince1970
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("stream-orientation.json"), options: .atomic)
    }
    @objc private func connectPressed() {
        if preparingTransport { showConnection(message: nil); return }
        guard !connecting else { return }
        view.endEditing(true)
        switch entryMode {
        case .certificate:
            presentTrustedMacs(automaticallyStart: true)
        case .qr:
            if let host = qrPairedHost {
                presentTrustedMacs(automaticallyStart: true, preferredHostID: host.hostID)
                return
            }
            guard let scannedLink else {
                showConnectionMessage("请先扫描 Mac 配对码并完成配对。", error: true)
                return
            }
            connectUsing(scannedLink)
        case .address:
            if let host = addressPairedHost {
                presentTrustedMacs(automaticallyStart: true, preferredHostID: host.hostID)
            } else if (try? Connection(text: linkField.text ?? "")) != nil {
                // Existing session links remain usable, but never start on paste or pair.
                connectUsing(linkField.text ?? "")
            } else {
                showConnectionMessage("请先点“配对 Mac”保存主机。", error: true)
            }
        }
    }
    private func connectUsing(_ link: String) {
        guard !connecting, !preparingTransport else { return }
        do {
            let connection = try Connection(text: link)
            embeddedScanner?.setActive(false)
            activeRoute = selectedRoute
            setPreparingTransport(true)
            showConnectionMessage("正在准备\(activeRoute.title)…")
            transport.start(activeRoute, connection: connection)
        } catch { showConnectionMessage(error.localizedDescription, error: true) }
    }
    @objc private func routeChanged() {
        activeRoute = selectedRoute
        routeControl.accessibilityHint = routeBenefit
        showConnectionMessage(nil)
    }
    private func setPreparingTransport(_ preparing: Bool) {
        preparingTransport = preparing
        routeControl.isEnabled = !preparing; linkField.isEnabled = !preparing
        pairAddressButton.isEnabled = !preparing
        entryControl.isEnabled = !preparing; scanButton.isEnabled = !preparing
        trustedMacSelection.isUserInteractionEnabled = !preparing
        var configuration = connectButton.configuration
        configuration?.title = preparing ? "取消连接" : "连接串流"
        connectButton.configuration = configuration
        UIApplication.shared.isIdleTimerDisabled = preparing || connecting
    }
    private func beginSession(_ connection: Connection) {
        embeddedScanner?.setActive(false)
        connecting = true; connectPanel.isHidden = true; controls.isHidden = false
        touchSurface.clientRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        UIApplication.shared.isIdleTimerDisabled = true
        updateAppearance(); requestLandscapeForConnection()
        session.connect(connection, layer: videoLayer)
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
    @objc private func exitPressed() { touchSurface.releaseAll(); session.disconnect() }
    @objc private func resignActive() {
        touchSurface.acceptsTouches = false; session.releaseTouches()
    }
    @objc private func backgrounded() {
        embeddedScanner?.setActive(false)
        if connecting { session.disconnect(reason: .background, message: "已在后台断开，所有触点已释放。") }
        else if preparingTransport { showConnection(message: "已取消后台连接，请回到 App 后重新连接。") }
    }
    @objc private func becameActive() {
        touchSurface.acceptsTouches = session.isReady && connecting
    }
    @objc private func audioInterrupted(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              type == AVAudioSession.InterruptionType.began.rawValue else { return }
        if connecting { session.disconnect(reason: .audioInterruption, message: "系统音频中断，已暂停串流并释放触控。") }
    }
    private func showConnection(message: String?) {
        closeStreamSettings(animated: false)
        transport.stop()
        setPreparingTransport(false)
        presentedViewController?.dismiss(animated: false)
        touchSurface.acceptsTouches = false
        connecting = false; connectPanel.isHidden = false; controls.isHidden = true
        UIApplication.shared.isIdleTimerDisabled = false
        showConnectionMessage(message, error: message != nil)
        updateAppearance()
    }
    private func updateAppearance() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        setNeedsStatusBarAppearanceUpdate(); setNeedsUpdateOfHomeIndicatorAutoHidden(); setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }
}

/// Keep the system clear control, moving its real layout rect instead of drawing a separate icon.
private final class ConnectionLinkTextField: UITextField {
    private let trailingPadding: CGFloat = 14
    private let textToClearGap: CGFloat = 6

    override func leftViewRect(forBounds bounds: CGRect) -> CGRect {
        // Keep this padding view narrow when UIKit asks it for a fitting size.
        CGRect(x: bounds.minX, y: bounds.minY, width: min(14, max(0, bounds.width)), height: bounds.height)
    }

    override func clearButtonRect(forBounds bounds: CGRect) -> CGRect {
        positionedClearRect(forBounds: bounds)
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        paddedContentRect(super.textRect(forBounds: bounds), bounds: bounds)
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        paddedContentRect(super.editingRect(forBounds: bounds), bounds: bounds)
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        paddedContentRect(super.placeholderRect(forBounds: bounds), bounds: bounds)
    }

    private func positionedClearRect(forBounds bounds: CGRect) -> CGRect {
        var rect = super.clearButtonRect(forBounds: bounds)
        // Preserve UIKit's button size and vertical position; clamp the origin for narrow layouts.
        rect.origin.x = max(bounds.minX, min(rect.minX, bounds.maxX - trailingPadding - rect.width))
        return rect
    }

    private func paddedContentRect(_ nativeRect: CGRect, bounds: CGRect) -> CGRect {
        var rect = nativeRect // UIKit already accounts for the existing 14pt leftView.
        var rightEdge = bounds.maxX - min(trailingPadding, max(0, bounds.width))
        let clearIsVisible: Bool
        switch clearButtonMode {
        case .never: clearIsVisible = false
        case .whileEditing: clearIsVisible = isEditing && hasText
        case .unlessEditing: clearIsVisible = !isEditing && hasText
        case .always: clearIsVisible = hasText
        @unknown default: clearIsVisible = false
        }
        if clearIsVisible {
            let clearRect = positionedClearRect(forBounds: bounds)
            if clearRect.width > 0 { rightEdge = min(rightEdge, clearRect.minX - textToClearGap) }
        }
        // Capping the native rect is idempotent if UIKit has already applied the custom clear rect.
        rect.size.width = max(0, min(nativeRect.maxX, rightEdge) - nativeRect.minX)
        return rect
    }
}
