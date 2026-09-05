import AppKit
import Foundation
import UniformTypeIdentifiers

/// SFTP 面板拖出下载的 NSItemProvider 工厂。Finder 在用户真正放下后才请求文件表示:
/// 先下载到独立临时目录,交给 NSItemProvider 复制,并在宽限期后清理临时副本。
/// 单独成型是为了让自动化验收能不经 Finder 直接 loadFileRepresentation 走同一条路
/// (文件与文件夹的表示都在这里注册)。
@MainActor
enum SFTPDragProvider {
    static func make(
        entry: SFTPBrowser.Entry,
        remoteDirectory: String,
        browser: SFTPBrowser?
    ) -> NSItemProvider {
        let provider = NSItemProvider()

        let pathExtension = (entry.name as NSString).pathExtension
        let inferredType = entry.isDirectory || pathExtension.isEmpty
            ? nil
            : UTType(filenameExtension: pathExtension)
        let contentType = entry.isDirectory ? UTType.folder : (inferredType ?? .data)
        // Finder 会按 UTI 自动补首选扩展名;这里给基名可避免 foo.json.json。
        // 未知扩展名会回落 public.data,它不会自动补扩展,因此仍保留完整名称。
        provider.suggestedName = entry.isDirectory || inferredType?.preferredFilenameExtension == nil
            ? entry.name
            : (entry.name as NSString).deletingPathExtension

        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let total = !entry.isDirectory && entry.size > 0 ? Int64(clamping: entry.size) : 1
            let progress = Progress(totalUnitCount: total)
            let task = Task {
                let lease: SFTPDragStagingLease
                do {
                    lease = try await SFTPDragStagingStore.shared.create(
                        named: entry.name,
                        isDirectory: entry.isDirectory
                    )
                } catch {
                    completion(nil, false, error)
                    return
                }

                do {
                    guard let browser else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let result = try await browser.downloadForDrag(
                        entry,
                        remoteDirectory: remoteDirectory,
                        to: lease.payloadURL,
                        progress: progress
                    )
                    try await SFTPDragStagingStore.shared.markDelivered(lease, payloadBytes: result.copiedBytes)
                    completion(lease.payloadURL, false, nil)
                    // 文件表示的接收方可能在 completion 返回后才开始复制。
                    // 依据实际成功写入本地的 payloadBytes, 通过统一策略源 SFTPDragRetentionPolicy
                    // 计算预估消费窗口 (基线 30 分钟, 慢速介质按 2 MiB/s 延长),
                    // 再清理由 Berth 创建的临时副本; 启动/新拖拽时也会兜底 sweep。
                    let retentionSeconds = SFTPDragRetentionPolicy.retentionInterval(payloadBytes: result.copiedBytes)
                    Task.detached {
                        try? await Task.sleep(for: .seconds(retentionSeconds))
                        await SFTPDragStagingStore.shared.discardIfDelivered(lease)
                    }
                } catch {
                    await SFTPDragStagingStore.shared.discard(lease)
                    let finalError = normalizedCancellationError(error)
                    completion(nil, false, finalError)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }

    /// 判断是否为用户主动发起的取消操作 (覆盖 Swift.CancellationError, CocoaError(.userCancelled), Task.isCancelled)
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.userCancelled.rawValue {
            return true
        }
        if Task.isCancelled {
            return true
        }
        return false
    }

    /// 将取消类错误标准化为 CocoaError(.userCancelled), 其余真实错误原样保留
    nonisolated static func normalizedCancellationError(_ error: Error) -> Error {
        if isCancellation(error) {
            return CocoaError(.userCancelled)
        }
        return error
    }
}
