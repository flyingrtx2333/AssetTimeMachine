#!/usr/bin/env swift
import AppKit
import Foundation

struct V5Spec {
    let file: String
    let sourceFile: String
    let title: String
    let backgroundTop: UInt32
    let backgroundBottom: UInt32
    let accent: UInt32
}

let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let setRoot=root.appendingPathComponent("marketing/app-store/2026-08-15-redesign")
let outRoot=setRoot.appendingPathComponent("v5-preview/zh-CN")
let W=1242, H=2688
let specs:[V5Spec]=[
    .init(file:"01-dashboard",sourceFile:"01-dashboard",title:"资产全景",backgroundTop:0x4A361B,backgroundBottom:0x17120C,accent:0xF1D08E),
    .init(file:"05-today-allocation",sourceFile:"05-today-allocation-clean",title:"今日调仓",backgroundTop:0x56301A,backgroundBottom:0x1A100B,accent:0xF3BE70),
    .init(file:"07-multi-asset-share-poster",sourceFile:"07-multi-asset-share-poster",title:"策略回测",backgroundTop:0x17483E,backgroundBottom:0x0A1815,accent:0x8CE1C9)
]

func c(_ hex:UInt32,_ alpha:CGFloat=1)->NSColor { NSColor(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:alpha) }
func topRect(_ x:CGFloat,_ top:CGFloat,_ width:CGFloat,_ height:CGFloat)->NSRect { NSRect(x:x,y:CGFloat(H)-top-height,width:width,height:height) }

func render(_ spec:V5Spec) throws {
    let srcURL=setRoot.appendingPathComponent("raw/zh-CN/\(spec.sourceFile).png")
    guard let source=NSImage(contentsOf:srcURL) else { throw NSError(domain:"V5",code:1,userInfo:[NSLocalizedDescriptionKey:"Missing \(srcURL.path)"]) }
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:W,pixelsHigh:H,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    bitmap.size=NSSize(width:W,height:H)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let canvas=NSRect(x:0,y:0,width:W,height:H)
    NSGradient(colors:[c(spec.backgroundTop),c(spec.backgroundBottom)])!.draw(in:canvas,angle:-90)

    // Soft brand glow, shared geometry across the set.
    let glow=NSGradient(starting:c(spec.accent,0.22),ending:c(spec.accent,0))!
    glow.draw(in:NSBezierPath(ovalIn:NSRect(x:120,y:CGFloat(H)-520,width:1002,height:420)),relativeCenterPosition:.zero)

    let paragraph=NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byClipping
    let title=NSAttributedString(string:spec.title,attributes:[.font:NSFont.systemFont(ofSize:84,weight:.bold),.foregroundColor:c(spec.accent),.paragraphStyle:paragraph,.kern:-1])
    title.draw(in:topRect(71,140,1100,110))

    // Full screenshot, aspect-fit. All three use the exact same width and top position.
    let imageWidth:CGFloat=1020
    let imageHeight=imageWidth*source.size.height/source.size.width
    let frame=topRect((CGFloat(W)-imageWidth)/2,390,imageWidth,imageHeight)

    let shadow=NSShadow(); shadow.shadowColor=c(0x000000,0.48); shadow.shadowBlurRadius=48; shadow.shadowOffset=NSSize(width:0,height:-20)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); c(0x050608).setFill(); NSBezierPath(roundedRect:frame,xRadius:48,yRadius:48).fill(); NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect:frame,xRadius:48,yRadius:48).addClip(); source.draw(in:frame,from:.zero,operation:.copy,fraction:1); NSGraphicsContext.restoreGraphicsState()
    c(spec.accent,0.24).setStroke(); let border=NSBezierPath(roundedRect:frame.insetBy(dx:-1,dy:-1),xRadius:49,yRadius:49); border.lineWidth=2; border.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try FileManager.default.createDirectory(at:outRoot,withIntermediateDirectories:true)
    let out=outRoot.appendingPathComponent("\(spec.file).png")
    try bitmap.representation(using:.png,properties:[:])!.write(to:out)
    print("rendered \(out.path) frame=\(Int(imageWidth))x\(Int(imageHeight)) bottom=\(Int(390+imageHeight))")
}
for spec in specs { try render(spec) }
