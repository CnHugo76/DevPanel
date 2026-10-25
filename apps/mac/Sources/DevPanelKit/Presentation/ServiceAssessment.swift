import Foundation

public struct ServiceAssessment: Sendable, Equatable {
    public var evidence: String
    public var nextStep: String?
    public var warning: Bool

    public static func make(_ service: ServiceView) -> Self? {
        if service.state == .unknown {
            return Self(evidence: service.error?.displayText ?? "管理服务无法核验原进程身份，当前状态未知。",
                        nextStep: "先恢复管理服务连接并刷新运行信息；身份无法核验时不要按名称或端口结束进程。", warning: true)
        }
        if service.state == .failed {
            return Self(evidence: service.failureReason,
                        nextStep: "查看失败运行的错误上下文，并在「命令与环境」核对实际启动命令与选项。", warning: true)
        }
        guard service.state == .running else { return nil }
        guard let ready = service.currentRun?.ready else {
            return Self(evidence: "进程正在运行；管理服务尚未提供就绪证据。",
                        nextStep: "查看启动日志，并检查是否配置了就绪条件。", warning: false)
        }
        return Self(evidence: ready.explanation, nextStep: ready.nextStep,
                    warning: ready.state == .timedOut || ready.state == .unknown || ready.state == .endedBeforeReady)
    }
}
