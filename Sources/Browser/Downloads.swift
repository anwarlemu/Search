import AppKit
import WebKit
import Combine
import SwiftUI

/// An attempt remains visible after failure/cancellation. Credentials and
/// resume data stay in this window's memory, never in the downloads JSON.
@MainActor
final class Transfer: ObservableObject, Identifiable {
    enum State { case starting, receiving, failed, cancelled, complete }
    let id = UUID()
    @Published var state: State = .starting
    @Published var name: String
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    @Published var problem: String?
    @Published var cancelling = false
    var destination: URL?
    var resumeData: Data?
    var request: URLRequest?
    let isPrivate: Bool
    let store: WKWebsiteDataStore
    weak var source: WKWebView?
    weak var download: WKDownload?
    var retryPage: WKWebView?
    var attempt = UUID()
    private var progress: AnyCancellable?

    init(_ download: WKDownload, private isPrivate: Bool) {
        self.isPrivate = isPrivate
        request = download.originalRequest
        let filename = download.originalRequest?.url?.lastPathComponent ?? ""
        name = filename.isEmpty ? "Download" : filename
        source = download.webView
        store = download.webView?.configuration.websiteDataStore ?? (isPrivate ? .nonPersistent() : Store.websites)
    }

    var active: Bool { state == .starting || state == .receiving }
    var canRetry: Bool {
        guard !active, !cancelling, state != .complete else { return false }
        if resumeData != nil { return true }
        guard let request, ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "") else { return false }
        return ["GET", "HEAD"].contains((request.httpMethod ?? "GET").uppercased())
    }
    var fraction: Double? { total > 0 ? min(1, max(0, Double(received) / Double(total))) : nil }
    var amount: String {
        let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        return total > 0 ? got + " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : got
    }

    func attach(_ download: WKDownload) {
        self.download = download
        request = download.originalRequest ?? request
        source = download.webView ?? source
        problem = nil
        resumeData = nil
        state = .receiving
        progress = download.progress.publisher(for: \.completedUnitCount)
            .combineLatest(download.progress.publisher(for: \.totalUnitCount))
            .throttle(for: .milliseconds(150), scheduler: RunLoop.main, latest: true)
            .sink { [weak self, weak download] got, size in
                guard let self, let download, self.download === download, self.active else { return }
                self.received = got
                self.total = size
            }
    }

    func detach() {
        progress = nil
        download = nil
        retryPage = nil
    }
}

struct TransferRow: View {
    let browser: Browser
    @ObservedObject var transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: transfer.state == .failed ? "exclamationmark.circle" : "arrow.down.circle")
                    .foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(transfer.name).font(.system(size: 13)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(status).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if transfer.active {
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack(spacing: 12) {
                if transfer.active {
                    Button("Cancel") { browser.cancelDownload(transfer) }
                } else {
                    if transfer.canRetry {
                        Button(transfer.resumeData == nil ? "Retry" : "Resume") { browser.retryDownload(transfer) }
                    }
                    if transfer.state == .complete, let url = transfer.destination {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Remove") { browser.removeTransfer(transfer) }.disabled(transfer.cancelling)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var status: String {
        switch transfer.state {
        case .starting: return "Starting…"
        case .receiving: return transfer.amount
        case .cancelled: return transfer.cancelling ? "Cancelling…" : "Cancelled · " + transfer.amount
        case .failed: return transfer.problem ?? "Download failed."
        case .complete: return "Saved"
        }
    }
}

extension Browser: WKDownloadDelegate {
    func keep(_ download: WKDownload, as existing: Transfer? = nil) {
        let privateTab = download.webView.flatMap { tab(for: $0) }?.shy == true
        let transfer = existing ?? Transfer(download, private: isPrivate || privateTab)
        transfer.attach(download)
        if existing == nil { transfers.insert(transfer, at: 0) }
        download.delegate = self
        downloading.append(download)
    }

    func cancelDownload(_ transfer: Transfer) {
        guard transfer.active else { return }
        transfer.state = .cancelled
        transfer.attempt = UUID()
        guard let download = transfer.download else { transfer.detach(); return }
        transfer.cancelling = true
        download.cancel { [weak self, weak transfer] data in
            guard let self, let transfer else { return }
            transfer.resumeData = data
            transfer.cancelling = false
            self.downloading.removeAll { $0 === download }
            download.delegate = nil
            transfer.detach()
        }
    }

    func retryDownload(_ transfer: Transfer) {
        guard transfer.canRetry else { return }
        let resume = transfer.resumeData
        let token = UUID()
        transfer.attempt = token
        transfer.state = .starting
        transfer.problem = nil
        let web: WKWebView
        if let source = transfer.source { web = source } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = transfer.store
            web = WKWebView(frame: .zero, configuration: configuration)
        }
        // Keep the originating view alive only for the retry's duration.
        transfer.retryPage = web
        let started: @MainActor @Sendable (WKDownload) -> Void = { [weak self, weak transfer] download in
            guard let self, let transfer, transfer.attempt == token, transfer.active else {
                download.cancel(nil)
                return
            }
            self.keep(download, as: transfer)
        }
        if let resume {
            web.resumeDownload(fromResumeData: resume, completionHandler: started)
        } else if let request = transfer.request {
            transfer.received = 0
            transfer.total = 0
            web.startDownload(using: request, completionHandler: started)
        }
    }

    func removeTransfer(_ transfer: Transfer) {
        guard !transfer.active, !transfer.cancelling else { return }
        transfers.removeAll { $0.id == transfer.id }
    }

    func clearDownloads() {
        loot.forgetAll()
        transfers.removeAll { !$0.active && !$0.cancelling }
    }

    func endDownloads() {
        for transfer in transfers {
            transfer.attempt = UUID()
            transfer.download?.delegate = nil
            transfer.download?.cancel(nil)
            transfer.detach()
        }
        downloading.removeAll()
        transfers.removeAll()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let transfer = transfers.first(where: { $0.download === download }) else { completionHandler(nil); return }
        let asked = response.url.flatMap { namedDownloads.removeValue(forKey: $0) }
        let requested = asked ?? (suggestedFilename.isEmpty ? "download" : suggestedFilename)
        let filename = (requested as NSString).lastPathComponent
        let name = ["", ".", "..", "/"].contains(filename) ? "download" : filename
        transfer.name = name
        let choose: (URL?) -> Void = { [weak self, weak transfer] url in
            guard let self, let transfer, transfer.download === download, transfer.active else { completionHandler(nil); return }
            guard let url else {
                transfer.state = .cancelled
                self.downloading.removeAll { $0 === download }
                transfer.detach()
                completionHandler(nil)
                return
            }
            transfer.destination = url
            transfer.name = url.lastPathComponent
            completionHandler(url)
            self.announce("Downloading \(url.lastPathComponent)")
        }
        if prefs.asksWhereToSave {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = transfer.destination?.deletingLastPathComponent() ?? prefs.downloads
            panel.canCreateDirectories = true
            if let window {
                panel.beginSheetModal(for: window) { result in choose(result == .OK ? panel.url : nil) }
            } else { choose(panel.runModal() == .OK ? panel.url : nil) }
        } else {
            choose(freeDownloadName(name, in: transfer.destination?.deletingLastPathComponent() ?? prefs.downloads))
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloading.removeAll { $0 === download }
        guard let transfer = transfers.first(where: { $0.download === download }), transfer.active else { return }
        transfer.destination = download.progress.fileURL ?? transfer.destination
        transfer.state = .complete
        transfer.detach()
        if let file = transfer.destination, !transfer.isPrivate {
            loot.add(Keep(name: file.lastPathComponent, from: transfer.request?.url?.host() ?? "", path: file.path, date: Date()))
            transfers.removeAll { $0.id == transfer.id }
        }
        announce("Saved \(transfer.name)")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloading.removeAll { $0 === download }
        guard let transfer = transfers.first(where: { $0.download === download }), transfer.active else { return }
        transfer.state = .failed
        transfer.problem = error.localizedDescription
        transfer.resumeData = resumeData
        transfer.detach()
        announce("Download failed — open Downloads to retry")
    }

    func freeDownloadName(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let reserved = Set(transfers.filter(\.active).compactMap(\.destination))
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
