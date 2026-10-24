import AppHarborCore
import AppKit
import SwiftUI

/// Shows an installed bundle's real Finder icon when AppHarbor has an exact
/// local path, with a native symbol while loading or when that path is stale.
struct ApplicationIconView: View {
    let installation: Installation
    var size: CGFloat = 20

    @State private var loadedIcon: NSImage?

    private var bundlePath: String? { Self.bundlePath(for: installation) }
    private var requestID: String { "\(bundlePath ?? "")|\(installation.observedAt.timeIntervalSinceReferenceDate)" }

    var body: some View {
        Group {
            if let loadedIcon {
                Image(nsImage: loadedIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbol(for: installation))
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.14)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if installation.isStale {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: max(9, size * 0.23), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(2)
                    .background(.background, in: Circle())
                    .offset(x: 3, y: 3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHidden(true)
        .task(id: requestID) {
            let currentRequest = requestID
            loadedIcon = nil
            guard let bundlePath else { return }
            let image = await InstalledIconCache.shared.icon(at: bundlePath)
            guard !Task.isCancelled, requestID == currentRequest else { return }
            loadedIcon = image
        }
    }

    /// Bundle paths are taken only from the scanned app's canonical path or
    /// Homebrew's exact Bundle path evidence. Display names never locate apps.
    static func bundlePath(for installation: Installation) -> String? {
        let paths: [String]
        switch installation.kind {
        case .appBundle:
            paths = [installation.canonicalLocation]
        case .cask:
            paths = installation.evidence
                .filter { $0.label == "Bundle path" }
                .map(\.value)
        case .formula, .npmPackage, .pipxEnvironment, .cargoPackage, .other:
            return nil
        }
        return paths.first { path in
            path.hasPrefix("/") && URL(fileURLWithPath: path).pathExtension.lowercased() == "app"
        }
    }
}

private func fallbackSymbol(for installation: Installation) -> String {
    switch installation.kind {
    case .appBundle, .cask: "app.dashed"
    case .formula, .npmPackage, .pipxEnvironment, .cargoPackage: "terminal"
    case .other: "shippingbox"
    }
}

/// The bounded cache is actor-isolated to the UI. Workspace icon lookup and
/// filesystem metadata run off the view-update path; cache keys include the
/// exact path and bundle metadata so an updated app can replace its icon.
@MainActor
private final class InstalledIconCache {
    static let shared = InstalledIconCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<Data?, Never>] = [:]

    private init() {
        cache.countLimit = 512
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func icon(at path: String) async -> NSImage? {
        let metadata = await Task.detached(priority: .utility) { () -> (String, Bool) in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard url.pathExtension.lowercased() == "app",
                  FileManager.default.fileExists(atPath: path) else { return (path, false) }

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let fileSize = values?.fileSize ?? 0
            return ("\(path)|\(modified)|\(fileSize)", true)
        }.value

        guard metadata.1 else { return nil }
        if let cached = cache.object(forKey: metadata.0 as NSString) { return cached }
        let data: Data?
        if let pending = inFlight[metadata.0] {
            data = await pending.value
        } else {
            let pending = Task.detached(priority: .utility) {
                let icon = NSWorkspace.shared.icon(forFile: path)
                let dimension = 128
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                    pixelsWide: dimension,
                                                    pixelsHigh: dimension,
                                                    bitsPerSample: 8,
                                                    samplesPerPixel: 4,
                                                    hasAlpha: true,
                                                    isPlanar: false,
                                                    colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0,
                                                    bitsPerPixel: 0) else { return nil as Data? }
                bitmap.size = NSSize(width: dimension, height: dimension)
                NSGraphicsContext.saveGraphicsState()
                guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                    NSGraphicsContext.restoreGraphicsState()
                    return nil as Data?
                }
                NSGraphicsContext.current = context
                context.imageInterpolation = .high
                icon.draw(in: NSRect(x: 0, y: 0, width: dimension, height: dimension),
                          from: .zero,
                          operation: .copy,
                          fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                return bitmap.representation(using: .png, properties: [:])
            }
            inFlight[metadata.0] = pending
            data = await pending.value
            inFlight[metadata.0] = nil
        }
        guard let data else { return nil }
        guard let image = NSImage(data: data) else { return nil }
        let cost = max(data.count, 128 * 128 * 4)
        cache.setObject(image, forKey: metadata.0 as NSString, cost: cost)
        return image
    }
}

enum LibraryViewMode: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
}
