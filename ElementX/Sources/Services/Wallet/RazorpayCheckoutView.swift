//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI
@preconcurrency import WebKit

/// Razorpay's standard checkout rendered inside a WKWebView. Avoids pulling the native iOS SDK
/// (which would require CocoaPods/SPM dependency setup) while still using the same `key_id` and
/// `order_id` issued by the Wallet API. The web page postMessages success/failure back to native.
struct RazorpayCheckoutView: View {
    let order: CreateOrderResponse
    let userName: String?
    let userContact: String?
    let onCompleted: (RazorpayResult) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RazorpayWebView(order: order,
                            userName: userName,
                            userContact: userContact) { result in
                onCompleted(result)
                dismiss()
            }
            .ignoresSafeArea()
            .navigationTitle("Recharge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        onCompleted(.cancelled)
                        dismiss()
                    }
                }
            }
        }
    }
}

enum RazorpayResult {
    case success(paymentId: String, orderId: String, signature: String)
    case failure(code: Int, message: String)
    case cancelled
}

private struct RazorpayWebView: UIViewRepresentable {
    let order: CreateOrderResponse
    let userName: String?
    let userContact: String?
    let onCompleted: (RazorpayResult) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompleted: onCompleted)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "razorpayBridge")
        config.userContentController = userContent

        // Razorpay opens bank / 3-D Secure pages through `window.open`.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.loadHTMLString(htmlPage, baseURL: ClarivaConfig.apiBaseURL)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) { }

    private var htmlPage: String {
        // The Razorpay checkout.js hosted page handles the entire UI; we only configure key, order
        // id and amount, then forward the result through window.webkit.messageHandlers.razorpayBridge.
        let escapedName = (userName ?? "").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedContact = (userContact ?? "").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f7f7f7;">
        <script src="https://checkout.razorpay.com/v1/checkout.js"></script>
        <script>
        function postBridge(payload) {
            try {
                window.webkit.messageHandlers.razorpayBridge.postMessage(payload);
            } catch (e) {}
        }
        function startCheckout() {
            var options = {
                key: "\(order.keyId)",
                amount: \(order.amountInPaise),
                currency: "\(order.currency)",
                name: "Clariva",
                description: "Wallet Recharge",
                order_id: "\(order.orderId)",
                prefill: { name: "\(escapedName)", contact: "\(escapedContact)" },
                theme: { color: "#3399cc" },
                handler: function (response) {
                    postBridge({
                        type: "success",
                        razorpay_payment_id: response.razorpay_payment_id,
                        razorpay_order_id: response.razorpay_order_id,
                        razorpay_signature: response.razorpay_signature
                    });
                },
                modal: {
                    ondismiss: function () { postBridge({ type: "cancelled" }); }
                }
            };
            var rzp = new Razorpay(options);
            rzp.on("payment.failed", function (resp) {
                postBridge({
                    type: "failure",
                    code: (resp && resp.error && resp.error.code) || "PAYMENT_FAILED",
                    description: (resp && resp.error && resp.error.description) || "Unknown error"
                });
            });
            rzp.open();
        }
        window.addEventListener("load", startCheckout);
        </script>
        <p style="text-align:center;padding:24px;color:#555;">Loading payment…</p>
        </body></html>
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        private let onCompleted: (RazorpayResult) -> Void
        private var done = false
        /// Popups (`window.open`) opened by the checkout, e.g. bank authentication pages.
        private var popupWebViews: [WKWebView] = []

        init(onCompleted: @escaping (RazorpayResult) -> Void) {
            self.onCompleted = onCompleted
        }

        // MARK: WKNavigationDelegate

        /// UPI intent flows navigate to app schemes (`upi://`, `phonepe://`, `tez://`,
        /// `paytmmp://`, …) and some banks use `itms-apps://` / `tel:` links. A WKWebView can't
        /// load those, so hand them to the system instead.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased(),
                  !Self.webSchemes.contains(scheme) else {
                return .allow
            }

            openExternally(url)
            return .cancel
        }

        private func openExternally(_ url: URL) {
            UIApplication.shared.open(url, options: [:]) { opened in
                if !opened {
                    MXLog.warning("[Razorpay] No app can handle the \(url.scheme ?? "unknown") payment link")
                }
            }
        }

        private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "javascript"]

        // MARK: WKUIDelegate

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Non-web schemes from `window.open` go to the system, like regular navigations.
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               !Self.webSchemes.contains(scheme) {
                openExternally(url)
                return nil
            }

            // Show the popup on top of the checkout so that `window.opener` keeps working and the
            // page can close it again with `window.close()`.
            let popup = WKWebView(frame: webView.bounds, configuration: configuration)
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            popup.navigationDelegate = self
            popup.uiDelegate = self
            webView.addSubview(popup)
            popupWebViews.append(popup)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard let index = popupWebViews.firstIndex(of: webView) else { return }
            popupWebViews.remove(at: index)
            webView.removeFromSuperview()
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !done, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "success":
                guard let paymentId = body["razorpay_payment_id"] as? String,
                      let orderId = body["razorpay_order_id"] as? String,
                      let signature = body["razorpay_signature"] as? String else { return }
                done = true
                onCompleted(.success(paymentId: paymentId, orderId: orderId, signature: signature))
            case "failure":
                let codeStr = (body["code"] as? String) ?? "0"
                let code = Int(codeStr) ?? 0
                let message = (body["description"] as? String) ?? ""
                done = true
                onCompleted(.failure(code: code, message: message))
            case "cancelled":
                done = true
                onCompleted(.cancelled)
            default:
                break
            }
        }
    }
}
