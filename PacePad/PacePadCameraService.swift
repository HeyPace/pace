@preconcurrency import AVFoundation
import Combine
import CoreImage
import Foundation
import UIKit
import Vision

@MainActor
final class PacePadCameraService: NSObject, ObservableObject {
    @Published private(set) var cameraPermissionIsGranted = false
    @Published private(set) var isRunning = false
    @Published private(set) var isUserPresent = false
    @Published private(set) var lastErrorText: String?

    var onStablePresenceChanged: ((Bool, Double, Date) -> Void)?

    private nonisolated let frameProcessor = PacePadCameraFrameProcessor()
    private let captureController: PacePadCameraCaptureController
    private var pendingPresenceValue: Bool?
    private var consecutivePresenceSampleCount = 0

    override init() {
        captureController = PacePadCameraCaptureController(frameProcessor: frameProcessor)
        super.init()
        frameProcessor.setResultConsumer { [weak self] result in
            Task { @MainActor [weak self] in
                self?.accept(result)
            }
        }
    }

    func requestPermissionAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPermissionIsGranted = true
        case .notDetermined:
            cameraPermissionIsGranted = await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            cameraPermissionIsGranted = false
        @unknown default:
            cameraPermissionIsGranted = false
        }
        guard cameraPermissionIsGranted else {
            lastErrorText = "Camera access is off. Enable it in iPad Settings to use presence awareness."
            return
        }
        do {
            isRunning = try await captureController.start()
            lastErrorText = isRunning ? nil : "The iPad camera could not start."
        } catch {
            isRunning = false
            lastErrorText = error.localizedDescription
        }
    }

    func pause() {
        if isRunning {
            Task {
                await captureController.stop()
            }
        }
        isRunning = false
        frameProcessor.cancelPendingJPEGRequest()
        pendingPresenceValue = nil
        consecutivePresenceSampleCount = 0
        if isUserPresent {
            isUserPresent = false
            onStablePresenceChanged?(false, 1, Date())
        }
    }

    func updateImageOrientation(_ interfaceOrientation: UIInterfaceOrientation) {
        let imageOrientation: CGImagePropertyOrientation =
            switch interfaceOrientation {
            case .portrait: .leftMirrored
            case .portraitUpsideDown: .rightMirrored
            case .landscapeLeft: .downMirrored
            case .landscapeRight: .upMirrored
            default: .leftMirrored
            }
        frameProcessor.setImageOrientation(imageOrientation)
    }

    func captureNextJPEGFrame() async -> (imageData: Data, capturedAt: Date)? {
        guard isRunning else { return nil }
        return await withCheckedContinuation { continuation in
            frameProcessor.requestNextJPEGFrame { imageData, capturedAt in
                continuation.resume(returning: imageData.map { ($0, capturedAt) })
            }
        }
    }

    private func accept(_ frameResult: PacePadCameraFrameProcessor.Result) {
        guard isRunning else { return }
        if pendingPresenceValue == frameResult.isUserPresent {
            consecutivePresenceSampleCount += 1
        } else {
            pendingPresenceValue = frameResult.isUserPresent
            consecutivePresenceSampleCount = 1
        }
        guard consecutivePresenceSampleCount >= 2,
            isUserPresent != frameResult.isUserPresent
        else {
            return
        }
        isUserPresent = frameResult.isUserPresent
        onStablePresenceChanged?(
            frameResult.isUserPresent,
            frameResult.confidence,
            frameResult.observedAt
        )
    }
}

private final class PacePadCameraCaptureController: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let frameProcessor: PacePadCameraFrameProcessor
    private let cameraQueue = DispatchQueue(label: "com.pace.pad.camera", qos: .utility)
    private var hasConfiguredSession = false

    init(frameProcessor: PacePadCameraFrameProcessor) {
        self.frameProcessor = frameProcessor
    }

    func start() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            cameraQueue.async { [self] in
                do {
                    try configureSessionIfNeeded()
                    if !captureSession.isRunning {
                        captureSession.startRunning()
                    }
                    continuation.resume(returning: captureSession.isRunning)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            cameraQueue.async { [self] in
                if captureSession.isRunning {
                    captureSession.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameProcessor.process(sampleBuffer: sampleBuffer)
    }

    private func configureSessionIfNeeded() throws {
        guard !hasConfiguredSession else { return }
        guard
            let frontCamera = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .front
            )
        else {
            throw PacePadCameraError.frontCameraUnavailable
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .vga640x480
        let cameraInput = try AVCaptureDeviceInput(device: frontCamera)
        guard captureSession.canAddInput(cameraInput) else {
            throw PacePadCameraError.cameraInputUnavailable
        }
        captureSession.addInput(cameraInput)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)
        guard captureSession.canAddOutput(videoOutput) else {
            throw PacePadCameraError.cameraOutputUnavailable
        }
        captureSession.addOutput(videoOutput)
        hasConfiguredSession = true
    }
}

private final class PacePadCameraFrameProcessor: @unchecked Sendable {
    struct Result: Sendable {
        let isUserPresent: Bool
        let confidence: Double
        let observedAt: Date
    }

    private var resultConsumer: (@Sendable (Result) -> Void)?
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let pendingJPEGRequestLock = NSLock()
    private let imageOrientationLock = NSLock()
    private var pendingJPEGConsumer: (@Sendable (Data?, Date) -> Void)?
    private var imageOrientation: CGImagePropertyOrientation = .leftMirrored
    private var lastProcessedAt = Date.distantPast

    func setResultConsumer(_ resultConsumer: @escaping @Sendable (Result) -> Void) {
        self.resultConsumer = resultConsumer
    }

    func requestNextJPEGFrame(
        _ consumer: @escaping @Sendable (Data?, Date) -> Void
    ) {
        pendingJPEGRequestLock.lock()
        let replacedConsumer = pendingJPEGConsumer
        pendingJPEGConsumer = consumer
        pendingJPEGRequestLock.unlock()
        replacedConsumer?(nil, Date())
    }

    func cancelPendingJPEGRequest() {
        pendingJPEGRequestLock.lock()
        let cancelledConsumer = pendingJPEGConsumer
        pendingJPEGConsumer = nil
        pendingJPEGRequestLock.unlock()
        cancelledConsumer?(nil, Date())
    }

    func setImageOrientation(_ imageOrientation: CGImagePropertyOrientation) {
        imageOrientationLock.lock()
        self.imageOrientation = imageOrientation
        imageOrientationLock.unlock()
    }

    func process(sampleBuffer: CMSampleBuffer) {
        let observedAt = Date()
        guard observedAt.timeIntervalSince(lastProcessedAt) >= 1,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }
        lastProcessedAt = observedAt

        let humanDetectionRequest = VNDetectHumanRectanglesRequest()
        let imageOrientation = currentImageOrientation()
        try? VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: imageOrientation
        ).perform([humanDetectionRequest])
        let highestConfidence =
            humanDetectionRequest.results?
            .map { Double($0.confidence) }
            .max() ?? 0
        resultConsumer?(
            Result(
                isUserPresent: highestConfidence >= 0.45,
                confidence: highestConfidence,
                observedAt: observedAt
            ))

        pendingJPEGRequestLock.lock()
        let jpegConsumer = pendingJPEGConsumer
        pendingJPEGConsumer = nil
        pendingJPEGRequestLock.unlock()
        if let jpegConsumer {
            jpegConsumer(
                makeJPEGData(pixelBuffer: pixelBuffer, imageOrientation: imageOrientation),
                observedAt
            )
        }
    }

    private func currentImageOrientation() -> CGImagePropertyOrientation {
        imageOrientationLock.lock()
        defer { imageOrientationLock.unlock() }
        return imageOrientation
    }

    private func makeJPEGData(
        pixelBuffer: CVPixelBuffer,
        imageOrientation: CGImagePropertyOrientation
    ) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(imageOrientation)
        guard let renderedImage = imageContext.createCGImage(image, from: image.extent) else {
            return nil
        }
        return UIImage(cgImage: renderedImage).jpegData(compressionQuality: 0.72)
    }
}

nonisolated enum PacePadCameraError: Error {
    case frontCameraUnavailable
    case cameraInputUnavailable
    case cameraOutputUnavailable
}

extension PacePadCameraError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .frontCameraUnavailable:
            "The iPad front camera is unavailable."
        case .cameraInputUnavailable, .cameraOutputUnavailable:
            "The iPad camera could not be configured."
        }
    }
}
