import SwiftUI
import WebKit

// Адрес страницы в интернете. Новые версии страницы подхватываются отсюда
// без пересборки приложения. Если интернета нет — открывается встроенная копия polarity.html.
let remotePageURL = URL(string: "https://marselle33-hub.github.io/autozvuk/")!

@main
struct AutoZvukApp: App {
    var body: some Scene {
        WindowGroup {
            WebContainer()
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

struct WebContainer: UIViewRepresentable {
    func makeCoordinator() -> AudioBridge { AudioBridge() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let content = WKUserContentController()
        content.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "audio")
        config.userContentController = content

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = .systemBackground
        webView.isOpaque = false
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        // Потянуть страницу вниз — загрузить свежую версию
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(AudioBridge.pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        context.coordinator.webView = webView
        context.coordinator.loadRemote()
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
