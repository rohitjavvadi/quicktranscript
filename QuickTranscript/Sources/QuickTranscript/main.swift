import AVFoundation
import Foundation

final class Recorder {
    private let engine = AVAudioEngine()
    private let outputDirectory: URL
    private let chunkSeconds: TimeInterval
    private let markerQueue = DispatchQueue(label: "quick-transcript.markers")

    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var chunkStart = Date()
    private var chunkIndex = 0
    private var isStopping = false

    init(outputDirectory: URL, chunkSeconds: TimeInterval) {
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
                    fputs("Could not rotate audio chunk: \(error)\n", stderr)
                }
            }

            do {
                try self.currentFile?.write(from: buffer)
            } catch {
                fputs("Could not write audio: \(error)\n", stderr)
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

        print("Recording \(name)")
        fflush(stdout)
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

func sessionDirectory() -> URL {
    if let explicitPath = ProcessInfo.processInfo.environment["QUICK_TRANSCRIPT_SESSION_DIR"], !explicitPath.isEmpty {
        return URL(fileURLWithPath: explicitPath).standardizedFileURL
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    let sessionName = "meeting-\(formatter.string(from: Date()))"

    let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    return desktop.appendingPathComponent("MeetingTranscripts").appendingPathComponent(sessionName)
}

func requestMicrophoneAccess() -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false

    AVCaptureDevice.requestAccess(for: .audio) { allowed in
        granted = allowed
        semaphore.signal()
    }

    semaphore.wait()
    return granted
}

let outputDirectory = sessionDirectory()
print("QuickTranscript")
print("Output: \(outputDirectory.path)")
print("This records the Mac microphone. For Zoom, use laptop speakers so the mic hears the meeting.")
print("")

guard requestMicrophoneAccess() else {
    fputs("Microphone access was not granted. Enable it in System Settings > Privacy & Security > Microphone.\n", stderr)
    exit(2)
}

let recorder = Recorder(outputDirectory: outputDirectory, chunkSeconds: 30)

do {
    try recorder.start()
} catch {
    fputs("Could not start recording: \(error)\n", stderr)
    exit(1)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interruptSource.setEventHandler {
    print("")
    print("Stopping...")
    recorder.stop()
    exit(0)
}
interruptSource.resume()

let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminateSource.setEventHandler {
    recorder.stop()
    exit(0)
}
terminateSource.resume()

print("")
print("Recording. Press Enter after the meeting to stop.")
_ = readLine()

recorder.stop()
print("Stopped. Audio chunks are in: \(outputDirectory.path)")
