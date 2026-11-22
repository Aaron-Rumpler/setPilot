import AppKit
import SwiftUI
import WidgetKit
import XCTest

/// Renders the Mac widgets' views (the same views as the iPhone's) and compares them with the
/// pictures in Tests/Snapshots. Each render is also written to SNAPSHOT_DIR (CI uploads it), so a
/// missing or intended change of picture can be taken from there: with no picture to compare
/// with, a test only records.
@MainActor
final class WidgetSnapshotTests: XCTestCase {
    func testPresetsWidget() throws {
        try snapshot("presets-small", PresetsWidgetView(entry: .sample), size: CGSize(width: 170, height: 170))
    }

    func testBulbWidget() throws {
        try snapshot("bulb-small", StatusWidgetView(entry: .sample), size: CGSize(width: 170, height: 170))
    }

    func testBulbWidgetOff() throws {
        let base = BulbEntry.sample
        var off = base.snapshot ?? LightSnapshot()
        off.isOn = false
        let entry = BulbEntry(date: base.date, snapshot: off, presets: base.presets)
        try snapshot("bulb-small-off", StatusWidgetView(entry: entry), size: CGSize(width: 170, height: 170))
    }

    // MARK: Rendering and comparing

    private func snapshot<V: View>(_ name: String, _ view: V, size: CGSize) throws {
        let content = view
            .padding(12)
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.93))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "Couldn't render \(name)")
        let png = try XCTUnwrap(Self.png(image))

        let out = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("setPilot-snapshots")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try png.write(to: out.appendingPathComponent("\(name).png"))

        let reference = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Snapshots/\(name).png")
        guard let data = try? Data(contentsOf: reference), let expected = NSBitmapImageRep(data: data)?.cgImage else {
            print("No picture to compare \(name) with yet: recorded only")
            return
        }
        let difference = Self.difference(image, expected)
        XCTAssertLessThan(difference, 0.01, "\(name) differs from Tests/Snapshots/\(name).png in \(Int(difference * 100))% of its pixels (the new one is in \(out.path))")
    }

    private static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// The share of pixels that differ noticeably (1 for a different size).
    private static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height, let pa = pixels(a), let pb = pixels(b) else { return 1 }
        var differing = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            let d = (0..<3).map { abs(Int(pa[i + $0]) - Int(pb[i + $0])) }.max() ?? 0
            if d > 24 { differing += 1 }
        }
        return Double(differing) / Double(a.width * a.height)
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
}
