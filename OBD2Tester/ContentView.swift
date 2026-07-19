import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark

    var id: String { rawValue }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
    var icon: String { self == .light ? "sun.max.fill" : "moon.fill" }
}

private let driverDownloadURL = URL(string: "https://ftdichip.com/drivers/vcp-drivers/")!

struct ContentView: View {
    @StateObject private var manager = SerialPortManager()
    @AppStorage("obd2tester.theme") private var themeRaw: String = AppTheme.light.rawValue
    @Environment(\.openWindow) private var openWindow

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .light }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            connectionCard
            actionsCard
            logCard
            driverCard
        }
        .padding(18)
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 640, minHeight: 820, idealHeight: 900, maxHeight: 1200)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(theme.colorScheme)
        .onAppear { manager.scanPorts() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("OBD2Tester")
                    .font(.title2.bold())
                Text("USB OBD2 / ELM327 connection tester for macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    openWindow(id: "about")
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.bordered)
                .help("About OBD2Tester")

                themeToggle
            }
        }
    }

    private var themeToggle: some View {
        Picker("Appearance", selection: $themeRaw) {
            ForEach(AppTheme.allCases) { t in
                Image(systemName: t.icon).tag(t.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 84)
    }

    // MARK: - Connection card

    private var connectionCard: some View {
        card(title: "Connection", systemImage: "cable.connector") {
            statusPill

            HStack(spacing: 8) {
                Picker("Port", selection: $manager.selectedPort) {
                    if manager.availablePorts.isEmpty {
                        Text("No ports found").tag(String?.none)
                    }
                    ForEach(manager.availablePorts, id: \.self) { port in
                        Text(port).tag(String?.some(port))
                    }
                }
                .labelsHidden()
                .disabled(manager.isConnected)

                Button {
                    manager.scanPorts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(manager.isConnected)
                .help("Refresh port list")
            }

            Picker("Baud rate", selection: $manager.baudRate) {
                ForEach(SerialPortManager.candidateBaudRates, id: \.self) { rate in
                    Text(baudLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.menu)
            .disabled(manager.isConnected)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(statusColor.opacity(0.15)))
        .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch manager.outcome {
        case .idle: return .gray
        case .testing: return .yellow
        case .noResponse: return .red
        case .noData: return .orange
        case .success: return .green
        }
    }

    private var statusText: String {
        switch manager.outcome {
        case .idle: return manager.isConnected ? "Connected" : "Not connected"
        case .testing: return "Testing..."
        case .noResponse: return "No response from adapter"
        case .noData: return "Adapter OK — ECU: NO DATA"
        case .success(let detail): return "ECU confirmed (\(detail))"
        }
    }

    private func baudLabel(_ rate: Int32) -> String {
        switch rate {
        case SerialPortManager.defaultBaudRate: return "\(rate) (ELM327 default)"
        case 115200: return "\(rate) (vLinker FS)"
        default: return "\(rate)"
        }
    }

    // MARK: - Actions card

    private var actionsCard: some View {
        card(title: "Actions", systemImage: "bolt.fill") {
            HStack(spacing: 10) {
                Button(manager.isConnected ? "Disconnect" : "Connect") {
                    if manager.isConnected {
                        manager.disconnect()
                    } else {
                        manager.connect()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!manager.isConnected && manager.selectedPort == nil)

                Button {
                    Task { await manager.runDiagnostics() }
                } label: {
                    HStack(spacing: 6) {
                        if manager.isRunningDiagnostic {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Run Diagnostic Test")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!manager.isConnected || manager.isRunningDiagnostic)

                Spacer()
            }
        }
    }

    // MARK: - Log card

    private var logCard: some View {
        card(title: "Log", systemImage: "text.alignleft") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(manager.log) { entry in
                            logRow(entry).id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 220)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .onChange(of: manager.log.count) { _ in
                    if let last = manager.log.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.direction == .sent ? ">" : entry.direction == .received ? "<" : "*")
                .foregroundStyle(logColor(for: entry.direction))
            Text(entry.text)
                .foregroundStyle(entry.direction == .info ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }

    private func logColor(for direction: LogEntry.Direction) -> Color {
        switch direction {
        case .sent: return .blue
        case .received: return .green
        case .info: return .secondary
        }
    }

    // MARK: - Driver card

    private var driverCard: some View {
        card(title: "Driver", systemImage: "arrow.down.circle") {
            Text("If you can't see your OBD2 adapter in the port list above, install the FTDI VCP driver for macOS from FTDI's site below, then unplug and reconnect the vLinker FS. It will then show up as /dev/cu.usbserial-XXXXXXXX.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                NSWorkspace.shared.open(driverDownloadURL)
            } label: {
                Label("Download FTDI VCP Driver", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Card container

    private func card<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

#Preview {
    ContentView()
}
