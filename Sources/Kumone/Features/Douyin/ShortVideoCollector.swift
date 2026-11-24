#if os(iOS)
import Foundation
import WebKit

/// 登录 cookie 的判定规则：主 WebView 和登录弹窗共用同一套，避免两边结论不一致。
enum ShortVideoLoginCookie {
    /// 两个站的登录 cookie 名字基本一致。
    static let names: Set<String> = [
        "sessionid", "sessionid_ss", "sid_guard", "sid_tt", "uid_tt",
    ]

    /// 只认主站域（或主站子域）上的 cookie。`sso.` / `login.` 这类单点登录
    /// 子域的 host-only cookie 只对登录页有效，不能代表主站已登录。
    static func matchesDomain(_ cookie: HTTPCookie, needle: String) -> Bool {
        let domain = cookie.domain.lowercased()
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == needle || host.hasSuffix("." + needle) else { return false }
        guard !host.hasPrefix("sso."), !host.hasPrefix("login.") else { return false }
        return true
    }

    /// `expiresDate` 为 nil 表示会话 cookie，仍然有效；只拒绝明确过期的。
    static func isExpired(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        guard let expires = cookie.expiresDate else { return false }
        return expires <= now
    }

    static func isLogin(_ cookie: HTTPCookie, needle: String, now: Date = Date()) -> Bool {
        guard names.contains(cookie.name), matchesDomain(cookie, needle: needle) else { return false }
        return !isExpired(cookie, now: now)
    }
}

/// 在真实的 `WKWebView` 里抓收藏夹。
///
/// 抖音和 TikTok 的网页接口都要签名（抖音是 `a_bogus` + UIFID，缺了就
/// `403 Blocked by ArgusSecurityPlugin`），自己做签名不现实。让真实页面跑起来、
/// 由站点自己的 JS 去签，我们只在旁边把返回的 JSON 抄一份——里面本来就带着
/// 可以直接播的地址。
///
/// 关键点：**登录、搜索这些交互阶段不向原生回传任何抓取数据**。收藏页从
/// documentStart 起只装一个「缓冲区」监听：站点自己的请求先留在 JS 里，只有
/// 点「开始抓取」才激活并回传。首页、视频详情和登录页完全不装监听。
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
    /// 本地已有的视频 id 集合：抓取时整段都是旧 id 的响应可以跳过完整解析。
    private var knownVideoIDs: Set<String> = []
    private var startedAt = Date()
    private var hasLoadedPage = false
    private var pendingCollect = false
    /// 本次抓取是否已经为「缓冲为空」刷新过一次页面（防 reload 死循环）。
    private var attemptedReloadFallback = false
    /// 每次主框架导航自增，异步探测据此丢弃过期页面的回调。
    private var navigationGeneration = 0
    /// 当前收藏页监听已准备好的导航代次。
    private var preparedGeneration = -1
    private var preparingCollection = false
    /// 一共收到多少段被抄下来的响应（不等于视频条数）。
    @Published private(set) var rawCount = 0
    private var popupController: ShortVideoPopupViewController?
    private var lastPopupSignature = ""
    private var lastPopupAt = Date.distantPast
    /// 登录完成轮询用：每次开始新一轮轮询自增，旧轮询据此自我失效。
    private var loginWatchGeneration = 0
    /// 登录浮层是否曾经出现过（区分「弹出过又关掉」和「压根没弹出」）。
    private var loginDialogSeen = false
    /// 主页面是否已经加载完成：登录按钮要等页面渲染完再点，否则会落到 SSO 整页。
    private var pageReady = false
    /// 页面还没加载完时用户就点了登录：记下来，等 didFinish 再点。
    private var pendingLogin = false
    /// 回首页重试登录按钮的次数，避免首页也点不到时无限循环。
    private var loginRetryCount = 0
    /// 最近一次因 popup 登录成功而刷新主页面，用来避免关闭 popup 时重复 reload。
    private var lastLoginSyncAt = Date.distantPast
    /// 登录态通知的观察者令牌，deinit 时注销。
    private var loginObserver: NSObjectProtocol?

    static let handlerName = "shortvideo"

    /// 常驻的极轻量脚本：只接管 `window.open`。
    ///
    /// 登录阶段是不注入抓取脚本的（注入会把抖音自己的登录面板弄坏），
    /// 但 WKWebView 在「非用户手势」或弹窗被拦时**根本不会回调**
    /// `createWebViewWith`——表现就是点「登录」一点反应都没有。
    /// 这个桥先让原生弹窗打开，登录页才真能显示出来。
    static let popupBridgeScript = """
    (function () {
      if (window.__kumonePopupBridge) { return; }
      window.__kumonePopupBridge = true;
      var realOpen = window.open;
      window.open = function (url, name, features) {
        var handle = null;
        try { handle = realOpen.apply(window, arguments); } catch (e) { handle = null; }
        try {
          var target = url ? String(url) : '';
          if (!handle && target && target !== 'about:blank') {
            window.webkit.messageHandlers.shortvideo.postMessage({ popup: target });
          }
        } catch (e) {}
        return handle;
      };
    })();
    """

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
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.popupBridgeScript,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.favoritesBufferHookScript(for: platform),
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        webView = view
        loginObserver = NotificationCenter.default.addObserver(
            forName: .shortVideoLoginStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let platformRawValue = notification.object as? String
            Task { @MainActor [weak self] in
                guard let self, platformRawValue == self.platform.rawValue else { return }
                self.handleLoginStateDidChange()
            }
        }
        note("已就绪（\(useMobileUserAgent ? "手机 UA" : "桌面 UA")）")
    }

    deinit {
        driverTask?.cancel()
        if let loginObserver = loginObserver {
            NotificationCenter.default.removeObserver(loginObserver)
        }
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
        reloadPage()
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

    /// 打开登录。
    ///
    /// 直接 `load(loginURL)` 是不行的：`sso.douyin.com` 只是一个登录落地页，
    /// 登录浮层必须由 `www.douyin.com` 自己的前端拉起来，才有回调把 cookie
    /// 写进 douyin.com 域。这里改成：先在当前页面里用 JS 点官方登录按钮，
    /// 点不到再退回 SSO。
    func openLoginPage() {
        hasLoadedPage = true
        lastError = nil
        loginRetryCount = 0
        refreshLoginState { [weak self] in
            guard let self else { return }
            if self.loggedIn {
                self.status = "已登录 \(self.platform.albumName)，无需再次登录"
                self.note("已登录，跳过登录浮层")
                return
            }
            guard self.pageReady else {
                self.pendingLogin = true
                self.status = "页面加载完成后自动调出登录浮层…"
                self.note("页面未加载完成，登录请求排队到 didFinish")
                if !self.webView.isLoading {
                    if self.webView.url == nil {
                        self.load(self.platform.homeURLString)
                    } else {
                        self.webView.reload()
                    }
                }
                return
            }
            self.triggerLoginPrompt()
        }
    }

    /// 只在 `didFinish` 之后调用：页面没渲染完时点按钮会落到 SSO 整页。
    private func triggerLoginPrompt() {
        phase = .loading
        status = "正在调出登录浮层…"
        webView.evaluateJavaScript(Self.loginTriggerScript) { [weak self] result, error in
            guard let self else { return }
            if error == nil, Self.truthy(result) {
                self.status = "已调出登录浮层，登录完成后等待自动刷新…"
                self.watchLoginCompletion()
                return
            }
            // 首页也可能还没渲染出入口：先回首页重试一次，再退回 SSO 整页。
            if self.loginRetryCount == 0 {
                self.loginRetryCount = 1
                self.pendingLogin = true
                self.status = "登录入口尚未渲染，正在回到首页重试…"
                self.note("登录入口未找到，回首页重试一次")
                self.openHomePage()
                return
            }
            self.status = "登录页：登录完成后点「收藏页」回去抓取"
            self.note("登录入口未找到，退回站点登录页")
            self.load(self.platform.loginURLString)
        }
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

    // MARK: - 弹窗

    func presentPopup(_ request: URLRequest) {
        guard let url = request.url else { return }
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else {
            note("拦下非网页弹窗：\(scheme)://")
            return
        }
        // `window.open` 会被两条路同时报到（JS 桥 + WKUIDelegate），这里去重。
        let signature = url.absoluteString
        if signature == lastPopupSignature, Date().timeIntervalSince(lastPopupAt) < 3 {
            return
        }
        lastPopupSignature = signature
        lastPopupAt = Date()

        // 弹窗已经开着时以前直接 return：抖音登录先弹扫码再转手机号，第二次
        // `window.open` 被静默吞掉，用户感觉「点了完全没反应」。现在让已有
        // 弹窗自己跳过去，而不是丢弃这次导航。
        if let existing = popupController {
            existing.load(request)
            return
        }

        guard let host = ShortVideoTopView.controller() else {
            note("弹窗失败：找不到可用的窗口")
            return
        }
        note("弹窗：\(url.absoluteString.prefix(70))")

        let controller = ShortVideoPopupViewController(
            request: request,
            userAgent: userAgent,
            onLogin: { [weak self] in
                guard let self else { return }
                NotificationCenter.default.post(
                    name: .shortVideoLoginStateDidChange,
                    object: self.platform.rawValue
                )
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.popupController = nil
                self.refreshLoginState { [weak self] in
                    guard let self else { return }
                    // 登录通知已经刷新过主页时不再重复加载。
                    if self.loggedIn {
                        self.note("关闭弹窗，登录态已同步")
                        return
                    }
                    self.note("关闭弹窗，刷新本页")
                    self.reloadCurrentPage()
                }
            }
        )
        popupController = controller
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .fullScreen
        host.present(navigation, animated: true)
    }

    // MARK: - 抓取

    /// 开始抓取。
    ///
    /// 已经在「我的 / 某个收藏夹」这一页上就直接开抓——不能重新加载，否则会把
    /// 用户特意挑的那个收藏夹冲掉，退回默认的「收藏」tab。
    func startCollecting() {
        guard phase != .collecting else { return }
        if isOnFavoritesPage {
            beginCollecting()
            return
        }
        pendingCollect = true
        reloadPage()
        status = "正在打开收藏页，加载完自动开始抓取…"
    }

    private var isOnFavoritesPage: Bool {
        guard let current = webView.url?.absoluteString else { return false }
        switch platform {
        case .douyin:
            // 只要还在个人页就行（`/user/self` 下面挂着「收藏」和各个「收藏夹」）。
            return current.contains("/user/self")
        case .tiktok:
            // `tiktok.com/@user/video/123` 同样是 `/@` 开头，但那是视频详情页。
            return current.contains("tiktok.com/@") && !current.contains("/video/")
        }
    }

    private func beginCollecting() {
        guard isOnFavoritesPage else {
            // 打开收藏页后被重定向到登录页时会走到这里：不能再 reload，否则会在
            // 「收藏页 → 登录页」之间无限循环。交给用户登录后手动重试。
            pendingCollect = false
            phase = .idle
            status = "当前不在收藏页（可能被重定向到登录），登录后再点「开始抓取」"
            note("抓取中止：页面不是收藏页")
            return
        }
        guard pageReady, !webView.isLoading else {
            pendingCollect = true
            status = "收藏页加载完成后自动开始抓取…"
            note("收藏页尚未加载完成，抓取排队到 didFinish")
            return
        }

        pendingCollect = false
        phase = .collecting
        idleRounds = 0
        lastCount = videos.count
        knownVideoIDs = Set(videos.map { $0.id })
        startedAt = Date()
        lastError = nil
        lastScriptError = nil
        rawCount = 0
        preparedGeneration = -1
        preparingCollection = false
        attemptedReloadFallback = false
        status = "正在抓取…准备当前收藏页的监听"
        note("开始抓取：直接激活当前收藏页的缓冲监听，不重新加载")
        prepareCollectionOnCurrentPage()
    }

    /// 监听必须在收藏页 documentStart 就装好，否则首屏收藏请求早于 didFinish，
    /// 跳过 reload 后就会一段数据都收不到。这里只负责激活/兜底补装当前页面，
    /// 等 JS 把浏览期间缓冲的响应用 `send` 回传后再启动驱动脚本。
    private func prepareCollectionOnCurrentPage() {
        guard phase == .collecting, isOnFavoritesPage, !preparingCollection else { return }
        preparingCollection = true
        preparedGeneration = -1
        let generation = navigationGeneration
        let probe = "!!window.__kumoneShortVideoHook"
            + " && typeof window.__kumoneStartCollecting === 'function'"
        webView.evaluateJavaScript(probe) { [weak self] result, _ in
            guard let self else { return }
            guard generation == self.navigationGeneration, self.phase == .collecting else {
                if generation == self.navigationGeneration {
                    self.preparingCollection = false
                }
                return
            }
            if Self.truthy(result) {
                self.activateHook(generation: generation)
            } else {
                self.webView.evaluateJavaScript(Self.hookScript(for: self.platform)) { [weak self] _, _ in
                    guard let self else { return }
                    guard generation == self.navigationGeneration, self.phase == .collecting else {
                        if generation == self.navigationGeneration {
                            self.preparingCollection = false
                        }
                        return
                    }
                    self.activateHook(generation: generation)
                }
            }
        }
    }

    private func activateHook(generation: Int) {
        webView.evaluateJavaScript(Self.activateHookScript) { [weak self] result, error in
            guard let self else { return }
            guard generation == self.navigationGeneration, self.phase == .collecting else {
                if generation == self.navigationGeneration {
                    self.preparingCollection = false
                }
                return
            }
            self.preparingCollection = false
            if let error {
                self.note("激活监听失败：\(error.localizedDescription)")
            }
            // 激活脚本现在返回回放的缓冲段数：-1 = 监听根本没装上，
            // 0 = 装上了但缓冲为空（首屏请求发生在监听安装之前，晚注入场景）。
            let flushed = (result as? NSNumber)?.intValue ?? -1
            if flushed < 0 {
                // 明确报错，绝不静默 0 条（BATCH_03 复审要求）。
                self.stopCollecting(message: "监听激活失败：请退出收藏页重进后再点「开始抓取」")
                return
            }
            if flushed == 0 {
                // 缓冲为空：兜底刷新当前页一次。reload 的是当前 URL（不是默认
                // 收藏页），收藏夹的 URL 参数原样保留；重载后 documentStart 的
                // 全站缓冲监听从第一刻起抄请求，首屏数据不会漏。
                if self.attemptedReloadFallback {
                    self.stopCollecting(message: "没有收到收藏接口数据：请确认已在收藏页，或重新登录后再试")
                    return
                }
                self.attemptedReloadFallback = true
                self.pendingCollect = true
                self.status = "正在刷新当前收藏页以捕获首屏数据（保持所选收藏夹）…"
                self.note("缓冲为空：刷新当前页重新捕获首屏")
                self.reloadCurrentPage()
                return
            }
            self.preparedGeneration = generation
            self.note("监听已激活，回放 \(flushed) 段缓冲，开始驱动当前收藏页")
            self.startDriver()
        }
    }

    private func startDriver() {
        // 把本地已有的条数传进去：驱动脚本滚到「见过 ≥ 本地基线、且连续两轮没新增」
        // 就停，不再为了同步几条新增而把几百条旧收藏从头滚一遍。
        webView.evaluateJavaScript(Self.driverScript(for: platform, knownCount: videos.count)) { [weak self] _, error in
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
        preparingCollection = false
        webView.evaluateJavaScript(
            "try{clearInterval(window.__kumoneDriver);window.__kumoneDriver=null;"
            + "window.__kumoneCollecting=false;}catch(e){}"
        )
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
        knownVideoIDs = []
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
        knownVideoIDs = Set(merged.map { $0.id })
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
        if idleRounds >= 6 {
            if rawCount == 0 {
                stopCollecting(message: "一条都没抓到：当前收藏页没有回传数据（监听未生效或页面不是收藏页）")
            } else if videos.isEmpty {
                let detail = "收到 \(rawCount) 段数据但解析出 0 条（字段可能变了）"
                stopCollecting(message: "一条都没抓到：\(detail)")
            } else {
                stopCollecting(message: "抓取完成，共 \(videos.count) 条")
            }
        }
    }

    private func ingest(_ body: String, url: String?) {
        guard !Self.isNonFavoriteResponse(url: url, platform: platform) else {
            note("跳过非收藏接口：\(url?.prefix(80) ?? "")")
            return
        }
        guard phase == .collecting, isOnFavoritesPage else { return }
        guard Self.favoriteListMarkers(for: platform).contains(where: { body.contains($0) }) else { return }
        rawCount += 1
        // 先只扫 id：整段都是本地已有的旧响应就跳过 `JSONSerialization`，
        // 收藏多时避免每段都重跑完整解析。扫不到 id 时退回到原路径。
        let seenIDs = ShortVideoParser.ids(inResponseBody: body)
        if !seenIDs.isEmpty, seenIDs.isSubset(of: knownVideoIDs) {
            return
        }
        let parsed = ShortVideoParser.videos(fromResponseBody: body, platform: platform)
        guard !parsed.isEmpty else {
            note("第 \(rawCount) 段数据没解析出条目（\(body.count) 字符）")
            return
        }
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
                knownVideoIDs.insert(video.id)
                changed += 1
            }
        }
        guard changed > 0 else { return }
        status = "已抓取 \(videos.count) 条…"
        ShortVideoStore.save(videos, for: platform)
    }

    // MARK: - 登录状态

    /// 检查主站登录态。`completion` 在主线程、登录态写回之后调用。
    ///
    /// 只认主站域上、没过期的登录 cookie。以前只按名字判断，
    /// 过期的 `sessionid` 也会被当成已登录，于是收藏页一直 403。
    /// 日志只输出 cookie 名，绝不输出 cookie 值。
    func refreshLoginState(completion: (() -> Void)? = nil) {
        let needle = platform.cookieDomainNeedle
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let now = Date()
            var active: Set<String> = []
            var expired: Set<String> = []
            for cookie in cookies where ShortVideoLoginCookie.names.contains(cookie.name) {
                guard ShortVideoLoginCookie.matchesDomain(cookie, needle: needle) else { continue }
                if ShortVideoLoginCookie.isExpired(cookie, now: now) {
                    expired.insert(cookie.name)
                } else {
                    active.insert(cookie.name)
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyLoginState(loggedIn: !active.isEmpty, expiredNames: expired)
                completion?()
            }
        }
    }

    /// 把 cookie 检测结果写回界面。日志里只允许出现 cookie 名。
    private func applyLoginState(loggedIn: Bool, expiredNames: Set<String>) {
        let changed = self.loggedIn != loggedIn
        if changed {
            self.loggedIn = loggedIn
        }
        if loggedIn {
            guard changed else { return }
            self.note("检测到登录态")
            if self.status.isEmpty
                || self.status.contains("未登录")
                || self.status.contains("登录已过期") {
                self.status = "已登录 \(platform.albumName)"
            }
            return
        }
        if !expiredNames.isEmpty {
            guard changed || status != "登录已过期，请重新登录" else { return }
            note("登录 cookie 已过期：\(expiredNames.sorted().joined(separator: ", "))")
            status = "登录已过期，请重新登录"
            return
        }
        guard changed else { return }
        note("检测到未登录")
        if status.isEmpty {
            status = "未登录，请先登录 \(platform.albumName)"
        }
    }

    /// popup 登录成功后收到通知：先等主站 cookie 可见，再刷新主 WebView。
    private func handleLoginStateDidChange() {
        let now = Date()
        guard now.timeIntervalSince(lastLoginSyncAt) >= 2 else { return }
        lastLoginSyncAt = now
        note("收到登录态变更，检查主站 cookie")
        syncLoginAfterPopup(attempt: 0)
    }

    private func syncLoginAfterPopup(attempt: Int) {
        refreshLoginState { [weak self] in
            guard let self else { return }
            if self.loggedIn {
                self.lastLoginSyncAt = Date()
                self.phase = .loading
                self.status = "登录成功，正在刷新页面…"
                self.note("登录态已同步，刷新主页面")
                self.webView.reload()
                return
            }
            // popup 写 cookie 和通知几乎同时发生，给主站 cookie 一点落盘时间。
            guard attempt < 3 else {
                self.note("收到登录通知，但主站 cookie 仍不可见")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.syncLoginAfterPopup(attempt: attempt + 1)
            }
        }
    }

    /// `evaluateJavaScript` 把 JS 布尔桥接成 `NSNumber` 而不是 `Bool`，
    /// 直接 `as? Bool` 会永远失败，于是每次都被当成「没点到」退回 SSO。
    static func truthy(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    /// 等登录完成，然后刷新当前页把登录态带进来。
    ///
    /// 抖音的登录浮层是前端自己管理的，登录完不会整页跳转，cookie 虽然写进了
    /// douyin.com 域，但当前页面上的旧渲染还是未登录状态；不刷新就抓不到收藏。
    private func watchLoginCompletion() {
        loginWatchGeneration += 1
        loginDialogSeen = false
        let generation = loginWatchGeneration
        pollLoginState(generation: generation, attempt: 0)
    }

    private func pollLoginState(generation: Int, attempt: Int) {
        guard generation == loginWatchGeneration, attempt < 60 else { return }
        let probe = """
        (function () {
          var dialog = document.querySelector(
            '[class*=login-container], [class*=loginModal], [id*=login-modal]'
          );
          var dialogVisible = false;
          if (dialog) {
            var style = window.getComputedStyle(dialog);
            var rect = dialog.getBoundingClientRect();
            dialogVisible = style.display !== 'none'
              && style.visibility !== 'hidden'
              && rect.width > 0
              && rect.height > 0;
          }
          var avatar = document.querySelector(
            '[data-e2e*=user-info], [class*=userInfo], [class*=avatar]'
          );
          // seen 用来区分「登录浮层出现过又关掉」和「压根没弹出浮层」：
          // 未登录页面上也有 avatar 节点，只看它会一开头就误判成已登录。
          return { visible: dialogVisible, seen: !!dialog, avatar: !!avatar };
        })();
        """
        webView.evaluateJavaScript(probe) { [weak self] result, _ in
            guard let self, generation == self.loginWatchGeneration else { return }
            let map = result as? [String: Any] ?? [:]
            let visible = Self.truthy(map["visible"])
            let seen = Self.truthy(map["seen"])
            let avatar = Self.truthy(map["avatar"])
            if seen { self.loginDialogSeen = true }
            // 判定登录完成：浮层曾出现过、现在已关闭，且页面上出现了登录态节点。
            if self.loginDialogSeen && !visible && avatar {
                self.loginWatchGeneration += 1
                self.status = "登录成功，正在刷新页面…"
                self.webView.reload()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.pollLoginState(generation: generation, attempt: attempt + 1)
            }
        }
    }

    /// 在当前页面里找官方登录入口并点一下。
    ///
    /// 顺序：抖音头部的「登录」按钮 → 侧栏「我的」→ TikTok 的 log in 链接。
    /// 返回 true 表示点到了至少一个候选元素。
    static let loginTriggerScript: String = """
    (function () {
      var texts = ['登录', '立即登录', 'Log in', 'Log in to TikTok', '登录/注册'];
      var nodes = document.querySelectorAll(
        'button, a, div[role=button], [data-e2e*=login], [class*=login]'
      );
      var hit = 0;
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        var t = (el.innerText || el.textContent || '').trim();
        if (t.length === 0 || t.length > 12) { continue; }
        for (var j = 0; j < texts.length; j++) {
          if (t === texts[j] || t.indexOf(texts[j]) === 0) {
            var r = el.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0) { continue; }
            el.click();
            hit = hit + 1;
            break;
          }
        }
        if (hit > 0) { break; }
      }
      if (hit === 0) {
        // 兜底：站点常把登录入口挂在 avatar / 个人中心上。
        var avatar = document.querySelector(
          '[data-e2e*=avatar], [class*=avatar], [class*=Avatar]'
        );
        if (avatar) { avatar.click(); hit = hit + 1; }
      }
      return hit > 0;
    })();
    """

    // MARK: - 注入脚本


    static func favoriteListMarkers(for platform: ShortVideoPlatform) -> [String] {
        switch platform {
        case .douyin: return ["aweme_list"]
        case .tiktok: return ["itemList", "item_list"]
        }
    }

    /// 「作品」列表和收藏列表的响应字段长得很像（都带 `aweme_list` / `itemList`），
    /// 只靠字段名分不出来。这里列出已知的作品接口，避免用户停在「作品」tab 时
    /// 把作品当收藏写进本地并同步上云。
    static func nonFavoriteURLMarkers(for platform: ShortVideoPlatform) -> [String] {
        switch platform {
        case .douyin:
            // 「作品」和「喜欢」都不是收藏；收藏夹/收藏列表走别的接口。
            return ["/aweme/v1/web/aweme/post/", "/aweme/v1/web/aweme/favorite/"]
        case .tiktok:
            // 作品、喜欢、转发都不是收藏。
            return ["/api/post/item_list", "/api/like/item_list", "/api/repost/item_list"]
        }
    }

    static func isNonFavoriteResponse(url: String?, platform: ShortVideoPlatform) -> Bool {
        guard let url, !url.isEmpty else { return false }
        return nonFavoriteURLMarkers(for: platform).contains(where: { url.contains($0) })
    }

    /// 全站从 documentStart 起安装的缓冲监听。
    ///
    /// 之前只在个人页/收藏页安装，但用户从首页经站内 SPA 进入收藏页时没有
    /// 新 document，监听装不上，首屏收藏请求就会漏掉（BATCH_03 复审指出的
    /// 晚注入空洞）。改成全站安装：hookScript 的 post() 自己按 onFavoritesPage()
    /// 过滤，首页/视频详情页的响应根本不会进 buffer，也不会向原生回传；
    /// 在收藏页缓冲的响应，要等用户点「开始抓取」才由 `__kumoneStartCollecting`
    /// 一次性回传，浏览阶段不向原生发任何抓取数据，也不改动页面请求。
    static func favoritesBufferHookScript(for platform: ShortVideoPlatform) -> String {
        let needle = platform.cookieDomainNeedle
        return """
        (function () {
          var host = String(window.location.hostname || '').toLowerCase();
          var suffix = ".\(needle)";
          var onSite = host === "\(needle)"
            || (host.length > suffix.length && host.slice(-suffix.length) === suffix);
          if (!onSite) { return; }
          \(hookScript(for: platform))
        })();
        """
    }

    static let activateHookScript = """
    (function () {
      if (typeof window.__kumoneStartCollecting !== 'function') { return -1; }
      window.__kumoneStartCollecting();
      return window.__kumoneFlushedCount || 0;
    })();
    """

    static func hookScript(for platform: ShortVideoPlatform) -> String {
        let markers = favoriteListMarkers(for: platform).map { "\"\($0)\"" }.joined(separator: ", ")
        let nonFavoriteMarkers = nonFavoriteURLMarkers(for: platform)
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        // 是否还需要驱动脚本去点「收藏」tab：
        // - 抖音：URL 带 `showTab=favorite_collection` 说明当前就是收藏区（用户手选的
        //   收藏夹也在这个 tab 下），点 tab 会把手选收藏夹冲回默认，必须跳过；
        //   没带这个参数（例如停在「作品」）才允许点。
        // - TikTok：`/@me` 是个人页根，收藏 tab 默认没打开，得靠驱动点一下才会发请求。
        let tabAlreadyOpen: String
        switch platform {
        case .douyin:
            tabAlreadyOpen = "window.location.search.indexOf('showTab=favorite_collection') >= 0"
        case .tiktok:
            tabAlreadyOpen = "false"
        }
        let favoritesPageCheck: String
        switch platform {
        case .douyin:
            favoritesPageCheck = """
            function onFavoritesPage() {
              var path = String(window.location.pathname || '');
              if (path.indexOf('/user/self') !== 0) { return false; }
              var search = String(window.location.search || '');
              // 只排除已知的「作品 / 喜欢」tab；收藏夹和未知 tab 仍按收藏页处理。
              if (search.indexOf('showTab=post') >= 0
                  || search.indexOf('showTab=like') >= 0) {
                return false;
              }
              return true;
            }
            """
        case .tiktok:
            favoritesPageCheck = """
            function onFavoritesPage() {
              var path = String(window.location.pathname || '');
              return path.indexOf('/@') === 0 && path.indexOf('/video/') < 0;
            }
            """
        }
        return """
        (function () {
          if (window.__kumoneShortVideoHook) { return; }
          window.__kumoneShortVideoHook = true;
          window.__kumoneCollecting = false;
          window.__kumoneSeenCount = 0;
          // 当前页面上是否已经见过收藏列表响应。它跨多轮抓取保留：第二轮抓取时
          // 页面已经停在收藏区，驱动就不该再点 tab 把收藏夹冲回默认。
          window.__kumoneSawFavoritesData = false;

          var MARKERS = [\(markers)];
          var NON_FAVORITE = [\(nonFavoriteMarkers)];
          var TAB_ALREADY_OPEN = \(tabAlreadyOpen);
          \(favoritesPageCheck)
          var HANDLER = "\(handlerName)";
          var reported = {};
          var posted = {};
          var buffer = [];
          var bufferChars = 0;
          var MAX_BUFFERED = 40;
          // 浏览阶段可能攒很久：按条数和总字符数双上限，避免在手机上把内存吃满。
          var MAX_BUFFER_CHARS = 6000000;
          window.__kumonePosted = posted;

          function send(payload) {
            try { window.webkit.messageHandlers[HANDLER].postMessage(payload); } catch (e) {}
          }

          function note(text) {
            if (!window.__kumoneCollecting) { return; }
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

          function countSeen(text) {
            try {
              // 只数明确的视频 id 字段，避免把 "id": 之类的杂项算进去导致提前停止滚动。
              var ids = text.match(/"(?:aweme_id|item_id)"\\s*:\\s*"?([0-9]{8,})/g);
              if (ids) {
                window.__kumoneSeenCount = (window.__kumoneSeenCount || 0) + ids.length;
              }
            } catch (e) {}
          }

          function deliver(payload) {
            countSeen(payload.body);
            send(payload);
          }

          window.__kumoneStartCollecting = function () {
            window.__kumoneCollecting = true;
            window.__kumoneSeenCount = 0;
            // 同一页面上再次抓取时清掉「同一段响应只回传一次」的去重表，
            // 否则页面重发同样的请求不会再上报。
            for (var k in posted) { delete posted[k]; }
            var pending = buffer.slice();
            buffer.length = 0;
            bufferChars = 0;
            // 已经见过当前页的收藏数据、或 URL 已标明收藏 tab，就不要再点 tab：
            // 点「收藏」会把用户手选的收藏夹重置回默认。只有两样都不成立时才让
            // 驱动点 tab 重新触发请求（TikTok 首次打开 `/@me` 属于这种）。
            window.__kumoneClickedTab = window.__kumoneSawFavoritesData || TAB_ALREADY_OPEN;
            for (var i = 0; i < pending.length; i++) {
              deliver(pending[i]);
            }
            window.__kumoneFlushedCount = pending.length;
          };

          function post(url, text) {
            try {
              if (!interesting(text)) { return; }
              var address = String(url || '');
              for (var n = 0; n < NON_FAVORITE.length; n++) {
                if (address.indexOf(NON_FAVORITE[n]) >= 0) { return; }
              }
              // SPA 在同一个 document 里切换页面时 hook 会一直留着：
              // 只缓存/回传当前确实在收藏页时拿到的响应，避免把首页或
              // 别人的个人页数据带进收藏。
              if (!onFavoritesPage()) { return; }
              window.__kumoneSawFavoritesData = true;
              // 同一段响应只回传一次；太大的（>3MB）跳过，别把主线程堵死。
              var key = address + '#' + text.length;
              if (posted[key]) { return; }
              posted[key] = true;
              if (text.length > 3000000) { return; }
              var payload = { url: String(url), body: text };
              if (window.__kumoneCollecting) {
                deliver(payload);
              } else {
                bufferChars += text.length;
                while (buffer.length > 0
                       && (buffer.length >= MAX_BUFFERED || bufferChars > MAX_BUFFER_CHARS)) {
                  var dropped = buffer.shift();
                  bufferChars -= dropped.body.length;
                }
                buffer.push(payload);
              }
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
    ///
    /// `knownCount` 是本地已经有的收藏条数（0 表示没有本地基线）。
    /// 一旦页面上累计见过的条目达到这个数、且连续若干轮没有新增，就停止滚动：
    /// 收藏几百条时，无限滚动会把整个收藏夹从头拉一遍；只要新增的部分抓到了，
    /// 剩下的旧条目本地本来就有，没必要再滚。
    static func driverScript(for platform: ShortVideoPlatform, knownCount: Int = 0) -> String {
        let titles = platform.tabTitles.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        (function () {
          if (window.__kumoneDriver) { return; }
          var TITLES = [\(titles)];
          var KNOWN = \(knownCount);
          var idleRounds = 0;
          var lastHeight = 0;
          window.__kumoneDriver = setInterval(function () {
            try {
              // 数据可能在「开始抓取」之后才到：先等一拍，别抢在响应前面点 tab。
              if (!window.__kumoneClickedTab && window.__kumoneSawFavoritesData) {
                window.__kumoneClickedTab = true;
              }
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
                return;
              }
              var height = document.body.scrollHeight;
              if (height === lastHeight) {
                idleRounds = idleRounds + 1;
              } else {
                idleRounds = 0;
                lastHeight = height;
              }
              // 滚不动了：已经到底，或者能拉的都拉完了。
              if (idleRounds >= 4) {
                clearInterval(window.__kumoneDriver);
                window.__kumoneDriver = null;
                return;
              }
              // 已经攒够本地基线那么多条、又连续两轮没有新的：就停，不再无谓地翻旧数据。
              if (KNOWN > 0 && window.__kumoneSeenCount >= KNOWN && idleRounds >= 2) {
                clearInterval(window.__kumoneDriver);
                window.__kumoneDriver = null;
                return;
              }
              window.scrollTo(0, height);
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
        let bodyURL = payload["url"] as? String
        let error = payload["error"] as? String
        let popup = payload["popup"] as? String
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let body, self.phase == .collecting, self.isOnFavoritesPage {
                self.ingest(body, url: bodyURL)
            }
            if let error {
                self.lastScriptError = error
                self.note("页面：\(error)")
            }
            if let popup, let url = URL(string: popup) {
                self.note("页面要开新窗口：\(popup.prefix(70))")
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                self.presentPopup(request)
            }
        }
    }
}

extension ShortVideoCollector: WKUIDelegate {
    /// `window.open` 单独弹一层窗口。
    ///
    /// 抖音的二维码登录走 `window.open`。之前把它塞回本页加载，会把抖音自己的
    /// SPA 冲掉——表现就是「二维码刚出来又闪回首页」。现在开一个真正的弹窗：
    /// cookie 落在同一个域上，登录完关掉弹窗、本页刷新一下就是登录态。
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        let request = navigationAction.request
        Task { @MainActor [weak self] in
            self?.presentPopup(request)
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
            self.navigationGeneration += 1
            self.preparedGeneration = -1
            self.preparingCollection = false
            self.pageReady = false
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
            self.pageReady = true
            self.refreshLoginState()
            self.syncNavigationState()
            self.note("加载完成：\(self.webView.url?.absoluteString.prefix(70) ?? "")")
            if self.pendingCollect {
                self.pendingCollect = false
                self.beginCollecting()
                return
            }
            // 页面上没有登录入口时用户就点了登录：等渲染完再点，避免落到 SSO 整页。
            if self.pendingLogin {
                self.pendingLogin = false
                self.triggerLoginPrompt()
                return
            }
            // 抓取过程中发生了整页导航（用户自己点链接/刷新）：旧页面的驱动已失效，
            // 等新页加载完重新准备当前收藏页，绝不再走「reload 收藏页」那条路。
            if self.phase == .collecting,
               self.isOnFavoritesPage,
               self.preparedGeneration != self.navigationGeneration,
               !self.preparingCollection {
                self.prepareCollectionOnCurrentPage()
                return
            }
            if self.phase == .loading {
                self.status = self.loggedIn
                    ? "页面已加载：已登录，可点「开始抓取」"
                    : "页面已加载：登录后点「开始抓取」"
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

extension Notification.Name {
    /// popup 里登录成功后广播给主 collector；`object` 是平台 rawValue。
    static let shortVideoLoginStateDidChange = Notification.Name("shortVideoLoginStateDidChange")
}
#endif
