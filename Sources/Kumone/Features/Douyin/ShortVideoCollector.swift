#if os(iOS)
import Foundation
import WebKit

/// 在真实的 `WKWebView` 里抓收藏夹。
///
/// 抖音和 TikTok 的网页接口都要签名（抖音是 `a_bogus` + UIFID，缺了就
/// `403 Blocked by ArgusSecurityPlugin`），自己做签名不现实。让真实页面跑起来、
/// 由站点自己的 JS 去签，我们只在旁边把返回的 JSON 抄一份——里面本来就带着
/// 可以直接播的地址。
@MainActor
final class ShortVideoCollector: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case collecting
        case finished
        case failed(String)
    }

    let platform: ShortVideoPlatform

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var videos: [ShortVideo] = []
    @Published private(set) var status = ""
    @Published private(set) var loggedIn = false
    @Published private(set) var lastError: String?

    private(set) var webView: WKWebView!

    private var driverTask: Task<Void, Never>?
    private var idleRounds = 0
    private var lastCount = 0
    private var startedAt = Date()
    private var hasLoadedPage = false

    static let handlerName = "shortvideo"

    var isCollecting: Bool { phase == .collecting }

    init(platform: ShortVideoPlatform) {
        self.platform = platform
        super.init()
        videos = ShortVideoStore.load(platform)
        status = videos.isEmpty
            ? "在下面的网页里登录 \(platform.albumName)，然后点「开始抓取」"
            : "已加载上次抓取的 \(videos.count) 条，可重新抓取"

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.hookScript(for: platform),
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        configuration.userContentController.add(self, name: Self.handlerName)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = platform.userAgent
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        webView = view
    }

    deinit {
        driverTask?.cancel()
    }

    // MARK: - 导航

    func loadFavoritesPageIfNeeded() {
        guard !hasLoadedPage else { return }
        reloadPage()
    }

    func reloadPage() {
        hasLoadedPage = true
        phase = .loading
        lastError = nil
        status = "正在打开 \(platform.albumName) 网页版…"
        guard let url = URL(string: platform.homeURLString) else {
            phase = .failed("链接无效")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webView.customUserAgent = platform.userAgent
        webView.load(request)
    }

    /// 打开站点首页：登录弹窗一般在首页触发，收藏页被拦时可以退回去登录。
    func openHomePage() {
        phase = .loading
        lastError = nil
        status = "正在打开 \(platform.albumName) 首页…"
        let home = platform == .douyin ? "https://www.douyin.com/" : "https://www.tiktok.com/"
        guard let url = URL(string: home) else { return }
        webView.customUserAgent = platform.userAgent
        webView.load(URLRequest(url: url))
    }

    /// 直接打开站点登录页（抖音是 sso.douyin.com）。登录完 cookie 落在同一个
    /// 域上，点「刷新」回收藏页就能用。
    func openLoginPage() {
        phase = .loading
        lastError = nil
        status = "登录页：登录完成后点右上角刷新回收藏页"
        guard let target = URL(string: platform.loginURLString) else { return }
        webView.customUserAgent = platform.userAgent
        webView.load(URLRequest(url: target))
    }

    // MARK: - 抓取

    func startCollecting() {
        guard phase != .collecting else { return }
        phase = .collecting
        idleRounds = 0
        lastCount = videos.count
        startedAt = Date()
        lastError = nil
        status = "正在抓取…如果一直没动静，请先在网页里登录 \(platform.albumName)"
        webView.evaluateJavaScript(Self.driverScript(for: platform))

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
        ShortVideoStore.save(videos, for: platform)
    }

    func clear() {
        videos = []
        ShortVideoStore.save(videos, for: platform)
        status = "已清空，可重新抓取"
        phase = .idle
    }

    /// 把远端列表并进本地（WebDAV 同步回来时调用）。
    func applyRemote(_ remote: [ShortVideo]) {
        guard !remote.isEmpty else { return }
        let merged = ShortVideoMerge.merge(videos, remote)
        guard merged != videos else { return }
        videos = merged
        ShortVideoStore.save(videos, for: platform)
        status = "已同步 \(videos.count) 条"
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
        let parsed = ShortVideoParser.videos(fromResponseBody: body, platform: platform)
        guard !parsed.isEmpty else { return }
        var indexByID = Dictionary(
            videos.enumerated().map { ($1.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var changed = 0
        for video in parsed {
            if let index = indexByID[video.id] {
                // 直链是签名过的，会过期；重抓时用新的覆盖旧的。
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
        ShortVideoStore.save(videos, for: platform)
    }

    // MARK: - 登录状态

    func refreshLoginState() {
        let needle = platform.cookieDomainNeedle
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            var names: Set<String> = []
            for cookie in cookies where cookie.domain.lowercased().contains(needle) {
                names.insert(cookie.name)
            }
            let loggedIn = names.contains("sessionid")
                || names.contains("sessionid_ss")
                || names.contains("sid_guard")
                || names.contains("sid_tt")
                || names.contains("uid_tt")
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.loggedIn != loggedIn { self.loggedIn = loggedIn }
            }
        }
    }

    // MARK: - 注入脚本

    /// 包住 `fetch` / `XMLHttpRequest`，凡是返回体里带平台特征字段的都回传原生。
    ///
    /// 顺带把 `window.open` 和 `target="_blank"` 改成本页跳转：WKWebView 不实现
    /// `uiDelegate` 时新窗口一律是 `nil`，抖音右上角「登录」点了没反应就是这个。
    static func hookScript(for platform: ShortVideoPlatform) -> String {
        let markers = platform.payloadMarkers.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        (function () {
          if (window.__kumoneShortVideoHook) { return; }
          window.__kumoneShortVideoHook = true;

          var MARKERS = [\(markers)];
          var HANDLER = "\(handlerName)";

          function interesting(text) {
            if (!text || text.length < 40) { return false; }
            for (var i = 0; i < MARKERS.length; i++) {
              if (text.indexOf(MARKERS[i]) >= 0) { return true; }
            }
            return false;
          }

          function post(url, text) {
            try {
              if (!interesting(text)) { return; }
              window.webkit.messageHandlers[HANDLER].postMessage({ url: String(url), body: text });
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
                    response.clone().text().then(function (text) { post(url, text); }).catch(function () {});
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
                try { post(xhr.__kumoneURL, xhr.responseText); } catch (e) {}
              });
            } catch (e) {}
            return send.apply(this, arguments);
          };

          // 新窗口 -> 本页打开
          var nativeOpen = window.open;
          window.open = function (url) {
            try {
              if (url && String(url).indexOf('http') === 0) {
                window.location.href = String(url);
              }
            } catch (e) {}
            return window;
          };
          if (!nativeOpen) { window.open = window.open; }

          document.addEventListener('click', function (event) {
            try {
              var node = event.target;
              while (node && node.tagName !== 'A') { node = node.parentElement; }
              if (!node) { return; }
              var target = (node.getAttribute('target') || '').toLowerCase();
              var href = node.getAttribute('href') || '';
              if (target === '_blank' && href.indexOf('http') === 0) {
                event.preventDefault();
                window.location.href = href;
              }
            } catch (e) {}
          }, true);
        })();
        """
    }

    /// 自动点开「收藏」tab，并持续滚到底，让列表继续分页。
    static func driverScript(for platform: ShortVideoPlatform) -> String {
        let titles = platform.tabTitles.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        (function () {
          if (window.__kumoneDriver) { return; }
          var TITLES = [\(titles)];
          window.__kumoneDriver = setInterval(function () {
            try {
              if (!window.__kumoneClickedTab) {
                var nodes = document.querySelectorAll('div,span,a,li,button');
                for (var i = 0; i < nodes.length; i++) {
                  var text = (nodes[i].textContent || '').trim();
                  for (var t = 0; t < TITLES.length; t++) {
                    if (text === TITLES[t]) {
                      nodes[i].click();
                      window.__kumoneClickedTab = true;
                      return;
                    }
                  }
                }
              }
              window.scrollTo(0, document.body.scrollHeight);
            } catch (e) {}
          }, 1200);
        })();
        """
    }
}

extension ShortVideoCollector: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == ShortVideoCollector.handlerName,
              let payload = message.body as? [String: Any],
              let body = payload["body"] as? String else { return }
        Task { @MainActor [weak self] in
            self?.ingest(body)
        }
    }
}

extension ShortVideoCollector: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshLoginState()
            if self.phase == .loading {
                self.status = "页面已加载：登录后点「开始抓取」"
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.report(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor [weak self] in
            self?.report(error)
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak self] in
            self?.lastError = "网页进程被系统回收，请重新加载"
            self?.status = "网页进程被系统回收，请点右上角刷新"
        }
    }
}

private extension ShortVideoCollector {
    func report(_ error: Error) {
        let ns = error as NSError
        // 用户主动取消的跳转不算错误。
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        lastError = error.localizedDescription
        if phase == .loading || phase == .collecting {
            phase = .failed(error.localizedDescription)
        }
        status = "网页加载失败：\(error.localizedDescription)"
    }
}
#endif