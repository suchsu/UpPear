import AppKit
import Foundation
import UpPearCore

@main
struct Diagnostics {
    @MainActor static func main() async {
        // SPUUpdater requires the AppKit main run loop even for probing.
        _ = NSApplication.shared
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "scan" || args.first == "inventory" else {
            print("UpPearDiagnostics inventory | scan [--output PATH]\nRead-only: this tool never upgrades or installs applications.")
            return
        }
        if args.first == "inventory" {
            let scan = await Task.detached { AppScanner.scan() }.value
            print("Apps: \(scan.apps.count), App Store: \(scan.apps.filter(\.isAppStore).count), Sparkle feeds: \(scan.apps.filter { !$0.isAppStore && $0.feedURL != nil }.count)")
            for warning in scan.warnings { print(warning) }
            return
        }
        do {
            let snapshot = try await UpdateEngine.scan(options: .init()) { progress in
                if progress.total > 0 && progress.completed % 10 == 0 {
                    print("Checked \(progress.completed)/\(progress.total)")
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            if let index = args.firstIndex(of: "--output"), args.indices.contains(index + 1) {
                try data.write(to: URL(fileURLWithPath: args[index + 1]), options: .atomic)
            }
            let sources = Dictionary(grouping: snapshot.records, by: \.source)
            print("Records: \(snapshot.records.count), available updates: \(snapshot.updateCount), failed: \(snapshot.failureCount)")
            for source in UpdateSource.allCases {
                let records = sources[source] ?? []
                print("\(source.title): \(records.count) records, \(records.filter { $0.state == .updateAvailable }.count) updates, \(records.filter { $0.state == .failed }.count) failed")
            }
            for warning in snapshot.warnings { print(warning) }
        } catch {
            print("Scan failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
