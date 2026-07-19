import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var manager = SerialPortManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            controls
            Divider()
            logView
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 560)
        .onAppear { manager.scanPorts() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("OBD2Tester")
                .font(.title2)
                .bold()
            Spacer()
            statusIndicator
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.subheadline)
        }
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

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Port", selection: $manager.selectedPort) {
                    if manager.availablePorts.isEmpty {
                        Text("No ports found").tag(String?.none)
                    }
                    ForEach(manager.availablePorts, id: \.self) { port in
                        Text(port).tag(String?.some(port))
                    }
                }
                .frame(minWidth: 260)
                .disabled(manager.isConnected)

                Button {
                    manager.scanPorts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(manager.isConnected)
                .help("Refresh port list")
            }

            Picker("Baud rate", selection: $manager.baudRate) {
                ForEach(SerialPortManager.candidateBaudRates, id: \.self) { rate in
                    Text(rate == SerialPortManager.defaultBaudRate ? "\(rate) (ELM327 default)" : "\(rate)")
                        .tag(rate)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260, alignment: .leading)
            .disabled(manager.isConnected)

            HStack {
                Button(manager.isConnected ? "Disconnect" : "Connect") {
                    if manager.isConnected {
                        manager.disconnect()
                    } else {
                        manager.connect()
                    }
                }
                .disabled(!manager.isConnected && manager.selectedPort == nil)

                Button("Run Diagnostic Test") {
                    Task { await manager.runDiagnostics() }
                }
                .disabled(!manager.isConnected || manager.isRunningDiagnostic)

                if manager.isRunningDiagnostic {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                }

                Spacer()
            }
        }
    }

    // MARK: - Log

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Log")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(manager.log) { entry in
                            logRow(entry).id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
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
        .frame(maxHeight: .infinity)
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
    }

    private func logColor(for direction: LogEntry.Direction) -> Color {
        switch direction {
        case .sent: return .blue
        case .received: return .green
        case .info: return .secondary
        }
    }
}

#Preview {
    ContentView()
}
