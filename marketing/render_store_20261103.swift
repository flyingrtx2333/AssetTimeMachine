#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Typeset marketing around actual iOS screenshots. No UI or balances are redrawn.
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "marketing/app-store/ios-refresh-20261103")
let width = 1320, height = 2868
let W = CGFloat(width), H = CGFloat(height)
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: H-y-h, width: w, height: h)
}
func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, ink: NSColor = color(0x1D221D), bold: Bool = true) {
    let font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .kern: -size*0.035]
    let measured = (string as NSString).size(withAttributes: attributes)
    precondition(measured.width <= W-x-60, "Headline exceeds canvas: \(string) \(measured.width)")
    (string as NSString).draw(at: NSPoint(x: x, y: H-y-measured.height), withAttributes: attributes)
}
func headline(_ lines: [String], y: CGFloat, english: Bool, size: CGFloat? = nil) {
    let s = size ?? (english ? 164 : 180)
    for (i, line) in lines.enumerated() { text(line, x: 84, y: y+CGFloat(i)*s*1.19, size: s) }
}
func image(_ name: String, locale: String) -> NSImage {
    let url = root.appendingPathComponent("raw/\(locale)/\(name).png")
    guard let result = NSImage(contentsOf: url) else { fatalError("Missing \(url.path)") }
    // PNG DPI metadata must never change our pixel-based source crop geometry.
    result.size = NSSize(width: 1320, height: 2868)
    return result
}
func crop(_ image: NSImage, _ r: NSRect) -> NSRect {
    NSRect(x: r.minX, y: image.size.height-r.maxY, width: r.width, height: r.height)
}
func card(_ image: NSImage, source: NSRect, x: CGFloat, y: CGFloat, w: CGFloat, angle: CGFloat = 0) {
    let h = w * source.height / source.width
    let frame = rect(x, y, w, h)
    NSGraphicsContext.saveGraphicsState()
    let transform = AffineTransform(translationByX: frame.midX, byY: frame.midY)
    (transform as NSAffineTransform).concat()
    let rotation = NSAffineTransform(); rotation.rotate(byDegrees: angle); rotation.concat()
    let local = NSRect(x: -w/2, y: -h/2, width: w, height: h)
    let path = NSBezierPath(roundedRect: local, xRadius: 44, yRadius: 44)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.09)
    shadow.shadowBlurRadius = 58; shadow.shadowOffset = NSSize(width: 0, height: -30); shadow.set()
    color(0xFFFCF6).setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    path.addClip(); image.draw(in: local, from: crop(image, source), operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}
func footer(_ english: Bool) {
    text(english ? "Asset Time Machine" : "资产时光机", x: 84, y: 2778, size: 24, ink: color(0x77796F), bold: false)
    text(english ? "Sample data" : "示例数据", x: english ? 1100 : 1140, y: 2778, size: 24, ink: color(0x77796F), bold: false)
}
func cover(_ locale: String, english: Bool) {
    let photo = NSImage(contentsOf: root.appendingPathComponent("hero-background.png"))!
    photo.size = NSSize(width: 900, height: 1748)
    let scale = H / photo.size.height, offset = (W-photo.size.width*scale)/2
    photo.draw(in: NSRect(x: offset, y: 0, width: photo.size.width*scale, height: H))
    let screen = rect(offset+221*scale, 590*scale, 454*scale, 937*scale)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: screen, xRadius: 51*scale, yRadius: 51*scale).addClip()
    let screenshot = image("dashboard", locale: locale)
    screenshot.draw(in: screen, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    headline(english ? ["Your wealth.", "In view."] : ["资产，", "心中有数。"], y: 215, english: english, size: english ? 171 : 188)
    text(english ? "Sample data" : "示例数据", x: 84, y: 2780, size: 24, ink: color(0x64665D), bold: false)
}
let files = ["01-wealth", "02-records", "03-time-machine", "04-daily-changes", "05-gold-equivalent"]
for locale in ["zh-Hans", "en-US"] {
    let english = locale == "en-US"
    let out = root.appendingPathComponent("posters/\(locale)")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for index in 0..<files.count {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: W, height: H)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        color(0xF4F2EC).setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)).fill()
        switch index {
        case 0: cover(locale, english: english)
        case 1:
            headline(english ? ["Every account.", "One place."] : ["账户，", "一本理清。"], y: 180, english: english)
            card(image("records", locale: locale), source: NSRect(x: 0, y: 205, width: 1320, height: 2190),
                 x: 96, y: 765, w: 1128, angle: -2)
            footer(english)
        case 2:
            card(image("time-machine", locale: locale), source: NSRect(x: 12, y: 205, width: 1296, height: 1575),
                 x: 72, y: 315, w: 1176, angle: 2)
            headline(english ? ["Go back.", "See any day."] : ["每一天，", "都能回看。"], y: 2070, english: english)
            footer(english)
        case 3:
            headline(english ? ["Every change.", "Day by day."] : ["变化，", "一格一天。"], y: 180, english: english)
            card(image("calendar", locale: locale), source: NSRect(x: 0, y: 285, width: 1320, height: 1265),
                 x: 72, y: 1000, w: 1176, angle: -3)
            footer(english)
        default:
            headline(english ? ["Your wealth.", "In grams of gold."] : ["同一份资产，", "值多少黄金。"], y: 180, english: english, size: english ? 143 : 172)
            card(image("gold", locale: locale), source: NSRect(x: 12, y: 205, width: 1296, height: 1575),
                 x: 72, y: 940, w: 1176, angle: 2)
            footer(english)
        }
        NSGraphicsContext.restoreGraphicsState()
        let url = out.appendingPathComponent(files[index]+".png")
        // AppKit drawing requires RGBA; App Store uploads require an opaque RGB PNG.
        let rgba = bitmap.bitmapData!
        var rgb = Data(count: width*height*3)
        rgb.withUnsafeMutableBytes { buffer in
            let target = buffer.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let source = y*bitmap.bytesPerRow+x*4, dest = (y*width+x)*3
                target[dest] = rgba[source]; target[dest+1] = rgba[source+1]; target[dest+2] = rgba[source+2]
            } }
        }
        let opaque = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: width*3, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: [],
            provider: CGDataProvider(data: rgb as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, opaque, nil)
        precondition(CGImageDestinationFinalize(destination))
        print(url.path)
    }
}
