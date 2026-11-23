import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@main
struct MaciPhoneStreamApp: App {
    @NSApplicationDelegateAdaptor(HostDelegate.self) private var delegate

    var body: some Scene {
        Window("Mac iPhone Stream", id: "host") {
            HostView(model: delegate.model)
                .frame(minWidth: 530, idealWidth: 650, minHeight: 455, idealHeight: 690)
                .task { delegate.begin() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 650, height: 690)
    }
}

@MainActor
final class HostDelegate: NSObject, NSApplicationDelegate {
    let model = HostModel()
    private var started = false

    func begin() {
        guard !started else { return }
        started = true
        model.begin()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.serviceRunning else { return .terminateNow }
        model.quit { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

private struct HostView: View {
    @ObservedObject var model: HostModel
    @State private var approval: PendingPair?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                capture
                Divider()
                connection
                Divider()
                deviceTrust
            }
            .padding(28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
        .confirmationDialog(
            "核对 iPhone 上的六位配对码",
            isPresented: Binding(
                get: { approval != nil },
                set: { if !$0 { approval = nil } }
            ),
            titleVisibility: .visible,
            presenting: approval
        ) { request in
            Button("配对码相同，允许连接") {
                model.action("approve", ["pair_id": request.id, "code": request.code])
            }
            Button("取消", role: .cancel) {}
        } message: { request in
            Text("仅当 \(request.name) 显示的配对码也为 \(request.code) 时允许连接。")
        }
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("串流窗口").font(.title.bold())

            if model.permissionRequired {
                Text("请在系统设置的「屏幕与系统音频录制」中允许此 App 录制窗口。")
                    .foregroundStyle(.secondary)
                Button("请求录屏权限") { model.refreshWindows(requestPermission: true) }
                    .disabled(model.probing)
            }

            HStack(spacing: 12) {
                Picker("窗口", selection: Binding(
                    get: { model.status.windowID ?? 0 },
                    set: model.choose
                )) {
                    Text("选择窗口").tag(UInt32(0))
                    if let selected = model.status.windowID,
                       !model.visibleWindows.contains(where: { $0.id == selected }) {
                        Text("所选窗口").tag(selected)
                    }
                    ForEach(model.visibleWindows) { window in Text(window.label).tag(window.id) }
                }
                .labelsHidden()
                .accessibilityLabel("串流窗口")
                .disabled(model.permissionRequired || !model.serviceRunning || model.working)
                .frame(maxWidth: .infinity)
                Button {
                    model.refreshWindows()
                } label: {
                    Label("刷新窗口列表", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help("刷新窗口列表")
                .disabled(model.probing)
                Button("使用触控测试窗口") { model.openDemo() }
                    .disabled(model.working || !model.serviceRunning)
            }
            if let failure = model.captureError {
                Text(failure).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if model.serviceRunning {
                    if model.status.stream == "idle" {
                        Button("开始串流") { model.action("start") }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.status.windowID == nil || model.permissionRequired || model.working)
                    } else {
                        Button("停止串流") { model.action("stop") }
                            .disabled(model.working)
                    }
                } else {
                    Button("启动主机服务") { model.launch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.working)
                }
                statusIndicator
            }
            if let message = model.message {
                Text(message).foregroundStyle(.secondary)
            } else if let failure = model.status.serviceError, failure != "trust_unavailable" {
                Text("窗口采集异常。请检查所选窗口和录屏权限。").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch model.status.stream {
        case "connected":
            Label("iPhone 已连接", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case "waiting":
            Label("等待 iPhone 连接", systemImage: "iphone")
                .foregroundStyle(.secondary)
        default:
            Label("等待窗口串流", systemImage: "rectangle.on.rectangle")
                .foregroundStyle(.secondary)
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接 iPhone").font(.headline)
            if let address = model.status.connectionURL {
                HStack(alignment: .center, spacing: 16) {
                    StreamQR(value: address, accessibilityText: "串流连接二维码")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("在 iPhone 串流 App 中扫码，或复制地址。")
                            .foregroundStyle(.secondary)
                        Button("复制连接地址") { copy(address) }
                        if model.status.usb == "connected" {
                            Label("USB 通道已连接", systemImage: "cable.connector")
                                .foregroundStyle(.secondary)
                        } else if model.status.usb == "waiting" {
                            Label("USB 通道待连接", systemImage: "cable.connector")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("开始串流后，连接二维码和地址会显示在这里。")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deviceTrust: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("信任的 iPhone").font(.headline)
                Spacer()
                if model.status.pairingOpen {
                    Button("关闭配对") { model.action("close-pairing") }.disabled(model.working)
                } else {
                    Button("配对新 iPhone") { model.action("open-pairing") }
                        .disabled(model.working || !model.serviceRunning || model.status.serviceError == "trust_unavailable")
                }
            }
            if model.status.serviceError == "trust_unavailable" {
                Text("设备配对服务暂不可用。").foregroundStyle(.secondary)
            } else if let invitation = model.status.invitation, model.status.pairingOpen {
                HStack(spacing: 16) {
                    StreamQR(value: invitation, accessibilityText: "设备配对二维码")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("在 iPhone 串流 App 内扫描二维码，并核对两端显示的六位码。")
                            .foregroundStyle(.secondary)
                        Button("复制配对地址") { copy(invitation) }
                    }
                }
            } else if model.status.pending.isEmpty && model.status.devices.isEmpty {
                Text("配对一次后，可以从 iPhone 启动所选窗口的串流。")
                    .foregroundStyle(.secondary)
            }

            ForEach(model.status.pending) { request in
                HStack(spacing: 12) {
                    Label(request.name, systemImage: "iphone")
                    Text(request.code).font(.body.monospacedDigit().bold())
                    Spacer()
                    Button("拒绝") { model.action("deny", ["pair_id": request.id]) }
                    Button("核对配对码") { approval = request }.buttonStyle(.borderedProminent)
                }
                .disabled(model.working)
            }

            ForEach(model.status.devices) { phone in
                HStack {
                    Label(phone.name, systemImage: "iphone")
                    Spacer()
                    Button("取消信任") { model.action("revoke", ["device_id": phone.id]) }
                        .disabled(model.working)
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct StreamQR: View {
    let value: String
    let accessibilityText: String
    private static let context = CIContext()

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 104, height: 104)
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(accessibilityText)
        }
    }

    private var image: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return Self.context.createCGImage(output, from: output.extent)
    }
}
