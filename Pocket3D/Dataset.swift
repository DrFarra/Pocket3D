import ARKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Exporta capturas para procesarlas en el PC (RealityScan, Postshot, nerfstudio con GPU NVIDIA).
enum Dataset {
    private static let context = CIContext()

    /// Guarda foto + profundidad LiDAR de un fotograma y devuelve su entrada de transforms.json (formato nerfstudio).
    /// La profundidad solo se guarda si viene en el mismo fotograma: la de otro instante no cuadraría con la foto.
    static func write(_ frame: ARFrame, index: Int, to folder: URL) throws -> [String: Any] {
        let name = String(format: "%05d", index)
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
        else { throw CocoaError(.fileWriteUnknown) }
        try jpeg.write(to: folder.appending(path: "images/\(name).jpg"))

        // Las poses de ARKit ya usan el convenio de nerfstudio (OpenGL: x derecha, y arriba, z hacia atrás)
        // siempre que la imagen se guarde en la orientación nativa del sensor, como aquí.
        let k = frame.camera.intrinsics
        var entry: [String: Any] = [
            "file_path": "images/\(name).jpg",
            "transform_matrix": rows(frame.camera.transform),
            "fl_x": k[0][0], "fl_y": k[1][1], "cx": k[2][0], "cy": k[2][1],
            "w": Int(frame.camera.imageResolution.width), "h": Int(frame.camera.imageResolution.height),
        ]
        if let depth = frame.sceneDepth, let png = depthPNG(depth) {
            try png.write(to: folder.appending(path: "depth/\(name).png"))
            entry["depth_file_path"] = "depth/\(name).png"
        }
        return entry
    }

    /// simd es column-major; transforms.json espera filas.
    static func rows(_ m: simd_float4x4) -> [[Float]] {
        (0..<4).map { r in [m.columns.0[r], m.columns.1[r], m.columns.2[r], m.columns.3[r]] }
    }

    /// PNG de 16 bits en milímetros (lo que nerfstudio espera); 0 = sin dato.
    static func millimeters(_ meters: Float, confident: Bool) -> UInt16 {
        confident && meters.isFinite && meters > 0 ? UInt16(min(meters * 1000, 65535)) : 0
    }

    /// Profundidad LiDAR en mm, a 0 donde ARKit no está seguro (confianza baja).
    static func depthMillimeters(_ data: ARDepthData) -> (mm: [UInt16], width: Int, height: Int)? {
        let depth = data.depthMap
        let confidence = data.confidenceMap
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }

        let width = CVPixelBufferGetWidth(depth), height = CVPixelBufferGetHeight(depth)
        guard let depthBase = CVPixelBufferGetBaseAddress(depth) else { return nil }
        let confBase = confidence.flatMap(CVPixelBufferGetBaseAddress)
        var mm = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            let d = (depthBase + y * CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float32.self)
            let c = confBase.map { ($0 + y * CVPixelBufferGetBytesPerRow(confidence!)).assumingMemoryBound(to: UInt8.self) }
            for x in 0..<width {
                let confident = c.map { $0[x] >= UInt8(ARConfidenceLevel.medium.rawValue) } ?? true
                mm[y * width + x] = millimeters(d[x], confident: confident)
            }
        }
        return (mm, width, height)
    }

    /// Foto reducida + profundidad de un fotograma normal de ARKit, para colorear la malla al guardar.
    static func colorView(from frame: ARFrame, width: Int = 256) -> ColorView? {
        guard let depth = frame.sceneDepth.flatMap(depthMillimeters) else { return nil }
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        let scale = CGFloat(width) / image.extent.width
        let height = Int((image.extent.height * scale).rounded())
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), toBitmap: &rgba, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let k = frame.camera.intrinsics
        let s = Float(scale)
        return ColorView(worldToCamera: frame.camera.transform.inverse,
                         fx: k[0][0] * s, fy: k[1][1] * s, cx: k[2][0] * s, cy: k[2][1] * s,
                         width: width, height: height, rgba: rgba,
                         depthMM: depth.mm, depthWidth: depth.width, depthHeight: depth.height)
    }

    private static func depthPNG(_ data: ARDepthData) -> Data? {
        guard let depth = depthMillimeters(data) else { return nil }
        let (width, height) = (depth.width, depth.height)
        let bytes = depth.mm.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: width * 2,
                                    space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// Fotos HEIC de Object Capture → JPEG (con su EXIF) en un .zip para RealityScan/Postshot.
    static func exportPhotos(from folder: URL, to zipURL: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where url.pathExtension.lowercased() == "heic" {
            let out = tmp.appending(path: url.deletingPathExtension().lastPathComponent + ".jpg")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        try zip(tmp, to: zipURL)
    }

    /// iOS no tiene API de zip, pero NSFileCoordinator comprime carpetas al leerlas "para subir".
    static func zip(_ folder: URL, to zipURL: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { tmpZip in
            do { try FileManager.default.copyItem(at: tmpZip, to: zipURL) } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError { throw error }
    }

    #if DEBUG
    static func selfCheck() {
        assert(millimeters(1.2345, confident: true) == 1234)
        assert(millimeters(1.2, confident: false) == 0)
        assert(millimeters(.nan, confident: true) == 0)
        assert(millimeters(100, confident: true) == 65535)
        var m = matrix_identity_float4x4
        m.columns.3 = [1, 2, 3, 1]
        assert(rows(m)[0] == [1, 0, 0, 1] && rows(m)[2][3] == 3)
    }
    #endif
}
