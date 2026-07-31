import Darwin
import Foundation

/// Discord Rich Presence over Discord's local IPC protocol — a length-
/// prefixed JSON frame protocol spoken over a Unix domain socket. This is a
/// direct port of core/src/services/DiscordRpcService.{h,cpp} (the Windows/
/// Linux implementation, built on Qt's QLocalSocket); read that pair of files
/// for the canonical protocol reference this mirrors state-for-state.
///
/// Entirely optional and silently inert without a client ID. The ID is baked
/// in from a git-ignored .env at build time — see build.sh, which generates
/// Generated/DiscordConfig.swift (itself git-ignored) from .env.example's
/// DISCORD_CLIENT_ID, mirroring core/CMakeLists.txt's .env handling for the
/// Qt build. No .env, no ID, no RPC — every checkout but the maintainer's own
/// just runs without it.
///
/// Everything here — the socket, its read source, every timer — runs on the
/// main queue/run loop deliberately, not a background one: the payloads are a
/// few hundred bytes over a local Unix socket, so the blocking read()/write()
/// calls cost microseconds, and staying single-threaded avoids having to
/// synchronize `handshakeAcked`/`pendingActivity`/the socket fd across
/// queues — the same simplification the Qt version gets for free from being
/// single-threaded by construction.
public final class DiscordRPCService: @unchecked Sendable {
    public static let shared = DiscordRPCService()

    private let clientId: String
    public var isEnabled: Bool { !clientId.isEmpty }

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    private var handshakeAcked = false
    private var nextPipeIndex = 0
    private let pipeAttempts = 10

    private var reconnectTimer: Timer?
    private var debounceTimer: Timer?
    private var pendingActivity: [String: Any]?

    private let sessionStartEpoch = Int(Date().timeIntervalSince1970)

    private static let handshakeOp: UInt32 = 0
    private static let frameOp: UInt32 = 1
    private static let closeOp: UInt32 = 2

    private init() {
        clientId = DiscordConfig.clientId
        guard isEnabled else {
            // No .env at build time — the default for every checkout but the
            // maintainer's own, so this stays quiet rather than warning.
            return
        }
        connect()
    }

    // MARK: - Public API — mirrors DiscordRpcService.h exactly

    public func setIdle() {
        queueActivity(buildActivity(details: "Idle", state: "Waiting for video...",
                                     largeImageText: "Segmenter",
                                     startEpoch: sessionStartEpoch, endEpoch: 0))
    }

    public func setVideoLoaded(videoName: String, formattedShowName: String? = nil) {
        let details = formattedShowName ?? truncateName(videoName, 60)
        let state = formattedShowName.map { "Editing: \(truncateName($0, 40))" } ?? "Editing Segments"
        queueActivity(buildActivity(details: details, state: state,
                                     largeImageText: "Segmenter — Ready",
                                     startEpoch: sessionStartEpoch, endEpoch: 0))
    }

    public func setPlaying(videoName: String, positionMs: Int, durationMs: Int,
                            formattedShowName: String? = nil) {
        let details = formattedShowName ?? truncateName(videoName, 60)
        let state = formattedShowName.map { "Segmenting: \(truncateName($0, 40))" } ?? "Editing Segments"

        // Discord renders a native progress bar when both timestamp ends are
        // set, so play/pause is the one state that reports real ones instead
        // of the session start.
        let nowEpoch = Int(Date().timeIntervalSince1970)
        let startEpoch = nowEpoch - positionMs / 1000
        let endEpoch = startEpoch + durationMs / 1000

        queueActivity(buildActivity(details: details, state: state,
                                     largeImageText: "Segmenter — Playing",
                                     startEpoch: startEpoch, endEpoch: endEpoch))
    }

    public func setPaused(videoName: String, positionMs: Int, durationMs: Int,
                           formattedShowName: String? = nil) {
        let details = formattedShowName ?? truncateName(videoName, 60)
        let timeText = "\(formatDuration(positionMs)) / \(formatDuration(durationMs))"
        let state = formattedShowName.map { "Segmenting: \(truncateName($0, 30)) [\(timeText)]" }
            ?? "[\(timeText)]"
        queueActivity(buildActivity(details: details, state: state,
                                     largeImageText: "Segmenter — Paused",
                                     startEpoch: sessionStartEpoch, endEpoch: 0))
    }

    public func setAnalyzing(videoName: String) {
        queueActivity(buildActivity(details: "Analyzing audio waveform...",
                                     state: truncateName(videoName, 60),
                                     largeImageText: "Segmenter — Analyzing",
                                     startEpoch: sessionStartEpoch, endEpoch: 0))
    }

    /// Clears the presence rather than leaving a stale one showing after the
    /// app quits. Safe to call even when disabled or never connected.
    public func clear() {
        guard isEnabled, socketFD >= 0 else { return }
        // No "activity" key at all is how this protocol clears the presence.
        let args: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier]
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString,
        ]
        writeFrame(opcode: Self.frameOp, payload: payload)
    }

    // MARK: - Activity payload construction

    private func buildActivity(details: String, state: String, largeImageText: String,
                                startEpoch: Int, endEpoch: Int) -> [String: Any] {
        var activity: [String: Any] = [
            "details": details,
            "state": state,
            // "segmenter_logo" has to exist as an uploaded Rich Presence
            // asset on whichever Discord application DISCORD_CLIENT_ID
            // names — see .env.example.
            "assets": [
                "large_image": "segmenter_logo",
                "large_text": largeImageText,
                "small_image": "segmenter_logo",
                "small_text": "Video Segmenter",
            ],
            "buttons": [
                ["label": "Download Segmenter", "url": "https://github.com/Lynder063/segmenter"]
            ],
        ]

        if startEpoch > 0 || endEpoch > 0 {
            var timestamps: [String: Any] = [:]
            if startEpoch > 0 { timestamps["start"] = startEpoch }
            if endEpoch > 0 { timestamps["end"] = endEpoch }
            activity["timestamps"] = timestamps
        }

        return activity
    }

    private func truncateName(_ name: String, _ maxLen: Int) -> String {
        guard !name.isEmpty else { return name }
        var result = (name as NSString).lastPathComponent
        result = (result as NSString).deletingPathExtension
        if result.count > maxLen {
            result = String(result.prefix(maxLen)) + "…"
        }
        return result
    }

    private func formatDuration(_ ms: Int) -> String {
        let totalSec = ms / 1000
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Debounced activity queue

    private func queueActivity(_ activity: [String: Any]) {
        guard isEnabled else { return }
        // Must already be on the main queue for every call site below (all
        // public setters are called from SwiftUI view code / the main-thread
        // AppDelegate), so no extra dispatch here — see the class doc for why
        // everything in this file assumes the main queue.
        pendingActivity = activity
        // Restarts the countdown if one is already pending — the debounce
        // itself. Dragging the seek slider would otherwise spam Discord's
        // IPC socket on every position update.
        debounceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.debounceTimer = nil
            self?.flushQueuedActivity()
        }
        RunLoop.main.add(timer, forMode: .common)
        debounceTimer = timer
    }

    private func flushQueuedActivity() {
        guard handshakeAcked, let activity = pendingActivity else { return }
        pendingActivity = nil

        let args: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "activity": activity,
        ]
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString,
        ]
        writeFrame(opcode: Self.frameOp, payload: payload)
    }

    // MARK: - Connection lifecycle

    /// Same base-directory convention Discord's own clients use: a Unix
    /// domain socket under the per-user temp directory (what `TMPDIR`/
    /// `NSTemporaryDirectory()` resolve to), trying index 0-9 in turn since
    /// there is no discovery mechanism, only probing. This matches the
    /// Linux fallback chain in DiscordRpcService.cpp's ipcSocketPath() —
    /// macOS has no XDG_RUNTIME_DIR, so it always uses this path directly
    /// rather than Linux's TMPDIR/TMP/TEMP/tmp cascade.
    private func socketPath(index: Int) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("discord-ipc-\(index)")
    }

    private func connect() {
        guard isEnabled, socketFD < 0 else { return }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            scheduleReconnect()
            return
        }

        let path = socketPath(index: nextPipeIndex)
        nextPipeIndex = (nextPipeIndex + 1) % pipeAttempts

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let buffer = rawPtr.bindMemory(to: UInt8.self)
            for i in 0..<min(pathBytes.count, buffer.count - 1) {
                buffer[i] = pathBytes[i]
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            close(fd)
            // Discord not running, or this pipe index belongs to something
            // else — both routine, logged at info rather than warn/error.
            LoggerService.shared.info("[DiscordRPC] \(path) not reachable, will retry")
            scheduleReconnect()
            return
        }

        socketFD = fd
        handshakeAcked = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.main)
        source.setEventHandler { [weak self] in
            self?.handleReadable()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        readSource = source

        sendHandshake()
    }

    private func scheduleReconnect() {
        handshakeAcked = false
        guard reconnectTimer == nil else { return }
        let timer = Timer(timeInterval: 15.0, repeats: false) { [weak self] _ in
            self?.reconnectTimer = nil
            self?.connect()
        }
        RunLoop.main.add(timer, forMode: .common)
        reconnectTimer = timer
    }

    private func teardownConnection() {
        readSource?.cancel() // fires the cancel handler above, which closes the fd
        readSource = nil
        socketFD = -1
        readBuffer.removeAll()
        scheduleReconnect()
    }

    private func handleReadable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(socketFD, &buf, buf.count)
        guard n > 0 else {
            teardownConnection() // 0 = peer closed, negative = error
            return
        }
        readBuffer.append(contentsOf: buf[0..<n])
        processReadBuffer()
    }

    private func processReadBuffer() {
        while readBuffer.count >= 8 {
            let opcode = readUInt32LE(readBuffer, at: 0)
            let length = Int(readUInt32LE(readBuffer, at: 4))
            guard readBuffer.count >= 8 + length else {
                return // rest of this frame has not arrived yet
            }

            readBuffer.removeFirst(8 + length)

            if opcode == Self.handshakeOp || opcode == Self.frameOp {
                // The first frame back after a handshake is Discord's own
                // READY dispatch; anything queued before the connection went
                // live can go out now.
                if !handshakeAcked {
                    handshakeAcked = true
                    flushQueuedActivity()
                }
            } else if opcode == Self.closeOp {
                teardownConnection()
            }
        }
    }

    /// `readBuffer` may be a slice with a non-zero startIndex after
    /// `removeFirst`, so indices are relative to `startIndex` — not 0 —
    /// throughout this file.
    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        let b0 = UInt32(data[base])
        let b1 = UInt32(data[base + 1])
        let b2 = UInt32(data[base + 2])
        let b3 = UInt32(data[base + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private func sendHandshake() {
        let payload: [String: Any] = ["v": 1, "client_id": clientId]
        writeFrame(opcode: Self.handshakeOp, payload: payload)
    }

    private func writeFrame(opcode: UInt32, payload: [String: Any]) {
        guard socketFD >= 0,
              let json = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }

        var frame = Data()
        withUnsafeBytes(of: opcode.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(json)

        frame.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
            guard var ptr = rawPtr.baseAddress else { return }
            var remaining = rawPtr.count
            while remaining > 0 {
                let n = write(socketFD, ptr, remaining)
                if n <= 0 { break } // socket gone; the next read will notice and reconnect
                remaining -= n
                ptr = ptr.advanced(by: n)
            }
        }
    }
}
