#!/usr/bin/env swift
import AppKit
import Foundation

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resourceDirectory = repoRoot.appendingPathComponent("Resources", isDirectory: true)
let sourceURL = resourceDirectory.appendingPathComponent("AppHarborIcon.svg")
let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
let iconset = temporaryRoot.appendingPathComponent("AppHarbor.iconset", isDirectory: true)
let iconURL = resourceDirectory.appendingPathComponent("AppHarbor.icns")
let previewURL = resourceDirectory.appendingPathComponent("AppHarbor-icon.png")
let smallPreviewURL = resourceDirectory.appendingPathComponent("AppHarbor-icon-128.png")

func render(size: Int, source: NSImage) throws -> Data {
    let dimension = CGFloat(size)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "AppHarborIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap context"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true
    context.cgContext.setAllowsAntialiasing(true)
    context.cgContext.setShouldAntialias(true)
    source.draw(in: NSRect(x: 0, y: 0, width: dimension, height: dimension),
                from: NSRect(origin: .zero, size: source.size), operation: .copy, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AppHarborIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
    }
    return data
}

guard let source = NSImage(contentsOf: sourceURL) else {
    throw NSError(domain: "AppHarborIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not load canonical SVG at \(sourceURL.path)"])
}
let sizes: [(String, Int)] = [
    ("icon_16x16.png",16), ("icon_16x16@2x.png",32),
    ("icon_32x32.png",32), ("icon_32x32@2x.png",64),
    ("icon_128x128.png",128), ("icon_128x128@2x.png",256),
    ("icon_256x256.png",256), ("icon_256x256@2x.png",512),
    ("icon_512x512.png",512), ("icon_512x512@2x.png",1024)
]
try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in sizes {
    try render(size: size, source: source).write(to: iconset.appendingPathComponent(name), options: .atomic)
}
try render(size: 1024, source: source).write(to: previewURL, options: .atomic)
try render(size: 128, source: source).write(to: smallPreviewURL, options: .atomic)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", iconURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw NSError(domain: "AppHarborIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}
try? FileManager.default.removeItem(at: iconset)
print("Generated canonical SVG renders: \(iconURL.path), \(previewURL.path), and \(smallPreviewURL.path)")
