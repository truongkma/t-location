// Renders the TLocation icon (blue gradient + white pin) to assets/tlocation-icon.png.
import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let ctx = NSGraphicsContext.current!.cgContext

// Background gradient — matches the .icon bundle's fill (approximated in sRGB).
let colors = [
    CGColor(red: 0.381, green: 0.788, blue: 0.979, alpha: 1),
    CGColor(red: 0.208, green: 0.425, blue: 0.946, alpha: 1)
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])

// White map pin — round head + tapered tail, similar to TLocation.icon/Assets/Pin.svg.
// (The head is a circle; the tail is two symmetric bezier curves down to a point.)
let headCenter = CGPoint(x: 512, y: 620)
let headRadius: CGFloat = 280
let apex = CGPoint(x: 512, y: 100)
let leftAttach = CGPoint(x: 297.5, y: 440)
let rightAttach = CGPoint(x: 726.5, y: 440)

let pin = CGMutablePath()
pin.move(to: rightAttach)
// Sweep counterclockwise from the right attach point, over the top, to the left attach point.
pin.addArc(center: headCenter, radius: headRadius,
           startAngle: -40 * .pi / 180, endAngle: 220 * .pi / 180, clockwise: false)
pin.addCurve(to: apex, control1: CGPoint(x: 297.5, y: 260), control2: CGPoint(x: 460, y: 130))
pin.addCurve(to: rightAttach, control1: CGPoint(x: 564, y: 130), control2: CGPoint(x: 726.5, y: 260))
pin.closeSubpath()
pin.addEllipse(in: CGRect(x: headCenter.x - 90, y: headCenter.y - 90, width: 180, height: 180))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.addPath(pin)
ctx.fillPath(using: .evenOdd)

NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
try! FileManager.default.createDirectory(atPath: "assets", withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: "assets/tlocation-icon.png"))
print("wrote assets/tlocation-icon.png")
