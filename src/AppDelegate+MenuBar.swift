// Copyright (C) 2026 lcssos
// SPDX-License-Identifier: AGPL-3.0-only

import Cocoa

// MARK: - 图标与动画

extension AppDelegate {
    func setIcon(connected: Bool) {
        guard let button = item.button else { return }
        let dark = menuBarIsDark()
        let name = connected ? "lock.shield.fill" : "lock.shield"
        let color = iconColor(dark: dark)
        if let img = tintedSymbol(name, color: color) {
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
            logLine("icon \(flag) appearance=\(button.effectiveAppearance.name.rawValue) color=\(color)")
        }
    }

    private func menuBarIsDark() -> Bool {
        let appearance = item.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func iconColor(dark: Bool) -> NSColor {
        dark ? .white : .black
    }

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
        let color = iconColor(dark: menuBarIsDark())
        guard let hollow = tintedSymbol("lock.shield", color: color),
              let filled = tintedSymbol("lock.shield.fill", color: color) else { return }

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
        NSImage(size: size, flipped: false) { rect in
            let x = (rect.width - image.size.width) / 2
            let y = (rect.height - image.size.height) / 2
            image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height))
            return true
        }
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
