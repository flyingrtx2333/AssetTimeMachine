#!/usr/bin/env swift
import AppKit
import Foundation

struct PosterSpec {
    let source: String
    let output: String
    let eyebrow: String
    let title: String
    let subtitle: String
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let setRoot = root.appendingPathComponent("marketing/app-store/2026-08-13-refresh")
let width = 1242
let height = 2688

let specs: [PosterSpec] = [
    .init(source: "raw/zh-CN/01-dashboard.png", output: "posters/zh-CN/01-portfolio.png", eyebrow: "资产时光机", title: "管理资产全貌", subtitle: "看清结构与自由进度"),
    .init(source: "raw/zh-CN/02-records.png", output: "posters/zh-CN/02-records.png", eyebrow: "资产时光机", title: "记录每次变化", subtitle: "资产负债统一维护"),
    .init(source: "raw/zh-CN/03-time-machine.png", output: "posters/zh-CN/03-timeline.png", eyebrow: "资产时光机", title: "穿越财富轨迹", subtitle: "趋势、结余与购买力"),
    .init(source: "raw/zh-CN/04-quant.png", output: "posters/zh-CN/04-quant.png", eyebrow: "资产时光机 · 量化", title: "从回测到行动", subtitle: "今日仓位与买卖建议"),
    .init(source: "raw/en-US/01-dashboard.png", output: "posters/en-US/01-portfolio.png", eyebrow: "ASSET TIME MACHINE", title: "See your full picture", subtitle: "Allocation and freedom, at a glance"),
    .init(source: "raw/en-US/02-records.png", output: "posters/en-US/02-records.png", eyebrow: "ASSET TIME MACHINE", title: "Track every change", subtitle: "Assets and liabilities in one place"),
    .init(source: "raw/en-US/03-time-machine.png", output: "posters/en-US/03-timeline.png", eyebrow: "ASSET TIME MACHINE", title: "Travel your wealth timeline", subtitle: "Trends, balance and purchasing power"),
    .init(source: "raw/en-US/04-quant.png", output: "posters/en-US/04-quant.png", eyebrow: "ASSET TIME MACHINE · QUANT", title: "From backtest to action", subtitle: "Today's targets and trade guidance")
]

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func drawText(_ text: String, x: CGFloat, yTop: CGFloat, width: CGFloat, font: NSFont, color: NSColor, tracking: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
        .kern: tracking
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let size = attributed.boundingRect(with: NSSize(width: width, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
    attributed.draw(in: NSRect(x: x, y: CGFloat(height) - yTop - size.height, width: width, height: size.height + 8))
}

func render(_ spec: PosterSpec) throws {
    guard let source = NSImage(contentsOf: setRoot.appendingPathComponent(spec.source)) else {
        throw NSError(domain: "Poster", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing source: \(spec.source)"])
    }

    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let canvas = NSRect(x: 0, y: 0, width: width, height: height)
    let gradient = NSGradient(colors: [color(0x070707), color(0x100c07), color(0x030303)])!
    gradient.draw(in: canvas, angle: -72)

    // Warm, restrained glow behind the product shot.
    let glow = NSGradient(starting: color(0xD59A3A, alpha: 0.16), ending: color(0xD59A3A, alpha: 0))!
    glow.draw(in: NSBezierPath(ovalIn: NSRect(x: 490, y: 1160, width: 900, height: 1500)), relativeCenterPosition: NSPoint(x: 0, y: 0))

    // Quiet star/dust texture; deterministic and intentionally sparse.
    var state: UInt64 = 0xA55E7
    for _ in 0..<95 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let x = CGFloat(state % UInt64(width))
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let y = CGFloat(state % UInt64(height))
        let r = CGFloat(1 + state % 3) / 2
        color(0xD8A758, alpha: 0.10).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r, height: r)).fill()
    }

    drawText(spec.eyebrow, x: 90, yTop: 170, width: 1062, font: .systemFont(ofSize: 28, weight: .semibold), color: color(0xCDA96D), tracking: 6)

    let titleSize: CGFloat = spec.title.count > 24 ? 68 : (spec.title.count > 16 ? 76 : 88)
    drawText(spec.title, x: 75, yTop: 250, width: 1092, font: .systemFont(ofSize: titleSize, weight: .bold), color: color(0xFFF7E8))
    drawText(spec.subtitle, x: 105, yTop: 390, width: 1032, font: .systemFont(ofSize: 39, weight: .medium), color: color(0xAFA9A0))

    let phoneRect = NSRect(x: 94, y: -260, width: 1054, height: 2300)
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, alpha: 0.75)
    shadow.shadowBlurRadius = 42
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x0A0A0B).setFill()
    NSBezierPath(roundedRect: phoneRect.insetBy(dx: -12, dy: -12), xRadius: 54, yRadius: 54).fill()
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: phoneRect, xRadius: 44, yRadius: 44).addClip()

    let scale = phoneRect.width / source.size.width
    let drawHeight = source.size.height * scale
    source.draw(in: NSRect(x: phoneRect.minX, y: phoneRect.maxY - drawHeight, width: phoneRect.width, height: drawHeight), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.current?.restoreGraphicsState()

    color(0xC28A31, alpha: 0.65).setStroke()
    let border = NSBezierPath(roundedRect: phoneRect.insetBy(dx: -1, dy: -1), xRadius: 45, yRadius: 45)
    border.lineWidth = 2
    border.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Poster", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    let output = setRoot.appendingPathComponent(spec.output)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: output)
    print("rendered \(output.path)")
}

for spec in specs { try render(spec) }
