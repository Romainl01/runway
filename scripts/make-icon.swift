// Renders the Runway app icon (black square, small white gauge) as a 1024 px PNG.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824 px body centred in 1024, continuous-ish corners.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
NSColor.black.setFill()
NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).fill()

// Mini gauge: track white 22 %, fill white at 62 %.
let track = NSRect(x: 292, y: 488, width: 440, height: 48)
NSColor(white: 1, alpha: 0.22).setFill()
NSBezierPath(roundedRect: track, xRadius: 24, yRadius: 24).fill()
var fill = track
fill.size.width = track.width * 0.62
NSColor.white.setFill()
NSBezierPath(roundedRect: fill, xRadius: 24, yRadius: 24).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
