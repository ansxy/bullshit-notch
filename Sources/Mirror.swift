import AVFoundation
import SwiftUI

/// Live, mirrored front-camera preview. The camera runs only while this view is on screen.
struct MirrorView: NSViewRepresentable {
    func makeNSView(context: Context) -> CameraPreview { CameraPreview() }
    func updateNSView(_ view: CameraPreview, context: Context) {}
    static func dismantleNSView(_ view: CameraPreview, coordinator: ()) { view.stop() }
}

final class CameraPreview: NSView {
    private let session = AVCaptureSession()
    private let preview: AVCaptureVideoPreviewLayer

    init() {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        preview.videoGravity = .resizeAspectFill
        wantsLayer = true
        layer = preview

        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            DispatchQueue.global().async { self.configureAndStart() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureAndStart() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true  // like a mirror, not like a photo
        }
        session.startRunning()
    }

    func stop() {
        DispatchQueue.global().async { [session] in session.stopRunning() }
    }
}
