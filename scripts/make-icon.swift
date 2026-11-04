// Disegna l'icona di Pina e genera Resources/AppIcon.icns.
// Uso: swift scripts/make-icon.swift
import AppKit

func disegna(_ lato: CGFloat) -> NSImage {
    // Direzione "Spugna": tessera lavanda, spugna gialla con abrasivo verde, bolle.
    NSImage(size: NSSize(width: lato, height: lato), flipped: true) { r in
        let u = lato / 128
        func rett(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ raggio: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: NSRect(x: x * u, y: y * u, width: w * u, height: h * u), xRadius: raggio * u, yRadius: raggio * u)
        }
        func cerchio(_ cx: CGFloat, _ cy: CGFloat, _ raggio: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: (cx - raggio) * u, y: (cy - raggio) * u, width: raggio * 2 * u, height: raggio * 2 * u))
        }
        let lavanda = NSColor(red: 0.357, green: 0.247, blue: 0.769, alpha: 1)
        let giallo = NSColor(red: 1, green: 0.784, blue: 0.239, alpha: 1)
        let verde = NSColor(red: 0.247, green: 0.725, blue: 0.541, alpha: 1)
        let pori = NSColor(red: 0.878, green: 0.647, blue: 0.125, alpha: 1)

        lavanda.setFill(); rett(13, 13, 102, 102, 23).fill()

        // Spugna inclinata.
        NSGraphicsContext.current?.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: 64 * u, yBy: 78 * u); t.rotate(byDegrees: -10); t.translateX(by: -64 * u, yBy: -78 * u)
        t.concat()
        giallo.setFill(); rett(26, 56, 76, 46, 13).fill()
        verde.setFill(); rett(26, 56, 76, 14, 7).fill()
        pori.setFill()
        for (x, y, d) in [(42.0, 82.0, 4.0), (60, 92, 3.2), (80, 80, 4.6), (90, 93, 2.6)] { cerchio(x, y, d).fill() }
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.white.setStroke()
        for (x, y, d, w) in [(80.0, 38.0, 10.0, 3.4), (98, 27, 6, 2.6), (62, 32, 5, 2.4)] {
            let c = cerchio(x, y, d); c.lineWidth = w * u; c.stroke()
        }
        return true
    }
}

let set = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for lato in [16, 32, 128, 256, 512] {
    for scala in [1, 2] {
        let px = lato * scala
        let img = disegna(CGFloat(px))
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        let nome = scala == 1 ? "icon_\(lato)x\(lato).png" : "icon_\(lato)x\(lato)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(nome))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print("Resources/AppIcon.icns")
