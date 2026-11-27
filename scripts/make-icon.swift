// Renders the Runway app icon (black square, white plane) as a 1024 px PNG.
// The plane comes from scripts/PlaneGlyph.swift, so the script runs with that file in front:
// Usage: cat scripts/PlaneGlyph.swift scripts/make-icon.swift > build/make-icon.swift && swift build/make-icon.swift <out.png>
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

// Plane: fits a 440 px square, about half the body, centred.
NSColor.white.setFill()
PlaneGlyph.path(in: NSRect(x: 292, y: 292, width: 440, height: 440)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
