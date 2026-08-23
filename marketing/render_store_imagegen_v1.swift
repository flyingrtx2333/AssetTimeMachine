#!/usr/bin/env swift
import AppKit
import Foundation

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let root = cwd.appendingPathComponent("marketing/app-store/2026-08-15-redesign")
let backgroundURL = root.appendingPathComponent("imagegen-v1/background-continuous.png")
let screenshotURL = root.appendingPathComponent("raw/zh-CN/03-time-machine-3year-demo-clean.png")
let outputURL = root.appendingPathComponent("imagegen-v1/01-time-machine-main-poster.png")

guard let background = NSImage(contentsOf: backgroundURL), let screenshot = NSImage(contentsOf: screenshotURL) else { fatalError("missing input") }
let canvasSize = NSSize(width: 1242, height: 2688)
let rep = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:1242, pixelsHigh:2688, bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB, bytesPerRow:0, bitsPerPixel:0)!
rep.size = canvasSize
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Aspect-fill the generated art while preserving its center.
let targetRatio = canvasSize.width / canvasSize.height
let sourceRatio = background.size.width / background.size.height
var sourceRect = NSRect(origin: .zero, size: background.size)
if sourceRatio > targetRatio {
    let cropWidth = background.size.height * targetRatio
    sourceRect.origin.x = (background.size.width - cropWidth) / 2
    sourceRect.size.width = cropWidth
}
background.draw(in:NSRect(origin:.zero,size:canvasSize), from:sourceRect, operation:NSCompositingOperation.copy, fraction:1)

let title = "财富时光机"
let attrs:[NSAttributedString.Key:Any] = [
    .font:NSFont.systemFont(ofSize:88, weight:.bold),
    .foregroundColor:NSColor(calibratedRed:0.96, green:0.91, blue:0.78, alpha:1),
    .kern:1.5
]
let titleSize = title.size(withAttributes:attrs)
title.draw(at:NSPoint(x:(1242-titleSize.width)/2, y:2480), withAttributes:attrs)

// One identical full-screenshot frame can be reused across every poster.
let frameWidth:CGFloat = 1050
let frameHeight = frameWidth * screenshot.size.height / screenshot.size.width
let frame = NSRect(x:(1242-frameWidth)/2, y:82, width:frameWidth, height:frameHeight)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.72); shadow.shadowBlurRadius=46; shadow.shadowOffset=NSSize(width:0,height:-14); shadow.set()
let clip = NSBezierPath(roundedRect:frame,xRadius:52,yRadius:52); clip.addClip()
screenshot.draw(in:frame, from:NSRect(origin:.zero,size:screenshot.size), operation:NSCompositingOperation.sourceOver, fraction:1)
NSGraphicsContext.restoreGraphicsState()
NSColor(calibratedRed:0.79, green:0.64, blue:0.32, alpha:0.42).setStroke()
let border = NSBezierPath(roundedRect:frame,xRadius:52,yRadius:52); border.lineWidth=2; border.stroke()

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using:.png, properties:[:])!
try data.write(to:outputURL)
print("rendered \(outputURL.path); full screenshot \(Int(frame.width))x\(Int(frame.height)); bottom=\(Int(frame.minY))")
