// 앱 아이콘을 코드로 그려서 여러 해상도 PNG로 내보내는 1회성 스크립트.
// 사용: swift Resources/generate_icon.swift <출력 디렉터리>
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let corner = size * 0.22
    let bg = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.12, alpha: 1)
    ])
    gradient?.draw(in: bg, angle: -90)

    // 두 개의 세로 "게이지" 막대: Codex(주황)와 Claude(청록)를 상징
    let barWidth = size * 0.16
    let gap = size * 0.10
    let baseY = size * 0.18
    let maxHeight = size * 0.64
    let totalWidth = barWidth * 2 + gap
    let startX = (size - totalWidth) / 2

    func bar(x: CGFloat, heightFraction: CGFloat, color: NSColor) {
        let h = maxHeight * heightFraction
        let barRect = NSRect(x: x, y: baseY, width: barWidth, height: h)
        let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth * 0.3, yRadius: barWidth * 0.3)
        color.setFill()
        path.fill()
    }

    bar(x: startX, heightFraction: 0.55, color: NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.20, alpha: 1))
    bar(x: startX + barWidth + gap, heightFraction: 0.85, color: NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.75, alpha: 1))

    image.unlockFocus()
    return image
}

for size in sizes {
    let image = drawIcon(size: CGFloat(size))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let path = "\(outDir)/icon_\(size)x\(size).png"
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
