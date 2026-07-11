// 앱 아이콘 생성기: 다크 스쿼클 + 흰 게이지 심볼 → assets/AppIcon.icns
// 실행: swift scripts/make-icon.swift  (레포 루트에서)
import AppKit

let repoRoot = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()  // scripts/
    .deletingLastPathComponent()  // repo root

func tinted(_ image: NSImage, color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    let rect = NSRect(origin: .zero, size: image.size)
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    rect.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

// 1024 master
let master = NSImage(size: NSSize(width: 1024, height: 1024))
master.lockFocus()
let squircle = NSBezierPath(
    roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
    xRadius: 186, yRadius: 186)
NSGradient(
    starting: NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.31, alpha: 1),
    ending: NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.11, alpha: 1)
)!.draw(in: squircle, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .medium)
if let symbol = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let colored = tinted(symbol, color: .white)
    let s = colored.size
    let scale = min(540 / s.width, 540 / s.height)
    let w = s.width * scale
    let h = s.height * scale
    colored.draw(
        in: NSRect(x: (1024 - w) / 2, y: (1024 - h) / 2, width: w, height: h),
        from: .zero, operation: .sourceOver, fraction: 1)
}
master.unlockFocus()

// iconset PNGs
let iconset = repoRoot.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func writePNG(_ px: Int, name: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    master.draw(
        in: NSRect(x: 0, y: 0, width: px, height: px),
        from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    writePNG(base, name: "icon_\(base)x\(base).png")
    writePNG(base * 2, name: "icon_\(base)x\(base)@2x.png")
}

// icns
let assets = repoRoot.appendingPathComponent("assets")
try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = [
    "-c", "icns", iconset.path,
    "-o", assets.appendingPathComponent("AppIcon.icns").path,
]
try! proc.run()
proc.waitUntilExit()
print(proc.terminationStatus == 0 ? "생성됨: assets/AppIcon.icns" : "iconutil 실패")
exit(proc.terminationStatus)
