#!/usr/bin/env swift
import AppKit
import Foundation

struct V4Spec { let file: String; let sourceFile: String; let title: String }

let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let setRoot = root.appendingPathComponent("marketing/app-store/2026-08-15-redesign")
let outRoot = setRoot.appendingPathComponent("v4-preview/zh-CN")
let W=1242, H=2688
let specs:[V4Spec] = [
    .init(file:"01-dashboard",sourceFile:"01-dashboard",title:"资产全景"),
    .init(file:"05-today-allocation",sourceFile:"05-today-allocation-clean",title:"今日调仓"),
    .init(file:"07-multi-asset-share-poster",sourceFile:"07-multi-asset-share-poster",title:"策略回测")
]

func color(_ hex:UInt32,_ alpha:CGFloat=1)->NSColor { NSColor(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:alpha) }
func topRect(_ x:CGFloat,_ top:CGFloat,_ width:CGFloat,_ height:CGFloat)->NSRect { NSRect(x:x,y:CGFloat(H)-top-height,width:width,height:height) }

func render(_ spec:V4Spec) throws {
    let srcURL=setRoot.appendingPathComponent("raw/zh-CN/\(spec.sourceFile).png")
    guard let source=NSImage(contentsOf:srcURL) else { throw NSError(domain:"V4",code:1,userInfo:[NSLocalizedDescriptionKey:"Missing \(srcURL.path)"]) }
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:W,pixelsHigh:H,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    bitmap.size=NSSize(width:W,height:H)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let canvas=NSRect(x:0,y:0,width:W,height:H)
    NSGradient(colors:[color(0xFAF8F3),color(0xEEE9DF)])!.draw(in:canvas,angle:-90)

    let p=NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byClipping
    let headline=NSAttributedString(string:spec.title,attributes:[.font:NSFont.systemFont(ofSize:84,weight:.bold),.foregroundColor:color(0x1A1815),.paragraphStyle:p,.kern:-1])
    headline.draw(in:topRect(71,150,1100,110))

    // Every poster uses this exact screenshot grid. No per-page scaling or offsets.
    let frame=topRect(70,360,1102,2240)
    let scale=frame.width/source.size.width
    let visibleSourceHeight=frame.height/scale
    let sourceRect=NSRect(x:0,y:source.size.height-visibleSourceHeight,width:source.size.width,height:visibleSourceHeight)

    let shadow=NSShadow(); shadow.shadowColor=color(0x322B21,0.20); shadow.shadowBlurRadius=44; shadow.shadowOffset=NSSize(width:0,height:-18)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); color(0x08090B).setFill(); NSBezierPath(roundedRect:frame,xRadius:48,yRadius:48).fill(); NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); NSBezierPath(roundedRect:frame,xRadius:48,yRadius:48).addClip(); source.draw(in:frame,from:sourceRect,operation:.copy,fraction:1); NSGraphicsContext.restoreGraphicsState()
    color(0x1A1815,0.09).setStroke(); let border=NSBezierPath(roundedRect:frame.insetBy(dx:-1,dy:-1),xRadius:49,yRadius:49); border.lineWidth=2; border.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try FileManager.default.createDirectory(at:outRoot,withIntermediateDirectories:true)
    let out=outRoot.appendingPathComponent("\(spec.file).png")
    try bitmap.representation(using:.png,properties:[:])!.write(to:out)
    print("rendered \(out.path)")
}

for spec in specs { try render(spec) }
