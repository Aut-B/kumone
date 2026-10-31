#if os(iOS)
import Foundation
import WebKit

/// 在真实的 `WKWebView` 里抓收藏夹。
///
/// 抖音和 TikTok 的网页接口都要签名（抖音是 `a_bogus` + UIFID，缺了就
/// `403 Blocked by ArgusSecurityPlugin`），自己做签名不现实。让真实页面跑起来、
/// 由站点自己的 JS 去签，我们只在旁边把返回的 JSON 抄一份——里面本来就带着
/// 可以直接播的地址。
///
/// 关键点：**登录、搜索这些交互阶段完全不注入任何脚本**。之前为了抓接口在
/// documentStart 就换掉 `fetch` / `XMLHttpRequest`，站点一旦察觉被改过，
/// 「登录」按钮和搜索就会静默失效。现在脚本只在点「开始抓取」时才注入，
/// 页面加载和登录全程是原样的。
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
    @Published private(set) var lastScriptError: String?
    @Published private(set) var logLines: [String] = []
    @Published private(set) var useMobileUserAgent: Bool
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private(set) var webView: WKWebView!

    private var driverTask: Task<Void, Never>?
    private var idleRounds = 0
    private var lastCount = 0
    private var startedAt = Date()
    private var hasLoadedPage = false
    private var pendingCollect = false
    private var hookInstalled = false

    static let handlerName = "shortvideo"

    var isCollecting: Bool { phase == .collecting }

    /// 桌面 UA 是主力；某些账号在桌面版登录面板上点不动时，切成手机 UA 用
    /// 短信验证码登录，cookie 落在同一个域上，切回桌面版照样有效。
    var userAgent: String {
        useMobileUserAgent ? platform.mobileUserAgent : platform.userAgent
    }

    private static func lastRefreshKey(_ platform: ShortVideoPlatform) -> String {
        "shortVideoLastRefresh.\(platform.rawValue)"
    }

    private static func mobileUAKey(_ platform: ShortVideoPlatform) -> String {
        "shortVideoMobileUA.\(platform.rawValue)"
    }

    var lastRefreshAt: Date? {
        let stamp = UserDefaults.standard.double(forKey: Self.lastRefreshKey(platform))
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// 直链是签名过的，两小时左右就开始失效；过期前重抓一次。
    var isStale: Bool {
        guard !videos.isEmpty else { return false }
        guard let last = lastRefreshAt else { return true }
        return Date().timeIntervalSince(last) > 2 * 3600
    }

    /// 老数据没有 `videoID`，只能用会过期的签名直链——提示重抓一次。
    var missingStableID: Bool {
        guard !videos.isEmpty else { return false }
        return videos.contains { ($0.videoID ?? "").isEmpty }
    }

    init(platform: ShortVideoPlatform) {
        self.platform = platform
        self.useMobileUserAgent = UserDefaults.standard.bool(forKey: Self.mobileUAKey(platform))
        super.init()
        videos = ShortVideoStore.load(platform)
        status = videos.isEmpty
            ? "在下面的网页里登录 \(platform.albumName)，然后点「开始抓取」。"
            : "已加载上次抓取的 \(videos.count) 条，可重新抓取"

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.add(self, name: Self.handlerName)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        webView = view
        note("已就绪（\(useMobileUserAgent ? "手机 UA" : "桌面 UA")）")
    }

    deinit {
        driverTask?.cancel()
    }

    // MARK: - 日志

    func note(_ line: String) {
        let stamp = DateFormatter.shortClock.string(from: Date())
        logLines.append("\(stamp) \(line)")
        if logLines.count > 60 { logLines.removeFirst(logLines.count - 60) }
    }

    // MARK: - 导航

    func loadFavoritesPageIfNeeded() {
        guard !hasLoadedPage else { return }
        hasLoadedPage = true
        openHomePage()
    }

    /// 打开收藏页。
    func reloadPage() {
        hasLoadedPage = true
        phase = .loading
        lastError = nil
        status = "正在打开 \(platform.albumName) 收藏页…"
        load(platform.favoritesURLString)
    }

    /// 打开站点首页：登录面板一般在首页触发，收藏页被拦时可以退回去登录。
    func openHomePage() {
        hasLoadedPage = true
        phase = .loading
        lastError = nil
        status = "正在打开 \(platform.albumName) 首页…"
        load(platform.homeURLString)
    }

    /// 直接打开站点登录页（抖音是 sso.douyin.com）。
    func openLoginPage() {
        hasLoadedPage = true
        phase = .loading
        lastError = nil
        status = "登录页：登录完成后点「收藏页」回去抓取"
        load(platform.loginURLString)
    }

    func reloadCurrentPage() {
        lastError = nil
        phase = .loading
        status = "重新加载…"
        webView.reload()
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    func toggleUserAgent() {
        useMobileUserAgent.toggle()
        UserDefaults.standard.set(useMobileUserAgent, forKey: Self.mobileUAKey(platform))
        webView.customUserAgent = userAgent
        note("切换为\(useMobileUserAgent ? "手机 UA" : "桌面 UA")")
        status = "已切换为\(useMobileUserAgent ? "手机" : "桌面")版，正在重新加载…"
        reloadCurrentPage()
    }

    private func load(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webView.customUserAgent = userAgent
        note("打开 \(urlString)")
        webView.load(request)
    }

    // MARK: - 抓取

    /// 开始抓取。当前不在收藏页时先去收藏页，加载完再自动开始。
    func startCollecting() {
        guard phase != .collecting else { return }
        if !isOnFavoritesPage {
            pendingCollect = true
            reloadPage()
            status = "正在打开收藏页，加载完自动开始抓取…"
            return
        }
        beginCollecting()
    }

    private var isOnFavoritesPage: Bool {
        guard let current = webView.url?.absoluteString else { return false }
        switch platform {
        case .douyin:
            return current.contains("/user/self") || current.contains("showTab=favorite")
        case .tiktok:
            return current.contains("tiktok.com/@")
        }
    }

    private func beginCollecting() {
        phase = .collecting
        idleRounds = 0
        lastCount = videos.count
        startedAt = Date()
        lastError = nil
        lastScriptError = nil
        status = "正在抓取…如果一直没动静，请先在网页里登录 \(platform.albumName)"
        note("开始抓取")

        if hookInstalled {
            startDriver()
            return
        }
        webView.evaluateJavaScript(Self.hookScript(for: platform)) { [weak self] _, error in
            guard let self else { return }
            if let error {
                self.note("注入失败：\(error.localizedDescription)")
            } else {
                self.hookInstalled = true
                self.note("接口监听已装上")
            }
            self.startDriver()
        }
    }

    private func startDriver() {
        webView.evaluateJavaScript(Self.driverScript(for: platform)) { [weak self] _, error in
            guard let self, let error else { return }
            self.note("驱动脚本失败：\(error.localizedDescription)")
        }
        startTicking()
    }

    private func startTicking() {
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
        if !videos.isEmpty {
            UserDefaults.standard.set(Date().timeIntervalSince1970,
                                      forKey: Self.lastRefreshKey(platform))
        }
        note("停止抓取：\(videos.count) 条")
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
                if videos[index].playURL != video.playURL
                    || videos[index].videoID != video.videoID {
                    var updated = video
                    if (updated.videoID ?? "").isEmpty {
                        updated.videoID = videos[index].videoID
                    }
                    videos[index] = updated
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
                if self.loggedIn != loggedIn {
                    self.loggedIn = loggedIn
                    self.note(loggedIn ? "检测到登录态" : "检测到未登录")
                }
            }
        }
    }

    // MARK: - 注入脚本


    static func hookScript(for platform: ShortVideoPlatform) -> String {
        let markers = platform.payloadMarkers.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        (function () {
          if (window.__kumoneShortVideoHook) { return; }
          window.__kumoneShortVideoHook = true;

          var MARKERS = [\(markers)];
          var HANDLER = "\(handlerName)";
          var reported = {};

          function send(payload) {
            try { window.webkit.messageHandlers[HANDLER].postMessage(payload); } catch (e) {}
          }

          function note(text) {
            try {
              var key = String(text).slice(0, 120);
              if (reported[key]) { return; }
              reported[key] = true;
              send({ error: key });
            } catch (e) {}
          }

          window.addEventListener('error', function (event) {
            var target = event && event.target;
            if (target && target !== window && (target.src || target.href)) {
              note('资源加载失败: ' + (target.src || target.href));
              return;
            }
            note('JS 错误: ' + (event && event.message ? event.message : 'unknown'));
          }, true);

          window.addEventListener('unhandledrejection', function (event) {
            var reason = event && event.reason;
            var text = (reason && (reason.message || reason.errMsg)) || reason;
            note('JS 异常: ' + String(text));
          });

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
              send({ url: String(url), body: text });
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
                    if (response && response.status >= 400) {
                      note('接口 ' + response.status + ': ' + String(url).slice(0, 90));
                    }
                    response.clone().text().then(function (text) { post(url, text); }).catch(function () {});
                  } catch (e) {}
                }).catch(function (error) {
                  note('请求失败: ' + String(url).slice(0, 90) + ' ' + (error && error.message ? error.message : ''));
                });
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
                  if (xhr.status >= 400) {
                    note('接口 ' + xhr.status + ': ' + String(xhr.__kumoneURL).slice(0, 90));
                  }
                  post(xhr.__kumoneURL, xhr.responseText);
                } catch (e) {}
              });
              xhr.addEventListener('error', function () {
                note('请求失败: ' + String(xhr.__kumoneURL).slice(0, 90));
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
                if (this === wrapped[i]) { return 'function ' + (wrapped[i].name || '') + '() { [native code] }'; }
              }
              return originalToString.call(this);
            };
          } catch (e) {}
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
              let payload = message.body as? [String: Any] else { return }
        let body = payload["body"] as? String
        let error = payload["error"] as? String
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let body { self.ingest(body) }
            if let error {
                self.lastScriptError = error
                self.note("页面：\(error)")
            }
        }
    }
}

extension ShortVideoCollector: WKUIDelegate {
    /// `window.open` / `target=_blank` 一律在本页打开。
    ///
    /// 抖音的「登录」、搜索结果、视频详情全是新窗口链接；不实现这个回调，
    /// 点了就什么都不发生——这正是「登录按钮点不动」的真正原因。
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        let target = navigationAction.request.url
        Task { @MainActor [weak self] in
            guard let self, let target else { return }
            let scheme = (target.scheme ?? "").lowercased()
            if scheme == "http" || scheme == "https" || scheme == "about" {
                self.note("新窗口转本页：\(target.absoluteString.prefix(80))")
                var request = URLRequest(url: target)
                request.timeoutInterval = 30
                self.webView.load(request)
            } else {
                self.note("拦下非网页链接：\(target.absoluteString.prefix(80))")
            }
        }
        return nil
    }

    nonisolated func webView(_ webView: WKWebView,
                             runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    nonisolated func webView(_ webView: WKWebView,
                             runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

extension ShortVideoCollector: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let scheme = (url?.scheme ?? "").lowercased()
        if !scheme.isEmpty, scheme != "http", scheme != "https", scheme != "about",
           scheme != "file", scheme != "data", scheme != "blob" {
            Task { @MainActor [weak self] in
                self?.note("拦下 App 跳转：\(scheme)://")
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.hookInstalled = false
            self.syncNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = "页面已响应：\(self.webView.url?.absoluteString.prefix(60) ?? "")"
            self.syncNavigationState()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshLoginState()
            self.syncNavigationState()
            self.note("加载完成：\(self.webView.url?.absoluteString.prefix(70) ?? "")")
            if self.pendingCollect {
                self.pendingCollect = false
                self.beginCollecting()
                return
            }
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
            self?.status = "网页进程被系统回收，请点「重新加载」"
            self?.note("网页进程被回收")
        }
    }
}

private extension ShortVideoCollector {
    func syncNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func report(_ error: Error) {
        let ns = error as NSError
        // 用户主动取消的跳转不算错误。
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        lastError = error.localizedDescription
        if phase == .loading || phase == .collecting {
            phase = .failed(error.localizedDescription)
        }
        status = "网页加载失败：\(error.localizedDescription)"
        note("加载失败：\(ns.code) \(error.localizedDescription)")
    }
}

private extension DateFormatter {
    static let shortClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
#endif