import Foundation

/// Locates `yt-dlp`/`brew` on disk and drives a `brew install`, off the AppModel.
enum YtDlpInstaller {
    enum Outcome: Sendable {
        case success
        case failure(String)
    }

    static func locate() -> String? {
        for path in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in env.split(separator: ":") {
            let candidate = "\(dir)/yt-dlp"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func locateBrew() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func install(formula: String, brewPath: String) async -> Outcome {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brewPath)
        proc.arguments = ["install", formula]
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let (chunkStream, chunkContinuation) = AsyncStream.makeStream(of: Data.self)
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                chunkContinuation.finish()
            } else {
                chunkContinuation.yield(chunk)
            }
        }

        let bufferTask = Task<String, Never> {
            var data = Data()
            for await chunk in chunkStream {
                data.append(chunk)
            }
            return String(decoding: data, as: UTF8.self)
        }

        do {
            try proc.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            chunkContinuation.finish()
            return .failure("Could not launch brew: \(error.localizedDescription)")
        }
        return await withCheckedContinuation { cont in
            proc.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                chunkContinuation.finish()
                Task {
                    let output = await bufferTask.value
                    if p.terminationStatus == 0 {
                        cont.resume(returning: .success)
                    } else {
                        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        cont.resume(returning: .failure(detail.isEmpty ? "brew exited with status \(p.terminationStatus)." : detail))
                    }
                }
            }
        }
    }
}
