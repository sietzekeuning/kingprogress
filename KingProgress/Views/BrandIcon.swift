import SwiftUI

/// The KingProgress mark: a crown above a progress ring, drawn on a 24x24
/// grid like the SVG the Electron version used.
struct BrandIcon: View {
    var size: CGFloat = 18

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 24

            var crown = Path()
            crown.move(to: CGPoint(x: 6, y: 3.25))
            crown.addLine(to: CGPoint(x: 9.25, y: 5.25))
            crown.addLine(to: CGPoint(x: 12, y: 1.75))
            crown.addLine(to: CGPoint(x: 14.75, y: 5.25))
            crown.addLine(to: CGPoint(x: 18, y: 3.25))
            crown.addLine(to: CGPoint(x: 16.75, y: 7.75))
            crown.addLine(to: CGPoint(x: 7.25, y: 7.75))
            crown.closeSubpath()
            context.fill(crown.applying(CGAffineTransform(scaleX: scale, y: scale)), with: .style(.foreground))

            // The ring: radius 7.5 around (12, 14.3), open at the top where
            // the crown sits. 72% of it is drawn in full colour, the rest faint.
            let center = CGPoint(x: 12, y: 14.315)
            let start = -39.9 * .pi / 180
            let sweep = 259.8 * .pi / 180

            func arc(fraction: Double) -> Path {
                var path = Path()
                let steps = 64
                for step in 0 ... steps {
                    let angle = start + sweep * fraction * Double(step) / Double(steps)
                    let point = CGPoint(x: (center.x + 7.5 * cos(angle)) * scale, y: (center.y + 7.5 * sin(angle)) * scale)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                return path
            }

            let stroke = StrokeStyle(lineWidth: 2 * scale, lineCap: .round)
            context.stroke(arc(fraction: 1), with: .style(.foreground.opacity(0.32)), style: stroke)
            context.stroke(arc(fraction: 0.72), with: .style(.foreground), style: stroke)
        }
        .frame(width: size, height: size)
    }
}
