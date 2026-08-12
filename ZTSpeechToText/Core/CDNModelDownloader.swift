//
//  CDNModelDownloader.swift
//  Resume-safe downloader for CDN-hosted Whisper model zips.
//

import Foundation
import ZIPFoundation

final class CDNModelDownloader: NSObject {

    enum DownloadError: Error {
        case badResponse
        case unzipFailed
        case fileIOFailure
        case invalidRequest
    }

    struct TransferProgress {
        let fraction: Double
        let downloadedBytes: Int64
        let totalBytes: Int64
    }

    private struct ActiveRequest {
        let modelZipURL: URL
        let installFolderName: String
    }

    private let stateLock = NSLock()
    private var progressCallback: ((TransferProgress) -> Void)?
    private var continuations: [CheckedContinuation<URL, Error>] = []
    private var activeDataTask: URLSessionDataTask?
    private var outputHandle: FileHandle?
    private var bytesAlreadyOnDisk: Int64 = 0
    private var bytesReceivedThisSession: Int64 = 0
    private var totalBytesExpected: Int64 = 0
    private var retryAttempt: Int = 0
    private var activeRequest: ActiveRequest?

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func downloadAndUnzip(
        modelZipURL: URL,
        installFolderName: String,
        progressCallback: @escaping (TransferProgress) -> Void
    ) async throws -> URL {
        let request = ActiveRequest(modelZipURL: modelZipURL, installFolderName: installFolderName)

        return try await withCheckedThrowingContinuation { continuation in
            stateLock.lock()
            self.progressCallback = progressCallback
            continuations.append(continuation)

            if activeDataTask == nil {
                activeRequest = request
                do {
                    try startDataDownloadLocked()
                    let task = activeDataTask
                    stateLock.unlock()
                    task?.resume()
                    return
                } catch {
                    let pending = continuations
                    continuations.removeAll()
                    self.progressCallback = nil
                    activeRequest = nil
                    stateLock.unlock()
                    for continuation in pending {
                        continuation.resume(throwing: error)
                    }
                    return
                }
            }

            stateLock.unlock()
        }
    }

    private func partialZipURL(for request: ActiveRequest) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeechModelDownload", isDirectory: true)
            .appendingPathComponent("\(request.installFolderName).zip.part")
    }

    private func destinationFolderURL(for request: ActiveRequest) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(request.installFolderName, isDirectory: true)
    }

    private func startDataDownloadLocked() throws {
        guard let request = activeRequest else { throw DownloadError.invalidRequest }
        let partialURL = partialZipURL(for: request)
        let fileManager = FileManager.default
        let directory = partialURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: partialURL.path) {
            guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                throw DownloadError.fileIOFailure
            }
        }

        let attributes = try fileManager.attributesOfItem(atPath: partialURL.path)
        bytesAlreadyOnDisk = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        bytesReceivedThisSession = 0
        totalBytesExpected = 0

        var urlRequest = URLRequest(url: request.modelZipURL)
        if bytesAlreadyOnDisk > 0 {
            urlRequest.setValue("bytes=\(bytesAlreadyOnDisk)-", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: urlRequest)
        activeDataTask = task
    }

    private func openOutputHandle(append: Bool) throws {
        guard let request = activeRequest else { throw DownloadError.invalidRequest }
        let partialURL = partialZipURL(for: request)
        let handle = try FileHandle(forWritingTo: partialURL)
        if append {
            _ = try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
        }
        outputHandle = handle
    }

    private func unzip() throws -> URL {
        guard let request = activeRequest else { throw DownloadError.invalidRequest }
        let fileManager = FileManager.default
        let partialURL = partialZipURL(for: request)
        let destination = destinationFolderURL(for: request)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            try fileManager.unzipItem(at: partialURL, to: destination)
        } catch {
            throw DownloadError.unzipFailed
        }

        return try resolvedModelFolder(in: destination)
    }

    private func resolvedModelFolder(in destination: URL) throws -> URL {
        let fileManager = FileManager.default
        if isModelFolder(destination, fileManager: fileManager) {
            return destination
        }

        let children = (try? fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for child in children where isModelFolder(child, fileManager: fileManager) {
            return child
        }

        throw DownloadError.unzipFailed
    }

    private func isModelFolder(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        let requiredNames = [
            "MelSpectrogram.mlmodelc",
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
            "config.json"
        ]
        return requiredNames.allSatisfy { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    private func finalizeFromPartialFile() {
        do {
            let modelFolder = try unzip()
            resolveAll(.success(modelFolder))
        } catch {
            resolveAll(.failure(error))
        }
    }

    private func isRetryable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private func scheduleRetryIfPossible(for error: Error) -> Bool {
        guard isRetryable(error) else { return false }

        stateLock.lock()
        guard !continuations.isEmpty else {
            stateLock.unlock()
            return false
        }

        retryAttempt += 1
        let delay = min(pow(2.0, Double(retryAttempt - 1)), 20.0)
        activeDataTask = nil
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            self.stateLock.lock()
            guard !self.continuations.isEmpty, self.activeDataTask == nil else {
                self.stateLock.unlock()
                return
            }

            do {
                try self.startDataDownloadLocked()
                let task = self.activeDataTask
                self.stateLock.unlock()
                task?.resume()
            } catch {
                self.stateLock.unlock()
                self.resolveAll(.failure(error))
            }
        }

        return true
    }

    private func resolveAll(_ result: Result<URL, Error>) {
        stateLock.lock()
        let pending = continuations
        continuations.removeAll()
        activeDataTask = nil
        progressCallback = nil
        outputHandle = nil
        bytesAlreadyOnDisk = 0
        bytesReceivedThisSession = 0
        totalBytesExpected = 0
        retryAttempt = 0
        activeRequest = nil
        stateLock.unlock()

        for continuation in pending {
            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
}

extension CDNModelDownloader: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            resolveAll(.failure(DownloadError.badResponse))
            return
        }

        do {
            switch httpResponse.statusCode {
            case 200:
                stateLock.lock()
                retryAttempt = 0
                bytesAlreadyOnDisk = 0
                bytesReceivedThisSession = 0
                let contentLength = response.expectedContentLength
                totalBytesExpected = contentLength > 0 ? contentLength : 0
                try openOutputHandle(append: false)
                stateLock.unlock()
                completionHandler(.allow)

            case 206:
                stateLock.lock()
                retryAttempt = 0
                bytesReceivedThisSession = 0
                let contentLength = response.expectedContentLength
                let serverReportedTotal = httpResponse.value(forHTTPHeaderField: "Content-Range")
                    .flatMap { header -> Int64? in
                        guard let slashIndex = header.lastIndex(of: "/") else { return nil }
                        let total = header[header.index(after: slashIndex)...]
                        return Int64(total)
                    }
                totalBytesExpected = serverReportedTotal ?? (bytesAlreadyOnDisk + max(0, contentLength))
                try openOutputHandle(append: true)
                stateLock.unlock()
                completionHandler(.allow)

            case 416:
                completionHandler(.cancel)
                finalizeFromPartialFile()

            default:
                completionHandler(.cancel)
                resolveAll(.failure(DownloadError.badResponse))
            }
        } catch {
            completionHandler(.cancel)
            resolveAll(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var callback: ((TransferProgress) -> Void)?
        var progressToSend: TransferProgress?
        var writeError: Error?

        stateLock.lock()
        do {
            if outputHandle == nil {
                try openOutputHandle(append: bytesAlreadyOnDisk > 0)
            }

            outputHandle?.write(data)
            retryAttempt = 0
            bytesReceivedThisSession += Int64(data.count)

            let downloaded = bytesAlreadyOnDisk + bytesReceivedThisSession
            let total = totalBytesExpected
            let fraction: Double
            if total > 0 {
                fraction = min(1, max(0, Double(downloaded) / Double(total)))
            } else {
                fraction = 0
            }

            progressToSend = TransferProgress(
                fraction: fraction,
                downloadedBytes: downloaded,
                totalBytes: total
            )
            callback = progressCallback
        } catch {
            writeError = error
        }
        stateLock.unlock()

        if let writeError {
            resolveAll(.failure(writeError))
            return
        }

        if let progressToSend, let callback {
            DispatchQueue.main.async {
                callback(progressToSend)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        outputHandle?.closeFile()
        outputHandle = nil

        if let error {
            if scheduleRetryIfPossible(for: error) {
                return
            }
            resolveAll(.failure(error))
            return
        }

        finalizeFromPartialFile()
    }
}
