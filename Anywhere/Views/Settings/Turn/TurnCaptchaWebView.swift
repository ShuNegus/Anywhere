//
//  TurnCaptchaWebView.swift
//  Anywhere
//

import SwiftUI
import WebKit

/// Sheet hosting the VK captcha page served by the tunnel process over loopback.
/// Dismissed automatically once the local server disappears — see `TurnCaptchaMonitor`.
struct TurnCaptchaSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CaptchaWebView(url: TurnCaptcha.url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Solve Captcha")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }
}

private struct CaptchaWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing about a captcha is worth persisting.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
