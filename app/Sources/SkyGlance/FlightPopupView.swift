import OverheadKit
import SwiftUI

/// The card that unfolds from the menu bar icon.
///
/// Ordered by what is useful in the sixty seconds the aircraft is actually
/// overhead: where to look first, what it is second, everything else after.
struct FlightPopupView: View {
    @ObservedObject var presenter: FlightPopupPresenter

    var body: some View {
        Group {
            if let content = presenter.content {
                card(content)
                    .opacity(presenter.isRevealed ? 1 : 0)
                    // Anchored at the top so it reads as unfolding *from* the
                    // menu bar rather than fading in place. Skipped entirely
                    // under Reduce Motion.
                    .scaleEffect(presenter.isRevealed || presenter.prefersReducedMotion ? 1 : 0.90,
                                 anchor: .top)
                    .offset(y: presenter.isRevealed || presenter.prefersReducedMotion ? 0 : -10)
            }
        }
        .frame(width: FlightPopupPresenter.size.width,
               height: FlightPopupPresenter.size.height,
               alignment: .top)
    }

    private func card(_ content: FlightPopupContent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            photo(content)

            VStack(alignment: .leading, spacing: 3) {
                // The headline is the instruction — "Look SE — Lufthansa" —
                // because pointing your face is the only time-critical part.
                Text(content.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    glyph(content)
                    Text(content.typeLabel)
                        .font(.system(size: 11, weight: .medium))
                    if let op = content.operatorName {
                        Text(op)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if let route = content.route {
                    Text(route)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(content.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { presenter.openMainPanel() }
        .onHover { presenter.isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(content.headline). \(content.typeLabel). \(content.detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the SkyGlance panel")
    }

    /// Fixed height whether or not a photo ever arrives, so a late image
    /// cross-fades in without the card resizing under the pointer.
    private func photo(_ content: FlightPopupContent) -> some View {
        ZStack {
            Rectangle().fill(content.categoryTint.opacity(0.14))
            if let url = content.photoURL, let parsed = URL(string: url) {
                // Phase-based, with an animated transaction. The two-closure
                // form does not animate its own placeholder→loaded swap, and a
                // `.transition` on the outside fires when `photoURL` becomes
                // non-nil — which is while the image is still loading, so the
                // thing that faded in was the empty placeholder and the real
                // pixels appeared abruptly a moment later.
                AsyncImage(url: parsed,
                           transaction: Transaction(animation: .easeInOut(duration: 0.3))) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
            } else {
                // Not a spinner: most aircraft resolve no photo at all, and a
                // spinner that never resolves reads as broken.
                Image(systemName: "airplane")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(content.categoryTint.opacity(0.45))
            }
        }
        .frame(height: 104)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    /// The same silhouette the dome draws, rotated to the real heading — so the
    /// shape you see here is the shape you are looking for up there.
    private func glyph(_ content: FlightPopupContent) -> some View {
        Canvas { context, size in
            guard let track = content.trackDegrees else {
                let d: CGFloat = 5
                context.fill(Path(ellipseIn: CGRect(x: size.width / 2 - d / 2,
                                                    y: size.height / 2 - d / 2,
                                                    width: d, height: d)),
                             with: .color(content.categoryTint))
                return
            }
            var g = context
            g.translateBy(x: size.width / 2, y: size.height / 2)
            g.rotate(by: .degrees(track))
            g.fill(SkyDomeView.dart(size: 6), with: .color(content.categoryTint))
        }
        .frame(width: 14, height: 14)
    }
}
