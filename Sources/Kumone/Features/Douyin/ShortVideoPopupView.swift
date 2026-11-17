#if os(iOS)
import UIKit
import WebKit

private let shortVideoPopupHandlerName = "shortvideoPopup"

/// 找当前最上层的视图控制器（弹窗要从这里 present）。
@MainActor
enum ShortVideoTopView {
    static func controller() -> UIViewController? {
        var root: UIViewController?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                root = window.rootViewController
                break
            }
        }
        if root == nil {
            root = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController
        }
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

/// 弹窗里 `window.close()` 的回调桥。
///
/// 抖音扫码成功后会自己关窗。没有这个桥，用户只能手动点「关闭」，
/// 而且不知道到底登上了没有。
@MainActor
final class ShortVideoPopupBridge: NSObject, WKScriptMessageHandler {
    var onClose: (() -> Void)?

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard message.name == shortVideoPopupHandlerName else { return }
        Task { @MainActor [weak self] in
            self?.onClose?()
        }
    }
}

/// `window.open` 弹出来的窗口。
///
/// 抖音的二维码登录走 `window.open`。以前把它塞回本页加载，会把抖音自己的
/// SPA 冲掉——表现就是「二维码刚出来又闪回首页」。现在开一个真正的弹窗：
/// cookie 落在同一个域上，登录完关掉弹窗、本页刷新一下就是登录态。
@MainActor
final class ShortVideoPopupViewController: UIViewController, WKNavigationDelegate {
    private let request: URLRequest
    private let userAgent: String
    private let onClose: () -> Void
    private let bridge = ShortVideoPopupBridge()
    private var didNotify = false

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.add(bridge, name: shortVideoPopupHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.closeBridgeScript,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = userAgent
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }()

    private static let closeBridgeScript = """
    (function () {
      if (window.__kumoneCloseBridge) { return; }
      window.__kumoneCloseBridge = true;
      var realClose = window.close;
      window.close = function () {
        try { window.webkit.messageHandlers.shortvideoPopup.postMessage({ close: true }); } catch (e) {}
        try { return realClose.apply(window, arguments); } catch (e) {}
      };
    })();
    """

    init(request: URLRequest, userAgent: String, onClose: @escaping () -> Void) {
        self.request = request
        self.userAgent = userAgent
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = request.url?.host ?? "登录"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "关闭",
            style: .done,
            target: self,
            action: #selector(closeSelf)
        )
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"),
                            style: .plain,
                            target: self,
                            action: #selector(reloadSelf)),
            UIBarButtonItem(image: UIImage(systemName: "chevron.backward"),
                            style: .plain,
                            target: self,
                            action: #selector(backSelf)),
        ]

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        bridge.onClose = { [weak self] in
            self?.closeSelf()
        }
        webView.load(request)
    }

    @objc private func closeSelf() {
        dismiss(animated: true)
    }

    @objc private func reloadSelf() {
        if webView.url == nil {
            webView.load(request)
        } else {
            webView.reload()
        }
    }

    @objc private func backSelf() {
        if webView.canGoBack {
            webView.goBack()
        } else {
            reloadSelf()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !didNotify else { return }
        didNotify = true
        onClose()
    }

    // MARK: - WKNavigationDelegate

    /// 自定义 scheme（`snssdk1128://`、`alipays://`、`weixin://`）交给系统，
    /// 别让弹窗卡在一个永远加载不完的空白页上。
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = (navigationAction.request.url?.scheme ?? "").lowercased()
        let inApp = scheme.isEmpty
            || scheme == "http"
            || scheme == "https"
            || scheme == "about"
            || scheme == "file"
            || scheme == "data"
            || scheme == "blob"
        if inApp {
            decisionHandler(.allow)
            return
        }
        if let url = navigationAction.request.url {
            Task { @MainActor in
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
        }
        decisionHandler(.cancel)
    }
}
#endif