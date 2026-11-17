// Run with: swift scripts/generate_asset_emblems.swift [preview-directory]
// Original vector artwork. These are category marks, not exchange trademarks.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("AssetTimeMachine/Assets.xcassets")
let previewDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? root.appendingPathComponent("build/asset-emblems").path)
try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func polygon(_ points: [(CGFloat, CGFloat)], _ hex: UInt32) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: points[0].0, y: points[0].1))
    for p in points.dropFirst() { path.line(to: NSPoint(x: p.0, y: p.1)) }
    path.close(); color(hex).setFill(); path.fill()
}

final class Emblem: NSView {
    let kind: String
    init(_ kind: String) { self.kind = kind; super.init(frame: NSRect(x: 0, y: 0, width: 64, height: 64)) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let background: UInt32 = switch kind {
        case "sp500": 0xC94450
        case "nasdaq": 0x137B93
        case "gold": 0xFFF3D5
        default: 0xE6F0EA
        }
        let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        color(background).setFill(); tile.fill()
        color(0x000000).withAlphaComponent(0.06).setStroke(); tile.lineWidth = 0.6; tile.stroke()
        switch kind {
        case "sp500":
            let text = NSAttributedString(string: "500", attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold),
                                                                      .foregroundColor: color(0xFFF7F4), .kern: -1.1])
            text.draw(at: NSPoint(x: (64 - text.size().width) / 2, y: (64 - text.size().height) / 2 + 1))
        case "nasdaq":
            // Broad strokes remain legible at a 16-point row size.
            polygon([(16, 17), (24, 17), (24, 33), (42, 17), (49, 17),
                     (49, 47), (41, 47), (41, 31), (23, 47), (16, 47)], 0xFFFFFF)
            polygon([(41, 31), (49, 24), (49, 47), (41, 47)], 0x89D9E4)
        case "gold":
            polygon([(11, 28), (24, 43), (53, 43), (40, 28)], 0xE7B348)
            polygon([(11, 28), (40, 28), (40, 20), (11, 20)], 0xCD912C)
            polygon([(40, 28), (53, 43), (53, 35), (40, 20)], 0xA56C21)
            polygon([(16, 30), (26, 41), (47, 41), (37, 30)], 0xF8D980)
        default:
            let back = NSBezierPath(roundedRect: NSRect(x: 14, y: 25, width: 38, height: 23), xRadius: 5, yRadius: 5)
            color(0x6E9B83).setFill(); back.fill()
            let note = NSBezierPath(roundedRect: NSRect(x: 10, y: 17, width: 42, height: 26), xRadius: 5, yRadius: 5)
            color(0x2C634C).setFill(); note.fill()
            let inset = NSBezierPath(roundedRect: NSRect(x: 14, y: 21, width: 34, height: 18), xRadius: 3, yRadius: 3)
            color(0xBCD8C5).setStroke(); inset.lineWidth = 1.5; inset.stroke()
            color(0xE2F1E5).setFill(); NSBezierPath(ovalIn: NSRect(x: 26, y: 24, width: 10, height: 12)).fill()
        }
    }
}

let kinds = ["sp500", "nasdaq", "gold", "cash"]
let labels = ["标普 500", "纳指", "黄金", "现金 / 其他"]
var images: [NSImage] = []
for kind in kinds {
    let view = Emblem(kind)
    let data = view.dataWithPDF(inside: view.bounds)
    let directory = catalog.appendingPathComponent("icon_\(kind).imageset")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: directory.appendingPathComponent("icon-\(kind).pdf"))
    let contents: [String: Any] = ["images": [["filename": "icon-\(kind).pdf", "idiom": "universal"]],
                                   "info": ["author": "xcode", "version": 1], "properties": ["preserves-vector-representation": true]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
    images.append(NSImage(data: data)!)
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 560, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.scaleBy(x: 2, y: 2)
color(0xF8F8F6).setFill(); NSRect(x: 0, y: 0, width: 720, height: 280).fill()
color(0x20252A).setFill(); NSRect(x: 0, y: 0, width: 720, height: 84).fill()
for i in 0..<4 {
    let x = CGFloat(i) * 172 + 38
    images[i].draw(in: NSRect(x: x + 36, y: 154, width: 64, height: 64))
    let title = NSAttributedString(string: labels[i], attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: color(0x252A30)])
    title.draw(at: NSPoint(x: x + (136 - title.size().width) / 2, y: 118))
    images[i].draw(in: NSRect(x: x, y: 32, width: 20, height: 20))
    NSAttributedString(string: labels[i], attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: color(0xF1F1ED)]).draw(at: NSPoint(x: x + 29, y: 32))
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: previewDirectory.appendingPathComponent("asset-emblems.png"))
print("Generated four vector assets and preview: \(previewDirectory.path)")
