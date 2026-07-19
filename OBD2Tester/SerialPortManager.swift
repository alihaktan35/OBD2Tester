import Foundation
import Darwin

/// Connection lifecycle of the serial port itself (not the ECU).
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

/// Result of the last diagnostic run. Three meaningfully different outcomes:
/// the adapter never answered, the adapter answered but the ECU had nothing
/// to say (ignition off), or the ECU returned real data.
enum DiagnosticOutcome: Equatable {
    case idle
    case testing
    case noResponse
    case noData
    case success(detail: String)
}

struct LogEntry: Identifiable {
    enum Direction {
        case sent, received, info
    }

    let id = UUID()
    let timestamp: Date
    let direction: Direction
    let text: String
}

@MainActor
final class SerialPortManager: ObservableObject {
    static let candidateBaudRates: [Int32] = [9600, 38400, 115200]
    /// ELM327 devices default to this rate.
    static let defaultBaudRate: Int32 = 38400

    private static let portPrefixes = ["cu.usbserial", "cu.wchusbserial", "cu.SLAB_USBtoUART", "cu.usbmodem"]

    @Published private(set) var availablePorts: [String] = []
    @Published var selectedPort: String?
    @Published var baudRate: Int32 = SerialPortManager.defaultBaudRate
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var outcome: DiagnosticOutcome = .idle
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var isRunningDiagnostic = false

    var isConnected: Bool { connectionState == .connected }

    private var fileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "com.ahsdev.OBD2Tester.serial")
    private var readBuffer = Data()
    private var pendingContinuation: CheckedContinuation<String?, Never>?
    private var pendingTimeoutWorkItem: DispatchWorkItem?

    // MARK: - Port discovery

    func scanPorts() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: "/dev")) ?? []
        let matches = entries
            .filter { name in Self.portPrefixes.contains { name.hasPrefix($0) } }
            .sorted()

        availablePorts = matches
        if let selectedPort, !matches.contains(selectedPort) {
            self.selectedPort = matches.first
        } else if selectedPort == nil {
            selectedPort = matches.first
        }

        appendLog(.info, matches.isEmpty
            ? "No USB-serial ports found in /dev."
            : "Found \(matches.count) port(s): \(matches.joined(separator: ", "))")
    }

    // MARK: - Connection

    func connect() {
        guard connectionState == .disconnected else { return }
        guard let port = selectedPort else {
            appendLog(.info, "No port selected.")
            return
        }

        connectionState = .connecting
        let path = "/dev/" + port

        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            appendLog(.info, "Failed to open \(path): \(String(cString: strerror(errno)))")
            connectionState = .disconnected
            outcome = .noResponse
            return
        }

        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else {
            appendLog(.info, "tcgetattr failed on \(path): \(String(cString: strerror(errno)))")
            close(fd)
            connectionState = .disconnected
            outcome = .noResponse
            return
        }

        cfmakeraw(&tty)
        let speed = speed_t(baudRate)
        cfsetispeed(&tty, speed)
        cfsetospeed(&tty, speed)

        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tty.c_cflag &= ~tcflag_t(PARENB)
        tty.c_cflag &= ~tcflag_t(CSTOPB)
        tty.c_cflag &= ~tcflag_t(CSIZE)
        tty.c_cflag |= tcflag_t(CS8)
        tty.c_cflag &= ~tcflag_t(CRTSCTS)

        withUnsafeMutableBytes(of: &tty.c_cc) { rawPtr in
            let cc = rawPtr.bindMemory(to: cc_t.self)
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 1
        }

        guard tcsetattr(fd, TCSANOW, &tty) == 0 else {
            appendLog(.info, "tcsetattr failed on \(path): \(String(cString: strerror(errno)))")
            close(fd)
            connectionState = .disconnected
            outcome = .noResponse
            return
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        tcflush(fd, TCIOFLUSH)

        fileDescriptor = fd
        startReadSource(fd: fd)
        connectionState = .connected
        outcome = .idle
        appendLog(.info, "Connected to \(path) at \(baudRate) baud.")
    }

    func disconnect() {
        guard connectionState != .disconnected else { return }
        failPendingContinuation()
        readSource?.cancel()
        readSource = nil
        fileDescriptor = -1
        readBuffer.removeAll()
        connectionState = .disconnected
        appendLog(.info, "Disconnected.")
    }

    private func startReadSource(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 256)
            let bytesRead = read(fd, &buffer, buffer.count)
            guard bytesRead > 0, let self else { return }
            let chunk = Data(buffer[0..<bytesRead])
            Task { @MainActor in
                self.appendReceived(chunk)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        readSource = source
    }

    private func appendReceived(_ chunk: Data) {
        readBuffer.append(chunk)
        guard let text = String(data: readBuffer, encoding: .isoLatin1), text.contains(">") else { return }
        readBuffer.removeAll()
        completePending(with: text)
    }

    // MARK: - Command / response

    /// Sends a single AT/OBD2 command and waits for the ELM327 ">" prompt.
    /// Returns nil if the adapter never answered within `timeout`.
    @discardableResult
    func sendCommand(_ command: String, timeout: TimeInterval = 3.0) async -> String? {
        guard connectionState == .connected, fileDescriptor >= 0 else { return nil }

        appendLog(.sent, command)
        let fd = fileDescriptor
        let bytes = Array((command + "\r").utf8)
        let written = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else {
            appendLog(.info, "Write failed: \(String(cString: strerror(errno)))")
            return nil
        }

        let rawResponse = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            pendingContinuation = continuation
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.failPendingContinuation() }
            }
            pendingTimeoutWorkItem = workItem
            ioQueue.asyncAfter(deadline: .now() + timeout, execute: workItem)
        }

        guard let rawResponse else {
            appendLog(.received, "(no response — timeout)")
            return nil
        }

        let cleaned = Self.clean(response: rawResponse, echoing: command)
        appendLog(.received, cleaned.isEmpty ? "(empty)" : cleaned)
        return cleaned
    }

    private func completePending(with response: String) {
        pendingTimeoutWorkItem?.cancel()
        pendingTimeoutWorkItem = nil
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        continuation.resume(returning: response)
    }

    private func failPendingContinuation() {
        pendingTimeoutWorkItem?.cancel()
        pendingTimeoutWorkItem = nil
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        continuation.resume(returning: nil)
    }

    /// Strips the command echo, the trailing ">" prompt, and normalizes whitespace.
    private static func clean(response raw: String, echoing command: String) -> String {
        var text = raw
        if let range = text.range(of: command) {
            text.removeSubrange(text.startIndex..<range.upperBound)
        }
        text = text.replacingOccurrences(of: ">", with: "")
        let lines = text
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: " ")
    }

    // MARK: - Diagnostic sequence

    /// Runs ATZ -> ATE0 -> ATL0 -> ATSP0 -> 010C and classifies the result.
    func runDiagnostics() async {
        guard connectionState == .connected else {
            appendLog(.info, "Not connected — connect to a port first.")
            return
        }

        isRunningDiagnostic = true
        outcome = .testing
        defer { isRunningDiagnostic = false }

        appendLog(.info, "Starting diagnostic sequence...")

        guard await sendCommand("ATZ", timeout: 3.0) != nil else {
            outcome = .noResponse
            appendLog(.info, "No response to ATZ. Check the port, wiring, or that the FTDI VCP driver is installed.")
            return
        }
        guard await sendCommand("ATE0", timeout: 2.0) != nil else {
            outcome = .noResponse
            return
        }
        guard await sendCommand("ATL0", timeout: 2.0) != nil else {
            outcome = .noResponse
            return
        }
        guard await sendCommand("ATSP0", timeout: 2.0) != nil else {
            outcome = .noResponse
            return
        }

        guard let rpmResponse = await sendCommand("010C", timeout: 5.0) else {
            outcome = .noResponse
            appendLog(.info, "Adapter stopped responding during the PID request.")
            return
        }

        let upper = rpmResponse.uppercased()
        if upper.contains("NO DATA") {
            outcome = .noData
            appendLog(.info, "Adapter responded, but the ECU returned NO DATA. The adapter and wiring are fine — the ignition is likely off, or the car isn't connected.")
        } else if upper.contains("UNABLE TO CONNECT") {
            outcome = .noData
            appendLog(.info, "Adapter could not establish a protocol with the ECU (UNABLE TO CONNECT).")
        } else if let rpm = Self.parseRPM(from: rpmResponse) {
            outcome = .success(detail: "\(rpm) RPM")
            appendLog(.info, "ECU responded with live data. Connection fully confirmed. Engine RPM: \(rpm).")
        } else {
            outcome = .success(detail: rpmResponse)
            appendLog(.info, "ECU responded to 010C: \(rpmResponse)")
        }
    }

    /// Parses a "41 0C AA BB" response into RPM = ((A*256)+B)/4.
    private static func parseRPM(from response: String) -> Int? {
        let tokens = response
            .uppercased()
            .split(separator: " ")
            .compactMap { UInt8($0, radix: 16) }
        guard let modeIndex = tokens.firstIndex(of: 0x41),
              tokens.count > modeIndex + 3,
              tokens[modeIndex + 1] == 0x0C else {
            return nil
        }
        let a = Int(tokens[modeIndex + 2])
        let b = Int(tokens[modeIndex + 3])
        return ((a * 256) + b) / 4
    }

    // MARK: - Logging

    private func appendLog(_ direction: LogEntry.Direction, _ text: String) {
        log.append(LogEntry(timestamp: Date(), direction: direction, text: text))
        if log.count > 500 {
            log.removeFirst(log.count - 500)
        }
    }
}
