import AppKit
import SwiftUI

/// Modal cropper: pan/zoom a photo inside a circular guide, then export a square PNG.
struct UserAvatarCropSheet: View {
    let sourceImage: NSImage
    let onCancel: () -> Void
    let onConfirm: (NSImage) -> Void

    @ObservedObject private var languageStore = LanguageStore.shared

    /// Side length of the interactive crop viewport.
    private let viewportSize: CGFloat = 280
    private let minScaleFactor: CGFloat = 1.0
    private let maxScaleFactor: CGFloat = 4.0

    @State private var baseCoverScale: CGFloat = 1
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 16) {
            Text(languageStore.t("settings.profile.cropTitle"))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(languageStore.t("settings.profile.cropHelp"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Image(nsImage: sourceImage)
                    .resizable()
                    .frame(
                        width: sourceImage.size.width * scale,
                        height: sourceImage.size.height * scale
                    )
                    .offset(offset)
                    .frame(width: viewportSize, height: viewportSize, alignment: .topLeading)
                    .clipped()
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                            .frame(width: viewportSize - 8, height: viewportSize - 8)
                            .allowsHitTesting(false)
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    dragStartOffset = offset
                                }
                                offset = CGSize(
                                    width: dragStartOffset.width + value.translation.width,
                                    height: dragStartOffset.height + value.translation.height
                                )
                                clampOffset()
                            }
                            .onEnded { _ in
                                isDragging = false
                                clampOffset()
                            }
                    )
            }
            .frame(width: viewportSize, height: viewportSize)
            .onAppear { resetToCover() }

            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { scale },
                        set: { newValue in
                            scale = newValue
                            clampOffset()
                        }
                    ),
                    in: sliderRange
                )
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            .frame(width: viewportSize)

            HStack(spacing: 12) {
                Text(languageStore.t("settings.profile.cropPreview"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(Color.black.opacity(0.2))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(nsImage: sourceImage)
                            .resizable()
                            .frame(
                                width: sourceImage.size.width * scale * (48 / viewportSize),
                                height: sourceImage.size.height * scale * (48 / viewportSize)
                            )
                            .offset(
                                x: offset.width * (48 / viewportSize),
                                y: offset.height * (48 / viewportSize)
                            )
                            .frame(width: 48, height: 48, alignment: .topLeading)
                            .clipped()
                    }
                    .clipShape(Circle())
                    .overlay(Circle().stroke(AppTheme.contentStroke, lineWidth: 1))
                Spacer(minLength: 0)
            }
            .frame(width: viewportSize)

            HStack {
                Button(languageStore.t("common.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .appSecondaryButton()
                Spacer()
                Button(languageStore.t("settings.profile.cropApply")) {
                    if let cropped = UserAvatarStore.renderCrop(
                        image: sourceImage,
                        scale: scale,
                        offset: offset,
                        viewportSize: viewportSize
                    ) {
                        onConfirm(cropped)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var sliderRange: ClosedRange<CGFloat> {
        let lower = baseCoverScale * minScaleFactor
        let upper = max(baseCoverScale * maxScaleFactor, lower + 0.01)
        return lower...upper
    }

    /// Fit image so the shorter side covers the viewport (center-crop ready).
    private func resetToCover() {
        let size = sourceImage.size
        guard size.width > 0, size.height > 0 else { return }
        baseCoverScale = max(viewportSize / size.width, viewportSize / size.height)
        scale = baseCoverScale
        let imgW = size.width * scale
        let imgH = size.height * scale
        offset = CGSize(
            width: (viewportSize - imgW) / 2,
            height: (viewportSize - imgH) / 2
        )
    }

    /// Keep the crop circle filled (no empty edges) when the image is large enough.
    private func clampOffset() {
        let imgW = sourceImage.size.width * scale
        let imgH = sourceImage.size.height * scale
        let x: CGFloat
        let y: CGFloat
        if imgW >= viewportSize {
            x = offset.width.clamped(to: (viewportSize - imgW)...0)
        } else {
            x = (viewportSize - imgW) / 2
        }
        if imgH >= viewportSize {
            y = offset.height.clamped(to: (viewportSize - imgH)...0)
        } else {
            y = (viewportSize - imgH) / 2
        }
        offset = CGSize(width: x, height: y)
    }
}

private extension Comparable {
    /// Clamp `self` into an inclusive range.
    ///
    /// - Parameter range: Closed range bounds. Required.
    /// - Returns: Value limited to `range`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
