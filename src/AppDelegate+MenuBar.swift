// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Cocoa

// MARK: - 图标与动画

extension AppDelegate {
    func setIcon(connected: Bool) {
        guard let button = item.button else { return }
        let dark = menuBarIsDark()
        // 模板图由系统自动适配深浅色，只需按连接状态缓存两张。
        let key = connected ? "connected" : "disconnected"
        let name = connected ? "lock.shield.fill" : "lock.shield"

        // 常驻期间只生成一次小位图；之后每次轮询复用，不再保留 SF Symbol 的矢量图。
        if let cached = iconCache[key] {
            // 忙碌动画会临时换上 busyFrames；即使缓存命中也要确认按钮当前不是动画帧
            if button.image !== cached {
                button.image = cached
                button.title = ""
                button.contentTintColor = nil
                button.needsDisplay = true
            }
        } else if let img = rasterizedSymbol(name) {
            iconCache[key] = img
            button.image = img
            button.title = ""
            button.contentTintColor = nil
            button.needsDisplay = true
        } else {
            button.image = nil
            button.title = "VPN"
            button.contentTintColor = dark ? .white : .black
        }

        let flag = "connected=\(connected) dark=\(dark)"
        if flag != lastIconLog {
            lastIconLog = flag
            logLine("icon \(flag) appearance=\(button.effectiveAppearance.name.rawValue) color=\(iconColor(dark: dark))")
        }
    }

    private func menuBarIsDark() -> Bool {
        let appearance = item.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func iconColor(dark: Bool) -> NSColor {
        dark ? .white : .black
    }

    /// 把 SF Symbol 一次性栅格化成小位图。不要缓存带 drawing handler 的 NSImage：
    /// 那样会把整个矢量图及其解析缓存一起留住，实测常驻内存反而多出 1–2 MB。
    private func rasterizedSymbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "VPN")?
            .withSymbolConfiguration(cfg) else { return nil }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let points = base.size
        let pxW = max(1, Int(ceil(points.width * scale)))
        let pxH = max(1, Int(ceil(points.height * scale)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = points

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        base.draw(in: NSRect(origin: .zero, size: points))

        // 模板图只用 alpha 通道，系统会按菜单栏外观自动着色
        let out = NSImage(size: points)
        out.addRepresentation(rep)
        out.isTemplate = true
        return out
    }

    /// 调试导出用：带颜色的完整尺寸图标（不参与常驻图标路径）
    private func tintedSymbol(_ name: String, color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "VPN")?
            .withSymbolConfiguration(cfg) else { return nil }
        let out = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }

    /// 进入「操作进行中」状态：图标在实心/空心锁之间切换
    func startBusyAnimation() {
        guard animTimer == nil else { return }
        guard let hollow = rasterizedSymbol("lock.shield"),
              let filled = rasterizedSymbol("lock.shield.fill") else { return }

        // 先显示与当前状态相反的那一个，点下去立刻有反馈
        let connectedNow = isConnected()
        let ordered = connectedNow ? [hollow, filled] : [filled, hollow]

        // 两个符号的包围盒可能差零点几像素；统一画布，切换时菜单栏图标不会左右跳
        let canvas = NSSize(width: max(hollow.size.width, filled.size.width),
                            height: max(hollow.size.height, filled.size.height))
        busyFrames = ordered.map { centered($0, in: canvas) }
        busyFrameIndex = 0
        applyBusyFrame()

        // .common 模式：打开菜单、弹窗时也能继续切
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self, !self.busyFrames.isEmpty else { return }
            self.busyFrameIndex = (self.busyFrameIndex + 1) % self.busyFrames.count
            self.applyBusyFrame()
        }
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    private func centered(_ image: NSImage, in size: NSSize) -> NSImage {
        let out = NSImage(size: size, flipped: false) { rect in
            let x = (rect.width - image.size.width) / 2
            let y = (rect.height - image.size.height) / 2
            image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height))
            return true
        }
        // 重新画到画布后要保留模板标记，否则忙碌动画在深色菜单栏里会变成黑图标
        out.isTemplate = image.isTemplate
        return out
    }

    private func applyBusyFrame() {
        guard busyFrames.indices.contains(busyFrameIndex), let button = item.button else { return }
        button.image = busyFrames[busyFrameIndex]
        button.needsDisplay = true
    }

    func stopBusyAnimation() {
        animTimer?.invalidate()
        animTimer = nil
        busyFrames = []
        busyFrameIndex = 0
        item.button?.alphaValue = 1.0
    }

    func dumpIcon(connected: Bool, to path: String) {
        let dark = menuBarIsDark()
        let color = iconColor(dark: dark)
        let name = connected ? "lock.shield.fill" : "lock.shield"
        guard let icon = tintedSymbol(name, color: color) else { return }
        let scale: CGFloat = 10
        let out = NSImage(size: NSSize(width: icon.size.width * scale,
                                       height: icon.size.height * scale),
                          flipped: false) { rect in
            NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1).setFill()
            rect.fill()
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(in: rect)
            return true
        }
        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
