import Foundation
import AVFoundation
import Vision
import UIKit
import AudioToolbox

enum RaceMode: String, CaseIterable, Identifiable {
    case classic = "Course classique"
    case fixedLaps = "Tours fixes"
    case timedCooper = "Temps fixe (Cooper)"
    var id: String { rawValue }
}

struct RunnerResult: Identifiable, Codable {
    let id: UUID
    let bibNumber: String
    var name: String
    var laps: Int
    var splitTimes: [TimeInterval]
    var finishTime: TimeInterval?
    var lastCrossingTimestamp: TimeInterval
}

final class BibVisionEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var isRunning = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var detectedBibs: [(bib: String, box: CGRect)] = []
    @Published var results: [RunnerResult] = []
    @Published var finishLineX: CGFloat = 0.5
    @Published var shutterSpeedDenominator: Int32 = 1000
    @Published var use2xLens: Bool = true
    @Published var raceMode: RaceMode = .classic
    @Published var targetLaps: Int = 4
    @Published var cooldownSeconds: TimeInterval = 10.0
    @Published var lastToast: String?
    @Published var roster: [String: String] = ["1": "Coureur 1", "2": "Coureur 2", "3": "Coureur 3", "4": "Coureur 4"]

    let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "com.chronodossard.vision", qos: .userInteractive)
    private var startTime: TimeInterval = 0
    private var timer: Timer?
    private var previousCenterXByBib: [String: CGFloat] = [:]
    private var frameCounter = 0

    override init() {
        super.init()
        configureCamera()
    }

    func configureCamera() {
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        let deviceType: AVCaptureDevice.DeviceType = use2xLens ? .builtInTelephotoCamera : .builtInWideAngleCamera
        let camera = AVCaptureDevice.default(deviceType, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

        guard let device = camera,
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }

        session.inputs.forEach { session.removeInput($0) }
        if session.canAddInput(input) { session.addInput(input) }

        do {
            try device.lockForConfiguration()
            let duration = CMTimeMake(value: 1, timescale: shutterSpeedDenominator)
            if device.isExposureModeSupported(.custom) {
                let minISO = device.activeFormat.minISO
                let maxISO = device.activeFormat.maxISO
                let targetISO = min(max(minISO * 4, minISO), maxISO)
                device.setExposureModeCustom(duration: duration, iso: targetISO, completionHandler: nil)
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch {
            print("Configuration obturation: \(error)")
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        session.outputs.forEach { session.removeOutput($0) }
        if session.canAddOutput(output) { session.addOutput(output) }

        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        session.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    func startRace() {
        startTime = CACurrentMediaTime()
        isRunning = true
        previousCenterXByBib.removeAll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            self.elapsedTime = CACurrentMediaTime() - self.startTime
        }
    }

    func stopRace() {
        isRunning = false
        timer?.invalidate()
    }

    func resetRace() {
        stopRace()
        elapsedTime = 0
        results.removeAll()
        previousCenterXByBib.removeAll()
        lastToast = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCounter += 1
        guard frameCounter % 2 == 0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let textRequest = VNRecognizeTextRequest { [weak self] request, _ in
            guard let self = self,
                  let observations = request.results as? [VNRecognizedTextObservation] else { return }

            var currentDetections: [(bib: String, box: CGRect)] = []
            let now = CACurrentMediaTime()

            for obs in observations {
                guard let candidate = obs.topCandidates(1).first,
                      candidate.confidence > 0.65 else { continue }

                let digits = candidate.string.filter { $0.isNumber }
                guard !digits.isEmpty, digits.count <= 4 else { continue }

                let box = CGRect(
                    x: obs.boundingBox.minX,
                    y: 1.0 - obs.boundingBox.maxY,
                    width: obs.boundingBox.width,
                    height: obs.boundingBox.height
                )
                currentDetections.append((bib: digits, box: box))

                if self.isRunning {
                    self.evaluateLineCrossing(bib: digits, centerX: box.midX, timestamp: now)
                }
            }

            DispatchQueue.main.async {
                self.detectedBibs = currentDetections
            }
        }

        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false
        if !roster.isEmpty {
            textRequest.customWords = Array(roster.keys)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([textRequest])
    }

    private func evaluateLineCrossing(bib: String, centerX: CGFloat, timestamp: TimeInterval) {
        defer { previousCenterXByBib[bib] = centerX }
        guard let prevX = previousCenterXByBib[bib] else { return }

        let crossed = (prevX < finishLineX && centerX >= finishLineX) ||
                      (prevX > finishLineX && centerX <= finishLineX)
        guard crossed else { return }

        let raceElapsed = timestamp - startTime

        DispatchQueue.main.async {
            if let idx = self.results.firstIndex(where: { $0.bibNumber == bib }) {
                guard timestamp - self.results[idx].lastCrossingTimestamp >= self.cooldownSeconds else { return }
                if self.raceMode == .classic { return }

                self.results[idx].laps += 1
                self.results[idx].splitTimes.append(raceElapsed)
                self.results[idx].lastCrossingTimestamp = timestamp

                if self.raceMode == .fixedLaps && self.results[idx].laps >= self.targetLaps {
                    self.results[idx].finishTime = raceElapsed
                }
                self.triggerCrossingFeedback(bib: bib, lap: self.results[idx].laps, time: raceElapsed)
            } else {
                let runnerName = self.roster[bib] ?? "Dossard #\(bib)"
                let finish: TimeInterval? = (self.raceMode == .classic || (self.raceMode == .fixedLaps && self.targetLaps == 1)) ? raceElapsed : nil
                let entry = RunnerResult(
                    id: UUID(),
                    bibNumber: bib,
                    name: runnerName,
                    laps: 1,
                    splitTimes: [raceElapsed],
                    finishTime: finish,
                    lastCrossingTimestamp: timestamp
                )
                self.results.append(entry)
                self.triggerCrossingFeedback(bib: bib, lap: 1, time: raceElapsed)
            }
        }
    }

    private func triggerCrossingFeedback(bib: String, lap: Int, time: TimeInterval) {
        AudioServicesPlaySystemSound(1057)
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
        lastToast = "Dossard #\(bib) — Tour \(lap) (\(formatTime(time)))"
    }

    func formatTime(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        let hundredths = Int((interval - floor(interval)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, hundredths)
    }

    func generateBibsPDF(raceTitle: String) -> URL? {
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let sortedBibs = roster.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Dossards_ChronoDossard.pdf")

        do {
            try renderer.writePDF(to: url) { context in
                for i in stride(from: 0, to: sortedBibs.count, by: 2) {
                    context.beginPage()
                    drawSingleBib(bib: sortedBibs[i], name: roster[sortedBibs[i]] ?? "", title: raceTitle, rect: CGRect(x: 24, y: 24, width: pageWidth - 48, height: (pageHeight / 2) - 36))

                    let dashPath = UIBezierPath()
                    dashPath.move(to: CGPoint(x: 18, y: pageHeight / 2))
                    dashPath.addLine(to: CGPoint(x: pageWidth - 18, y: pageHeight / 2))
                    UIColor.gray.setStroke()
                    dashPath.setLineDash([6, 6], count: 2, phase: 0)
                    dashPath.stroke()

                    if i + 1 < sortedBibs.count {
                        drawSingleBib(bib: sortedBibs[i + 1], name: roster[sortedBibs[i + 1]] ?? "", title: raceTitle, rect: CGRect(x: 24, y: (pageHeight / 2) + 12, width: pageWidth - 48, height: (pageHeight / 2) - 36))
                    }
                }
            }
            return url
        } catch {
            return nil
        }
    }

    private func drawSingleBib(bib: String, name: String, title: String, rect: CGRect) {
        UIColor.white.setFill()
        UIRectFill(rect)
        UIColor.black.setStroke()
        let border = UIBezierPath(rect: rect)
        border.lineWidth = 5
        border.stroke()

        let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 16, weight: .bold), .foregroundColor: UIColor.darkGray]
        (title as NSString).draw(at: CGPoint(x: rect.minX + 16, y: rect.minY + 12), withAttributes: titleAttrs)

        let numberAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 195, weight: .black), .foregroundColor: UIColor.black]
        let numSize = (bib as NSString).size(withAttributes: numberAttrs)
        (bib as NSString).draw(at: CGPoint(x: rect.midX - numSize.width / 2, y: rect.midY - numSize.height / 2 - 10), withAttributes: numberAttrs)

        let nameAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: UIColor.black]
        let nameSize = (name as NSString).size(withAttributes: nameAttrs)
        (name as NSString).draw(at: CGPoint(x: rect.midX - nameSize.width / 2, y: rect.maxY - 42), withAttributes: nameAttrs)
    }
}
