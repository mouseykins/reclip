import SwiftUI

struct RangeSliderView: View {
    @Binding var start: Double
    @Binding var end: Double
    let range: ClosedRange<Double>
    var onSeek: ((Double) -> Void)? = nil

    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - thumbSize
            let totalRange = range.upperBound - range.lowerBound
            let startFraction = totalRange > 0 ? (start - range.lowerBound) / totalRange : 0
            let endFraction = totalRange > 0 ? (end - range.lowerBound) / totalRange : 1

            // Note: the thumb DragGestures below rely on .offset being purely
            // visual — gesture locations are reported in the thumb's *un-offset*
            // layout frame (the leading edge of this ZStack), so location.x is
            // already the position along the track. Don't switch to .position
            // without reworking the math.
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumbSize / 2)

                // Selected range highlight
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(
                        width: CGFloat(endFraction - startFraction) * width,
                        height: trackHeight
                    )
                    .offset(x: thumbSize / 2 + CGFloat(startFraction) * width)

                // Start thumb
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(radius: 2)
                    .offset(x: CGFloat(startFraction) * width)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let fraction = max(0, min(Double(value.location.x / width), Double(endFraction) - 0.01))
                                let newStart = range.lowerBound + fraction * totalRange
                                start = newStart
                                onSeek?(newStart)
                            }
                    )

                // End thumb
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(radius: 2)
                    .offset(x: CGFloat(endFraction) * width)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let fraction = max(Double(startFraction) + 0.01, min(1, Double(value.location.x / width)))
                                let newEnd = range.lowerBound + fraction * totalRange
                                end = newEnd
                                onSeek?(newEnd)
                            }
                    )
            }
        }
        .frame(height: thumbSize)
    }
}
