import UIKit

/// The saved host certificate, rather than a remembered IP address, is the identity.
@MainActor
final class TrustedMacViewController: UITableViewController {
    var onConnection: ((String) -> Void)?
    var onPaired: ((TrustedMac) -> Void)?
    var onDismiss: (() -> Void)?
    var preferredHostID: String?
    /// A directed pairing flow. It never authorizes starting a stream.
    var invitation: PairingInvitation?
    /// Configure before loading the view. Disabled discovery is a fully local preview.
    var previewHosts: [TrustedMac]?
    var enablesDiscovery = true
    private var dismissalNotified = false
    private let store = DeviceTrustStore()
    private let discovery = TrustedMacDiscovery()
    private var hosts: [TrustedMac] = [] { didSet { updateDeviceCount() } }
    private var candidates: [DiscoveredMac] = []
    private var operation: Task<Void, Never>?
    private var pairingNamePrompt: UIAlertController?
    private var savedEndpointTask: Task<Void, Never>?
    private var metadataTasks: [String: Task<Void, Never>] = [:]
    private var metadataClients: [String: TrustedMacClient] = [:]
    private var metadataAttempted = Set<String>()
    private var client: TrustedMacClient?
    private let status = UILabel()
    private let statusContainer = UIView()
    private let deviceCountLabel = UILabel()
    private var didAutoSelect = false
    private var hasAppeared = false
    private var invitationProcessed = false
    var automaticallyStartSingleHost = true
    /// Credential management never authorizes a game or stream start.
    var managesTrustOnly = false
    private var newCandidates: [DiscoveredMac] { candidates.filter { item in !hosts.contains { item.matches($0) } } }
    private var automaticHost: TrustedMac? {
        if let preferredHostID { return hosts.first { $0.hostID == preferredHostID } }
        return hosts.count == 1 ? hosts.first : nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let invitation {
            managesTrustOnly = true; automaticallyStartSingleHost = false
            preferredHostID = invitation.hostID
        }
        title = managesTrustOnly ? "证书管理" : "连接 Mac"; overrideUserInterfaceStyle = .dark
        view.backgroundColor = StreamTheme.background
        tableView.backgroundColor = StreamTheme.background
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 68
        tableView.sectionHeaderTopPadding = 8
        tableView.contentInset.bottom = 12
        tableView.tintColor = StreamTheme.accent
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = StreamTheme.background
        appearance.shadowColor = .clear
        let navigationTraits = UITraitCollection(userInterfaceStyle: .dark)
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label.resolvedColor(with: navigationTraits)]
        navigationItem.standardAppearance = appearance
        navigationItem.scrollEdgeAppearance = appearance
        navigationItem.compactAppearance = appearance
        navigationController?.navigationBar.tintColor = StreamTheme.accent
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "chevron.left"),
            style: .plain, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"),
            style: .plain, target: self, action: #selector(refresh))
        navigationItem.leftBarButtonItem?.accessibilityLabel = "返回"
        navigationItem.rightBarButtonItem?.accessibilityLabel = "刷新"
        navigationItem.leftBarButtonItem?.tintColor = StreamTheme.accent
        navigationItem.rightBarButtonItem?.tintColor = StreamTheme.accent
        let navigationTitle = UILabel()
        navigationTitle.text = title; navigationTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        navigationTitle.textColor = UIColor.label.resolvedColor(with: navigationTraits); navigationTitle.textAlignment = .center
        deviceCountLabel.font = .systemFont(ofSize: 12)
        deviceCountLabel.textColor = UIColor.secondaryLabel.resolvedColor(with: navigationTraits); deviceCountLabel.textAlignment = .center
        let titleStack = UIStackView(arrangedSubviews: [navigationTitle, deviceCountLabel])
        // This view belongs to the parent navigation bar, outside this controller's dark view tree.
        titleStack.overrideUserInterfaceStyle = .dark
        titleStack.axis = .vertical; titleStack.alignment = .center; titleStack.spacing = 2
        navigationItem.titleView = titleStack
        updateDeviceCount()
        status.numberOfLines = 0; status.textAlignment = .center; status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabel
        let headerStack = UIStackView(arrangedSubviews: [status])
        headerStack.axis = .vertical; headerStack.spacing = 0
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.backgroundColor = StreamTheme.background
        statusContainer.addSubview(headerStack)
        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -20),
            headerStack.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 4),
            headerStack.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -16)
        ])
        tableView.tableHeaderView = statusContainer
        tableView.register(TrustedMacCardCell.self, forCellReuseIdentifier: "host")
        discovery.onChange = { [weak self] candidates in
            guard let self else { return }
            self.candidates = candidates; self.tableView.reloadData()
            self.refreshSavedHostNames()
            if self.operation == nil {
                self.setStatus(candidates.isEmpty ? "正在查找 Mac…请打开 Mac 上的串流主机。" :
                    (self.managesTrustOnly ? "选择新 Mac 配对。配对完成后，回到主页点“连接串流”。" :
                        "选择已配对的 Mac 开始串流。新 Mac 需先完成配对。"))
            }
            if !self.managesTrustOnly, self.automaticallyStartSingleHost, !self.didAutoSelect, self.operation == nil,
               let host = self.automaticHost,
               let candidate = candidates.first(where: { $0.matches(host) }) {
                self.didAutoSelect = true; self.start(host, candidate: candidate)
            }
        }
        discovery.onError = { [weak self] in self?.setStatus($0, error: true) }
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        refresh()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if let invitation, !invitationProcessed { processInvitation(invitation) }
    }
    private func updateDeviceCount() {
        deviceCountLabel.text = "\(hosts.count) 台已配对设备"
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let size = statusContainer.systemLayoutSizeFitting(CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if abs(statusContainer.frame.width - width) > 0.5 || abs(statusContainer.frame.height - size.height) > 0.5 {
            statusContainer.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
            tableView.tableHeaderView = statusContainer
        }
    }
    @objc private func enteredBackground() {
        didAutoSelect = true
        cancelWork(); busy(false)
        setStatus("已取消后台连接。回到 App 后点刷新即可重新发现 Mac。")
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancelWork(); notifyDismissed()
        }
    }
    @objc private func refresh() {
        guard operation == nil else { return }
        savedEndpointTask?.cancel(); savedEndpointTask = nil
        cancelMetadataRefresh()
        metadataAttempted.removeAll()
        do {
            if let previewHosts { hosts = previewHosts }
            else { hosts = enablesDiscovery ? try store.hosts() : [] }
        }
        catch { setStatus(error.localizedDescription, error: true); return }
        candidates.removeAll(); tableView.reloadData()
        guard enablesDiscovery else {
            setStatus("在这里查看和管理配对证书。配对后，回到主页点“连接串流”。")
            return
        }
        if let invitation {
            candidates = [invitation.candidate]; tableView.reloadData()
            invitationProcessed = false
            setStatus("正在验证主机配对信息…")
            if hasAppeared { processInvitation(invitation) }
            return
        }
        setStatus(managesTrustOnly ? "正在查找 Mac…此页面用于配对和管理设备证书。" :
            "正在查找 Mac…已信任的 Mac 会自动验证设备身份。")
        discovery.start()
        refreshSavedHostNames()
        scheduleSavedEndpoint()
    }
    @objc private func close() {
        cancelWork()
        dismiss(animated: true) { [weak self] in self?.notifyDismissed() }
    }
    private func notifyDismissed() {
        guard !dismissalNotified else { return }
        dismissalNotified = true; onDismiss?()
    }
    private func cancelWork() {
        pairingNamePrompt?.dismiss(animated: false); pairingNamePrompt = nil
        savedEndpointTask?.cancel(); savedEndpointTask = nil
        cancelMetadataRefresh()
        operation?.cancel(); operation = nil; client?.cancel(); client = nil; discovery.stop()
    }
    private func cancelMetadataRefresh() {
        for task in metadataTasks.values { task.cancel() }
        for client in metadataClients.values { client.cancel() }
        metadataTasks.removeAll(); metadataClients.removeAll()
    }
    /// Management may refresh labels, but it never sends start/status commands.
    private func refreshSavedHostNames() {
        guard enablesDiscovery, managesTrustOnly, invitation == nil else { return }
        for host in hosts where !metadataAttempted.contains(host.hostID) {
            guard let candidate = candidates.first(where: { $0.matches(host) }) ?? host.savedCandidate else { continue }
            metadataAttempted.insert(host.hostID)
            metadataTasks[host.hostID] = Task { [weak self] in
                guard let self else { return }
                do {
                    let client = try TrustedMacClient(candidate: candidate, host: host, identity: self.store.identity())
                    self.metadataClients[host.hostID] = client
                    defer { client.cancel() }
                    let name = try await client.verifyHostIdentity()
                    try Task.checkCancellation()
                    // Do not resurrect a certificate forgotten while verification was pending.
                    guard let saved = try self.store.hosts().first(where: {
                        $0.hostID == host.hostID && $0.deviceID == host.deviceID
                    }) else { return }
                    let updated = saved.withEndpoint(candidate, name: name)
                    if updated != saved { try self.store.save(updated) }
                    self.hosts = try self.store.hosts(); self.tableView.reloadData()
                } catch {
                    // An offline host or failed pin leaves the saved certificate and name intact.
                }
            }
        }
    }
    private func setStatus(_ text: String, error: Bool = false) {
        status.text = text; status.textColor = error ? .systemOrange : .secondaryLabel
        status.accessibilityLabel = text
        view.setNeedsLayout()
    }
    private func busy(_ value: Bool) {
        tableView.isUserInteractionEnabled = !value
        navigationItem.rightBarButtonItem?.isEnabled = !value
        isModalInPresentation = value
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? hosts.count : newCandidates.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "已信任的 Mac" : "配对新 Mac"
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "滑动可忘记此 Mac。要撤销手机的启动权限，请在 Mac 主机的设备列表中撤销。" :
            "首次配对前，请在 Mac 主机点“配对新 iPhone”。只有两端显示的六位码一致时才批准。"
    }
    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textLabel?.textColor = .secondaryLabel
        header.tintColor = StreamTheme.background
    }
    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        guard let footer = view as? UITableViewHeaderFooterView else { return }
        footer.textLabel?.font = .systemFont(ofSize: 12)
        footer.textLabel?.textColor = .secondaryLabel
        footer.tintColor = StreamTheme.background
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "host", for: indexPath) as! TrustedMacCardCell
        if indexPath.section == 0 {
            let host = hosts[indexPath.row]
            let available = candidates.contains { $0.matches(host) }
            let detail = managesTrustOnly ?
                (!enablesDiscovery ? "配对证书已保存" : (available ? "已配对 · 可回主页连接串流" : "已保存配对 · Mac 暂未出现")) :
                (available ? "设备已信任 · 点按启动并连接" : "等待 Mac 出现")
            cell.configure(name: host.name, detail: detail, selected: host.hostID == preferredHostID,
                           symbol: "desktopcomputer")
        } else {
            cell.configure(name: newCandidates[indexPath.row].name,
                           detail: "核对配对码并保存证书",
                           selected: false, symbol: "plus.circle")
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard operation == nil else { return }
        didAutoSelect = true
        if indexPath.section == 0 {
            let host = hosts[indexPath.row]
            if managesTrustOnly {
                setStatus("已与“\(host.name)”配对。回到主页点“连接串流”即可启动并连接。")
                return
            }
            guard let candidate = candidates.first(where: { $0.matches(host) }) ?? host.savedCandidate else {
                setStatus("尚未发现这台 Mac。请打开 Mac 串流主机，然后点刷新。", error: true); return
            }
            start(host, candidate: candidate)
        } else { pair(newCandidates[indexPath.row]) }
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 0, operation == nil else { return nil }
        let host = hosts[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: "忘记") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            do {
                if !self.enablesDiscovery {
                    self.hosts.removeAll { $0.hostID == host.hostID }
                    self.previewHosts = self.hosts
                } else {
                    try self.store.forget(host.hostID); self.hosts = try self.store.hosts()
                }
                self.tableView.reloadData()
                self.setStatus("已忘记此 Mac。Mac 端的手机授权可在主机设备列表中撤销。")
                completion(true)
            } catch { self.setStatus(error.localizedDescription, error: true); completion(false) }
        }
        let actions = UISwipeActionsConfiguration(actions: [action]); actions.performsFirstActionWithFullSwipe = false
        return actions
    }
    private func processInvitation(_ invitation: PairingInvitation) {
        guard enablesDiscovery, operation == nil, !invitationProcessed else { return }
        invitationProcessed = true
        if let saved = hosts.first(where: { $0.hostID == invitation.hostID }) {
            busy(true); setStatus("正在验证已配对的 Mac…")
            operation = Task { [weak self] in
                guard let self else { return }
                do {
                    let client = try TrustedMacClient(candidate: invitation.candidate, host: saved,
                        identity: self.store.identity(), expectedHostID: invitation.hostID)
                    self.client = client
                    let name = try await client.verifyHostIdentity()
                    try Task.checkCancellation()
                    let updated = saved.withEndpoint(invitation.candidate, name: name)
                    try self.store.save(updated)
                    self.completePairing(updated)
                } catch { self.finish(error) }
            }
        } else { pair(invitation.candidate, expectedHostID: invitation.hostID) }
    }
    private func completePairing(_ host: TrustedMac) {
        client?.cancel(); client = nil; operation = nil
        hosts = (try? store.hosts()) ?? hosts
        preferredHostID = host.hostID
        tableView.reloadData(); busy(false)
        setStatus("已与“\(host.name)”配对。回到主页点“连接串流”即可启动并连接。")
        let callback: () -> Void = { [weak self] in self?.onPaired?(host) }
        // Only close the SAS alert. The caller owns dismissing this management page.
        if let presentedViewController { presentedViewController.dismiss(animated: true, completion: callback) }
        else { callback() }
    }
    private func pair(_ candidate: DiscoveredMac, expectedHostID: String? = nil) {
        guard enablesDiscovery, operation == nil, pairingNamePrompt == nil else { return }
        // Retrying an invitation by tapping its row must retain the explicit pin.
        let expectedHostID = invitation?.hostID ?? expectedHostID
        didAutoSelect = true
        busy(true)
        let alert = UIAlertController(title: "为这台 iPhone 命名",
            message: "名称会显示在 Mac 的证书列表中，之后可在 Mac 修改。", preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = .dark
        alert.view.tintColor = StreamTheme.accent
        alert.addTextField { field in
            field.text = "iPhone"; field.placeholder = "设备名称（1–64 个字符）"
            field.autocorrectionType = .no; field.clearButtonMode = .whileEditing
            field.returnKeyType = .continue; field.textColor = .label
            field.accessibilityLabel = "iPhone 设备名称"
        }
        let confirm = UIAlertAction(title: "继续配对", style: .default) { [weak self, weak alert] _ in
            guard let self, let alert, let name = DeviceTrustProtocol.pairingDeviceName(alert.textFields?.first?.text ?? "") else { return }
            alert.dismiss(animated: true) { [weak self] in
                guard let self, self.pairingNamePrompt === alert else { return }
                self.pairingNamePrompt = nil
                self.beginPairing(candidate, expectedHostID: expectedHostID, deviceName: name)
            }
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.pairingNamePrompt = nil; self?.busy(false); self?.setStatus("已取消配对。")
        })
        alert.addAction(confirm); alert.preferredAction = confirm
        if let field = alert.textFields?.first {
            field.addAction(UIAction { [weak field, weak confirm] _ in
                confirm?.isEnabled = DeviceTrustProtocol.pairingDeviceName(field?.text ?? "") != nil
            }, for: .editingChanged)
        }
        pairingNamePrompt = alert
        present(alert, animated: true)
    }
    private func beginPairing(_ candidate: DiscoveredMac, expectedHostID: String?, deviceName: String) {
        guard enablesDiscovery, operation == nil else { return }
        busy(true); setStatus("正在请求配对…")
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = try self.store.identity()
                let client = try TrustedMacClient(candidate: candidate, host: nil, identity: identity,
                    pairing: true, expectedHostID: expectedHostID)
                self.client = client
                let pairing = try await client.beginPairing(deviceName: deviceName)
                try Task.checkCancellation()
                let alert = UIAlertController(title: pairing.code,
                    message: "请核对 Mac 上的六位码。两端完全一致后，在 Mac 批准这台 iPhone。", preferredStyle: .alert)
                alert.overrideUserInterfaceStyle = .dark; alert.view.tintColor = StreamTheme.accent
                alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
                    self?.operation?.cancel(); self?.client?.cancel()
                })
                self.present(alert, animated: true)
                self.setStatus("等待在 Mac 上批准此次配对…")
                var deviceID: String?
                while deviceID == nil {
                    try Task.checkCancellation()
                    deviceID = try await client.pollPairing(pairing)
                    if deviceID == nil { try await Task.sleep(nanoseconds: 1_000_000_000) }
                }
                try Task.checkCancellation()
                let host = TrustedMac(hostID: pairing.hostID, deviceID: deviceID!, name: pairing.hostName,
                                      serviceName: candidate.name, serviceDomain: candidate.domain,
                                      endpointURL: candidate.url?.absoluteString)
                try self.store.save(host)
                self.completePairing(host)
            } catch { self.finish(error) }
        }
    }
    private func start(_ host: TrustedMac, candidate: DiscoveredMac) {
        guard !managesTrustOnly, invitation == nil, enablesDiscovery else { return }
        savedEndpointTask?.cancel(); savedEndpointTask = nil
        busy(true); setStatus("正在验证 Mac 设备身份并开始串流…")
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let (client, verifiedCandidate) = try await self.clientBeforeStart(host, candidate: candidate)
                try Task.checkCancellation()
                try self.store.save(host.withEndpoint(verifiedCandidate, name: client.verifiedHostName))
                self.hosts = try self.store.hosts(); self.tableView.reloadData()
                var response = try await client.command("start", host: host)
                let deadline = Date().addingTimeInterval(180)
                while true {
                    try Task.checkCancellation()
                    if let url = response["url"] as? String {
                        // Validate with the existing strict LAN/session parser before presenting it.
                        _ = try Connection(text: url)
                        self.client?.cancel(); self.client = nil; self.operation = nil; self.discovery.stop()
                        let callback = self.onConnection
                        self.dismiss(animated: true) { callback?(url) }
                        return
                    }
                    if ["error", "failed"].contains(response["state"] as? String ?? "") {
                        throw DeviceTrustError.remote(response["message"] as? String ?? "Mac 启动未完成，请在 Mac 查看详情。")
                    }
                    self.setStatus(response["message"] as? String ?? "Mac 正在准备串流…")
                    guard Date() < deadline else { throw DeviceTrustError.expired }
                    // Each status uses a challenge and command: 2 seconds keeps
                    // the polling rate below the host's 90 requests/minute cap.
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    response = try await client.command("status", host: host)
                }
            } catch { self.finish(error) }
        }
    }
    private func scheduleSavedEndpoint() {
        guard !managesTrustOnly, automaticallyStartSingleHost, !didAutoSelect,
              let host = automaticHost, let candidate = host.savedCandidate else { return }
        savedEndpointTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.operation == nil, !self.didAutoSelect else { return }
            self.didAutoSelect = true
            self.start(host, candidate: self.candidates.first(where: { $0.matches(host) }) ?? candidate)
        }
    }
    private func clientBeforeStart(_ host: TrustedMac, candidate: DiscoveredMac) async throws -> (TrustedMacClient, DiscoveredMac) {
        let identity = try store.identity()
        let first = try TrustedMacClient(candidate: candidate, host: host, identity: identity)
        client = first
        do {
            _ = try await first.verifyHostIdentity()
            return (first, candidate)
        } catch {
            first.cancel(); client = nil
            try Task.checkCancellation()
            let value = error as NSError
            let reachabilityErrors = [NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
                NSURLErrorDNSLookupFailed]
            guard value.domain == NSURLErrorDomain, reachabilityErrors.contains(value.code) else { throw error }
            setStatus("正在重新查找这台 Mac…")
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                try Task.checkCancellation()
                if let updated = candidates.first(where: {
                    $0.advertisedHostID == host.hostID && $0.url != candidate.url
                }) {
                    let replacement = try TrustedMacClient(candidate: updated, host: host, identity: identity)
                    client = replacement
                    _ = try await replacement.verifyHostIdentity()
                    return (replacement, updated)
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw DeviceTrustError.unavailable
        }
    }
    private func finish(_ error: Error) {
        presentedViewController?.dismiss(animated: true)
        let cancelled = error is CancellationError || (error as NSError).code == NSURLErrorCancelled
        client?.cancel(); client = nil; operation = nil; busy(false)
        let cancelledMessage = managesTrustOnly ? "已取消配对。" : "已取消连接。Mac 上已经开始的启动流程不会被中断。"
        setStatus(cancelled ? cancelledMessage : error.localizedDescription, error: !cancelled)
    }
}

/// A compact, local-only credential selector. Selecting a row has no network or
/// startup side effects. The owning screen alone decides when to connect.
@MainActor
final class TrustedMacSelectionView: UIView, UITableViewDataSource, UITableViewDelegate {
    var selectedHostID: String? { didSet { table.reloadData() } }
    var onManage: (() -> Void)?
    /// Set this before reloadHosts() in previews to avoid every Keychain read.
    var previewHosts: [TrustedMac]? { didSet { reloadHosts() } }
    private let store = DeviceTrustStore()
    private var hosts: [TrustedMac] = []
    private let table = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let manageButton = UIButton(type: .system)

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 90) }
    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }
    private func build() {
        let heading = UILabel()
        heading.text = "已配对的 Mac"; heading.font = .systemFont(ofSize: 13, weight: .medium)
        heading.textColor = .secondaryLabel
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        manageButton.setTitle("管理", for: .normal)
        manageButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        manageButton.tintColor = StreamTheme.accent
        manageButton.accessibilityLabel = "管理 Mac 配对证书"
        manageButton.addTarget(self, action: #selector(managePressed), for: .touchUpInside)
        manageButton.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [heading, manageButton])
        header.axis = .horizontal; header.alignment = .center; header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear; table.separatorStyle = .none
        table.rowHeight = 44; table.estimatedRowHeight = 44
        table.alwaysBounceVertical = false; table.contentInsetAdjustmentBehavior = .never
        table.showsVerticalScrollIndicator = true
        table.dataSource = self; table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "saved-mac")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.text = "请先点“管理”配对一台 Mac"
        emptyLabel.textColor = .secondaryLabel; emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.numberOfLines = 2; emptyLabel.textAlignment = .center
        addSubview(header); addSubview(table); addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            table.leadingAnchor.constraint(equalTo: leadingAnchor),
            table.trailingAnchor.constraint(equalTo: trailingAnchor),
            table.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: table.leadingAnchor, constant: 8),
            emptyLabel.trailingAnchor.constraint(equalTo: table.trailingAnchor, constant: -8),
            emptyLabel.centerYAnchor.constraint(equalTo: table.centerYAnchor)
        ])
        // Intentionally no reload here: previewHosts can be supplied before any
        // Keychain access. Production callers call reloadHosts() when displayed.
    }
    func reloadHosts() {
        do {
            if let previewHosts { hosts = previewHosts }
            else { hosts = try store.hosts() }
            emptyLabel.text = "请先点“管理”配对一台 Mac"
        } catch {
            hosts = []; emptyLabel.text = "无法读取本机配对信息，请解锁 iPhone 后重试。"
        }
        if !hosts.contains(where: { $0.hostID == selectedHostID }) {
            selectedHostID = hosts.count == 1 ? hosts.first?.hostID : nil
        }
        emptyLabel.isHidden = !hosts.isEmpty
        table.isScrollEnabled = hosts.count > 1
        table.reloadData()
    }
    @objc private func managePressed() { onManage?() }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { hosts.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let host = hosts[indexPath.row]
        let selected = host.hostID == selectedHostID
        let cell = tableView.dequeueReusableCell(withIdentifier: "saved-mac", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = host.name
        content.textProperties.font = .systemFont(ofSize: 15, weight: selected ? .semibold : .regular)
        content.textProperties.numberOfLines = 1
        content.image = UIImage(systemName: "desktopcomputer")
        content.imageProperties.tintColor = selected ? StreamTheme.accent : .secondaryLabel
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        cell.contentConfiguration = content; cell.backgroundColor = .clear
        cell.tintColor = StreamTheme.accent; cell.accessoryType = selected ? .checkmark : .none
        cell.selectionStyle = .none
        cell.accessibilityLabel = host.name
        cell.accessibilityValue = selected ? "已选择" : "未选择"
        cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        selectedHostID = hosts[indexPath.row].hostID
    }
}

/// UIKit owns the inset-grouped section outline and its only background layer.
/// The transparent content container preserves the previous text/icon geometry.
@MainActor
private final class TrustedMacCardCell: UITableViewCell {
    private let card = UIView()
    private let symbol = UIImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let indicator = UIImageView()
    private var choiceSelected = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear; selectionStyle = .none
        automaticallyUpdatesBackgroundConfiguration = false
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .clear
        contentView.addSubview(card)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.contentMode = .scaleAspectFit
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.numberOfLines = 1
        detailLabel.font = .systemFont(ofSize: 12); detailLabel.numberOfLines = 2
        let text = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
        text.axis = .vertical; text.spacing = 4; text.translatesAutoresizingMaskIntoConstraints = false
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.contentMode = .scaleAspectFit
        indicator.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        card.addSubview(symbol); card.addSubview(text); card.addSubview(indicator)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            symbol.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            symbol.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 26), symbol.heightAnchor.constraint(equalToConstant: 26),
            text.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 12),
            text.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            text.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            indicator.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 8),
            indicator.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            indicator.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 16), indicator.heightAnchor.constraint(equalToConstant: 16)
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(name: String, detail: String, selected: Bool, symbol imageName: String) {
        nameLabel.text = name; detailLabel.text = detail
        symbol.image = UIImage(systemName: imageName)
        choiceSelected = selected
        indicator.image = UIImage(systemName: selected ? "checkmark" : "chevron.right")
        accessibilityLabel = name; accessibilityValue = detail
        accessibilityTraits = selected ? [.button, .selected] : [.button]
        applyColors()
    }
    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated); applyColors()
    }
    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated); applyColors()
    }
    private func applyColors() {
        let emphasized = choiceSelected || isHighlighted
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundInsets = .zero
        background.backgroundColor = emphasized ? StreamTheme.accent : StreamTheme.surface
        backgroundConfiguration = background
        nameLabel.textColor = emphasized ? StreamTheme.selectedForeground : .label
        detailLabel.textColor = emphasized ? StreamTheme.selectedForeground.withAlphaComponent(0.7) : .secondaryLabel
        symbol.tintColor = emphasized ? StreamTheme.selectedForeground : StreamTheme.accent
        indicator.tintColor = emphasized ? StreamTheme.selectedForeground : .tertiaryLabel
    }
}
