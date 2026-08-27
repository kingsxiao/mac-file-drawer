import AppKit

// MARK: - 窗口弹簧动画器
// 用数值积分驱动的欠阻尼弹簧逐帧移动窗口 frame，
// 相比 NSAnimationContext 的固定曲线，收起/展开会带轻微过冲回弹，
// 让「抽屉」有真实的物理手感。同一时间只跑一条弹簧（新动画从当前位置接力）。

@MainActor
final class WindowSpringAnimator {
    static let shared = WindowSpringAnimator()

    private var timer: Timer?
    private weak var window: NSWindow?

    /// 弹簧状态：对 x / y / width / height 各自积分，共用同一组参数
    private var state: [(value: CGFloat, velocity: CGFloat, target: CGFloat)] = []
    private var lastStep: CFTimeInterval = 0
    private var deadline: CFTimeInterval = 0

    /// 判定静止的阈值：位移与速度都足够小即结束
    private let epsilon: CGFloat = 0.35
    private let velocityEpsilon: CGFloat = 24

    /// 是否正在动画（外部可据此避免同帧 setFrame 打架）
    var isRunning: Bool { timer != nil }

    /// 启动（或接力）一条弹簧：从窗口当前 frame 平滑趋向目标。
    /// 默认参数的阻尼比 ≈ 0.76（过冲 ≈ 2.7%、约 0.4 秒收敛）——
    /// 肉眼能感到"拉出一格后轻轻回弹"，又不会晃。
    /// - Parameters:
    ///   - stiffness: 刚度，越大越快
    ///   - damping: 阻尼，越小过冲越明显
    func animate(
        window: NSWindow,
        to target: NSRect,
        stiffness: Double = 210,
        damping: Double = 22
    ) {
        self.window = window
        let current = window.frame
        // 接力时保留现有速度，切换目标不突兀
        if !isRunning || state.count != 4 {
            state = [
                (current.origin.x, 0, target.origin.x),
                (current.origin.y, 0, target.origin.y),
                (current.width, 0, target.width),
                (current.height, 0, target.height),
            ]
        } else {
            state = state.enumerated().map { index, s in
                let t: CGFloat = [target.origin.x, target.origin.y, target.width, target.height][index]
                return (s.value, s.velocity, t)
            }
        }

        lastStep = CACurrentMediaTime()
        // 弱弹簧最多跑 1.2 秒即收敛；超时保护强制结束
        deadline = lastStep + 1.2

        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.step(stiffness: stiffness, damping: damping)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 立即停在目标（外部直接 setFrame 定位时调用，避免弹簧又把窗口拉回去）
    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func step(stiffness: Double, damping: Double) {
        guard let window else {
            cancel()
            return
        }
        let now = CACurrentMediaTime()
        // 步长夹在 (0, 1/30]：runloop 卡顿时避免大步长导致弹簧发散
        let dt = min(max(now - lastStep, 1.0 / 240.0), 1.0 / 30.0)
        lastStep = now

        var settled = true
        for index in state.indices {
            let s = state[index]
            let force = CGFloat(stiffness) * (s.target - s.value) - CGFloat(damping) * s.velocity
            let velocity = s.velocity + force * dt
            let value = s.value + velocity * dt
            state[index] = (value, velocity, s.target)
            if abs(value - s.target) > epsilon || abs(velocity) > velocityEpsilon {
                settled = false
            }
        }

        if settled || now >= deadline {
            let target = NSRect(
                x: state[0].target, y: state[1].target,
                width: state[2].target, height: state[3].target
            )
            window.setFrame(target, display: true)
            cancel()
            return
        }

        window.setFrame(
            NSRect(
                x: state[0].value, y: state[1].value,
                width: state[2].value, height: state[3].value
            ),
            display: true
        )
    }
}
