// Luma — Minimal glass / liquid-glass UI helpers (Apple + Linear inspired).
// No new dependencies; macOS SwiftUI + AppKit only.
import SwiftUI
import AppKit

// MARK: - VisualEffectView (NSVisualEffectView wrapper)

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - GlassBackground (frosted chrome surface)

struct GlassBackground: View {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 0
    var shadowOpacity: Double = 0.06

    var body: some View {
        VisualEffectView(
            material: material,
            blendingMode: .behindWindow,
            state: .active
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .padding(padding)
        .shadow(color: .black.opacity(shadowOpacity), radius: 8, y: 2)
    }
}

// MARK: - HairlineDivider (1px, very low opacity)

struct HairlineDivider: View {
    var opacity: Double = 0.2

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(opacity))
            .frame(height: 1)
    }
}
