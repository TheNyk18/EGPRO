import AppKit
import SwiftUI

/// Fundal de "sticla mata" (se vede desktopul din spate, incetosat).
/// `transparency`: 0 = aproape opac, 1 = foarte transparent.
struct GlassBackground: NSViewRepresentable {
    var transparency: Double

    func makeNSView(context: Context) -> GlassView {
        let view = GlassView()
        view.transparency = transparency
        return view
    }

    func updateNSView(_ nsView: GlassView, context: Context) {
        nsView.transparency = transparency
    }
}

final class GlassView: NSVisualEffectView {
    var transparency: Double = 0.65 {
        didSet { applyTransparency() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) nu e folosit")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTransparency()
        // Fereastra din bara de sus isi termina configurarea putin mai tarziu.
        DispatchQueue.main.async { [weak self] in self?.applyTransparency() }
    }

    private func applyTransparency() {
        let t = min(max(transparency, 0), 1)
        alphaValue = CGFloat(1.0 - t * 0.9)

        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear

        // Ascundem fundalul standard al ferestrei, ca sa ramana doar al nostru.
        if let root = window.contentView?.superview ?? window.contentView {
            for effect in Self.effectViews(in: root) where effect !== self {
                effect.alphaValue = 0
            }
        }
    }

    private static func effectViews(in view: NSView) -> [NSVisualEffectView] {
        var found: [NSVisualEffectView] = []
        if let effect = view as? NSVisualEffectView {
            found.append(effect)
        }
        for sub in view.subviews {
            found.append(contentsOf: effectViews(in: sub))
        }
        return found
    }
}
