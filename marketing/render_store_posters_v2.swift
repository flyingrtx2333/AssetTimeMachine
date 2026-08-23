#!/usr/bin/env swift
import AppKit
import Foundation

struct PosterSpec {
    let locale: String
    let file: String
    let eyebrow: String
    let title: String
    let subtitle: String
    let tag: String
    let accent: UInt32
    let side: CGFloat
    let top: CGFloat
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let setRoot = root.appendingPathComponent("marketing/app-store/2026-08-15-redesign")
let W = 1242
let H = 2688

let zh: [PosterSpec] = [
    .init(locale:"zh-CN", file:"01-dashboard", eyebrow:"", title:"一眼看懂全部资产", subtitle:"", tag:"", accent:0xE7B85C, side:70, top:390),
    .init(locale:"zh-CN", file:"02-records", eyebrow:"", title:"每一次变化都有记录", subtitle:"", tag:"", accent:0x72A7F0, side:145, top:390),
    .init(locale:"zh-CN", file:"03-time-machine", eyebrow:"", title:"看见财富走过的时间", subtitle:"", tag:"", accent:0x71D39C, side:35, top:390),
    .init(locale:"zh-CN", file:"04-time-machine-insight", eyebrow:"", title:"点一下，看清那一天", subtitle:"", tag:"", accent:0xDFA4F1, side:105, top:390),
    .init(locale:"zh-CN", file:"05-today-allocation", eyebrow:"", title:"今日仓位，直接告诉你怎么调", subtitle:"", tag:"", accent:0xF4B447, side:40, top:390),
    .init(locale:"zh-CN", file:"06-forward-strategy-library", eyebrow:"", title:"用 NFCI 提前看见变化", subtitle:"", tag:"", accent:0xEA9E45, side:125, top:390),
    .init(locale:"zh-CN", file:"07-multi-asset-share-poster", eyebrow:"", title:"策略和基准，同起点比较", subtitle:"", tag:"", accent:0x45D6B0, side:55, top:390)
]

let en: [PosterSpec] = [
    .init(locale:"en-US", file:"01-dashboard", eyebrow:"", title:"All your wealth in one view", subtitle:"", tag:"", accent:0xE7B85C, side:70, top:390),
    .init(locale:"en-US", file:"02-records", eyebrow:"", title:"Every change, on the record", subtitle:"", tag:"", accent:0x72A7F0, side:145, top:390),
    .init(locale:"en-US", file:"03-time-machine", eyebrow:"", title:"Your wealth through time", subtitle:"", tag:"", accent:0x71D39C, side:35, top:390),
    .init(locale:"en-US", file:"04-time-machine-insight", eyebrow:"", title:"Tap any date to see it all", subtitle:"", tag:"", accent:0xDFA4F1, side:105, top:390),
    .init(locale:"en-US", file:"05-today-allocation", eyebrow:"", title:"From backtest to today's action", subtitle:"", tag:"", accent:0xF4B447, side:40, top:390),
    .init(locale:"en-US", file:"06-forward-strategy-library", eyebrow:"", title:"See macro shifts earlier", subtitle:"", tag:"", accent:0xEA9E45, side:125, top:390),
    .init(locale:"en-US", file:"07-multi-asset-share-poster", eyebrow:"", title:"Compare strategy performance fairly", subtitle:"", tag:"", accent:0x45D6B0, side:55, top:390)
]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: alpha)
}

func topRect(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x:x, y:CGFloat(H)-top-height, width:width, height:height)
}

func drawText(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat, font: NSFont, ink: NSColor, align: NSTextAlignment = .left, tracking: CGFloat = 0, maxHeight: CGFloat = 280) -> CGFloat {
    let p = NSMutableParagraphStyle(); p.alignment = align; p.lineBreakMode = .byWordWrapping; p.lineSpacing = 2
    let a: [NSAttributedString.Key:Any] = [.font:font, .foregroundColor:ink, .paragraphStyle:p, .kern:tracking]
    let s = NSAttributedString(string:text, attributes:a)
    let size = s.boundingRect(with:NSSize(width:width,height:maxHeight), options:[.usesLineFragmentOrigin,.usesFontLeading]).size
    s.draw(in:topRect(x:x,top:top,width:width,height:ceil(size.height)+8))
    return ceil(size.height)
}

func pill(_ text: String, x: CGFloat, top: CGFloat, accent: NSColor) {
    let font = NSFont.systemFont(ofSize:24, weight:.bold)
    let measured = (text as NSString).size(withAttributes:[.font:font]).width
    let trackingAllowance = CGFloat(max(0, text.count - 1))
    let w = max(118, measured + trackingAllowance + 58)
    let r = topRect(x:x,top:top,width:w,height:50)
    color(0xFFFFFF,0.055).setFill(); NSBezierPath(roundedRect:r,xRadius:25,yRadius:25).fill()
    accent.withAlphaComponent(0.38).setStroke(); let b=NSBezierPath(roundedRect:r,xRadius:25,yRadius:25); b.lineWidth=1.5; b.stroke()
    drawText(text,x:x+24,top:top+9,width:w-48,font:font,ink:accent,tracking:1,maxHeight:40)
}

func drawMotif(_ accent: NSColor, index: Int) {
    let orb = NSGradient(starting:accent.withAlphaComponent(0.20), ending:accent.withAlphaComponent(0))!
    let ox: CGFloat = index % 2 == 0 ? 640 : -280
    orb.draw(in:NSBezierPath(ovalIn:NSRect(x:ox,y:520,width:1040,height:1540)),relativeCenterPosition:.zero)
    let path=NSBezierPath(); path.move(to:NSPoint(x:-40,y:1780));
    for i in 0...7 { let x=CGFloat(i)*190-30; let y=1780+sin(CGFloat(i)*0.92+CGFloat(index))*85+CGFloat(index)*9; path.line(to:NSPoint(x:x,y:y)) }
    accent.withAlphaComponent(0.12).setStroke(); path.lineWidth=4; path.stroke()
}

func drawPhone(source: NSImage, x: CGFloat, top: CGFloat, accent: NSColor, index: Int) {
    // The strategy-library sheet is dense; show more vertical content so NFCI rows are actually visible.
    let width: CGFloat = index == 5 ? 1000 : 1102
    let height = width * source.size.height / source.size.width
    let rect = topRect(x:x,top:top,width:width,height:height)
    let shadow=NSShadow(); shadow.shadowColor=color(0x000000,0.85); shadow.shadowBlurRadius=48; shadow.shadowOffset=NSSize(width:0,height:-18)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); color(0x050608).setFill(); NSBezierPath(roundedRect:rect.insetBy(dx:-13,dy:-13),xRadius:58,yRadius:58).fill(); NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect:rect,xRadius:48,yRadius:48).addClip(); source.draw(in:rect,from:.zero,operation:.copy,fraction:1); NSGraphicsContext.restoreGraphicsState()
    accent.withAlphaComponent(0.62).setStroke(); let border=NSBezierPath(roundedRect:rect.insetBy(dx:-1,dy:-1),xRadius:49,yRadius:49); border.lineWidth=2.3; border.stroke()
    // Small editorial rail makes alternating layouts feel intentional.
    let railX = index % 2 == 0 ? rect.maxX + 18 : rect.minX - 30
    accent.withAlphaComponent(0.7).setFill(); NSBezierPath(roundedRect:NSRect(x:railX,y:rect.maxY-360,width:5,height:210),xRadius:3,yRadius:3).fill()
}

func fittedHeadlineFont(_ text: String, locale: String, width: CGFloat) -> NSFont {
    var size: CGFloat = locale == "zh-CN" ? 82 : 72
    while size > 42 {
        let font = NSFont.systemFont(ofSize:size,weight:.bold)
        let measured = (text as NSString).size(withAttributes:[.font:font,.kern:-1]).width
        if measured <= width { return font }
        size -= 1
    }
    return NSFont.systemFont(ofSize:42,weight:.bold)
}

func render(_ spec: PosterSpec, index: Int) throws {
    let srcURL=setRoot.appendingPathComponent("raw/\(spec.locale)/\(spec.file).png")
    guard let source=NSImage(contentsOf:srcURL) else { throw NSError(domain:"PosterV2",code:1,userInfo:[NSLocalizedDescriptionKey:"Missing \(srcURL.path)"]) }
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:W,pixelsHigh:H,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    bitmap.size=NSSize(width:W,height:H)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let canvas=NSRect(x:0,y:0,width:W,height:H)
    NSGradient(colors:[color(0x0A0B0E),color(0x12100E),color(0x050608)])!.draw(in:canvas,angle:-68)
    let accent=color(spec.accent)
    drawMotif(accent,index:index)
    // Sequence rail and number.
    accent.withAlphaComponent(0.9).setFill(); NSBezierPath(rect:topRect(x:72,top:74,width:94,height:5)).fill()
    drawText(String(format:"%02d",index+1),x:1050,top:62,width:120,font:.monospacedDigitSystemFont(ofSize:27,weight:.medium),ink:color(0xFFFFFF,0.38),align:.right,tracking:2,maxHeight:40)
    let headlineFont=fittedHeadlineFont(spec.title,locale:spec.locale,width:1090)
    drawText(spec.title,x:72,top:180,width:1090,font:headlineFont,ink:color(0xFFF8EA),tracking:-1,maxHeight:110)
    drawPhone(source:source,x:spec.side,top:spec.top,accent:accent,index:index)
    NSGraphicsContext.restoreGraphicsState()
    guard let data=bitmap.representation(using:.png,properties:[:]) else { throw NSError(domain:"PosterV2",code:2) }
    let out=setRoot.appendingPathComponent("posters/\(spec.locale)/\(spec.file).png")
    try FileManager.default.createDirectory(at:out.deletingLastPathComponent(),withIntermediateDirectories:true)
    try data.write(to:out); print("rendered \(out.path)")
}

for (i,s) in zh.enumerated() { try render(s,index:i) }
for (i,s) in en.enumerated() { try render(s,index:i) }
