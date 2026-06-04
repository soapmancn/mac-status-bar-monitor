import AppKit
import Darwin
import Foundation
import ServiceManagement

struct SystemMetrics {
    let cpuPercent: Double
    let memoryUsed: UInt64
    let memoryTotal: UInt64
    let memoryPercent: Double
    let diskUsed: UInt64
    let diskTotal: UInt64
    let diskPercent: Double
    let uploadBytesPerSecond: Double
    let downloadBytesPerSecond: Double
}

struct NetworkSnapshot {
    let receivedBytes: UInt64
    let sentBytes: UInt64
    let timestamp: Date
}

final class SystemSampler {
    private var previousCPUTicks: [UInt64]?
    private var previousNetworkSnapshot: NetworkSnapshot?

    func sample() -> SystemMetrics {
        let cpuPercent = readCPUPercent()
        let memory = readMemoryUsage()
        let disk = readDiskUsage()
        let network = readNetworkRate()

        return SystemMetrics(
            cpuPercent: cpuPercent,
            memoryUsed: memory.used,
            memoryTotal: memory.total,
            memoryPercent: memory.percent,
            diskUsed: disk.used,
            diskTotal: disk.total,
            diskPercent: disk.percent,
            uploadBytesPerSecond: network.upload,
            downloadBytesPerSecond: network.download
        )
    }

    private func readCPUPercent() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        let ticks = [
            UInt64(info.cpu_ticks.0),
            UInt64(info.cpu_ticks.1),
            UInt64(info.cpu_ticks.2),
            UInt64(info.cpu_ticks.3)
        ]

        defer {
            previousCPUTicks = ticks
        }

        guard let previousCPUTicks else {
            return 0
        }

        let deltas = zip(ticks, previousCPUTicks).map { current, previous in
            current >= previous ? current - previous : current
        }

        let user = deltas[Int(CPU_STATE_USER)]
        let system = deltas[Int(CPU_STATE_SYSTEM)]
        let nice = deltas[Int(CPU_STATE_NICE)]
        let idle = deltas[Int(CPU_STATE_IDLE)]
        let total = user + system + nice + idle

        guard total > 0 else {
            return 0
        }

        return (Double(total - idle) / Double(total)) * 100
    }

    private func readMemoryUsage() -> (used: UInt64, total: UInt64, percent: Double) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let hostPort = mach_host_self()

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(hostPort, HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            let total = ProcessInfo.processInfo.physicalMemory
            return (0, total, 0)
        }

        var pageSize = vm_size_t()
        host_page_size(hostPort, &pageSize)

        let total = ProcessInfo.processInfo.physicalMemory
        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let used = min(total, usedPages * UInt64(pageSize))
        let percent = total > 0 ? (Double(used) / Double(total)) * 100 : 0

        return (used, total, percent)
    }

    private func readDiskUsage() -> (used: UInt64, total: UInt64, percent: Double) {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
            guard
                let total = attributes[.systemSize] as? NSNumber,
                let free = attributes[.systemFreeSize] as? NSNumber
            else {
                return (0, 0, 0)
            }

            let totalBytes = total.uint64Value
            let freeBytes = free.uint64Value
            let usedBytes = totalBytes > freeBytes ? totalBytes - freeBytes : 0
            let percent = totalBytes > 0 ? (Double(usedBytes) / Double(totalBytes)) * 100 : 0

            return (usedBytes, totalBytes, percent)
        } catch {
            return (0, 0, 0)
        }
    }

    private func readNetworkRate() -> (upload: Double, download: Double) {
        let snapshot = readNetworkSnapshot()
        defer {
            previousNetworkSnapshot = snapshot
        }

        guard let previousNetworkSnapshot else {
            return (0, 0)
        }

        let interval = max(snapshot.timestamp.timeIntervalSince(previousNetworkSnapshot.timestamp), 0.1)
        let receivedDelta = byteDelta(current: snapshot.receivedBytes, previous: previousNetworkSnapshot.receivedBytes)
        let sentDelta = byteDelta(current: snapshot.sentBytes, previous: previousNetworkSnapshot.sentBytes)

        return (
            upload: Double(sentDelta) / interval,
            download: Double(receivedDelta) / interval
        )
    }

    private func readNetworkSnapshot() -> NetworkSnapshot {
        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return NetworkSnapshot(receivedBytes: 0, sentBytes: 0, timestamp: Date())
        }

        defer {
            freeifaddrs(interfaces)
        }

        for pointer in sequence(first: firstInterface, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee

            guard
                let address = interface.ifa_addr,
                address.pointee.sa_family == UInt8(AF_LINK),
                let data = interface.ifa_data
            else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            let flags = Int32(interface.ifa_flags)

            guard !name.hasPrefix("lo"), (flags & IFF_UP) != 0 else {
                continue
            }

            let networkData = data.assumingMemoryBound(to: if_data.self).pointee
            receivedBytes += UInt64(networkData.ifi_ibytes)
            sentBytes += UInt64(networkData.ifi_obytes)
        }

        return NetworkSnapshot(receivedBytes: receivedBytes, sentBytes: sentBytes, timestamp: Date())
    }

    private func byteDelta(current: UInt64, previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : current
    }
}

final class ByteFormatter {
    func storage(_ bytes: UInt64) -> String {
        format(Double(bytes), suffix: "")
    }

    func rate(_ bytesPerSecond: Double) -> String {
        format(bytesPerSecond, suffix: "/s")
    }

    private func format(_ bytes: Double, suffix: String) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = max(bytes, 0)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return String(format: "%.0f%@%@", value, units[unitIndex], suffix)
        }

        if value >= 100 {
            return String(format: "%.0f%@%@", value, units[unitIndex], suffix)
        }

        return String(format: "%.1f%@%@", value, units[unitIndex], suffix)
    }
}

@MainActor
final class MonitorStatusView: NSView {
    static let fixedWidth: CGFloat = 166
    static let fixedHeight: CGFloat = 24

    private var metrics: SystemMetrics?

    private let metricFont = NSFont.menuBarFont(ofSize: 0)
    private let networkArrowFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private let networkValueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    private let textColor = NSColor.labelColor

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.fixedWidth, height: Self.fixedHeight)
    }

    func update(metrics: SystemMetrics, tooltip: String) {
        self.metrics = metrics
        self.toolTip = tooltip
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let metrics else {
            drawPlaceholder()
            return
        }

        drawMetric(label: "C", value: percent(metrics.cpuPercent), x: 2)
        drawMetric(label: "M", value: percent(metrics.memoryPercent), x: 43)
        drawMetric(label: "D", value: percent(metrics.diskPercent), x: 84)
        drawNetwork(metrics: metrics)
    }

    private func drawPlaceholder() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: metricFont,
            .foregroundColor: textColor
        ]
        "--%  --%  --%".draw(at: NSPoint(x: 5, y: 3), withAttributes: attributes)
    }

    private func drawMetric(label: String, value: String, x: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: metricFont,
            .foregroundColor: textColor
        ]

        "\(label)\(value)".draw(
            in: NSRect(x: x, y: 2.4, width: 45, height: 17),
            withAttributes: attributes
        )
    }

    private func drawNetwork(metrics: SystemMetrics) {
        drawNetworkRow(arrow: "↑", value: fixedRate(metrics.uploadBytesPerSecond), y: 0.4)
        drawNetworkRow(arrow: "↓", value: fixedRate(metrics.downloadBytesPerSecond), y: 11.3)
    }

    private func drawNetworkRow(arrow: String, value: String, y: CGFloat) {
        let arrowAttributes: [NSAttributedString.Key: Any] = [
            .font: networkArrowFont,
            .foregroundColor: textColor
        ]

        let valueStyle = NSMutableParagraphStyle()
        valueStyle.alignment = .right

        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: networkValueFont,
            .foregroundColor: textColor,
            .paragraphStyle: valueStyle
        ]

        arrow.draw(
            in: NSRect(x: 126, y: y - 0.3, width: 7, height: 11),
            withAttributes: arrowAttributes
        )
        value.draw(
            in: NSRect(x: 134, y: y, width: 30, height: 11),
            withAttributes: valueAttributes
        )
    }

    private func percent(_ percent: Double) -> String {
        String(format: "%.0f%%", min(max(percent, 0), 100))
    }

    private func fixedRate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = max(bytesPerSecond, 0)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let raw: String
        if unitIndex == 0 {
            raw = String(format: "%.0f%@", min(value, 999), units[unitIndex])
        } else if value < 10 {
            raw = String(format: "%.1f%@", value, units[unitIndex])
        } else if value < 100 {
            raw = String(format: "%.0f%@", value, units[unitIndex])
        } else {
            raw = String(format: "%.0f%@", min(value, 999), units[unitIndex])
        }

        return raw
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sampler = SystemSampler()
    private let byteFormatter = ByteFormatter()
    private let statusView = MonitorStatusView()
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var refreshInterval: TimeInterval = {
        let storedInterval = UserDefaults.standard.double(forKey: "refreshInterval")
        let supportedIntervals: [TimeInterval] = [1, 2, 5, 10, 30]
        return supportedIntervals.contains(storedInterval) ? storedInterval : 2
    }()
    private let refreshIntervalOptions: [TimeInterval] = [1, 2, 5, 10, 30]
    private var refreshIntervalMenuItems: [NSMenuItem] = []

    private let cpuMenuItem = NSMenuItem()
    private let memoryMenuItem = NSMenuItem()
    private let diskMenuItem = NSMenuItem()
    private let networkMenuItem = NSMenuItem()
    private let updatedMenuItem = NSMenuItem()
    private let launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        refresh()
        startTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    @objc private func refresh() {
        let metrics = sampler.sample()

        statusView.update(metrics: metrics, tooltip: tooltip(for: metrics))

        cpuMenuItem.title = String(format: "CPU: %.1f%%", metrics.cpuPercent)
        memoryMenuItem.title = String(
            format: "Memory: %.1f%% (%@ / %@)",
            metrics.memoryPercent,
            byteFormatter.storage(metrics.memoryUsed),
            byteFormatter.storage(metrics.memoryTotal)
        )
        diskMenuItem.title = String(
            format: "Disk: %.1f%% (%@ / %@)",
            metrics.diskPercent,
            byteFormatter.storage(metrics.diskUsed),
            byteFormatter.storage(metrics.diskTotal)
        )
        networkMenuItem.title = "Network: U \(byteFormatter.rate(metrics.uploadBytesPerSecond))  D \(byteFormatter.rate(metrics.downloadBytesPerSecond))"
        updatedMenuItem.title = "Updated: \(Self.timeFormatter.string(from: Date()))"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? NSNumber else {
            return
        }

        refreshInterval = interval.doubleValue
        UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
        updateRefreshIntervalMenuState()
        startTimer()
        refresh()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showLaunchAtLoginError(error)
        }

        updateLaunchAtLoginMenuState()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: MonitorStatusView.fixedWidth)

        if let button = item.button {
            button.title = ""
            button.image = nil
            statusView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(statusView)

            NSLayoutConstraint.activate([
                statusView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                statusView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                statusView.topAnchor.constraint(equalTo: button.topAnchor),
                statusView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }

        statusItem = item
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(cpuMenuItem)
        menu.addItem(memoryMenuItem)
        menu.addItem(diskMenuItem)
        menu.addItem(networkMenuItem)
        menu.addItem(updatedMenuItem)
        menu.addItem(.separator())

        let refreshRateItem = NSMenuItem(title: "Refresh Rate", action: nil, keyEquivalent: "")
        let refreshRateMenu = NSMenu(title: "Refresh Rate")
        refreshIntervalMenuItems = refreshIntervalOptions.map { interval in
            let item = NSMenuItem(title: Self.intervalTitle(for: interval), action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: interval)
            refreshRateMenu.addItem(item)
            return item
        }
        refreshRateItem.submenu = refreshRateMenu
        menu.addItem(refreshRateItem)

        launchAtLoginMenuItem.action = #selector(toggleLaunchAtLogin)
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        updateRefreshIntervalMenuState()
        updateLaunchAtLoginMenuState()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginMenuState()
    }

    private func startTimer() {
        timer?.invalidate()

        let timer = Timer(timeInterval: refreshInterval, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateRefreshIntervalMenuState() {
        for item in refreshIntervalMenuItems {
            guard let interval = item.representedObject as? NSNumber else {
                item.state = .off
                continue
            }

            item.state = interval.doubleValue == refreshInterval ? .on : .off
        }
    }

    private func updateLaunchAtLoginMenuState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .on
        case .requiresApproval:
            launchAtLoginMenuItem.title = "Launch at Login (Requires Approval)"
            launchAtLoginMenuItem.state = .off
        default:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .off
        }
    }

    private func showLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Launch at Login"
        alert.informativeText = "Unable to update this setting: \(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func intervalTitle(for interval: TimeInterval) -> String {
        if interval < 1 {
            return String(format: "%.1f Seconds", interval)
        }

        if interval == 1 {
            return "1 Second"
        }

        return String(format: "%.0f Seconds", interval)
    }

    private func tooltip(for metrics: SystemMetrics) -> String {
        [
            String(format: "CPU %.1f%%", metrics.cpuPercent),
            String(
                format: "Memory %.1f%% (%@ / %@)",
                metrics.memoryPercent,
                byteFormatter.storage(metrics.memoryUsed),
                byteFormatter.storage(metrics.memoryTotal)
            ),
            String(
                format: "Disk %.1f%% (%@ / %@)",
                metrics.diskPercent,
                byteFormatter.storage(metrics.diskUsed),
                byteFormatter.storage(metrics.diskTotal)
            ),
            "Upload \(byteFormatter.rate(metrics.uploadBytesPerSecond))",
            "Download \(byteFormatter.rate(metrics.downloadBytesPerSecond))"
        ].joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
