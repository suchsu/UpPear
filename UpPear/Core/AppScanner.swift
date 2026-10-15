// Modified for UpPear on 2026-10-13; derived from Pearcleaner 5.4.3
// AppInfoFetch.swift / AppCategoryDetector, Alin Lupascu / alienator88.
// Changes: retain only updater metadata, read fresh plists, preserve outer
// wrapped-iOS launch paths, and collect scan errors. See docs/PROVENANCE.md.
// 2026-10-14: preserve unreadable/metadata-free launchers in the manual list.
import Foundation
import CoreServices

public struct AppScan: Sendable {
    public let apps: [AppInfo]
    public let warnings: [String]
}

public enum AppScanner {
    public static var defaultRoots: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    public static func scan(roots: [URL] = defaultRoots) -> AppScan {
        let manager = FileManager.default
        var apps: [AppInfo] = []
        var warnings: [String] = []
        var seen: Set<String> = []
        for root in roots where manager.fileExists(atPath: root.path) {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles], errorHandler: { url, error in
                        warnings.append("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)")
                        return true
                    }) else {
                warnings.append("无法读取应用目录：\(root.path)")
                continue
            }
            for case let path as URL in enumerator {
                if path.pathExtension.lowercased() == "app" {
                    enumerator.skipDescendants()
                    let canonical = path.resolvingSymlinksInPath().standardizedFileURL.path
                    guard seen.insert(canonical).inserted else { continue }
                    if let app = getAppInfo(atPath: path) {
                        if app.bundleIdentifier != "org.uppear.UpPear" { apps.append(app) }
                    } else {
                        warnings.append("无法读取应用信息：\(path.lastPathComponent)")
                        // A missing Info.plist must not silently remove a known
                        // launcher from the user's software inventory. It has
                        // no trusted source/version and can only be opened.
                        apps.append(AppInfo(path: path, bundleIdentifier: "",
                            appName: path.deletingPathExtension().lastPathComponent, appVersion: ""))
                    }
                } else if ["framework", "bundle", "plugin", "appex"].contains(path.pathExtension) {
                    enumerator.skipDescendants()
                }
            }
        }
        return AppScan(apps: apps.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }, warnings: warnings)
    }

    public static func getAppInfo(atPath path: URL) -> AppInfo? {
        let wrapperURL = path.appendingPathComponent("Wrapper", isDirectory: true)
        let wrapped = FileManager.default.fileExists(atPath: wrapperURL.path)
        let bundlePath: URL
        if wrapped {
            guard let contents = try? FileManager.default.contentsOfDirectory(at: wrapperURL, includingPropertiesForKeys: nil),
                  let innerApp = contents.first(where: { $0.pathExtension == "app" }) else { return nil }
            bundlePath = innerApp
        } else {
            bundlePath = path
        }
        let plistURL = wrapped ? bundlePath.appendingPathComponent("Info.plist") : bundlePath.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleIdentifier = dict["CFBundleIdentifier"] as? String, !bundleIdentifier.isEmpty else { return nil }

        let appVersion = dict["CFBundleShortVersionString"] as? String ?? ""
        let appBuildNumber = dict["CFBundleVersion"] as? String
        let metadataURL = wrapperURL.appendingPathComponent("iTunesMetadata.plist")
        let isAppStore = checkForAppStore(bundlePath: bundlePath, wrapped: wrapped, metadataURL: metadataURL)
        let isSetapp = bundleIdentifier.hasSuffix("-setapp")
        let feedURL = isSetapp ? nil : SparkleFeed.feedURL(information: dict, bundlePath: bundlePath, bundleIdentifier: bundleIdentifier)
        var adamID: UInt64?
        if wrapped, let metadata = NSDictionary(contentsOf: metadataURL) {
            adamID = (metadata["itemId"] as? NSNumber)?.uint64Value
        }
        if adamID == nil, isAppStore,
           let item = MDItemCreate(nil, path.path as CFString),
           let value = MDItemCopyAttribute(item, "kMDItemAppStoreAdamID" as CFString) as? NSNumber {
            adamID = value.uint64Value
        }
        let name = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String) ?? path.deletingPathExtension().lastPathComponent
        return AppInfo(path: path, bundlePath: bundlePath, bundleIdentifier: bundleIdentifier,
                       appName: name, appVersion: appVersion, appBuildNumber: appBuildNumber,
                       wrapped: wrapped, isAppStore: isAppStore, adamID: adamID,
                       feedURL: feedURL, isSetapp: isSetapp)
    }

    private static func checkForAppStore(bundlePath: URL, wrapped: Bool, metadataURL: URL) -> Bool {
        if wrapped && FileManager.default.fileExists(atPath: metadataURL.path) { return true }
        let receiptPath = bundlePath.appendingPathComponent("Contents/_MASReceipt/receipt")
        return FileManager.default.fileExists(atPath: receiptPath.path)
    }
}

enum SparkleFeed {
    // Pearcleaner's SUFeedURL + DevMate fallback, with URL validation and
    // SUFeedUrl support matching its original AppCategoryDetector.
    static func feedURL(information: [String: Any], bundlePath: URL, bundleIdentifier: String) -> URL? {
        if let string = (information["SUFeedURL"] ?? information["SUFeedUrl"]) as? String,
           let url = URL(string: string.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))),
           ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            return url
        }
        let frameworksURL = bundlePath.appendingPathComponent("Contents/Frameworks")
        let frameworks = try? FileManager.default.contentsOfDirectory(atPath: frameworksURL.path)
        if frameworks?.contains(where: { $0.contains("DevMateKit") }) ?? false {
            return URL(string: "https://updates.devmate.com")?
                .appendingPathComponent(bundleIdentifier).appendingPathExtension("xml")
        }
        return nil
    }
}
