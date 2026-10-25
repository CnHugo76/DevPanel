import Darwin
import Foundation

/// 将内置入口链接到明确选定的目录；检查与确认只覆盖同一份计划。
public struct CLIInstallation: Sendable {
    public struct Destination: Equatable, Sendable, Identifiable {
        public var id: String { path.path }
        public let path: URL
        public let existing: String?
        fileprivate let identity: String
    }
    public struct Plan: Sendable {
        public let directory: URL
        public let destinations: [Destination]
        public var needsConfirmation: Bool { destinations.contains { $0.existing != nil } }
    }
    public enum Failure: Error, LocalizedError {
        case message(String)
        public var errorDescription: String? { switch self { case .message(let text): text } }
    }
    public let runtime: URL
    public init(runtime: URL) { self.runtime = runtime }

    public func inspect(directory: URL) throws -> Plan {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw Failure.message("请选择绝对路径目录") }
        for name in ["devpanel", "devpaneld"] {
            guard FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("bin/\(name)").path) else {
                throw Failure.message("发布包缺少内置命令 \(name)")
            }
        }
        return Plan(directory: directory, destinations: try ["devpanel", "devpaneld"].map {
            try destination(directory.appendingPathComponent($0))
        })
    }

    public func install(_ plan: Plan, confirmedReplacement: Bool = false) throws {
        if plan.needsConfirmation && !confirmedReplacement { throw Failure.message("目标已存在，请查看现有内容后确认替换") }
        // 在写第一个入口前核对两处；预览后有改动就要求重新查看。
        for item in plan.destinations {
            guard try destination(item.path) == item else { throw Failure.message("目标在预览后发生变化，请重新查看") }
        }
        try FileManager.default.createDirectory(at: plan.directory, withIntermediateDirectories: true)
        for item in plan.destinations {
            let temporary = plan.directory.appendingPathComponent(".devpanel-install-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: runtime.appendingPathComponent("bin/\(item.path.lastPathComponent)"))
            guard rename(temporary.path, item.path.path) == 0 else {
                throw Failure.message("无法安装 \(item.path.path)：\(String(cString: strerror(errno)))")
            }
        }
    }

    private func destination(_ path: URL) throws -> Destination {
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: path.path) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return Destination(path: path, existing: nil, identity: "absent")
            }
            throw error
        }
        let type = attributes[.type] as? FileAttributeType
        let identity = [attributes[.systemFileNumber], attributes[.size], attributes[.modificationDate]].map { String(describing: $0) }.joined(separator: "|")
        if type == .typeSymbolicLink {
            let target = try fm.destinationOfSymbolicLink(atPath: path.path)
            return Destination(path: path, existing: "软链接 → \(target)", identity: identity + target)
        }
        guard type == .typeRegular else { throw Failure.message("\(path.path) 不是普通文件或软链接，未修改") }
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4096) ?? Data()
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let text = String(data: data, encoding: .utf8) ?? "二进制文件（\(size) 字节）"
        return Destination(path: path, existing: text + (size > 4096 ? "\n[仅显示前 4096 字节]" : ""), identity: identity + data.base64EncodedString())
    }
}
