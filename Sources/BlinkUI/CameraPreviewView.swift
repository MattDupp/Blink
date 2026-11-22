import SwiftUI

/// The camera picture with the eye squares drawn over it. Two windows show it: the setup,
/// to check that the squares sit on the eyes, and Live View, to show what is read.
///
/// It knows nothing about cameras or models: it is handed a picture, the frame's size and
/// the squares, and draws them.
public struct CameraPreviewView: View {

    private let image: CGImage?
    private let frameSize: CGSize
    private let eyeRects: [CGRect]
    private let tint: Color
    private let dashed: Bool
    private let placeholder: String

    /// - eyeRects: in camera pixels (origin top-left), as `EyeLocator` gives them.
    /// - placeholder: shown while there is no picture (starting, paused, access refused).
    /// - dashed: the squares are drawn dashed (Live View, while the eyes read as closed):
    ///   the state is then not said by colour alone.
    public init(image: CGImage?, frameSize: CGSize, eyeRects: [CGRect], tint: Color = .green, dashed: Bool = false, placeholder: String) {
        self.dashed = dashed
        self.image = image
        self.frameSize = frameSize
        self.eyeRects = eyeRects
        self.tint = tint
        self.placeholder = placeholder
    }

    public var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        // The squares are in camera pixels; the picture is drawn smaller.
                        // One factor converts one to the other.
                        GeometryReader { geometry in
                            let factor = geometry.size.width / max(frameSize.width, 1)
                            ForEach(Array(eyeRects.enumerated()), id: \.offset) { _, rect in
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(tint, style: StrokeStyle(lineWidth: 2, dash: dashed ? [5, 4] : []))
                                    .frame(width: rect.width * factor, height: rect.height * factor)
                                    .position(x: rect.midX * factor, y: rect.midY * factor)
                            }
                        }
                    }
            } else {
                Text(placeholder)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Camera picture")
    }
}
