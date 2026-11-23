//
// Copyright 2025 Element Creations Ltd.
// Copyright 2024-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import SwiftUI
import UIKit

struct QRCodeScannerView: UIViewControllerRepresentable {
    @Binding var result: Data?
    var isScanning: Bool
    /// Use the decoded text of the code when there is one, instead of the raw binary segments.
    /// Text payloads (e.g. user links) don't need the binary decoding used by QR login.
    var prefersTextPayload = false
    
    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.delegate = context.coordinator
        return controller
    }
 
    func updateUIViewController(_ uiViewController: QRScannerController, context: Context) {
        context.coordinator.prefersTextPayload = prefersTextPayload
        
        if isScanning {
            uiViewController.startScan()
        } else {
            uiViewController.stopScan()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator($result, prefersTextPayload: prefersTextPayload)
    }
    
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        @Binding var scanResult: Data?
        var prefersTextPayload: Bool
     
        init(_ scanResult: Binding<Data?>, prefersTextPayload: Bool) {
            _scanResult = scanResult
            self.prefersTextPayload = prefersTextPayload
        }
     
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            // Check if the metadataObjects array is not nil and it contains at least one object.
            guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject else {
                MXLog.error("Invalid QR scan")
                return
            }
            
            if prefersTextPayload, let stringValue = metadataObject.stringValue {
                scanResult = Data(stringValue.utf8)
                MXLog.info("Scanned text data")
                return
            }
            
            do {
                if let data = try metadataObject.qrBinaryValue {
                    scanResult = data
                    MXLog.info("Scanned data")
                    return
                }
            } catch {
                MXLog.error("Invalid binary QR code: \(error)")
            }

            // Clariva: `qrBinaryValue` only understands byte and alphanumeric segments. Fall back to
            // the decoded text for other codes (numeric / ECI segments) so that third-party user
            // links can still be scanned. QR login only uses binary payloads, which take the path above.
            if let stringValue = metadataObject.stringValue {
                scanResult = Data(stringValue.utf8)
                MXLog.info("Scanned text data")
            } else {
                MXLog.error("Invalid QR code: no payload")
            }
        }
    }
}

final class QRScannerController: UIViewController {
    private var captureSession = AVCaptureSession()
    private var videoPreviewLayer: AVCaptureVideoPreviewLayer?
 
    weak var delegate: AVCaptureMetadataOutputObjectsDelegate?
    
    override func viewDidLoad() {
        super.viewDidLoad()
 
        // Get the back-facing camera for capturing videos
        guard let captureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            MXLog.error("Failed to get the camera device")
            return
        }
 
        let videoInput: AVCaptureDeviceInput
 
        do {
            // Get an instance of the AVCaptureDeviceInput class using the previous device object.
            videoInput = try AVCaptureDeviceInput(device: captureDevice)
 
        } catch {
            // If any error occurs, simply print it out and don't continue any more.
            MXLog.error("ACaptureDeviceInput error: \(error)")
            return
        }
 
        // Set the input device on the capture session.
        captureSession.addInput(videoInput)
 
        // Initialize a AVCaptureMetadataOutput object and set it as the output device to the capture session.
        let captureMetadataOutput = AVCaptureMetadataOutput()
        captureSession.addOutput(captureMetadataOutput)
 
        // Set delegate and use the default dispatch queue to execute the call back
        captureMetadataOutput.setMetadataObjectsDelegate(delegate, queue: DispatchQueue.main)
        captureMetadataOutput.metadataObjectTypes = [.qr]
 
        // Initialize the video preview layer and add it as a sublayer to the viewPreview view's layer.
        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        videoPreviewLayer = previewLayer
        videoPreviewLayer?.videoGravity = AVLayerVideoGravity.resizeAspectFill
        videoPreviewLayer?.frame = view.layer.bounds
        view.layer.addSublayer(previewLayer)
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        videoPreviewLayer?.frame = view.layer.bounds
    }
    
    func startScan() {
        // Start video capture.
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
            MXLog.info("QRCodeScannerView: capture session started")
        }
    }
    
    func stopScan() {
        // Stop video capture.
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.stopRunning()
            MXLog.info("QRCodeScannerView: capture session stopped")
        }
    }
}
