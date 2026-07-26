import SwiftUI
@preconcurrency import VisionKit

struct WorkerQRScannerView: View {
    let onPayload: (String) -> Void
    @State private var scannerError: String?

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        Group {
            if Self.isAvailable {
                WorkerDataScannerRepresentable(
                    onPayload: onPayload,
                    onError: { scannerError = $0.localizedDescription }
                )
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text("Scan the QR code shown by your self-hosted Worker.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: .rect(cornerRadius: 14))
                        .padding()
                }
            } else {
                ContentUnavailableView(
                    "Scanner unavailable",
                    systemImage: "qrcode.viewfinder",
                    description: Text("Paste the Worker link instead.")
                )
            }
        }
        .navigationTitle("Scan Worker QR")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t use the camera", isPresented: Binding(
            get: { scannerError != nil },
            set: { if !$0 { scannerError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scannerError ?? "The camera is unavailable.")
        }
    }
}

private struct WorkerDataScannerRepresentable: UIViewControllerRepresentable {
    let onPayload: (String) -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        Task { @MainActor in
            do {
                try scanner.startScanning()
            } catch {
                onError(error)
            }
        }
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController,
                                          coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onPayload: (String) -> Void
        private var delivered = false

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let payload = barcode.payloadStringValue else { continue }
                delivered = true
                dataScanner.stopScanning()
                onPayload(payload)
                return
            }
        }
    }
}
