import Foundation
import Network

// ─────────────────────────────────────────────
//  MARK: - ScreenCaptureReceiver
//  Recibe la captura de pantalla de SteamVR desde
//  el PC vía TCP en el puerto 47295.
//
//  Protocolo real del driver (VrH264Streamer::SendNal):
//    [4 bytes] longitud del payload, Big Endian (UInt32)
//    [N bytes] datos H.264 crudos (Annex-B, con start codes),
//              UN paquete puede contener más de un NAL unit
//              pegado (p.ej. SPS+PPS+IDR en cada keyframe).
//
//  FIX: la versión anterior asumía que cada payload era un JPEG
//  completo (`UIImage(data:)`), por eso nunca se veía nada — el
//  driver de PC nunca mandó JPEG, siempre mandó H.264 real via
//  Media Foundation. Ahora este receptor solo se encarga de separar
//  el stream en payloads length-prefixed (que ya hacía bien) y
//  entrega los bytes crudos tal cual a quien lo use (H264Decoder se
//  encarga de parsear los NAL units y decodificar/mostrar).
//  Se repite continuamente mientras dure la conexión.
// ─────────────────────────────────────────────

final class ScreenCaptureReceiver {

    private let PORT: UInt16 = 47295
    private var connection: NWConnection?

    /// Entrega el payload crudo (Annex-B, puede contener 1+ NAL units).
    typealias FrameCallback = (Data) -> Void
    private var onFrame: FrameCallback?

    private(set) var isConnected = false

    // ── Conexión ──────────────────────────────────────────────

    func connect(to ip: String, onFrame: @escaping FrameCallback) {
        self.onFrame = onFrame
        disconnect()

        guard let port = NWEndpoint.Port(rawValue: PORT) else {
            print("[ScreenCaptureReceiver] Puerto inválido")
            return
        }
        let host = NWEndpoint.Host(ip)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let conn = NWConnection(host: host, port: port, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .setup:
                print("[ScreenCaptureReceiver] setup")
            case .preparing:
                print("[ScreenCaptureReceiver] preparing…")
            case .ready:
                print("[ScreenCaptureReceiver] Conectado ✓ a \(ip):\(self?.PORT ?? 0)")
                self?.isConnected = true
                self?.receiveLength()
            case .failed(let error):
                print("[ScreenCaptureReceiver] Falló la conexión: \(error.localizedDescription)")
                self?.isConnected = false
            case .waiting(let error):
                print("[ScreenCaptureReceiver] Esperando (posible bloqueo de firewall/puerto cerrado): \(error.localizedDescription)")
            case .cancelled:
                print("[ScreenCaptureReceiver] Conexión cancelada")
                self?.isConnected = false
            @unknown default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    // ── Lectura del protocolo length-prefixed ────────────────

    private func receiveLength() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isDone, error in
            guard let self else { return }

            if let error {
                print("[ScreenCaptureReceiver] Error leyendo longitud: \(error.localizedDescription)")
                self.isConnected = false
                return
            }

            if let data, data.count == 4 {
                let length = data.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
                self.receiveFrame(length: Int(length))
            } else if isDone {
                print("[ScreenCaptureReceiver] Conexión cerrada por el PC")
                self.isConnected = false
            } else {
                self.receiveLength()
            }
        }
    }

    private func receiveFrame(length: Int) {
        // Límite de seguridad: descarta longitudes absurdas (desincronización)
        guard length > 0, length < 20_000_000 else {
            print("[ScreenCaptureReceiver] Longitud de frame sospechosa (\(length)), descartando y resincronizando")
            receiveLength()
            return
        }

        var received = Data()

        func readMore() {
            let remaining = length - received.count
            connection?.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isDone, error in
                guard let self else { return }

                if let error {
                    print("[ScreenCaptureReceiver] Error leyendo frame: \(error.localizedDescription)")
                    self.isConnected = false
                    return
                }

                if let data { received.append(data) }

                if received.count >= length {
                    // Bytes H.264 crudos (Annex-B); el parseo de NAL
                    // units y la decodificación las hace H264Decoder.
                    self.onFrame?(received)
                    self.receiveLength()
                } else if isDone {
                    print("[ScreenCaptureReceiver] Conexión cerrada a mitad de frame")
                    self.isConnected = false
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }
}
