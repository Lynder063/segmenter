import Foundation
import AppKit

public struct MediaMetadata {
    public let durationMs: Int
    public let frameRate: Double
    public let videoCodec: String
    public let audioCodec: String
}

public final class FFmpegService {
    public static let shared = FFmpegService()

    private var ffmpegPath: String?
    private var ffprobePath: String?

    private init() {
        resolveBinaries()
    }

    public func resolveBinaries() {
        let fileManager = FileManager.default

        // 1. Check inside App Bundle Resources/bin/
        if let resourceBin = Bundle.main.resourceURL?.appendingPathComponent("bin") {
            let ffmpegApp = resourceBin.appendingPathComponent("ffmpeg").path
            let ffprobeApp = resourceBin.appendingPathComponent("ffprobe").path
            if fileManager.fileExists(atPath: ffmpegApp) {
                ffmpegPath = ffmpegApp
            }
            if fileManager.fileExists(atPath: ffprobeApp) {
                ffprobePath = ffprobeApp
            }
        }

        // 2. Check /tmp fallback
        if ffmpegPath == nil && fileManager.fileExists(atPath: "/tmp/ffmpeg") {
            ffmpegPath = "/tmp/ffmpeg"
        }
        if ffprobePath == nil && fileManager.fileExists(atPath: "/tmp/ffprobe") {
            ffprobePath = "/tmp/ffprobe"
        }

        // 3. Check System PATH
        if ffmpegPath == nil {
            ffmpegPath = findInPath("ffmpeg")
        }
        if ffprobePath == nil {
            ffprobePath = findInPath("ffprobe")
        }

        LoggerService.shared.info("[FFmpegService] Binary paths -> ffmpeg: \(ffmpegPath ?? "NOT FOUND"), ffprobe: \(ffprobePath ?? "NOT FOUND")")
    }

    private func findInPath(_ binaryName: String) -> String? {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let fileManager = FileManager.default
        for p in paths {
            let full = "\(p)/\(binaryName)"
            if fileManager.fileExists(atPath: full) {
                return full
            }
        }
        return nil
    }

    // Inspect any video format (MKV, MP4, AVI, MOV, WEBM)
    public func inspectMedia(url: URL) async -> MediaMetadata? {
        guard let probe = ffprobePath else {
            LoggerService.shared.warn("[FFmpegService] ffprobe binary not found, using fallback metadata")
            return nil
        }

        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: probe)
            process.arguments = [
                "-v", "error",
                "-show_entries", "format=duration:stream=r_frame_rate,codec_name,codec_type",
                "-of", "json",
                url.path
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    var durationMs = 0
                    if let format = json["format"] as? [String: Any],
                       let durStr = format["duration"] as? String,
                       let durSec = Double(durStr) {
                        durationMs = Int(durSec * 1000.0)
                    }

                    var frameRate = 23.976
                    var vCodec = "unknown"
                    var aCodec = "unknown"

                    if let streams = json["streams"] as? [[String: Any]] {
                        for s in streams {
                            let type = s["codec_type"] as? String ?? ""
                            if type == "video" {
                                vCodec = s["codec_name"] as? String ?? "video"
                                if let rateStr = s["r_frame_rate"] as? String {
                                    let parts = rateStr.split(separator: "/")
                                    if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
                                        frameRate = num / den
                                    }
                                }
                            } else if type == "audio" {
                                aCodec = s["codec_name"] as? String ?? "audio"
                            }
                        }
                    }

                    LoggerService.shared.info("[FFmpegService] Inspected \(url.lastPathComponent) -> Duration: \(durationMs)ms, FPS: \(frameRate), Video: \(vCodec), Audio: \(aCodec)")
                    return MediaMetadata(durationMs: durationMs, frameRate: frameRate, videoCodec: vCodec, audioCodec: aCodec)
                }
            } catch {
                LoggerService.shared.error("[FFmpegService] ffprobe inspection failed: \(error)")
            }
            return nil
        }.value
    }

    // Remux MKV or unsupported format to streamable MP4 in /tmp for AVPlayer playback (super fast, ~0.3s)
    public func preparePlayableURL(url: URL) async -> URL {
        let ext = url.pathExtension.lowercased()
        guard ext == "mkv" || ext == "avi" || ext == "webm" || ext == "flv" || ext == "vob" || ext == "wmv" else {
            return url // MP4 and MOV are played directly by AVPlayer
        }

        guard let ffmpeg = ffmpegPath else {
            LoggerService.shared.warn("[FFmpegService] ffmpeg binary missing; using original URL for \(url.lastPathComponent)")
            return url
        }

        return await Task.detached(priority: .userInitiated) {
            let tmpDir = URL(fileURLWithPath: "/tmp/Segmenter_remux")
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

            let hash = abs(url.path.hashValue)
            let remuxedURL = tmpDir.appendingPathComponent("\(hash)_\(url.deletingPathExtension().lastPathComponent).mp4")

            if FileManager.default.fileExists(atPath: remuxedURL.path) {
                LoggerService.shared.info("[FFmpegService] Using cached remuxed video: \(remuxedURL.lastPathComponent)")
                return remuxedURL
            }

            LoggerService.shared.info("[FFmpegService] Ultra-fast remuxing MKV/container to MP4: \(url.lastPathComponent)...")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-y",
                "-i", url.path,
                "-c:v", "copy",
                "-c:a", "aac",
                "-ac", "2",
                "-threads", "0",
                "-movflags", "+faststart",
                remuxedURL.path
            ]

            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: remuxedURL.path) {
                    LoggerService.shared.info("[FFmpegService] Fast remux complete: \(remuxedURL.path)")
                    return remuxedURL
                }
            } catch {
                LoggerService.shared.error("[FFmpegService] Remuxing failed: \(error)")
            }

            return url
        }.value
    }

    // Extract 16-bit 1000Hz PCM Mono audio stream via ffmpeg (super fast, <0.3s)
    public func extractPCMAudio(url: URL) async throws -> [Int16] {
        guard let ffmpeg = ffmpegPath else {
            throw NSError(domain: "FFmpegService", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffmpeg binary not found"])
        }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-y",
                "-i", url.path,
                "-f", "s16le",
                "-ac", "1",
                "-ar", "1000",
                "-threads", "0",
                "-"
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard !data.isEmpty else {
                throw NSError(domain: "FFmpegService", code: 2, userInfo: [NSLocalizedDescriptionKey: "ffmpeg audio stream empty"])
            }

            return data.withUnsafeBytes { ptr in
                Array(UnsafeBufferPointer(start: ptr.bindMemory(to: Int16.self).baseAddress, count: data.count / 2))
            }
        }.value
    }

    // Extract fast 160x90 JPEG thumbnail Data at timeMs via ffmpeg stdout pipe (in-memory <0.02s)
    public func extractThumbnailData(url: URL, timeMs: Int) async -> Data? {
        guard let ffmpeg = ffmpegPath else { return nil }

        return await Task.detached(priority: .userInitiated) {
            let sec = Double(timeMs) / 1000.0
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = [
                "-ss", String(format: "%.3f", sec),
                "-i", url.path,
                "-vframes", "1",
                "-s", "160x90",
                "-f", "image2pipe",
                "-c:v", "mjpeg",
                "pipe:1"
            ]


            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 && !data.isEmpty {
                    return data
                }
            } catch {
                LoggerService.shared.warn("[FFmpegService] Thumbnail extraction failed: \(error)")
            }
            return nil
        }.value
    }



}
