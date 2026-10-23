import SwiftUI
import AVFoundation

// ─────────────────────────────────────────────
//  MARK: - VideoLayerView
//  Envuelve el AVSampleBufferDisplayLayer de H264Decoder en una
//  UIView normal para poder usarlo dentro de SwiftUI. La capa se
//  redimensiona sola con el frame de la UIView (ver layoutSubviews).
// ─────────────────────────────────────────────

struct VideoLayerView: UIViewRepresentable {
    let decoder: H264Decoder
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> VideoContainerUIView {
        let view = VideoContainerUIView()
        view.backgroundColor = .black
        view.displayLayer = decoder.displayLayer
        decoder.displayLayer.videoGravity = videoGravity
        view.layer.addSublayer(decoder.displayLayer)
        return view
    }

    func updateUIView(_ uiView: VideoContainerUIView, context: Context) {
        decoder.displayLayer.videoGravity = videoGravity
        // Un AVSampleBufferDisplayLayer solo puede tener un superlayer a
        // la vez. Si otra instancia de VideoLayerView (p.ej. la miniatura
        // vs. la vista de pantalla completa) se la "robó" en algún punto,
        // la reclamamos acá para que esta vista nunca se quede en negro
        // por una condición de carrera de renderizado de SwiftUI.
        if decoder.displayLayer.superlayer !== uiView.layer {
            decoder.displayLayer.removeFromSuperlayer()
            uiView.layer.addSublayer(decoder.displayLayer)
            decoder.displayLayer.frame = uiView.bounds
        }
    }
}

final class VideoContainerUIView: UIView {
    var displayLayer: AVSampleBufferDisplayLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}
