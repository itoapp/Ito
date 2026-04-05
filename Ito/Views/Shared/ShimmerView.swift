import SwiftUI
import Combine

public struct ShimmerView: View {
    @State private var phase: CGFloat = -1.0

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.itoCardBackground

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: Color.white.opacity(0.25), location: 0.45),
                        .init(color: Color.white.opacity(0.25), location: 0.55),
                        .init(color: .clear, location: 1.0)
                    ]),
                    startPoint: UnitPoint(x: phase, y: 0.5),
                    endPoint: UnitPoint(x: phase + 0.6, y: 0.5)
                )
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .onAppear {
            withAnimation(
                .linear(duration: 1.3)
                .repeatForever(autoreverses: false)
            ) {
                phase = 1.4
            }
        }
    }
}
