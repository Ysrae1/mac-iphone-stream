import UIKit
import AVFoundation

/// Native, in-memory QR intake. It never opens a URL or starts a control session.
final class QRCodeScannerViewController: UIViewController {
    var onAccepted: ((String) -> Void)?
    /// Set before loading the view. The parent supplies the square and its corner clipping.
    var embedded = false
    /// Set before loading the view for layout previews; no authorization or device access occurs.
    var captureEnabled = true {
        didSet {
            if !captureEnabled {
                invalidateCapture()
                if isViewLoaded { showPreviewPlaceholder() }
            }
        }
    }
    private let camera = QRScannerCamera()
    private let preview = UIView()
    private lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        // An offline preview must not bind a session or participate in capture configuration.
        captureEnabled ? AVCaptureVideoPreviewLayer(session: camera.session) : AVCaptureVideoPreviewLayer()
    }()
    private let guide = CAShapeLayer()
    private let placeholder = UIImageView(image: UIImage(systemName: "qrcode.viewfinder"))
    private let bottomShade = CAGradientLayer()
    private let message = UILabel()
    private let retry = UIButton(type: .system)
    private let settings = UIButton(type: .system)
    private var startedOnce = false
    private var requestedActive = false
    private var onScreen = false
    private var paused = false
    private var finished = false
    private var pendingAcceptance = false
    private var generation = 0
    private var authorizedRequestGeneration: Int?
    private var permissionRequestInFlight = false
    private var permissionRequestGeneration: Int?

    /// Selecting another connection mode releases the camera and invalidates delayed results.
    func setActive(_ active: Bool) {
        refreshEmbeddedVisibility()
        guard requestedActive != active else { return }
        requestedActive = active
        if active {
            paused = false
            if isViewLoaded, onScreen, !finished { requestCamera() }
        } else {
            invalidateCapture()
        }
    }

    func restartScanning() {
        refreshEmbeddedVisibility()
        guard requestedActive, onScreen else { return }
        invalidateCapture()
        finished = false
        paused = false
        requestCamera()
    }

    private func refreshEmbeddedVisibility() {
        // A child added after its parent appeared need not receive a fresh appearance pass.
        // Explicit activation is the parent's selection signal; the window confirms attachment.
        if embedded, isViewLoaded, parent != nil, view.window != nil { onScreen = true }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = StreamTheme.background
        view.tintColor = StreamTheme.accent
        preview.backgroundColor = StreamTheme.background
        preview.layer.cornerRadius = embedded ? 0 : 20
        preview.layer.cornerCurve = .continuous; preview.clipsToBounds = true
        previewLayer.videoGravity = .resizeAspectFill
        preview.layer.addSublayer(previewLayer)
        guide.strokeColor = StreamTheme.accent.withAlphaComponent(0.7).cgColor
        guide.fillColor = UIColor.clear.cgColor; guide.lineWidth = 2
        guide.lineCap = .round; guide.lineJoin = .round
        preview.layer.addSublayer(guide)
        placeholder.tintColor = StreamTheme.accent.withAlphaComponent(0.35)
        placeholder.contentMode = .scaleAspectFit
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        preview.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: preview.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: preview.centerYAnchor, constant: -12),
            placeholder.widthAnchor.constraint(equalToConstant: 42),
            placeholder.heightAnchor.constraint(equalTo: placeholder.widthAnchor)
        ])
        message.text = scanningMessage
        message.numberOfLines = 0; message.font = .systemFont(ofSize: embedded ? 12 : 15)
        message.textAlignment = .center
        message.textColor = embedded ? .white : .secondaryLabel
        retry.setTitle("重新扫码", for: .normal)
        retry.addTarget(self, action: #selector(retryPressed), for: .touchUpInside)
        retry.isHidden = true
        settings.setTitle(embedded ? "打开设置" : "打开系统设置", for: .normal)
        settings.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        settings.isHidden = true
        for button in [retry, settings] {
            button.titleLabel?.font = .systemFont(ofSize: embedded ? 12 : 15, weight: .medium)
            button.tintColor = StreamTheme.accent
            let touchHeight = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
            touchHeight.priority = .defaultHigh; touchHeight.isActive = true
        }
        let actions = UIStackView(arrangedSubviews: [retry, settings])
        actions.axis = .horizontal; actions.spacing = 8; actions.distribution = .fillEqually
        if embedded {
            preview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(preview)
            bottomShade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.8).cgColor]
            preview.layer.addSublayer(bottomShade)
            let footer = UIStackView(arrangedSubviews: [message, actions])
            footer.axis = .vertical; footer.spacing = 3
            footer.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(footer)
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                preview.topAnchor.constraint(equalTo: view.topAnchor),
                preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
                footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
                footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
            ])
        } else {
            let title = UILabel()
            title.text = "扫码连接"; title.font = .systemFont(ofSize: 22, weight: .bold)
            let cancel = UIButton(type: .system)
            cancel.setTitle("取消", for: .normal)
            cancel.addTarget(self, action: #selector(cancelPressed), for: .touchUpInside)
            let header = UIStackView(arrangedSubviews: [title, UIView(), cancel])
            header.axis = .horizontal; header.alignment = .center
            let stack = UIStackView(arrangedSubviews: [header, preview, message, actions])
            stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
                preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
            ])
        }
        camera.onCode = { [weak self] in self?.received($0) }
        camera.onStarted = { [weak self] in
            guard let self, self.canCapture else { return }
            self.placeholder.isHidden = true
            self.view.setNeedsLayout()
        }
        camera.onFailure = { [weak self] _ in
            guard let self, self.canCapture else { return }
            self.message.text = "相机暂时不可用，请重试或使用地址连接。"
            self.placeholder.isHidden = false; self.retry.isHidden = false
        }
        if !captureEnabled { showPreviewPlaceholder() }
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(captureInterrupted), name: AVCaptureSession.wasInterruptedNotification, object: camera.session)
        NotificationCenter.default.addObserver(self, selector: #selector(captureInterrupted), name: AVCaptureSession.runtimeErrorNotification, object: camera.session)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onScreen = true
        if !embedded, !startedOnce {
            startedOnce = true
            setActive(true)
        } else if requestedActive, !paused, !finished {
            requestCamera()
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onScreen = false
        invalidateCapture()
        retry.isHidden = false
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            // A left/right landscape flip keeps the size; apply the final scene orientation.
            self?.view.setNeedsLayout()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer.frame = preview.bounds
        bottomShade.frame = CGRect(x: 0, y: preview.bounds.height * 0.45,
                                  width: preview.bounds.width, height: preview.bounds.height * 0.55)
        guide.frame = preview.bounds
        let edge = min(preview.bounds.width, preview.bounds.height)
        let inset = max(18, edge * 0.1)
        let rect = preview.bounds.insetBy(dx: inset, dy: inset)
        let arm = min(24, edge * 0.1)
        let path = UIBezierPath()
        for (x, y, dx, dy) in [(rect.minX, rect.minY, 1.0, 1.0),
                               (rect.maxX, rect.minY, -1.0, 1.0),
                               (rect.minX, rect.maxY, 1.0, -1.0),
                               (rect.maxX, rect.maxY, -1.0, -1.0)] {
            path.move(to: CGPoint(x: x + dx * arm, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy * arm))
        }
        guide.path = path.cgPath
        #if !targetEnvironment(macCatalyst)
        if let orientation = view.window?.windowScene?.interfaceOrientation,
           let connection = previewLayer.connection {
            let angle: CGFloat
            // UIInterfaceOrientation's landscape names are opposite to UIDeviceOrientation's.
            switch orientation {
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
        #endif
        CATransaction.commit()
    }
    private var scanningMessage: String {
        embedded ? "对准 Mac 配对二维码" : "对准 Mac 上的配对二维码。\n识别后会填入链接，由你确认连接。"
    }
    private var canCapture: Bool {
        captureEnabled && requestedActive && onScreen && !finished && !paused
            && UIApplication.shared.applicationState == .active
    }
    private func invalidateCapture() {
        generation += 1
        authorizedRequestGeneration = nil
        permissionRequestGeneration = nil
        if pendingAcceptance { finished = false; pendingAcceptance = false }
        paused = true
        camera.stop()
    }
    private func showPreviewPlaceholder() {
        message.text = "扫码预览区域"
        placeholder.isHidden = false
        retry.isHidden = true; settings.isHidden = true
    }
    @objc private func retryPressed() { restartScanning() }
    private func requestCamera() {
        guard captureEnabled else { showPreviewPlaceholder(); return }
        guard requestedActive, onScreen, !finished, !paused else { return }
        if permissionRequestInFlight {
            // The existing permission sheet can temporarily make the app inactive.
            // Rebinding its result does not inspect permission or request another sheet.
            permissionRequestGeneration = generation
            return
        }
        guard canCapture else { return }
        retry.isHidden = true; settings.isHidden = true
        #if targetEnvironment(simulator)
        message.text = "模拟器没有相机，请使用地址连接。"
        return
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startCameraIfVisible()
        case .notDetermined:
            message.text = "请允许访问相机，以读取 Mac 配对二维码。"
            // An immediate restart may arrive while this system sheet is still open.
            // Reuse that request for the latest explicit selection instead of opening another.
            permissionRequestGeneration = generation
            guard !permissionRequestInFlight else { return }
            permissionRequestInFlight = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.permissionRequestInFlight = false
                    let requestGeneration = self.permissionRequestGeneration
                    self.permissionRequestGeneration = nil
                    guard self.generation == requestGeneration, self.captureEnabled,
                          self.requestedActive, self.onScreen, !self.finished, !self.paused else { return }
                    if granted {
                        if UIApplication.shared.applicationState == .active {
                            self.startCameraIfVisible()
                        } else {
                            // Permission sheets can complete just before the app becomes active.
                            self.authorizedRequestGeneration = self.generation
                        }
                    } else { self.showDenied() }
                }
            }
        case .denied, .restricted: showDenied()
        @unknown default: showDenied()
        }
        #endif
    }
    private func startCameraIfVisible() {
        guard canCapture else { return }
        message.text = scanningMessage
        camera.start()
    }
    private func showDenied() {
        camera.stop()
        message.text = "相机权限未开启。可前往设置，或使用地址连接。"
        placeholder.isHidden = false
        settings.isHidden = false; retry.isHidden = false
    }
    private func received(_ text: String) {
        guard canCapture else { return }
        let isPairingInvitation = (try? PairingInvitation(text: text)) != nil
        guard text.utf8.count <= 2048, isPairingInvitation || (try? Connection(text: text)) != nil else {
            message.text = "二维码无效，请扫描 Mac 的配对码。"
            return
        }
        finished = true
        pendingAcceptance = true
        message.text = isPairingInvitation ? "已读取主机配对信息" : (embedded ? "已读取，点击“连接串流”继续" : "已读取配对链接。")
        retry.isHidden = embedded; settings.isHidden = true
        let acceptedGeneration = generation
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        camera.stop { [weak self] in
            guard let self, self.generation == acceptedGeneration, self.requestedActive,
                  self.onScreen, self.finished, !self.paused,
                  UIApplication.shared.applicationState == .active else { return }
            self.pendingAcceptance = false
            if self.embedded {
                self.onAccepted?(value)
            } else {
                self.dismiss(animated: true) { [weak self] in self?.onAccepted?(value) }
            }
        }
    }
    @objc private func cancelPressed() {
        finished = true
        generation += 1
        camera.stop { [weak self] in self?.dismiss(animated: true) }
    }
    @objc private func backgrounded() {
        guard requestedActive, onScreen, captureEnabled else { return }
        invalidateCapture()
        if !finished {
            message.text = "扫码已暂停，点“重新扫码”继续。"
            retry.isHidden = false
        }
    }
    @objc private func becameActive() {
        // Only finish this selection's permission request; backgrounding clears it.
        guard authorizedRequestGeneration == generation, canCapture else { return }
        authorizedRequestGeneration = nil
        startCameraIfVisible()
    }
    @objc private func captureInterrupted() {
        // AVFoundation can post capture-session notifications from its worker queue.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.captureInterrupted() }
            return
        }
        guard requestedActive, onScreen, !finished, !paused, captureEnabled else { return }
        invalidateCapture()
        message.text = "扫码已暂停，可重试或使用地址连接。"
        retry.isHidden = false
    }
    @objc private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// All capture configuration/start/stop work stays on one serial queue; no microphone input exists.
private final class QRScannerCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    var onCode: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onStarted: (() -> Void)?
    private let queue = DispatchQueue(label: "local.maciphonestream.client.qr-camera", qos: .userInitiated)
    private let lock = NSLock()
    private var wanted = false
    private var configured = false
    // Queue-confined; includes partially configured sessions that still need cleanup on failure.
    private var configurationStarted = false
    private var generation = 0
    private var acceptedOutput: AVCaptureMetadataOutput?
    private func isCurrent(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return wanted && generation == value
    }

    func start() {
        lock.lock()
        if !wanted { generation += 1 }
        wanted = true
        let requestGeneration = generation
        lock.unlock()
        queue.async { [self] in
            guard isCurrent(requestGeneration) else { return }
            do {
                if !configured { try configure(generation: requestGeneration) }
                guard isCurrent(requestGeneration) else { releaseCapture(); return }
                if !session.isRunning { session.startRunning() }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(requestGeneration) else { return }
                    self.onStarted?()
                }
            } catch {
                releaseCapture()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(requestGeneration) else { return }
                    self.onFailure?("没有可用的扫码相机，或相机正被占用。")
                }
            }
        }
    }
    func stop(completion: (() -> Void)? = nil) {
        lock.lock(); wanted = false; generation += 1; acceptedOutput = nil; lock.unlock()
        queue.async { [self] in
            releaseCapture()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }
    private func configure(generation value: Int) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else { throw CameraFailure.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureMetadataOutput()
        configurationStarted = true
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CameraFailure.unavailable }
        session.addInput(input); session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { throw CameraFailure.unavailable }
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        configured = true
        lock.lock()
        if wanted, generation == value { acceptedOutput = output }
        lock.unlock()
    }
    private func releaseCapture() {
        lock.lock(); acceptedOutput = nil; lock.unlock()
        // In particular, initial/offline stop must not race preview-layer initialization by
        // entering begin/commitConfiguration on a session that has never been configured.
        guard configurationStarted else { return }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
        configured = false
        configurationStarted = false
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        lock.lock()
        let acceptsOutput = wanted && acceptedOutput === output
        lock.unlock()
        guard acceptsOutput else { return }
        for case let object as AVMetadataMachineReadableCodeObject in metadataObjects where object.type == .qr {
            if let text = object.stringValue { onCode?(text); break }
        }
    }
    private enum CameraFailure: Error { case unavailable }
}
