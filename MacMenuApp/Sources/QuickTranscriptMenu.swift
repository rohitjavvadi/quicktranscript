import AppKit
import AVFoundation
import Foundation

private func appSupportURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("QuickTranscript")
}

private func pythonExecutablePath() -> String {
    appSupportURL().appendingPathComponent(".venv/bin/python").path
}

private func watcherScriptPath() -> String {
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("transcribe_watch.py"),
       FileManager.default.fileExists(atPath: bundled.path) {
        return bundled.path
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("scripts/transcribe_watch.py")
        .path
}

struct SessionInfo {
    let url: URL
    let name: String
    let createdAt: Date
    let audioChunks: Int
    let transcriptBytes: Int64
    let audioBytes: Int64

    var transcriptURL: URL {
        url.appendingPathComponent("transcript.txt")
    }

    var estimatedDuration: TimeInterval {
        TimeInterval(audioChunks * 30)
    }

    var menuTitle: String {
        "\(shortDate(createdAt)) - \(audioChunks) chunks - \(formatBytes(transcriptBytes)) text"
    }

    var details: String {
        """
        Session: \(name)
        Started: \(fullDate(createdAt))
        Estimated duration: \(formatDuration(estimatedDuration))
        Audio chunks: \(audioChunks)
        Audio size: \(formatBytes(audioBytes))
        Transcript size: \(formatBytes(transcriptBytes))
        Folder: \(url.path)
        """
    }
}

private func meetingRootURL() -> URL {
    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    return desktop.appendingPathComponent("MeetingTranscripts")
}

private func loadSessions(limit: Int = 12) -> [SessionInfo] {
    let root = meetingRootURL()
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    let sessions = entries.compactMap { url -> SessionInfo? in
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }

        let files = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let cafFiles = files.filter { $0.pathExtension == "caf" }
        let transcript = url.appendingPathComponent("transcript.txt")
        let transcriptBytes = Int64((try? transcript.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let audioBytes = cafFiles.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let date = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
        return SessionInfo(
            url: url,
            name: url.lastPathComponent,
            createdAt: date,
            audioChunks: cafFiles.count,
            transcriptBytes: transcriptBytes,
            audioBytes: audioBytes
        )
    }

    return Array(sessions.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
}

private func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, h:mm a"
    return formatter.string(from: date)
}

private func fullDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    return formatter.string(from: date)
}

private func formatDuration(_ duration: TimeInterval) -> String {
    let minutes = Int(duration / 60)
    if minutes < 1 {
        return "< 1 min"
    }
    let hours = minutes / 60
    let remainder = minutes % 60
    if hours > 0 {
        return "\(hours)h \(remainder)m"
    }
    return "\(minutes)m"
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

final class ChunkRecorder {
    private let engine = AVAudioEngine()
    private let outputDirectory: URL
    private let chunkSeconds: TimeInterval
    private let markerQueue = DispatchQueue(label: "quick-transcript.markers")

    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var chunkStart = Date()
    private var chunkIndex = 0
    private var isStopping = false

    init(outputDirectory: URL, chunkSeconds: TimeInterval = 30) {
        self.outputDirectory = outputDirectory
        self.chunkSeconds = chunkSeconds
    }

    func start() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        try openNextChunk(format: format)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            if Date().timeIntervalSince(self.chunkStart) >= self.chunkSeconds {
                do {
                    try self.rotateChunk(format: format)
                } catch {
                    NSLog("QuickTranscript rotate failed: \(error.localizedDescription)")
                }
            }

            do {
                try self.currentFile?.write(from: buffer)
            } catch {
                NSLog("QuickTranscript write failed: \(error.localizedDescription)")
            }
        }

        try engine.start()
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        closeCurrentChunk()
    }

    private func openNextChunk(format: AVAudioFormat) throws {
        chunkIndex += 1
        chunkStart = Date()
        let name = String(format: "chunk-%04d.caf", chunkIndex)
        let url = outputDirectory.appendingPathComponent(name)
        currentFile = try AVAudioFile(forWriting: url, settings: format.settings)
        currentURL = url
    }

    private func rotateChunk(format: AVAudioFormat) throws {
        closeCurrentChunk()
        try openNextChunk(format: format)
    }

    private func closeCurrentChunk() {
        guard let url = currentURL else { return }
        currentFile = nil
        currentURL = nil

        let doneURL = outputDirectory.appendingPathComponent(url.lastPathComponent + ".done")
        markerQueue.async {
            FileManager.default.createFile(atPath: doneURL.path, contents: Data())
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var startStopItem = NSMenuItem()
    private var statusItemText = NSMenuItem()
    private var openTranscriptItem = NSMenuItem()
    private var openFolderItem = NSMenuItem()
    private var copyPathItem = NSMenuItem()

    private var recorder: ChunkRecorder?
    private var watcher: Process?
    private var currentSessionURL: URL?
    private var isRecording = false
    private var controlWindow: NSWindow?
    private var controlStatusLabel: NSTextField?
    private var controlSessionLabel: NSTextField?
    private var controlStartStopButton: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("QuickTranscript applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.regular)
        configureApplicationMenu()
        configureStatusItem()
        rebuildMenu()
        DispatchQueue.main.async { [weak self] in
            self?.showControlWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRecording()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlWindow()
        return true
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "QuickTranscript")

        let showItem = NSMenuItem(title: "Show QuickTranscript", action: #selector(showQuickTranscript), keyEquivalent: "")
        showItem.target = self
        appMenu.addItem(showItem)

        let startStop = NSMenuItem(
            title: isRecording ? "Stop Recording" : "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: "r"
        )
        startStop.target = self
        appMenu.addItem(startStop)

        let openAll = NSMenuItem(title: "Open All Recordings", action: #selector(openAllRecordings), keyEquivalent: "")
        openAll.target = self
        appMenu.addItem(openAll)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit QuickTranscript", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        statusItem.length = NSStatusItem.squareLength
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "QuickTranscript")
                ?? NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "QuickTranscript")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "QuickTranscript"
        }
        statusItem.menu = menu
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        configureApplicationMenu()
        updateControlWindow()

        statusItemText = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        menu.addItem(statusItemText)
        menu.addItem(.separator())

        startStopItem = NSMenuItem(
            title: isRecording ? "Stop Recording" : "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        startStopItem.target = self
        menu.addItem(startStopItem)

        openTranscriptItem = NSMenuItem(title: "Open Transcript", action: #selector(openTranscript), keyEquivalent: "")
        openTranscriptItem.target = self
        openTranscriptItem.isEnabled = currentSessionURL != nil
        menu.addItem(openTranscriptItem)

        openFolderItem = NSMenuItem(title: "Open Session Folder", action: #selector(openSessionFolder), keyEquivalent: "")
        openFolderItem.target = self
        openFolderItem.isEnabled = currentSessionURL != nil
        menu.addItem(openFolderItem)

        copyPathItem = NSMenuItem(title: "Copy Transcript Path", action: #selector(copyTranscriptPath), keyEquivalent: "")
        copyPathItem.target = self
        copyPathItem.isEnabled = currentSessionURL != nil
        menu.addItem(copyPathItem)

        menu.addItem(.separator())

        addHistoryMenu()

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit QuickTranscript", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addHistoryMenu() {
        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        let sessions = loadSessions()

        if sessions.isEmpty {
            let emptyItem = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            historyMenu.addItem(emptyItem)
        } else {
            for session in sessions {
                let item = NSMenuItem(title: session.menuTitle, action: nil, keyEquivalent: "")
                item.submenu = makeSessionMenu(session)
                historyMenu.addItem(item)
            }
            historyMenu.addItem(.separator())
            let openAllItem = NSMenuItem(title: "Open All Recordings", action: #selector(openAllRecordings), keyEquivalent: "")
            openAllItem.target = self
            historyMenu.addItem(openAllItem)
        }

        historyItem.submenu = historyMenu
        menu.addItem(historyItem)
    }

    private func makeSessionMenu(_ session: SessionInfo) -> NSMenu {
        let submenu = NSMenu()

        let detailItem = NSMenuItem(title: "Show Info", action: #selector(showSessionInfo(_:)), keyEquivalent: "")
        detailItem.target = self
        detailItem.representedObject = session
        submenu.addItem(detailItem)

        let transcriptItem = NSMenuItem(title: "Open Transcript", action: #selector(openHistoryTranscript(_:)), keyEquivalent: "")
        transcriptItem.target = self
        transcriptItem.representedObject = session
        transcriptItem.isEnabled = FileManager.default.fileExists(atPath: session.transcriptURL.path)
        submenu.addItem(transcriptItem)

        let folderItem = NSMenuItem(title: "Open Folder", action: #selector(openHistoryFolder(_:)), keyEquivalent: "")
        folderItem.target = self
        folderItem.representedObject = session
        submenu.addItem(folderItem)

        let copyItem = NSMenuItem(title: "Copy Transcript Path", action: #selector(copyHistoryTranscriptPath(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = session
        copyItem.isEnabled = FileManager.default.fileExists(atPath: session.transcriptURL.path)
        submenu.addItem(copyItem)

        return submenu
    }

    private var statusTitle: String {
        if isRecording {
            return "Recording to \(currentSessionURL?.lastPathComponent ?? "session")"
        }
        if currentSessionURL != nil {
            return "Stopped"
        }
        return "Ready"
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    @objc private func showQuickTranscript() {
        showControlWindow()
    }

    private func showControlWindow() {
        NSLog("QuickTranscript showControlWindow")
        if let controlWindow {
            controlWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 230),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickTranscript"
        window.center()
        window.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "QuickTranscript")
        title.font = .boldSystemFont(ofSize: 20)

        let status = NSTextField(labelWithString: statusTitle)
        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor
        controlStatusLabel = status

        let session = NSTextField(labelWithString: currentSessionURL?.path ?? "No active session")
        session.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        session.textColor = .secondaryLabelColor
        session.lineBreakMode = .byTruncatingMiddle
        controlSessionLabel = session

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let startStop = NSButton(title: isRecording ? "Stop Recording" : "Start Recording", target: self, action: #selector(toggleRecording))
        startStop.bezelStyle = .rounded
        controlStartStopButton = startStop

        let transcript = NSButton(title: "Open Transcript", target: self, action: #selector(openTranscript))
        transcript.bezelStyle = .rounded

        let folder = NSButton(title: "Open Folder", target: self, action: #selector(openSessionFolder))
        folder.bezelStyle = .rounded

        buttons.addArrangedSubview(startStop)
        buttons.addArrangedSubview(transcript)
        buttons.addArrangedSubview(folder)

        let history = NSButton(title: "Open All Recordings", target: self, action: #selector(openAllRecordings))
        history.bezelStyle = .rounded

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(session)
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(history)

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            session.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        controlWindow = window
        updateControlWindow()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateControlWindow() {
        controlStatusLabel?.stringValue = statusTitle
        controlSessionLabel?.stringValue = currentSessionURL?.path ?? "No active session"
        controlStartStopButton?.title = isRecording ? "Stop Recording" : "Start Recording"
    }

    private func startRecording() {
        guard !isRecording else { return }

        let pythonPath = pythonExecutablePath()
        let watcherPath = watcherScriptPath()

        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            showAlert(
                "Missing Python environment",
                "Install the local Whisper runtime first:\n\n/Applications/QuickTranscript.app/Contents/Resources/setup_runtime.sh\n\nExpected Python at:\n\(pythonPath)"
            )
            return
        }

        guard FileManager.default.fileExists(atPath: watcherPath) else {
            showAlert("Missing transcriber", "Expected transcriber script at:\n\(watcherPath)")
            return
        }

        requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.showAlert(
                    "Microphone access needed",
                    "Open System Settings > Privacy & Security > Microphone, then enable QuickTranscript."
                )
                return
            }

            do {
                let sessionURL = try self.makeSession()
                try self.startWatcher(sessionURL: sessionURL)

                let recorder = ChunkRecorder(outputDirectory: sessionURL)
                try recorder.start()

                self.currentSessionURL = sessionURL
                self.recorder = recorder
                self.isRecording = true
                self.rebuildMenu()
            } catch {
                self.showAlert("Could not start recording", error.localizedDescription)
                self.stopRecording()
            }
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        rebuildMenu()

        guard let sessionURL = currentSessionURL else {
            stopWatcher()
            return
        }

        stopWatcher()
        runCatchupTranscription(sessionURL: sessionURL)
        rebuildMenu()
    }

    private func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }

    private func makeSession() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let sessionURL = desktop
            .appendingPathComponent("MeetingTranscripts")
            .appendingPathComponent("meeting-\(formatter.string(from: Date()))")

        try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        let transcript = sessionURL.appendingPathComponent("transcript.txt")
        let header = "QuickTranscript session started \(Date())\n\n"
        try header.write(to: transcript, atomically: true, encoding: .utf8)
        return sessionURL
    }

    private func startWatcher(sessionURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonExecutablePath())
        process.arguments = [watcherScriptPath(), sessionURL.path]
        process.currentDirectoryURL = appSupportURL()
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "PYTHONUNBUFFERED": "1"
        ]

        let logURL = sessionURL.appendingPathComponent("transcriber.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        watcher = process
    }

    private func stopWatcher() {
        watcher?.terminate()
        watcher = nil
    }

    private func runCatchupTranscription(sessionURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonExecutablePath())
        process.arguments = [watcherScriptPath(), sessionURL.path, "--once"]
        process.currentDirectoryURL = appSupportURL()
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "PYTHONUNBUFFERED": "1"
        ]

        do {
            try process.run()
        } catch {
            NSLog("QuickTranscript catch-up failed: \(error.localizedDescription)")
        }
    }

    @objc private func openTranscript() {
        guard let url = currentSessionURL?.appendingPathComponent("transcript.txt") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSessionFolder() {
        guard let url = currentSessionURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyTranscriptPath() {
        guard let path = currentSessionURL?.appendingPathComponent("transcript.txt").path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func openAllRecordings() {
        NSWorkspace.shared.open(meetingRootURL())
    }

    @objc private func showSessionInfo(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionInfo else { return }
        showAlert("Recording Info", session.details)
    }

    @objc private func openHistoryTranscript(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionInfo else { return }
        NSWorkspace.shared.open(session.transcriptURL)
    }

    @objc private func openHistoryFolder(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionInfo else { return }
        NSWorkspace.shared.open(session.url)
    }

    @objc private func copyHistoryTranscriptPath(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionInfo else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.transcriptURL.path, forType: .string)
    }

    @objc private func quit() {
        stopRecording()
        NSApp.terminate(nil)
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private let app = NSApplication.shared
private let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
