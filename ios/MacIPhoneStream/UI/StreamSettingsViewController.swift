import UIKit

/// Content hosted inside the floating control's single native glass surface.
final class StreamSettingsViewController: UIViewController {
    var onFillChange: ((Bool) -> Void)?
    var onContinue: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var profileProvider: (() -> String)?
    private let statusText: String
    private let routeTitle: String
    private let fillsScreen: Bool
    private let canFillScreen: Bool
    private let profileText: String
    private let heading = UILabel()
    private let back = UIButton(type: .system)
    private let mainStack = UIStackView()
    private let detailsStack = UIStackView()
    private let details = UITextView()

    init(statusText: String, routeTitle: String, fullBleed: Bool, canFillScreen: Bool, profileText: String) {
        self.statusText = statusText; self.routeTitle = routeTitle
        self.fillsScreen = fullBleed; self.canFillScreen = canFillScreen; self.profileText = profileText
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 320, height: 240)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear; view.tintColor = StreamTheme.accent
        let header = UIView(); header.translatesAutoresizingMaskIntoConstraints = false
        heading.text = "串流设置"; heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.textAlignment = .center; heading.translatesAutoresizingMaskIntoConstraints = false
        let summary = UILabel(); summary.numberOfLines = 1; summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabel; summary.textAlignment = .center
        summary.text = "\(statusText) · \(routeTitle)"
        [heading, summary].forEach { $0.setContentHuggingPriority(.required, for: .vertical) }
        let titleStack = UIStackView(arrangedSubviews: [heading, summary])
        titleStack.axis = .vertical; titleStack.alignment = .center; titleStack.spacing = 4
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        back.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        back.accessibilityLabel = "返回串流设置"; back.isHidden = true
        back.addAction(UIAction { [weak self] _ in self?.showDetails(false) }, for: .touchUpInside)
        back.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(back)
        header.addSubview(titleStack); view.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.heightAnchor.constraint(equalToConstant: 44),
            titleStack.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: header.leadingAnchor, constant: 44),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -44),
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            back.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: 44), back.heightAnchor.constraint(equalToConstant: 44)
        ])
        let fillTitle = UILabel(); fillTitle.text = "铺满画面"; fillTitle.font = .systemFont(ofSize: 15)
        let fillSwitch = UISwitch(); fillSwitch.isOn = fillsScreen && canFillScreen
        fillSwitch.isEnabled = canFillScreen; fillSwitch.onTintColor = StreamTheme.accent
        fillSwitch.accessibilityLabel = "铺满画面"
        fillSwitch.addAction(UIAction { [weak self, weak fillSwitch] _ in
            guard let self, self.canFillScreen, let fillSwitch else { return }
            self.onFillChange?(fillSwitch.isOn)
        }, for: .valueChanged)
        let fillRow = UIView()
        let info = UIButton(type: .system)
        info.setImage(UIImage(systemName: "info.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)), for: .normal)
        info.accessibilityLabel = "画布信息"
        info.addAction(UIAction { [weak self] _ in self?.showDetails(true) }, for: .touchUpInside)
        [fillTitle, info, fillSwitch].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; fillRow.addSubview($0) }
        fillTitle.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            fillTitle.leadingAnchor.constraint(equalTo: fillRow.leadingAnchor),
            fillTitle.centerYAnchor.constraint(equalTo: fillRow.centerYAnchor),
            info.leadingAnchor.constraint(equalTo: fillTitle.trailingAnchor, constant: 2),
            info.centerYAnchor.constraint(equalTo: fillRow.centerYAnchor),
            info.widthAnchor.constraint(equalToConstant: 36), info.heightAnchor.constraint(equalToConstant: 44),
            fillSwitch.trailingAnchor.constraint(equalTo: fillRow.trailingAnchor),
            fillSwitch.centerYAnchor.constraint(equalTo: fillRow.centerYAnchor)
        ])
        let note = UILabel(); note.numberOfLines = 2; note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabel
        note.text = canFillScreen ? "关闭后保留对称边距，不改变窗口内容位置。" : "窗口画面比例不匹配，当前完整显示画面。"
        let exit = action("退出串流", image: nil) { [weak self] in self?.onDisconnect?() }
        var exitConfig = UIButton.Configuration.filled(); exitConfig.title = "退出串流"
        exitConfig.baseBackgroundColor = .systemRed; exitConfig.baseForegroundColor = .white
        exitConfig.cornerStyle = .large; exit.configuration = exitConfig
        [fillRow, note, exit].forEach { mainStack.addArrangedSubview($0) }
        mainStack.axis = .vertical; mainStack.spacing = 8
        fillRow.heightAnchor.constraint(equalToConstant: 44).isActive = true
        exit.heightAnchor.constraint(equalToConstant: 44).isActive = true
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.isEditable = false; details.isSelectable = true; details.backgroundColor = .clear
        detailsStack.addArrangedSubview(details)
        detailsStack.axis = .vertical; detailsStack.spacing = 8; detailsStack.isHidden = true
        let contentInset: CGFloat = 18
        for content in [mainStack, detailsStack] {
            content.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: contentInset),
                content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -contentInset),
                content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4)
            ])
        }
        mainStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -contentInset).isActive = true
        detailsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -contentInset).isActive = true
    }
    private func action(_ title: String, image: String?, handler: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain(); config.title = title
        config.image = image.flatMap { UIImage(systemName: $0) }; config.imagePadding = 6
        config.baseForegroundColor = StreamTheme.accent
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes; result.font = .systemFont(ofSize: 14); return result
        }
        button.configuration = config
        button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return button
    }
    private func showDetails(_ showing: Bool) {
        heading.text = showing ? "画布信息" : "串流设置"
        back.isHidden = !showing; mainStack.isHidden = showing; detailsStack.isHidden = !showing
        if showing { details.text = profileProvider?() ?? profileText }
    }
    override func accessibilityPerformEscape() -> Bool { onContinue?(); return true }
}
