// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Cocoa

// 生成 VPNMenu 的 App 图标（1024x1024 PNG）
// 用法: swiftc -O -framework Cocoa -o make-icon make-icon.swift && ./make-icon out.png

let S: CGFloat = 1024

func squircle(in rect: NSRect, n: CGFloat = 5.0) -> NSBezierPath {
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    let p = NSBezierPath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { p.move(to: NSPoint(x: x, y: y)) } else { p.line(to: NSPoint(x: x, y: y)) }
    }
    p.close()
    return p
}

func tintedImage(_ base: NSImage, size: NSSize,
                 top: NSColor, bottom: NSColor) -> NSImage {
    return NSImage(size: size, flipped: false) { r in
        base.draw(in: r)
        let grad = NSGradient(starting: top, ending: bottom)!
        let gradImg = NSImage(size: r.size, flipped: false) { gr in
            grad.draw(in: gr, angle: -90)
            return true
        }
        gradImg.draw(in: r, from: .zero, operation: .sourceAtop, fraction: 1.0)
        return true
    }
}

let out = NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
    let inset: CGFloat = 100
    let bgRect = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let bg = squircle(in: bgRect)

    // 底色投影
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.30)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(srgbRed: 0.10, green: 0.24, blue: 0.62, alpha: 1).setFill()
    bg.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 蓝色渐变主体
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    let bgGrad = NSGradient(colors: [
        NSColor(srgbRed: 0.33, green: 0.60, blue: 0.99, alpha: 1),
        NSColor(srgbRed: 0.11, green: 0.27, blue: 0.70, alpha: 1),
        NSColor(srgbRed: 0.06, green: 0.16, blue: 0.48, alpha: 1),
    ])!
    bgGrad.draw(in: bgRect, angle: -72)

    // 顶部高光，让图标有体积感
    let sheen = NSGradient(colors: [
        NSColor(white: 1, alpha: 0.30),
        NSColor(white: 1, alpha: 0.0),
    ])!
    sheen.draw(in: NSRect(x: bgRect.minX, y: bgRect.midY,
                          width: bgRect.width, height: bgRect.height / 2),
               angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 细内描边
    NSGraphicsContext.saveGraphicsState()
    bg.lineWidth = 3
    NSColor(white: 1, alpha: 0.16).setStroke()
    bg.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // 白色盾牌
    let cfg = NSImage.SymbolConfiguration(pointSize: 520, weight: .regular)
    guard let sym = NSImage(systemSymbolName: "lock.shield.fill",
                            accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return true }
    let sz = sym.size
    let target = NSRect(x: (S - sz.width) / 2,
                        y: (S - sz.height) / 2 + 14,
                        width: sz.width, height: sz.height)

    NSGraphicsContext.saveGraphicsState()
    let sShadow = NSShadow()
    sShadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    sShadow.shadowBlurRadius = 22
    sShadow.shadowOffset = NSSize(width: 0, height: -10)
    sShadow.set()
    let white = tintedImage(sym, size: sz,
                            top: NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
                            bottom: NSColor(srgbRed: 0.84, green: 0.90, blue: 1.00, alpha: 1))
    white.draw(in: target)
    NSGraphicsContext.restoreGraphicsState()

    return true
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
guard let tiff = out.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: path))
print("wrote \(path)")
