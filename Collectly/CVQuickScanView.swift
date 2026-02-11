//
//  CVQuickScanView.swift
//  Cardia
//
//  Flow de scan rapide style CollX:
//  1. Caméra ouvre direct → photo front
//  2. "Tourne la carte" → photo back
//  3. OCR auto → preview → save
//

import SwiftUI
import SwiftData
import AVFoundation
import UIKit

// MARK: - Quick Scan View

struct CVQuickScanView: View {
    
    let ownerId: String
    let onComplete: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    // MARK: - Scan State
    
    enum ScanPhase {
        case capturingFront
        case capturingBack
        case processing
        case preview
    }
    
    @State private var phase: ScanPhase = .capturingFront
    
    // Images
    @State private var frontImage: UIImage? = nil
    @State private var backImage: UIImage? = nil
    @State private var frontImageData: Data? = nil
    @State private var backImageData: Data? = nil
    
    // OCR Results
    @State private var playerName: String = ""
    @State private var cardYear: String = ""
    @State private var companyName: String = ""
    @State private var setName: String = ""
    @State private var cardNumber: String = ""
    
    // Processing
    @State private var isProcessing: Bool = false
    @State private var processingStatus: String = ""
    
    // Error
    @State private var errorMessage: String? = nil
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            switch phase {
            case .capturingFront:
                CameraCaptureView(
                    instruction: "Scanne le DEVANT",
                    subInstruction: "Centre la carte dans le cadre",
                    onCapture: { image in
                        handleFrontCapture(image)
                    },
                    onCancel: {
                        dismiss()
                    }
                )
                
            case .capturingBack:
                CameraCaptureView(
                    instruction: "Tourne la carte ↻",
                    subInstruction: "Scanne le DOS",
                    onCapture: { image in
                        handleBackCapture(image)
                    },
                    onCancel: {
                        // Retour au front
                        phase = .capturingFront
                        frontImage = nil
                        frontImageData = nil
                    },
                    showFlipAnimation: true
                )
                
            case .processing:
                ProcessingView(status: processingStatus)
                
            case .preview:
                PreviewView(
                    frontImage: frontImage,
                    backImage: backImage,
                    playerName: $playerName,
                    cardYear: $cardYear,
                    companyName: $companyName,
                    setName: $setName,
                    cardNumber: $cardNumber,
                    onSave: saveCard,
                    onRetake: retake,
                    onCancel: { dismiss() }
                )
            }
            
            // Error overlay
            if let error = errorMessage {
                VStack {
                    Spacer()
                    Text(error)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(10)
                        .padding()
                }
            }
        }
        .statusBarHidden(phase == .capturingFront || phase == .capturingBack)
    }
    
    // MARK: - Handlers
    
    private func handleFrontCapture(_ image: UIImage) {
        frontImage = image
        frontImageData = image.jpegData(compressionQuality: 0.85)
        
        // Passe au back
        withAnimation(.easeInOut(duration: 0.3)) {
            phase = .capturingBack
        }
    }
    
    private func handleBackCapture(_ image: UIImage) {
        backImage = image
        backImageData = image.jpegData(compressionQuality: 0.85)
        
        // Lance l'OCR
        phase = .processing
        Task {
            await runOCR()
        }
    }
    
    private func runOCR() async {
        await MainActor.run {
            isProcessing = true
            processingStatus = "Analyse en cours..."
        }
        
        // OCR sur les deux images en parallèle
        async let frontOCR = performOCR(on: frontImage, side: "front")
        async let backOCR = performOCR(on: backImage, side: "back")
        
        let (frontResult, backResult) = await (frontOCR, backOCR)
        
        await MainActor.run {
            // Merge results (back is usually more reliable)
            mergeOCRResults(front: frontResult, back: backResult)
            
            isProcessing = false
            phase = .preview
        }
    }
    
    private func performOCR(on image: UIImage?, side: String) async -> OCRResult {
        guard let image = image else { return OCRResult() }
        
        await MainActor.run {
            processingStatus = side == "front" ? "Analyse du devant..." : "Analyse du dos..."
        }
        
        // Utilise le même OCR que CVPhotoOCRAddCardView
        let lines = await OCREngine.runMultiPass(on: image, note: side)
        
        if side == "front" {
            return OCREngine.parseFront(lines: lines)
        } else {
            return OCREngine.parseBack(lines: lines)
        }
    }
    
    private func mergeOCRResults(front: OCRResult, back: OCRResult) {
        // Player name: prefer back (usually more complete)
        if let backName = back.playerName, !backName.isEmpty {
            playerName = backName
        } else if let frontName = front.playerName, !frontName.isEmpty {
            playerName = frontName
        }
        
        // Year: prefer back
        if let backYear = back.year, !backYear.isEmpty {
            cardYear = backYear
        } else if let frontYear = front.year, !frontYear.isEmpty {
            cardYear = frontYear
        }
        
        // Company: either
        if let comp = back.company ?? front.company, !comp.isEmpty {
            companyName = comp
        }
        
        // Set: prefer back
        if let backSet = back.setName, !backSet.isEmpty {
            setName = backSet
        } else if let frontSet = front.setName, !frontSet.isEmpty {
            setName = frontSet
        }
        
        // Card number: prefer back
        if let backNum = back.cardNumber, !backNum.isEmpty {
            cardNumber = backNum
        } else if let frontNum = front.cardNumber, !frontNum.isEmpty {
            cardNumber = frontNum
        }
    }
    
    private func saveCard() {
        let title = playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty 
            ? "Carte" 
            : playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let card = CardItem(
            ownerId: ownerId,
            title: title,
            notes: nil,
            frontImageData: frontImageData,
            backImageData: backImageData,
            estimatedPriceCAD: nil,
            playerName: playerName.isEmpty ? nil : playerName,
            cardYear: cardYear.isEmpty ? nil : cardYear,
            companyName: companyName.isEmpty ? nil : companyName,
            setName: setName.isEmpty ? nil : setName,
            cardNumber: cardNumber.isEmpty ? nil : cardNumber
        )
        
        modelContext.insert(card)
        
        do {
            try modelContext.save()
            onComplete()
            dismiss()
        } catch {
            errorMessage = "Erreur: \(error.localizedDescription)"
        }
    }
    
    private func retake() {
        // Reset tout
        frontImage = nil
        backImage = nil
        frontImageData = nil
        backImageData = nil
        playerName = ""
        cardYear = ""
        companyName = ""
        setName = ""
        cardNumber = ""
        
        phase = .capturingFront
    }
}

// MARK: - OCR Result

struct OCRResult {
    var playerName: String? = nil
    var year: String? = nil
    var company: String? = nil
    var setName: String? = nil
    var cardNumber: String? = nil
}

// MARK: - Camera Capture View

struct CameraCaptureView: View {
    let instruction: String
    let subInstruction: String
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void
    var showFlipAnimation: Bool = false
    
    @State private var showFlip = false
    
    var body: some View {
        ZStack {
            // Camera
            CameraPreviewRepresentable(onCapture: onCapture)
                .ignoresSafeArea()
            
            // Overlay
            VStack {
                // Top bar
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                    Spacer()
                }
                .padding()
                
                Spacer()
                
                // Card frame guide
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.6), lineWidth: 2)
                    .frame(width: 280, height: 400)
                    .overlay(
                        // Flip animation
                        Group {
                            if showFlipAnimation && showFlip {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 60))
                                    .foregroundColor(.white)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    )
                
                Spacer()
                
                // Instructions
                VStack(spacing: 8) {
                    Text(instruction)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text(subInstruction)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.bottom, 100)
            }
        }
        .onAppear {
            if showFlipAnimation {
                withAnimation(.easeInOut(duration: 0.5).delay(0.2)) {
                    showFlip = true
                }
                // Hide after 1.5s
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation {
                        showFlip = false
                    }
                }
            }
        }
    }
}

// MARK: - Camera Preview (UIKit)

struct CameraPreviewRepresentable: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    
    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onCapture = onCapture
        return vc
    }
    
    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

class CameraViewController: UIViewController {
    var onCapture: ((UIImage) -> Void)?
    
    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    private lazy var captureButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        
        // Outer ring
        let outerRing = UIView()
        outerRing.translatesAutoresizingMaskIntoConstraints = false
        outerRing.backgroundColor = .clear
        outerRing.layer.borderColor = UIColor.white.cgColor
        outerRing.layer.borderWidth = 4
        outerRing.layer.cornerRadius = 37
        outerRing.isUserInteractionEnabled = false
        
        // Inner circle
        let innerCircle = UIView()
        innerCircle.translatesAutoresizingMaskIntoConstraints = false
        innerCircle.backgroundColor = .white
        innerCircle.layer.cornerRadius = 30
        innerCircle.isUserInteractionEnabled = false
        
        btn.addSubview(outerRing)
        btn.addSubview(innerCircle)
        
        NSLayoutConstraint.activate([
            outerRing.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            outerRing.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            outerRing.widthAnchor.constraint(equalToConstant: 74),
            outerRing.heightAnchor.constraint(equalToConstant: 74),
            
            innerCircle.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            innerCircle.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            innerCircle.widthAnchor.constraint(equalToConstant: 60),
            innerCircle.heightAnchor.constraint(equalToConstant: 60),
        ])
        
        btn.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        return btn
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupUI()
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
    
    private func setupCamera() {
        captureSession = AVCaptureSession()
        captureSession?.sessionPreset = .photo
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            return
        }
        
        photoOutput = AVCapturePhotoOutput()
        
        guard let session = captureSession,
              let output = photoOutput,
              session.canAddInput(input),
              session.canAddOutput(output) else {
            return
        }
        
        session.addInput(input)
        session.addOutput(output)
        
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer?.videoGravity = .resizeAspectFill
        previewLayer?.frame = view.bounds
        
        if let layer = previewLayer {
            view.layer.insertSublayer(layer, at: 0)
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }
    
    private func setupUI() {
        view.addSubview(captureButton)
        
        NSLayoutConstraint.activate([
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            captureButton.widthAnchor.constraint(equalToConstant: 74),
            captureButton.heightAnchor.constraint(equalToConstant: 74),
        ])
    }
    
    @objc private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        photoOutput?.capturePhoto(with: settings, delegate: self)
        
        // Feedback visuel
        UIView.animate(withDuration: 0.1) {
            self.captureButton.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        } completion: { _ in
            UIView.animate(withDuration: 0.1) {
                self.captureButton.transform = .identity
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }
}

extension CameraViewController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            return
        }
        
        // Fix orientation
        let fixedImage = image.fixedOrientation()
        
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(fixedImage)
        }
    }
}

// MARK: - Processing View

struct ProcessingView: View {
    let status: String
    
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            
            Text(status)
                .font(.headline)
                .foregroundColor(.white)
        }
    }
}

// MARK: - Preview View

struct PreviewView: View {
    let frontImage: UIImage?
    let backImage: UIImage?
    
    @Binding var playerName: String
    @Binding var cardYear: String
    @Binding var companyName: String
    @Binding var setName: String
    @Binding var cardNumber: String
    
    let onSave: () -> Void
    let onRetake: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Images preview
                    HStack(spacing: 12) {
                        if let front = frontImage {
                            Image(uiImage: front)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 180)
                                .cornerRadius(8)
                                .overlay(
                                    Text("DEVANT")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .padding(4)
                                        .background(Color.black.opacity(0.6))
                                        .cornerRadius(4)
                                        .padding(4),
                                    alignment: .topLeading
                                )
                        }
                        
                        if let back = backImage {
                            Image(uiImage: back)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 180)
                                .cornerRadius(8)
                                .overlay(
                                    Text("DOS")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .padding(4)
                                        .background(Color.black.opacity(0.6))
                                        .cornerRadius(4)
                                        .padding(4),
                                    alignment: .topLeading
                                )
                        }
                    }
                    .padding(.horizontal)
                    
                    // Fields
                    VStack(spacing: 12) {
                        FieldRow(label: "Joueur", text: $playerName)
                        FieldRow(label: "Année", text: $cardYear)
                        FieldRow(label: "Compagnie", text: $companyName)
                        FieldRow(label: "Set", text: $setName)
                        FieldRow(label: "Numéro", text: $cardNumber)
                    }
                    .padding(.horizontal)
                    
                    // Actions
                    VStack(spacing: 12) {
                        Button(action: onSave) {
                            Label("Enregistrer", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                        
                        Button(action: onRetake) {
                            Label("Reprendre les photos", systemImage: "camera")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.secondary.opacity(0.2))
                                .foregroundColor(.primary)
                                .cornerRadius(12)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Vérifier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler", action: onCancel)
                }
            }
        }
    }
}

struct FieldRow: View {
    let label: String
    @Binding var text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - UIImage Extension

extension UIImage {
    func fixedOrientation() -> UIImage {
        if imageOrientation == .up { return self }
        
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return result ?? self
    }
}

// MARK: - OCR Engine (Wrapper)

enum OCREngine {
    
    /// Multi-pass OCR (réutilise la logique de CVPhotoOCRAddCardView)
    static func runMultiPass(on image: UIImage, note: String) async -> [String] {
        // Utilise Vision pour l'OCR
        guard let cgImage = image.cgImage else { return [] }
        
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, err in
                if let err = err {
                    print("OCR error: \(err.localizedDescription)")
                    continuation.resume(returning: [])
                    return
                }
                
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                
                continuation.resume(returning: lines)
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US", "fr-FR"]
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }
    
    /// Parse front OCR lines
    static func parseFront(lines: [String]) -> OCRResult {
        var result = OCRResult()
        
        let upper = lines.map { $0.uppercased() }
        let joined = upper.joined(separator: " ")
        
        // Year
        if let year = findSeasonYear(in: lines) {
            result.year = year
        }
        
        // Company
        if joined.contains("UPPER") && joined.contains("DECK") {
            result.company = "Upper Deck"
        } else if joined.contains("TOPPS") {
            result.company = "Topps"
        } else if joined.contains("PANINI") {
            result.company = "Panini"
        }
        
        // Player name (2-word pattern)
        result.playerName = findPlayerName(in: lines)
        
        // Card number
        result.cardNumber = findCardNumber(in: lines)
        
        // Set
        if joined.contains("YOUNG") && joined.contains("GUN") {
            result.setName = "Young Guns"
        } else if joined.contains("SP AUTHENTIC") {
            result.setName = "SP Authentic"
        }
        
        return result
    }
    
    /// Parse back OCR lines
    static func parseBack(lines: [String]) -> OCRResult {
        var result = OCRResult()
        
        let upper = lines.map { $0.uppercased() }
        let joined = upper.joined(separator: " ")
        
        // Year
        if let year = findSeasonYear(in: lines) {
            result.year = year
        }
        
        // Company
        if joined.contains("UPPER") && joined.contains("DECK") {
            result.company = "Upper Deck"
        } else if joined.contains("TOPPS") {
            result.company = "Topps"
        } else if joined.contains("PANINI") {
            result.company = "Panini"
        }
        
        // Player name
        result.playerName = findPlayerName(in: lines)
        
        // Card number (back is usually more reliable)
        result.cardNumber = findCardNumber(in: lines)
        
        // Set
        if joined.contains("YOUNG") && joined.contains("GUN") {
            result.setName = "Young Guns"
        } else if joined.contains("SP AUTHENTIC") {
            result.setName = "SP Authentic"
        } else if joined.contains("FUTURE WATCH") {
            result.setName = "Future Watch"
        }
        
        // Series
        if joined.contains("SERIES 1") || joined.contains("SERIES1") {
            if let set = result.setName, !set.contains("Series") {
                result.setName = "Series 1 \(set)"
            } else if result.setName == nil {
                result.setName = "Series 1"
            }
        } else if joined.contains("SERIES 2") || joined.contains("SERIES2") {
            if let set = result.setName, !set.contains("Series") {
                result.setName = "Series 2 \(set)"
            } else if result.setName == nil {
                result.setName = "Series 2"
            }
        }
        
        return result
    }
    
    // MARK: - Helpers
    
    private static func findSeasonYear(in lines: [String]) -> String? {
        let pattern = #"\b(20\d{2})[-–/](\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let r = Range(match.range, in: line) {
                return String(line[r]).replacingOccurrences(of: "–", with: "-")
            }
        }
        return nil
    }
    
    private static func findPlayerName(in lines: [String]) -> String? {
        // Look for 2-3 word names (First Last or First Middle Last)
        let denyWords: Set<String> = [
            "UPPER", "DECK", "SERIES", "YOUNG", "GUNS", "HOCKEY", "NHL", "NHLPA",
            "ROOKIE", "RC", "AUTO", "PATCH", "AUTHENTIC", "FUTURE", "WATCH",
            "HEIGHT", "WEIGHT", "SHOOTS", "BORN"
        ]
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()
            
            // Skip lines with numbers or deny words
            if trimmed.rangeOfCharacter(from: .decimalDigits) != nil { continue }
            if denyWords.contains(where: { upper.contains($0) }) { continue }
            
            // Must be 2-3 words
            let words = trimmed.split(separator: " ").map(String.init)
            if words.count < 2 || words.count > 3 { continue }
            
            // Each word must be 2+ chars and start with capital
            let valid = words.allSatisfy { word in
                word.count >= 2 && word.first?.isUppercase == true
            }
            
            if valid {
                return words.joined(separator: " ")
            }
        }
        return nil
    }
    
    private static func findCardNumber(in lines: [String]) -> String? {
        // Look for #123 or prefix-123 patterns
        for line in lines {
            let upper = line.uppercased()
            
            // #123 pattern
            if let match = upper.range(of: #"#\s*\d{1,4}"#, options: .regularExpression) {
                let num = String(upper[match]).replacingOccurrences(of: " ", with: "")
                return num
            }
            
            // Prefix-number pattern (CQ-8, FWA-3, TS-30)
            if let match = upper.range(of: #"\b[A-Z]{1,4}-\d{1,4}\b"#, options: .regularExpression) {
                return String(upper[match])
            }
        }
        
        // Standalone number in first few lines
        for line in lines.prefix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let num = Int(trimmed), num >= 1 && num <= 999 {
                return "#\(num)"
            }
        }
        
        return nil
    }
}

// MARK: - Vision Import

import Vision

// MARK: - Preview

#Preview {
    CVQuickScanView(ownerId: "preview-user") {
        print("Completed!")
    }
}
