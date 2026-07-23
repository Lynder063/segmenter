import Foundation
import Segmenter

print("🚀 Starting RCD Test on /Users/lynder063/Downloads/Season 01...")
FFmpegService.shared.resolveBinaries()

let seasonURL = URL(fileURLWithPath: "/Users/lynder063/Downloads/Season 01")

let group = DispatchGroup()
group.enter()

Task {
    do {
        let results = try await RCDEngineService.shared.scanSeason(
            directoryURL: seasonURL,
            debugLogger: { msg in
                print(msg)
            },
            progressHandler: { text, pct in
                print("Progress: \(pct)% - \(text)")
            }
        )

        print("\n✅ RCD Scan Results:")
        for (ep, matches) in results.sorted(by: { $0.key < $1.key }) {
            print("  - \(ep):")
            for m in matches {
                print("      -> \(m.type.displayName): \(m.startSec)s - \(m.endSec)s (Confidence: \(m.confidence))")
            }
        }
    } catch {
        print("❌ RCD Scan Error: \(error)")
    }
    group.leave()
}

group.wait()
print("🎉 Test finished!")
