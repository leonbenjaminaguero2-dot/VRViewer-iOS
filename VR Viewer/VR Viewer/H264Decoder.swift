import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

// ─────────────────────────────────────────────
//  MARK: - H264Decoder
//  El driver de PC (VrH264Streamer) NO manda JPEG: manda un
//  stream H.264 real (Media Foundation), como NAL units en
//  formato Annex-B (con start codes 00 00 00 01), enviados por
//  SendNal() con un prefijo de 4 bytes de longitud (eso ya lo
//  separa ScreenCaptureReceiver). Un solo "paquete" de red puede
//  traer más de un NAL pegado (típicamente SPS+PPS+IDR juntos en
//  el primer frame / cada keyframe).
//
//  Esta clase:
//   1. Separa el buffer recibido en NAL units individuales.
//   2. Guarda SPS (tipo 7) y PPS (tipo 8) y arma un
//      CMVideoFormatDescription en cuanto tiene ambos.
//   3. Para NALs de slice (tipo 1 = no-IDR, tipo 5 = IDR),
//      los convierte a formato AVCC (largo de 4 bytes en vez de
//      start code) y los manda a un AVSampleBufferDisplayLayer,
//      que decodifica por HARDWARE (VideoToolbox por debajo) y
//      dibuja directamente — no hace falta un VTDecompressionSession
//      manual ni convertir a UIImage por frame.
//
//  Si SteamVR cambia de resolución (o el usuario cambia la
//  calidad desde el panel de CALIDAD del PC), llegan un SPS/PPS
//  nuevos: se detecta que cambiaron los bytes y se reconstruye el
//  formatDescription + se hace flush() de la capa para evitar
//  fotogramas corruptos mezclando el formato viejo con el nuevo.
// ─────────────────────────────────────────────

final class H264Decoder {

    /// Capa de video real. Insertarla en un UIView (ver VideoLayerView.swift)
    /// y ponerle bounds/videoGravity ahí.
    let displayLayer = AVSampleBufferDisplayLayer()

    private var spsData: Data?
    private var ppsData: Data?
    private var formatDescription: CMVideoFormatDescription?

    // Estadísticas simples para diagnóstico en la UI (opcional).
    private(set) var framesDecoded: Int = 0

    init() {
        displayLayer.videoGravity = .resizeAspect
    }

    func reset() {
        spsData = nil
        ppsData = nil
        formatDescription = nil
        framesDecoded = 0
        displayLayer.flush()
    }

    /// Llamar con cada chunk recibido de ScreenCaptureReceiver (un
    /// "paquete" length-prefixed del protocolo, que puede contener 1
    /// o más NAL units en Annex-B pegados).
    func decode(_ data: Data) {
        for nal in Self.splitAnnexB(data) {
            handle(nal: nal)
        }
    }

    // ── NAL individual ───────────────────────────────────────

    private func handle(nal: Data) {
        guard let first = nal.first else { return }
        let nalType = first & 0x1F

        switch nalType {
        case 7: // SPS
            if spsData != nal {
                spsData = nal
                tryBuildFormatDescription()
            }
        case 8: // PPS
            if ppsData != nal {
                ppsData = nal
                tryBuildFormatDescription()
            }
        case 1, 5: // slice no-IDR / IDR
            enqueue(nal: nal, isKeyframe: nalType == 5)
        default:
            // SEI (6), delimitadores, etc. — no hace falta para mostrar imagen.
            break
        }
    }

    private func tryBuildFormatDescription() {
        guard let sps = spsData, let pps = ppsData else { return }

        let result = sps.withUnsafeBytes { spsPtr -> CMVideoFormatDescription? in
            pps.withUnsafeBytes { ppsPtr -> CMVideoFormatDescription? in
                guard let spsBase = spsPtr.baseAddress, let ppsBase = ppsPtr.baseAddress else { return nil }
                var parameterSetPointers: [UnsafePointer<UInt8>] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self)
                ]
                var parameterSetSizes: [Int] = [sps.count, pps.count]
                var formatDesc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
                if status != noErr {
                    print("[H264Decoder] CMVideoFormatDescriptionCreateFromH264ParameterSets falló: \(status)")
                    return nil
                }
                return formatDesc
            }
        }

        if let result {
            // Nuevo formato (resolución/perfil cambió): limpiar la cola
            // de la capa para no mezclar frames del formato anterior.
            formatDescription = result
            displayLayer.flush()
        }
    }

    private func enqueue(nal: Data, isKeyframe: Bool) {
        guard let formatDescription else {
            // Todavía no llegaron SPS+PPS (normal en el primer instante
            // de la conexión, antes del primer keyframe).
            return
        }
        guard displayLayer.isReadyForMoreMediaData else {
            // La capa va más lenta que la red: preferimos DESCARTAR este
            // frame antes que acumular latencia (crítico en VR).
            return
        }

        // Annex-B (start code) → AVCC (longitud de 4 bytes big-endian),
        // que es lo que espera CMSampleBuffer con nalUnitHeaderLength=4.
        var length = UInt32(nal.count).bigEndian
        var avccData = Data(bytes: &length, count: 4)
        avccData.append(nal)

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil, // nil = CMBlockBuffer aloca su propia memoria
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard createStatus == noErr, let blockBuffer else {
            print("[H264Decoder] CMBlockBufferCreateWithMemoryBlock falló (status=\(createStatus))")
            return
        }

        let copyStatus = avccData.withUnsafeBytes { rawPtr -> OSStatus in
            guard let baseAddress = rawPtr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }

        guard copyStatus == noErr else {
            print("[H264Decoder] CMBlockBufferReplaceDataBytes falló (status=\(copyStatus))")
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccData.count

        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sbStatus == noErr, let sampleBuffer else {
            print("[H264Decoder] CMSampleBufferCreate falló (status=\(sbStatus))")
            return
        }

        // Forzar que se muestre de inmediato (no esperar timestamps de
        // reproducción, esto es un stream en vivo, no un archivo).
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        displayLayer.enqueue(sampleBuffer)
        framesDecoded += 1
    }

    // ── Utilidad: separar un buffer Annex-B en NAL units ─────

    /// Devuelve los NAL units SIN start code (solo los bytes del NAL en sí).
    private static func splitAnnexB(_ data: Data) -> [Data] {
        var result: [Data] = []
        let bytes = [UInt8](data)
        let n = bytes.count
        guard n > 4 else { return result }

        // Encuentra los offsets de cada start code (00 00 01 o 00 00 00 01)
        var starts: [(offset: Int, codeLen: Int)] = []
        var i = 0
        while i + 2 < n {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i + 3, 3))
                    i += 3
                    continue
                } else if i + 3 < n, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i + 4, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        guard !starts.isEmpty else { return result }

        for (idx, start) in starts.enumerated() {
            let nalStart = start.offset
            let nalEnd: Int
            if idx + 1 < starts.count {
                // El siguiente start code empieza codeLen bytes antes de su offset guardado
                nalEnd = starts[idx + 1].offset - starts[idx + 1].codeLen
            } else {
                nalEnd = n
            }
            guard nalStart < nalEnd else { continue }
            result.append(data.subdata(in: nalStart..<nalEnd))
        }

        return result
    }
}
