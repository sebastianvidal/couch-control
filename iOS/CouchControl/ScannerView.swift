import SwiftUI
import VisionKit

/// Camera sheet that looks for the pairing QR code and hands its URL back.
struct ScannerView: View {
    let onScan: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Scanner(onScan: onScan)
                        .ignoresSafeArea()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Scanning isn't available on this device.\nType the 6-digit code instead, or open the QR with the Camera app.")
                            .multilineTextAlignment(.center)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}

private struct Scanner: UIViewControllerRepresentable {
    let onScan: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (URL) -> Void
        private var done = false

        init(onScan: @escaping (URL) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in added {
                guard case let .barcode(barcode) = item,
                      let text = barcode.payloadStringValue,
                      let url = URL(string: text), url.scheme == "couchctl" else { continue }
                done = true
                scanner.stopScanning()
                onScan(url)
                return
            }
        }
    }
}
