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

    // 두 개의 원형 게이지 링: 바깥쪽 주황(5H), 안쪽 청록(1W) — 사용률 계기판 느낌
    let orange = NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.20, alpha: 1)
    let teal = NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.75, alpha: 1)
    let center = NSPoint(x: size / 2, y: size / 2)

    func ring(radius: CGFloat, lineWidth: CGFloat, color: NSColor, fraction: CGFloat) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        color.withAlphaComponent(0.18).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        let start: CGFloat = 90
        let end = start - 360 * fraction
        arc.appendArc(withCenter: center, radius: radius, startAngle: end, endAngle: start)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    ring(radius: size * 0.34, lineWidth: size * 0.085, color: orange, fraction: 0.68)
    ring(radius: size * 0.22, lineWidth: size * 0.085, color: teal, fraction: 0.85)

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
