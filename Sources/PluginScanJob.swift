import Foundation

// Only scanner-process lifecycle is locked. This object is never used by audio callbacks.
private final class PluginScanJob: @unchecked Sendable {
    private let process = Process(), pipe = Pipe(), lock = NSLock()
    private var reason: String?
    private var finished = false
    init(arguments: [String]) {
        process.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    }
    func cancel(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if reason == nil { reason = message }
        if process.isRunning { process.terminate() }
    }
    func run(timeout: TimeInterval) throws -> [PluginChoice] {
        lock.lock()
        if let reason { lock.unlock(); throw AudioFailure(reason) }
        do { try process.run() } catch { finished = true; lock.unlock(); throw error }
        lock.unlock()
        let deadline = DispatchWorkItem { [weak self] in self?.cancel("Обновление AU превысило время ожидания. Повторите попытку.") }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now()+timeout, execute: deadline)
        defer {
            deadline.cancel()
            lock.lock(); finished = true; lock.unlock()
            try? pipe.fileHandleForReading.close()
        }
        var data = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                guard data.count + chunk.count <= 8*1024*1024 else { throw AudioFailure("Некорректный размер каталога AU.") }
                data.append(chunk)
            }
        } catch {
            cancel("Ошибка чтения каталога AU.")
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        lock.lock(); let failure = reason; lock.unlock()
        if let failure { throw AudioFailure(failure) }
        guard process.terminationStatus == 0 else { throw AudioFailure("Не удалось обновить реестр AU. Повторите попытку.") }
        guard data.count <= 8*1024*1024 else { throw AudioFailure("Некорректный размер каталога AU.") }
        return try JSONDecoder().decode([PluginChoice].self, from: data)
    }
    static func scan(arguments: [String], timeout: TimeInterval) async throws -> [PluginChoice] {
        let job = PluginScanJob(arguments: arguments)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: [PluginChoice] = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try job.run(timeout: timeout)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { job.cancel("Обновление AU отменено.") }
    }
}

extension PluginCatalog {
    static func rescan(arguments: [String] = ["--scan-plugins"], timeout: TimeInterval = 20) async throws -> [PluginChoice] {
        try await PluginScanJob.scan(arguments: arguments, timeout: timeout)
    }
}
