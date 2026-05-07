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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(htmlPage, baseURL: URL(string: "https://wallet.dranzo.com/"))
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
                name: "Webuddy",
                description: "Wallet recharge",
                order_id: "\(order.orderId)",
                prefill: { name: "\(escapedName)", contact: "\(escapedContact)" },
                theme: { color: "#0DBD8B" },
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

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onCompleted: (RazorpayResult) -> Void
        private var done = false

        init(onCompleted: @escaping (RazorpayResult) -> Void) {
            self.onCompleted = onCompleted
        }

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
