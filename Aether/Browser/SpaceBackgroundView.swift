import SwiftUI
import UIKit

/// 首页动态背景（Metal 着色器，见 SpaceShader.metal）。限 30 帧，不显示时暂停。
final class SpaceBackgroundView: UIView {
    private final class Model: ObservableObject {
        @Published var center: CGPoint = .zero
        @Published var mono = false
        @Published var paused = false
    }

    private let model = Model()
    private let host: UIHostingController<SpaceCanvas>

    var holeCenter: CGPoint {
        get { model.center }
        set { if model.center != newValue { model.center = newValue } }
    }

    var isMonochrome: Bool {
        get { model.mono }
        set { model.mono = newValue }
    }

    var isPaused: Bool {
        get { model.paused }
        set { if model.paused != newValue { model.paused = newValue } }
    }

    override init(frame: CGRect) {
        host = UIHostingController(rootView: SpaceCanvas(model: model))
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        host.view.backgroundColor = .black
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.safeAreaRegions = []
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { fatalError() }

    private struct SpaceCanvas: View {
        @ObservedObject var model: Model
        private let start = Date()

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: model.paused)) { context in
                let t = Float(context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 3600))
                GeometryReader { geo in
                    Rectangle()
                        .fill(.black)
                        .colorEffect(ShaderLibrary.aetherSpace(
                            .float2(geo.size),
                            .float2(model.center),
                            .float(t),
                            .float(model.mono ? 1 : 0)
                        ))
                }
            }
            .ignoresSafeArea()
        }
    }
}
