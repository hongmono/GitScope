import AppKit
import Foundation

/// NotificationCenter 옵저버 토큰의 수명을 참조 수명에 묶는 상자.
///
/// 스케줄러가 `stop()` 없이 사라져도 이 상자가 함께 해제되며 옵저버를 걷어낸다.
/// `@MainActor` 클래스의 deinit 에서 격리된 상태를 건드리지 않기 위한 우회이기도 하다.
private final class ObserverToken {
    let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

/// 자동 fetch 를 실행할 시점만 판단하는 스케줄러.
///
/// 주기 타이머와 앱 활성화 알림 두 경로로 `onFire` 를 호출한다. 무엇을 가져올지,
/// 가져온 뒤 무엇을 갱신할지는 알지 못한다. 그 판단은 호출자 몫이다.
@MainActor
final class AutoFetchScheduler {
    /// 창 복귀로 실행할 때 요구하는 마지막 실행 이후 최소 간격.
    ///
    /// 다른 앱과 GitScope 를 빠르게 오갈 때 전환마다 fetch 가 실행되는 것을 막는다.
    private static let activationMinimumInterval: TimeInterval = 30

    private let onFire: () async -> Void
    private var timerTask: Task<Void, Never>?
    private var activationObserver: ObserverToken?
    private var lastFireDate: Date?
    private var isFiring = false

    init(onFire: @escaping () async -> Void) {
        self.onFire = onFire
    }

    var isRunning: Bool { timerTask != nil }

    /// 주기 타이머를 걸고 창 복귀 관찰을 시작한다. 이미 실행 중이면 새 주기로 다시 건다.
    func start(intervalMinutes: Int) {
        stop()

        let interval = Duration.seconds(max(1, intervalMinutes) * 60)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await self.fire()
            }
        }

        activationObserver = ObserverToken(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.fireOnActivation()
                }
            }
        )
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        // 토큰을 버리면 상자의 deinit 이 옵저버를 제거한다.
        activationObserver = nil
    }

    private func fireOnActivation() {
        guard isRunning else { return }
        if let lastFireDate,
           Date.now.timeIntervalSince(lastFireDate) < Self.activationMinimumInterval {
            return
        }
        Task { await fire() }
    }

    /// 실행이 겹치지 않도록 막고, 창 복귀 최소 간격의 기준 시각을 갱신한다.
    private func fire() async {
        guard !isFiring else { return }
        isFiring = true
        lastFireDate = .now
        await onFire()
        lastFireDate = .now
        isFiring = false
    }
}
