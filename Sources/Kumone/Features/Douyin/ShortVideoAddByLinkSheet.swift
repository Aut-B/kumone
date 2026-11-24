#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// 与 `ShortVideoLinkImportModel.captureScript` 里的 `HANDLER` 保持一致。
private let shortVideoLinkHandlerName = "shortVideoLink"

/// 粘贴分享文案，按单条视频导入收藏。
///
/// 抖音的详情接口需要运行时签名，免登录纯 HTTP 拿不到数据（BATCH_04 实测）。
/// 这里用一个独立的后台 `WKWebView` 打开视频页：它和收藏页共用 `.default()`
/// cookie，页面自己的 JS 会带上签名去请求详情，我们只在旁边把响应抄下来，
/// 再交给 `ShortVideoSingleVideo` 解析。失败时只在本页显示原因，不会启动
/// 全量抓取，也不会把收藏页切到网页。
struct ShortVideoAddByLinkSheet: View {
    let platform: ShortVideoPlatform
    let existingKeys: Set<String>
    let onImported: (ShortVideo, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ShortVideoLinkImportModel()
    @State private var shareText = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        AppNavStack {
            Form {
                Section {
                    TextEditor(text: $shareText)
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        if let clipboard = UIPasteboard.general.string {
                            shareText = clipboard
                        }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("分享文案")
                } footer: {
                    Text("在抖音里点「分享」→「复制链接」，把整段文案粘贴到这里。")
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    }
                }

                Section {
                    Button {
                        importTask = Task { await add() }
                    } label: {
                        HStack(spacing: 8) {
                            if model.isWorking {
                                ProgressView()
                            }
                            Text(model.isWorking ? "正在解析…" : "解析并添加")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isWorking || trimmedText.isEmpty)
                }
            }
            .navigationTitle("粘贴链接添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .background(
                ShortVideoLinkWebView(webView: model.webView)
                    .frame(width: 64, height: 64)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            )
            .onDisappear {
                importTask?.cancel()
                importTask = nil
                model.cancel()
            }
        }
    }

    private var trimmedText: String {
        shareText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() async {
        statusMessage = nil
        statusIsError = false
        do {
            let result = try await model.importShareText(trimmedText,
                                                         platform: platform,
                                                         existingKeys: existingKeys)
            switch result {
            case .imported(let video, let syncError):
                guard !Task.isCancelled else { return }
                onImported(video, syncError)
                dismiss()
            case .alreadyExists:
                statusMessage = "这条视频已经在收藏里了，没有重复添加。"
            }
        } catch is CancellationError {
            // 弹窗已关闭或任务被取消，不再显示半截状态。
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }
}

private struct ShortVideoLinkWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

enum ShortVideoLinkImportResult {
    case imported(ShortVideo, syncError: String?)
    case alreadyExists
}

enum ShortVideoLinkImportError: LocalizedError {
    case noLink
    case shortLinkUnresolved
    case timeout
    case parseFailed
    case navigationFailed(String)
    case tiktokUnavailable
    case busy

    var errorDescription: String? {
        switch self {
        case .noLink:
            return "没有识别到抖音视频链接。请粘贴抖音的分享文案，或形如 https://www.douyin.com/video/... 的链接。"
        case .shortLinkUnresolved:
            return "短链接解析失败，可能已过期。请在抖音里重新分享，或粘贴完整视频链接。"
        case .timeout:
            return "解析超时：没有拿到视频数据。请先在收藏页完成抖音登录，再回来重试。"
        case .parseFailed:
            return "已打开视频页，但没拿到可播放的视频数据。请确认已登录抖音后重试。"
        case .navigationFailed(let message):
            return "打开视频页失败：\(message)"
        case .tiktokUnavailable:
            return ShortVideoSingleVideo.tiktokUnavailableTitle
                + "\n\n" + ShortVideoSingleVideo.tiktokUnavailableMessage
        case .busy:
            return "正在解析上一条链接，请稍候。"
        }
    }
}

/// 后台打开视频页并抄下站点自己请求回来的详情 JSON。
@MainActor
final class ShortVideoLinkImportModel: NSObject, ObservableObject {
    @Published private(set) var isWorking = false

    private static let timeoutNanoseconds: UInt64 = 20 * 1_000_000_000

    private(set) var webView: WKWebView!

    private var contentController: WKUserContentController!
    private var continuation: CheckedContinuation<ShortVideo, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var expectedID: String?

    override init() {
        super.init()
        let controller = WKUserContentController()
        controller.add(self, name: shortVideoLinkHandlerName)
        controller.addUserScript(
            WKUserScript(source: Self.captureScript,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )
        contentController = controller

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.userContentController = controller

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = ShortVideoPlatform.douyin.userAgent
        view.navigationDelegate = self
        webView = view
    }

    func importShareText(_ text: String,
                         platform: ShortVideoPlatform,
                         existingKeys: Set<String>) async throws -> ShortVideoLinkImportResult {
        // 单链接导入目前只覆盖抖音；TikTok 分支在 B06 实测后判定不可行。
        // 入口处已按平台隐藏，这里再挡一次，避免任何调用路径把抖音条目写进 TikTok。
        guard platform == .douyin else { throw ShortVideoLinkImportError.tiktokUnavailable }
        guard !isWorking else { throw ShortVideoLinkImportError.busy }
        // 短链 302 解析也是异步网络，从这一步起就算「忙」，避免连点并发解析。
        isWorking = true
        defer { isWorking = false }

        let decision = ShortVideoSingleVideo.importDecision(forShareText: text)
        let id: String
        switch decision {
        case .douyin(let value):
            id = value
        case .tiktokUnavailable:
            // 抖音短链也可能和 TikTok 链接出现在同一段文案里；先给抖音短链一次机会。
            if ShortVideoSingleVideo.shortLink(in: text) != nil,
               let resolved = await ShortVideoSingleVideo.awemeID(fromShareText: text) {
                id = resolved
            } else {
                throw ShortVideoLinkImportError.tiktokUnavailable
            }
        case .unsupported:
            guard ShortVideoSingleVideo.shortLink(in: text) != nil else {
                throw ShortVideoLinkImportError.noLink
            }
            guard let resolved = await ShortVideoSingleVideo.awemeID(fromShareText: text) else {
                throw ShortVideoLinkImportError.shortLinkUnresolved
            }
            id = resolved
        }

        try Task.checkCancellation()
        if existingKeys.contains("\(platform.rawValue):\(id)") {
            return .alreadyExists
        }

        let video = try await loadVideo(id: id)
        try Task.checkCancellation()
        let syncError = await ShortVideoLinkImporter.store(video)
        return .imported(video, syncError: syncError)
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        expectedID = nil
        isWorking = false
        webView.stopLoading()
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: CancellationError())
        }
        // 消息处理器强引用 self，和 webView → configuration 构成环；
        // 这个 model 随弹窗生灭，关闭时必须自己拆掉，否则每次打开都漏一个 WebView。
        contentController?.removeScriptMessageHandler(forName: shortVideoLinkHandlerName)
    }

    private func loadVideo(id: String) async throws -> ShortVideo {
        guard continuation == nil else { throw ShortVideoLinkImportError.busy }
        guard let url = URL(string: ShortVideoPlatform.douyin.shareURL(for: id)) else {
            throw ShortVideoLinkImportError.noLink
        }

        expectedID = id
        isWorking = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.webView.load(URLRequest(url: url))
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                guard let self, !Task.isCancelled else { return }
                self.finish(.failure(ShortVideoLinkImportError.timeout))
            }
        }
    }

    private func finish(_ result: Result<ShortVideo, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        expectedID = nil
        continuation.resume(with: result)
    }

    private func handleCaptured(body: String) {
        guard isWorking, let expectedID else { return }
        guard body.contains("aweme_detail")
                || body.contains("aweme_list")
                || body.contains("item_list") else { return }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return }
        // `aweme_list` 可能带回多条；目标 id 不一定在第一条，按 id 找而不是取首条。
        let videos = ShortVideoParser.videos(fromJSONObject: object, platform: .douyin)
        let video = videos.first(where: { $0.id == expectedID })
            ?? ShortVideoSingleVideo.video(fromJSONObject: object, platform: .douyin)
        guard let video, video.id == expectedID else { return }
        finish(.success(video))
    }

    private static let captureScript = """
    (function () {
      if (window.__kumoneLinkHook) { return; }
      window.__kumoneLinkHook = true;
      var HANDLER = "shortVideoLink";

      function interesting(text) {
        if (!text || text.length < 40 || text.length > 4000000) { return false; }
        return text.indexOf('aweme_detail') >= 0
          || text.indexOf('aweme_list') >= 0
          || text.indexOf('item_list') >= 0;
      }

      function send(url, text) {
        try {
          if (!interesting(text)) { return; }
          window.webkit.messageHandlers[HANDLER].postMessage({
            url: String(url || ''),
            body: text
          });
        } catch (e) {}
      }

      var originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function () {
          var args = arguments;
          var url = '';
          try { url = (args[0] && args[0].url) ? args[0].url : args[0]; } catch (e) {}
          var promise = originalFetch.apply(this, args);
          try {
            promise.then(function (response) {
              try {
                response.clone().text().then(function (text) {
                  send(url, text);
                }).catch(function () {});
              } catch (e) {}
            }).catch(function () {});
          } catch (e) {}
          return promise;
        };
      }

      var open = XMLHttpRequest.prototype.open;
      var send2 = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__kumoneURL = url;
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        var xhr = this;
        try {
          xhr.addEventListener('load', function () {
            try {
              var text = '';
              try { text = xhr.responseText; } catch (e) {
                try { text = JSON.stringify(xhr.response); } catch (e2) {}
              }
              send(xhr.__kumoneURL, text);
            } catch (e) {}
          });
        } catch (e) {}
        return send2.apply(this, arguments);
      };

      // 别让站点一眼看出 fetch / XHR 被换过（抖音的 Argus 会做完整性检查）。
      try {
        var originalToString = Function.prototype.toString;
        var wrapped = [window.fetch, XMLHttpRequest.prototype.open, XMLHttpRequest.prototype.send];
        Function.prototype.toString = function () {
          for (var i = 0; i < wrapped.length; i++) {
            if (this === wrapped[i]) {
              return 'function ' + (wrapped[i].name || '') + '() { [native code] }';
            }
          }
          return originalToString.call(this);
        };
      } catch (e) {}
    })();
    """
}

extension ShortVideoLinkImportModel: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == shortVideoLinkHandlerName,
              let payload = message.body as? [String: Any],
              let body = payload["body"] as? String else { return }
        Task { @MainActor [weak self] in
            self?.handleCaptured(body: body)
        }
    }
}

extension ShortVideoLinkImportModel: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = (navigationAction.request.url?.scheme ?? "").lowercased()
        let inApp = scheme.isEmpty
            || scheme == "http"
            || scheme == "https"
            || scheme == "about"
            || scheme == "data"
            || scheme == "file"
            || scheme == "blob"
        decisionHandler(inApp ? .allow : .cancel)
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor [weak self] in
            self?.finish(.failure(
                ShortVideoLinkImportError.navigationFailed(error.localizedDescription)
            ))
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor [weak self] in
            self?.finish(.failure(
                ShortVideoLinkImportError.navigationFailed(error.localizedDescription)
            ))
        }
    }
}

/// 导入后的落盘与可选 WebDAV 推送。同步失败不回滚本地条目。
enum ShortVideoLinkImporter {
    /// 落盘平台一律取自 `video.platformKind`，调用方传错平台也不会串库。
    ///
    /// 推送只把这条视频并进远端文档，不再调用全量 `synchronize`，
    /// 免得一次单条导入顺手改写另一个平台的本地文件。
    static func store(_ video: ShortVideo) async -> String? {
        let platform = video.platformKind
        let merged = ShortVideoMerge.merge(ShortVideoStore.load(platform), [video])
        ShortVideoStore.save(merged, for: platform)

        let config = ShortVideoSyncConfig.load()
        guard config.isValid else { return nil }
        do {
            var document = try await ShortVideoSyncService.fetchRemote(config)
            document.items = ShortVideoMerge.merge(document.items, [video])
            document.updatedAt = Date().timeIntervalSince1970
            try await ShortVideoSyncService.upload(document, config: config)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
#endif
