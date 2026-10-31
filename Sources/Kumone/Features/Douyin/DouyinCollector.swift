#if os(iOS)
import Foundation
import WebKit

/// Scrapes the signed-in Douyin favourites page inside a real `WKWebView`.
///
/// Douyin's web API rejects plain HTTP clients (`ArgusSecurityPlugin`: UIFID
/// missing), and the signature algorithm changes often. Running the real page
/// lets Douyin's own JavaScript sign each request; we only observe the JSON it
/// receives, which already carries the play URLs.
@MainActor
final class DouyinCollector: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case collecting
        case finished
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var videos: [DouyinVideo] = []
    @Published private(set) var status = ""

    private(set) var webView: WKWebView!

    private var driverTask: Task<Void, Never>?
    private var idleRounds = 0
    private var lastCount = 0
    private var startedAt = Date()
    private var hasLoadedPage = false

    static let handlerName = "douyin"

    var isCollecting: Bool { phase == .collecting }

    override init() {
        super.init()
        videos = DouyinStore.load()
        status = videos.isEmpty
            ? "在下方网页里登录抖音，然后点「开始抓取」"
            : "已加载上次抓取的 \(videos.count) 条，可重新抓取"

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.hookScript,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        configuration.userContentController.add(self, name: Self.handlerName)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = DouyinPlatform.browserUserAgent
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        webView = view
    }

    deinit {
        driverTask?.cancel()
    }

    // MARK: - Navigation

    func loadFavoritesPageIfNeeded() {
        guard !hasLoadedPage else { return }
        reloadPage()
    }

    func reloadPage() {
        hasLoadedPage = true
        phase = .loading
        status = "正在打开抖音网页版…"
        guard let url = URL(string: "https://www.douyin.com/user/self?showTab=favorite_collection") else {
            phase = .failed("链接无效")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webView.load(request)
    }

    // MARK: - Collecting

    func startCollecting() {
        guard phase != .collecting else { return }
        phase = .collecting
        idleRounds = 0
        lastCount = videos.count
        startedAt = Date()
        status = "正在抓取…如果一直没动静，请先在网页里登录抖音"
        webView.evaluateJavaScript(Self.driverScript)

        driverTask?.cancel()
        driverTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    func stopCollecting(message: String? = nil) {
        driverTask?.cancel()
        driverTask = nil
        webView.evaluateJavaScript("try{clearInterval(window.__kumoneDriver);window.__kumoneDriver=null;}catch(e){}")
        phase = .finished
        status = message ?? "已抓取 \(videos.count) 条"
        DouyinStore.save(videos)
    }

    func clear() {
        videos = []
        DouyinStore.save(videos)
        status = "已清空，可重新抓取"
        phase = .idle
    }

    private func tick() {
        guard phase == .collecting else { return }
        webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);")

        if Date().timeIntervalSince(startedAt) > 300 {
            stopCollecting(message: "抓取超时，已保留 \(videos.count) 条")
            return
        }
        if videos.count == lastCount {
            idleRounds += 1
        } else {
            idleRounds = 0
            lastCount = videos.count
        }
        if idleRounds >= 10 {
            stopCollecting(message: "抓取完成，共 \(videos.count) 条")
        }
    }

    private func ingest(_ body: String) {
        let parsed = DouyinParser.videos(fromResponseBody: body)
        guard !parsed.isEmpty else { return }
        var indexByID = Dictionary(
            videos.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var changed = 0
        for video in parsed {
            if let index = indexByID[video.id] {
                // Play URLs are signed and expire; a re-scrape refreshes them
                // instead of keeping the stale copy.
                if videos[index].playURL != video.playURL {
                    videos[index] = video
                    changed += 1
                }
            } else {
                videos.append(video)
                indexByID[video.id] = videos.count - 1
                changed += 1
            }
        }
        guard changed > 0 else { return }
        status = "已抓取 \(videos.count) 条…"
        DouyinStore.save(videos)
    }

    // MARK: - Injected JavaScript

    /// Wraps `fetch` and `XMLHttpRequest` so every Douyin web API response the
    /// page receives is forwarded to the native side.
    private static let hookScript = #"""
    (function () {
      if (window.__kumoneDouyinHook) { return; }
      window.__kumoneDouyinHook = true;

      function post(url, text) {
        try {
          if (!text || text.length < 40) { return; }
          if (text.indexOf('aweme_list') < 0 && text.indexOf('aweme_detail') < 0) { return; }
          window.webkit.messageHandlers.douyin.postMessage({ url: String(url), body: text });
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
                if (String(url).indexOf('/aweme/v1/web/') >= 0) {
                  response.clone().text().then(function (text) { post(url, text); }).catch(function () {});
                }
              } catch (e) {}
            }).catch(function () {});
          } catch (e) {}
          return promise;
        };
      }

      var open = XMLHttpRequest.prototype.open;
      var send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__kumoneURL = url;
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        var xhr = this;
        try {
          xhr.addEventListener('load', function () {
            try {
              if (String(xhr.__kumoneURL).indexOf('/aweme/v1/web/') >= 0) {
                post(xhr.__kumoneURL, xhr.responseText);
              }
            } catch (e) {}
          });
        } catch (e) {}
        return send.apply(this, arguments);
      };
    })();
    """#

    /// Clicks the 收藏 tab once, then keeps the page scrolled to the bottom so
    /// the list paginates.
    private static let driverScript = #"""
    (function () {
      if (window.__kumoneDriver) { return; }
      window.__kumoneDriver = setInterval(function () {
        try {
          if (!window.__kumoneClickedTab) {
            var nodes = document.querySelectorAll('div,span,a,li');
            for (var i = 0; i < nodes.length; i++) {
              var text = (nodes[i].textContent || '').trim();
              if (text === '收藏' || text === '收藏夹') {
                nodes[i].click();
                window.__kumoneClickedTab = true;
                break;
              }
            }
          }
          window.scrollTo(0, document.body.scrollHeight);
        } catch (e) {}
      }, 1200);
    })();
    """#
}

extension DouyinCollector: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == DouyinCollector.handlerName,
              let payload = message.body as? [String: Any],
              let body = payload["body"] as? String else { return }
        Task { @MainActor [weak self] in
            self?.ingest(body)
        }
    }
}

extension DouyinCollector: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self, self.phase == .loading else { return }
            self.status = "页面已加载：登录后点「开始抓取」"
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.phase == .loading else { return }
            self.phase = .failed(error.localizedDescription)
            self.status = "网页加载失败：\(error.localizedDescription)"
        }
    }
}
#endif