import AppKit
let size = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 200, yRadius: 200).fill()
NSColor(calibratedWhite: 0.25, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 262, y: 200, width: 500, height: 500)).fill()
NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 412, y: 350, width: 200, height: 200)).fill()
NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.95, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 372, y: 770, width: 280, height: 60), xRadius: 30, yRadius: 30).fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
