#!/usr/bin/env swift
import AppKit
import Foundation

struct PreviewSpec {
    let locale: String
    let file: String
    let headline: String
    let accent: UInt32
    let cropTop: CGFloat
    let cropBottom: CGFloat
    let cardWidth: CGFloat
    let cardTop: CGFloat
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let setRoot = root.appendingPathComponent("marketing/app-store/2026-08-15-redesign")
let outputRoot = setRoot.appendingPathComponent("v3-preview")
let W = 1242
let H = 2688

let specs: [PreviewSpec] = [
    .init(locale:"zh-CN", file:"01-dashboard", headline:"资产全景", accent:0xB98535, cropTop:0, cropBottom:2700, cardWidth:1082, cardTop:390),
    .init(locale:"zh-CN", file:"05-today-allocation", headline:"今日调仓", accent:0xB77A22, cropTop:180, cropBottom:2100, cardWidth:1242, cardTop:390),
    .init(locale:"zh-CN", file:"07-multi-asset-share-poster", headline:"策略回测", accent:0x268E78, cropTop:170, cropBottom:2420, cardWidth:1082, cardTop:390),
    .init(locale:"en-US", file:"01-dashboard", headline:"Portfolio Overview", accent:0xB98535, cropTop:0, cropBottom:2700, cardWidth:1082, cardTop:390),
    .init(locale:"en-US", file:"05-today-allocation", headline:"Today's Allocation", accent:0xB77A22, cropTop:180, cropBottom:2100, cardWidth:1242, cardTop:390),
    .init(locale:"en-US", file:"07-multi-asset-share-poster", headline:"Strategy Backtest", accent:0x268E78, cropTop:170, cropBottom:2420, cardWidth:1082, cardTop:390)
]

func c(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:alpha)
}

func topRect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x:x,y:CGFloat(H)-top-height,width:width,height:height)
}

func fittedFont(_ text: String, locale: String, width: CGFloat) -> NSFont {
    var size: CGFloat = locale == "zh-CN" ? 82 : 68
    while size > 46 {
        let font=NSFont.systemFont(ofSize:size,weight:.bold)
        if (text as NSString).size(withAttributes:[.font:font,.kern:-1]).width <= width { return font }
        size -= 1
    }
    return .systemFont(ofSize:46,weight:.bold)
}

func drawHeadline(_ text: String, locale: String, accent: NSColor) {
    let width: CGFloat=1090
    let font=fittedFont(text,locale:locale,width:width)
    let paragraph=NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byClipping
    let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:c(0x1A1815),.paragraphStyle:paragraph,.kern:-1]
    let string=NSAttributedString(string:text,attributes:attrs)
    string.draw(in:topRect(76,170,width,110))
    accent.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect:topRect(571,305,100,7),xRadius:4,yRadius:4).fill()
}

func drawCard(source: NSImage, spec: PreviewSpec, accent: NSColor) {
    let x=(CGFloat(W)-spec.cardWidth)/2
    let sourceWidth=source.size.width
    let cropTop=max(0,spec.cropTop)
    let cropBottom=min(source.size.height,spec.cropBottom)
    let cropHeight=max(1,cropBottom-cropTop)
    let scale=spec.cardWidth/sourceWidth
    let cardHeight=cropHeight*scale
    let card=topRect(x,spec.cardTop,spec.cardWidth,cardHeight)
    let sourceRect=NSRect(x:0,y:source.size.height-cropBottom,width:sourceWidth,height:cropHeight)

    let shadow=NSShadow(); shadow.shadowColor=c(0x312A20,0.24); shadow.shadowBlurRadius=52; shadow.shadowOffset=NSSize(width:0,height:-22)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); c(0x050608).setFill(); NSBezierPath(roundedRect:card,xRadius:52,yRadius:52).fill(); NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect:card,xRadius:52,yRadius:52).addClip(); source.draw(in:card,from:sourceRect,operation:.copy,fraction:1); NSGraphicsContext.restoreGraphicsState()

    let border=NSBezierPath(roundedRect:card.insetBy(dx:-1,dy:-1),xRadius:53,yRadius:53)
    accent.withAlphaComponent(0.16).setStroke(); border.lineWidth=2; border.stroke()
}

func render(_ spec: PreviewSpec) throws {
    let src=setRoot.appendingPathComponent("raw/\(spec.locale)/\(spec.file).png")
    guard let source=NSImage(contentsOf:src) else { throw NSError(domain:"PreviewV3",code:1,userInfo:[NSLocalizedDescriptionKey:"Missing \(src.path)"]) }
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:W,pixelsHigh:H,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    bitmap.size=NSSize(width:W,height:H)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let canvas=NSRect(x:0,y:0,width:W,height:H)
    let accent=c(spec.accent)
    NSGradient(colors:[c(0xFAF7F0),c(0xEFE8DC),accent.withAlphaComponent(0.13)])!.draw(in:canvas,angle:-84)
    drawHeadline(spec.headline,locale:spec.locale,accent:accent)
    drawCard(source:source,spec:spec,accent:accent)
    NSGraphicsContext.restoreGraphicsState()
    let out=outputRoot.appendingPathComponent("\(spec.locale)/\(spec.file).png")
    try FileManager.default.createDirectory(at:out.deletingLastPathComponent(),withIntermediateDirectories:true)
    guard let data=bitmap.representation(using:.png,properties:[:]) else { throw NSError(domain:"PreviewV3",code:2) }
    try data.write(to:out)
    print("rendered \(out.path)")
}

for spec in specs { try render(spec) }
