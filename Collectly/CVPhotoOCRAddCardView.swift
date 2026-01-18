//
//  CVPhotoOCRAddCardView.swift
//  Collectly
//
//  Photo -> OCR Vision (Front) -> Step 2 (Back) -> Merge -> Save
//

import SwiftUI
import SwiftData
import UIKit
@preconcurrency import Vision
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Photo → OCR (Vision) → Ajout (Front + Back)

struct CVPhotoOCRAddCardView: View {

    let ownerId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // Prevent unwanted auto-dismiss
    @State private var allowDismiss: Bool = false

    // Picker
    private enum PickerRoute: Identifiable {
        case cameraFront
        case libraryFront
        case cameraBack
        case libraryBack

        var id: Int {
            switch self {
            case .cameraFront: return 1
            case .libraryFront: return 2
            case .cameraBack: return 3
            case .libraryBack: return 4
            }
        }

        var sourceType: UIImagePickerController.SourceType {
            switch self {
            case .cameraFront, .cameraBack: return .camera
            case .libraryFront, .libraryBack: return .photoLibrary
            }
        }

        var isFront: Bool {
            switch self {
            case .cameraFront, .libraryFront: return true
            case .cameraBack, .libraryBack: return false
            }
        }
    }

    @State private var activePicker: PickerRoute? = nil

    // Images
    @State private var frontUIImage: UIImage? = nil
    @State private var backUIImage: UIImage? = nil
    @State private var frontImageData: Data? = nil
    @State private var backImageData: Data? = nil

    // OCR
    @State private var isWorking = false
    @State private var frontLines: [String] = []
    @State private var backLines: [String] = []

    // Fields
    @State private var playerName: String = ""
    @State private var cardYear: String = ""
    @State private var companyName: String = ""
    @State private var setName: String = ""
    @State private var cardNumber: String = ""

    // Debug
    @State private var showDebug = true

    private var canSave: Bool {
        !playerName.trimmedLocal.isEmpty || frontImageData != nil || backImageData != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                // FRONT
                Section("Photo (avant)") {
                    HStack(spacing: 12) {
                        thumb(frontUIImage)

                        VStack(alignment: .leading, spacing: 10) {
                            Button { openFrontCamera() } label: {
                                Label("Prendre une photo", systemImage: "camera")
                            }
                            .disabled(activePicker != nil || isWorking)

                            Button { openFrontLibrary() } label: {
                                Label("Choisir dans Photos", systemImage: "photo.on.rectangle")
                            }
                            .disabled(activePicker != nil || isWorking)

                            if frontUIImage != nil {
                                Button(role: .destructive) { clearFront() } label: {
                                    Label("Retirer la photo", systemImage: "trash")
                                }
                                .disabled(isWorking)
                            }

                            Text("Astuce : évite les reflets. Remplis l’écran avec la carte.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                // STEP 2
                Section("Étape 2 (recommandé)") {
                    HStack {
                        Image(systemName: backUIImage == nil ? "rectangle.dashed" : "checkmark.seal.fill")
                            // Keep both sides of the ternary as Color (ShapeStyle) to satisfy the compiler.
                            .foregroundStyle(backUIImage == nil ? Color.secondary : Color.green)
                        Text(backUIImage == nil ? "Scanner le dos" : "Dos scanné")
                        Spacer()
                    }

                    HStack(spacing: 12) {
                        thumb(backUIImage)

                        VStack(alignment: .leading, spacing: 10) {
                            Button { openBackCamera() } label: {
                                Label("Prendre une photo (dos)", systemImage: "camera")
                            }
                            .disabled(activePicker != nil || isWorking)

                            Button { openBackLibrary() } label: {
                                Label("Choisir dans Photos (dos)", systemImage: "photo.on.rectangle")
                            }
                            .disabled(activePicker != nil || isWorking)

                            if backUIImage != nil {
                                Button(role: .destructive) { clearBack() } label: {
                                    Label("Retirer la photo (dos)", systemImage: "trash")
                                }
                                .disabled(isWorking)
                            }

                            Text("Le dos est souvent plus fiable pour le nom, l’année, le # et le set.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                // DETECTED
                Section("Infos détectées") {
                    TextField("Nom du joueur", text: $playerName)
                    TextField("Année (ex: 2023-24)", text: $cardYear)
                    TextField("Compagnie (Upper Deck, Topps…)", text: $companyName)
                    TextField("Set (Series 1, SP Authentic…)", text: $setName)
                    TextField("Numéro (ex: #201)", text: $cardNumber)
                }

                // ACTIONS
                Section {
                    Button {
                        save()
                    } label: {
                        Label("Enregistrer", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(!canSave || isWorking)

                    Button("Fermer", role: .cancel) {
                        allowDismiss = true
                        dismiss()
                    }
                    .disabled(isWorking)
                }

                // DEBUG
                if showDebug {
                    Section("Lignes OCR (avant)") {
                        if frontLines.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        } else {
                            ForEach(frontLines, id: \.self) { Text("• \($0)") }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Lignes OCR (dos)") {
                        if backLines.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        } else {
                            ForEach(backLines, id: \.self) { Text("• \($0)") }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Toggle("Debug OCR", isOn: $showDebug)
                }
            }
            .navigationTitle("Ajouter (Photo)")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(!allowDismiss)
            .sheet(item: $activePicker) { route in
                CVUIKitImagePicker(sourceType: route.sourceType) { img in
                    activePicker = nil
                    guard let img else { return }
                    if route.isFront {
                        handleFront(img)
                    } else {
                        handleBack(img)
                    }
                }
            }
        }
    }

    // MARK: - UI helpers

    @ViewBuilder
    private func thumb(_ image: UIImage?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 110, height: 150)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 110, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Aucune")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Picker open

    private func openFrontCamera() {
        guard activePicker == nil else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            activePicker = .cameraFront
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.activePicker = granted ? .cameraFront : nil
                }
            }
        default:
            break
        }
    }

    private func openFrontLibrary() {
        guard activePicker == nil else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else { return }
        activePicker = .libraryFront
    }

    private func openBackCamera() {
        guard activePicker == nil else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            activePicker = .cameraBack
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.activePicker = granted ? .cameraBack : nil
                }
            }
        default:
            break
        }
    }

    private func openBackLibrary() {
        guard activePicker == nil else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else { return }
        activePicker = .libraryBack
    }

    // MARK: - Clear

    private func clearFront() {
        frontUIImage = nil
        frontImageData = nil
        frontLines = []
        // Keep detected fields (user may want to keep manual edits)
    }

    private func clearBack() {
        backUIImage = nil
        backImageData = nil
        backLines = []
    }

    // MARK: - Handle picked

    private func handleFront(_ img: UIImage) {
        isWorking = true

        let normalized = img.fixedOrientation()
        frontUIImage = normalized
        frontImageData = normalized.jpegData(compressionQuality: 0.92)

        Task { @MainActor in
            defer { isWorking = false }

            let lines = await OCR.runMultiPass(on: normalized, note: "front")
            frontLines = lines

            // Basic extraction from front (loose)
            let front = FrontOCRParser.parse(lines: lines)

            if playerName.trimmedLocal.isEmpty, let ln = front.playerLastName {
                playerName = FrontOCRParser.titleCasedName(ln)
            }

            if companyName.trimmedLocal.isEmpty, let c = front.company { companyName = c }
            if setName.trimmedLocal.isEmpty, let s = front.setName { setName = s }

            // If front has an explicit card number like #202, keep it
            if cardNumber.trimmedLocal.isEmpty, let n = front.cardNumber { cardNumber = n }
        }
    }

    private func handleBack(_ img: UIImage) {
        isWorking = true

        let normalized = img.fixedOrientation()
        backUIImage = normalized
        backImageData = normalized.jpegData(compressionQuality: 0.92)

        Task { @MainActor in
            defer { isWorking = false }

            let lines = await OCR.runMultiPass(on: normalized, note: "back")
            backLines = lines

            // Parse back (strong)
            let parsed = BackOCRParser.parse(lines: lines, companyHint: companyName)

            // Back is king if it has a full name
            if let full = parsed.fullName, full.contains(" ") {
                playerName = full
            } else if playerName.trimmedLocal.isEmpty, let ln = parsed.lastName {
                playerName = ln
            }

            // Back metadata overrides
            if let y = parsed.year { cardYear = y }
            if let c = parsed.company, !c.isEmpty { companyName = c }
            if let s = parsed.setName, !s.isEmpty { setName = s }
            if let n = parsed.cardNumber, !n.isEmpty { cardNumber = n }
        }
    }

    // MARK: - Save

    private func save() {
        isWorking = true
        defer { isWorking = false }

        let title = playerName.trimmedLocal.isEmpty ? "Carte" : playerName.trimmedLocal

        let item = CardItem(
            ownerId: ownerId,
            title: title,
            notes: nil,
            frontImageData: frontImageData,
            backImageData: backImageData,
            estimatedPriceCAD: nil,
            playerName: playerName.trimmedLocal.isEmpty ? nil : playerName.trimmedLocal,
            cardYear: cardYear.trimmedLocal.isEmpty ? nil : cardYear.trimmedLocal,
            companyName: companyName.trimmedLocal.isEmpty ? nil : companyName.trimmedLocal,
            setName: setName.trimmedLocal.isEmpty ? nil : setName.trimmedLocal,
            cardNumber: cardNumber.trimmedLocal.isEmpty ? nil : cardNumber.trimmedLocal
        )

        modelContext.insert(item)

        allowDismiss = true
        dismiss()
    }
}

// MARK: - UIKit Picker

private struct CVUIKitImagePicker: UIViewControllerRepresentable {

    let sourceType: UIImagePickerController.SourceType
    let onPicked: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onPicked: (UIImage?) -> Void
        init(onPicked: @escaping (UIImage?) -> Void) { self.onPicked = onPicked }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPicked(nil)
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = (info[.originalImage] as? UIImage)
            onPicked(img)
        }
    }
}

// MARK: - OCR

private enum OCR {

    static func runCollect(on image: UIImage, note: String) async -> [String] {
        guard let cgImage = image.fixedOrientation().cgImage else { return [] }
        let boosted = boostContrast(cgImage: cgImage) ?? cgImage

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, err in
                if let err {
                    print("⚠️ VNRecognizeTextRequest error (\(note)):", err.localizedDescription)
                    continuation.resume(returning: [])
                    return
                }

                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }

                let cleaned = lines
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                continuation.resume(returning: cleaned)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.003
            request.recognitionLanguages = ["en-US", "fr-FR"]

            if #available(iOS 16.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
            }

            let handler = VNImageRequestHandler(cgImage: boosted, options: [:])
            do { try handler.perform([request]) }
            catch { continuation.resume(returning: []) }
        }
    }

    static func runMultiPass(on image: UIImage, note: String) async -> [String] {
        let top = crop(image: image, y0: 0.00, y1: 0.35)
        let bottom = crop(image: image, y0: 0.65, y1: 1.00)

        async let tLines = runCollect(on: top ?? image, note: "\(note)_top")
        async let fLines = runCollect(on: image, note: "\(note)_full")
        async let bLines = runCollect(on: bottom ?? image, note: "\(note)_bottom")

        let (tl, fl, bl) = await (tLines, fLines, bLines)

        var seen = Set<String>()
        var merged: [String] = []
        for arr in [tl, fl, bl] {
            for s in arr {
                let key = s.trimmedLocal
                guard !key.isEmpty else { continue }
                if !seen.contains(key) {
                    seen.insert(key)
                    merged.append(key)
                }
            }
        }
        return merged
    }

    private static func crop(image: UIImage, y0: CGFloat, y1: CGFloat) -> UIImage? {
        guard y1 > y0 else { return nil }
        let img = image.fixedOrientation()
        guard let cg = img.cgImage else { return nil }

        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let rect = CGRect(x: 0, y: h * y0, width: w, height: h * (y1 - y0)).integral
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: img.scale, orientation: img.imageOrientation)
    }

    private static func boostContrast(cgImage: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)

        let filter = CIFilter.colorControls()
        filter.inputImage = ci
        filter.brightness = 0.02
        filter.contrast = 1.30
        filter.saturation = 0.0

        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = filter.outputImage
        sharpen.sharpness = 0.42

        let ctx = CIContext()
        guard let out = sharpen.outputImage else { return nil }
        return ctx.createCGImage(out, from: out.extent)
    }
}

// MARK: - Front parsing (lightweight)

private enum FrontOCRParser {

    struct FrontResult {
        var playerLastName: String?
        var company: String?
        var setName: String?
        var cardNumber: String?
    }

    static func parse(lines: [String]) -> FrontResult {
        var out = FrontResult()

        let cleaned = lines.map { $0.trimmedLocal }.filter { !$0.isEmpty }
        let upper = cleaned.map { $0.uppercased() }

        // Company
        if upper.contains(where: { $0.contains("UPPER") }) && upper.contains(where: { $0.contains("DECK") }) {
            out.company = "Upper Deck"
        }

        // Set (very loose)
        if upper.contains(where: { $0.contains("YOUNG") }) {
            out.setName = "Young Guns"
        }

        // Number (if the front has it)
        out.cardNumber = firstNumberLike(in: cleaned)

        // Player candidates: last large alpha token
        out.playerLastName = bestLastName(from: cleaned)

        return out
    }

    private static func firstNumberLike(in lines: [String]) -> String? {
        for l in lines {
            let up = l.uppercased()
            if let m = firstRegexMatch("#\\s*\\d{1,4}", in: up) {
                let digits = m.filter { $0.isNumber }
                if !digits.isEmpty { return "#\(digits)" }
            }
        }
        return nil
    }

    private static func bestLastName(from lines: [String]) -> String? {
        let stop = Set(["UPPER", "DECK", "YOUNG", "GUNS", "...ERIES", "SERIES", "ROOKIE", "RC", "NHL",
                        "CARD", "TRADER", "SPORTS", "GAMES", "REMI", "RÉMI", "RÉMÍ",
                        "RANGERS", "NEW", "YORK", "CCM"])
        var best: String? = nil
        var bestScore = -1

        for l in lines {
            let lineUp = l.uppercased()
            // Ignore store / sticker / branding lines (common false positives)
            if lineUp.contains("CARD") && lineUp.contains("TRADER") { continue }
            if lineUp.contains("SPORTS") && lineUp.contains("GAMES") { continue }
            if lineUp.contains("REMICARDTRADER") || lineUp.contains("RÉMICARDTRADER") { continue }

            let parts = l
                .replacingOccurrences(of: "•", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { String($0).trimmedLocal }

            for p in parts {
                let u = p.uppercased()
                guard u.count >= 6 else { continue }
                guard u.allSatisfy({ $0.isLetter }) else { continue }
                guard !stop.contains(u) else { continue }

                let score = u.count
                if score > bestScore {
                    bestScore = score
                    best = u
                }
            }
        }

        return best.map { titleCasedName($0) }
    }

    static func titleCasedName(_ s: String) -> String {
        s.lowercased()
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func firstRegexMatch(_ pattern: String, in text: String) -> String? {
        do {
            let re = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let m = re.firstMatch(in: text, options: [], range: range),
               let r = Range(m.range, in: text) {
                return String(text[r])
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func regexMatches(_ pattern: String, in text: String) -> [String] {
        do {
            let r = try NSRegularExpression(pattern: pattern, options: [])
            let ns = text as NSString
            let matches = r.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            return matches.compactMap { m in
                guard m.numberOfRanges > 0 else { return nil }
                return ns.substring(with: m.range(at: 0))
            }
        } catch {
            return []
        }
    }
}

// MARK: - Back parsing (robust for hockey cards)

private enum BackOCRParser {

    struct Result {
        var fullName: String?
        var lastName: String?
        var year: String?
        var cardNumber: String?
        var company: String?
        var setName: String?
    }

    static func parse(lines: [String], companyHint: String?) -> Result {
        let raw = lines.map { $0.trimmedLocal }.filter { !$0.isEmpty }
        let upper = raw.map { $0.uppercased() }

        var out = Result()

        // 1) Name
        if let fn = findFullName(in: raw) {
            out.fullName = FrontOCRParser.titleCasedName(fn)
            out.lastName = fn.split(separator: " ").last.map { FrontOCRParser.titleCasedName(String($0)) }
        } else {
            out.lastName = findLikelyLastName(in: upper)
        }

        // 2) Year (prefer season)
        out.year = findSeasonYear(in: raw)

        // 3) Company (use hint if available)
        out.company = findCompany(in: upper) ?? (companyHint?.trimmedLocal.isEmpty == false ? companyHint?.trimmedLocal : nil)

        // 4) Card number
        let hasYoung = upper.contains(where: { $0.contains("YOUNG") })
        let compUp = (out.company ?? "").uppercased()
        let isUpperDeck = compUp.contains("UPPER") || compUp.contains("DECK")
        out.cardNumber = findCardNumber(in: raw, preferYoungGunsRule: (hasYoung || isUpperDeck))

        // 5) Set
        out.setName = findSet(in: upper, company: out.company, cardNumber: out.cardNumber)

        return out
    }

    private static func findCompany(in upperLines: [String]) -> String? {
        if upperLines.contains(where: { $0.contains("UPPER DECK") || ($0.contains("UPPER") && $0.contains("DECK")) }) {
            return "Upper Deck"
        }
        if upperLines.contains(where: { $0.contains("TOPPS") }) { return "Topps" }
        if upperLines.contains(where: { $0.contains("PANINI") }) { return "Panini" }
        return nil
    }

    private static func findSet(in upperLines: [String], company: String?, cardNumber: String?) -> String? {

        let series = detectSeriesNumber(in: upperLines) // 1 or 2
        let comp = (company ?? "").uppercased()
        let isUpperDeck = comp.contains("UPPER") || comp.contains("DECK")

        let joined = upperLines.joined(separator: "\n").uppercased()
        let hasYoung = joined.contains("YOUNG")
        let hasGuns = joined.contains("GUN") // covers GUN / GUNS
        let hasYoungGunsText = hasYoung && hasGuns

        if hasYoungGunsText {
            if let s = series { return "Series \(s) - Young Guns" }
            return "Young Guns"
        }

        // If OCR missed "GUNS", infer Young Guns by typical numbering ranges (Upper Deck).
        if isUpperDeck, let n = parseCardNumberInt(cardNumber) {
            let looksLikeYG = (201...250).contains(n) || (451...500).contains(n)
            if looksLikeYG {
                if let s = series { return "Series \(s) - Young Guns" }
                return "Young Guns"
            }
        }

        return nil
    }

    private static func detectSeriesNumber(in upperLines: [String]) -> Int? {
        let joined = upperLines.joined(separator: "\n")
        let up = joined.uppercased()

        if let s = firstRegexMatch("(?i)\\bSERIES\\s*([12])\\b", in: joined) {
            let digit = s.filter { $0 == "1" || $0 == "2" }
            if let d = digit.first, let v = Int(String(d)) { return v }
        }

        // OCR sometimes mangles SERIES a bit
        if let s = firstRegexMatch("(?i)SER.{0,3}IES\\s*([12])\\b", in: joined) {
            let digit = s.filter { $0 == "1" || $0 == "2" }
            if let d = digit.first, let v = Int(String(d)) { return v }
        }

        if up.contains("SERIES 2") || up.contains("SERIES2") { return 2 }
        if up.contains("SERIES 1") || up.contains("SERIES1") { return 1 }

        return nil
    }


    private static func findSeasonYear(in lines: [String]) -> String? {

        // ✅ Priority: footer line like "2024-25 UPPER DECK SERIES 2 HOCKEY"
        // This is the card's set year, and is more reliable than the stats table "YEAR 2023-24".
        if let y = Self.detectSeasonFromSeriesFooter(in: lines) {
            return y
        }

        // Avoid bio/stats lines when scanning for any remaining seasons.
        let bad = ["BORN", "BIRTH", "HEIGHT", "WEIGHT", "SHOOTS", "TEAM", "GP", "PTS", "PIM", "PPG", "YEAR"]
        for l in lines {
            let up = l.uppercased()
            if bad.contains(where: { up.contains($0) }) { continue }
            if let y = Self.firstSeasonToken(in: l) { return y }
        }

        return nil
    }

    private static func detectSeasonFromSeriesFooter(in lines: [String]) -> String? {
        for line in lines {
            let up = line.uppercased()
            let hasUpperDeck = up.contains("UPPER") && up.contains("DECK")
            let hasSeriesOrHockey = up.contains("SERIES") || up.contains("HOCKEY")
            guard hasUpperDeck && hasSeriesOrHockey else { continue }

            if let y = Self.firstSeasonToken(in: line) { return y }
        }
        return nil
    }

    private static func firstSeasonToken(in line: String) -> String? {
        // Match "2024-25" or "2024–25" or "2024/25"
        if let s = Self.firstRegexMatch("\\b(19|20)\\d{2}\\s*[-–/]\\s*\\d{2}\\b", in: line) {
            return s
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "–", with: "-")
                .replacingOccurrences(of: "/", with: "-")
        }
        return nil
    }

    private static func findCardNumber(in lines: [String], preferYoungGunsRule: Bool) -> String? {
        // 1) Explicit #123 (avoid grabbing addresses like #5830)
        for l in lines {
            let up = l.uppercased()
            if up.contains("EL CAMINO") || up.contains("CARLSBAD") || up.contains("PRINTED") { continue }
            if let m = firstRegexMatch("#\\s*\\d{1,3}", in: up) {
                let digits = m.filter { $0.isNumber }
                if !digits.isEmpty { return "#\(digits)" }
            }
        }

        // 2) Standalone number candidates (backs usually have a 1-3 digit number).
        // Reject 4+ digit numbers (addresses/product codes) and ignore stats/bio lines.
        let badLineKeywords = [
            "HEIGHT", "WEIGHT", "SHOOTS", "BORN", "BIRTH",
            "GP", "PTS", "PIM", "PPG", "SHG", "SOG", "+/-", "YEAR",
            "©", "UDC", "UPPER DECK COMPANY", "PRINTED", "RESERVED",
            "EL CAMINO", "CARLSBAD", "CALIF", "CA"
        ]

        let window = Array(lines.prefix(50))

        var candidates: [Int] = []

        for l in window {
            let up = l.uppercased()
            if badLineKeywords.contains(where: { up.contains($0) }) { continue }

            // Only accept standalone 1-3 digits (optionally with a trailing dot/comma)
            if let m = firstRegexMatch("(?i)^\\s*(\\d{1,3})\\s*[\\.,]*\\s*$", in: up) {
                let digits = m.filter { $0.isNumber }
                if let v = Int(digits) { candidates.append(v) }
            }
        }

        // Young Guns heuristic:
        // Series 1: 201-250
        // Series 2: 451-500
        if preferYoungGunsRule {
            if let best = candidates.first(where: { (201...250).contains($0) }) { return "#\(best)" }
            if let best = candidates.first(where: { (451...500).contains($0) }) { return "#\(best)" }
        }

        // General: prefer >= 100 to avoid jersey numbers
        let big = candidates.filter { $0 >= 100 }
        if let best = big.sorted(by: >).first { return "#\(best)" }

        if let best = candidates.sorted(by: >).first { return "#\(best)" }

        return nil
    }



    private static func findFullName(in lines: [String]) -> String? {
        // We expect the player name to be a short, 2-3 word ALL-CAPS line (e.g. "ZACHARY BOLDUC").
        // On some photos, a shop sticker at the top (e.g. "RÉMI CARD TRADER") gets picked up first,
        // so we aggressively exclude common shop/label words and prefer scanning from the bottom up.

        let badContains = [
            "TEAM", "YEAR", "HEIGHT", "WEIGHT", "SHOOTS", "BORN", "BIRTH",
            "NHL", "SEASON", "ROOKIE", "RC", "STATS", "CAREER", "BIO"
        ]

        // Common non-player words seen on stickers / shop labels
        let bannedWords: Set<String> = [
            "CARD", "CARDS", "TRADER", "TRADERS", "TRADING", "SPORTS", "GAMES",
            "SHOP", "STORE", "BREAKS", "COLLECTIBLES", "COLLECTIBLE", "HOBBY",
            "RÉMI", "REMI"
        ]

        let teamCityWords: Set<String> = [
            "NEW", "YORK", "RANGERS", "CANADIENS", "MONTREAL", "MONTRÉAL", "MAPLE", "LEAFS",
            "BRUINS", "BLACKHAWKS", "AVALANCHE", "OILERS", "FLAMES", "SENATORS", "JETS",
            "PANTHERS", "LIGHTNING", "PENGUINS", "CAPITALS", "ISLANDERS", "DEVILS", "KINGS",
            "DUCKS", "SHARKS", "STARS", "WILD", "SABRES", "BLUES", "PREDATORS", "KRAKEN",
            "HURRICANES", "COYOTES", "UTAH", "VEGAS", "GOLDEN", "KNIGHTS"
        ]

        // Prefer lower parts of the image (player name is usually printed near the bottom on the front,
        // and stickers are often at the top).
        for l in lines.reversed() {
            let up = l.uppercased()
            if badContains.contains(where: { up.contains($0) }) { continue }

            // Candidate: 2-3 words, letters only
            let parts = up
                .replacingOccurrences(of: "•", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { String($0).trimmedLocal }
                .filter { !$0.isEmpty }

            if parts.count < 2 || parts.count > 3 { continue }
            if parts.contains(where: { $0.count < 2 }) { continue }
            if parts.contains(where: { !$0.allSatisfy({ $0.isLetter }) }) { continue }

            // Exclude shop labels (any banned word in the line)
            if parts.contains(where: { bannedWords.contains($0) }) { continue }

            // Exclude set titles that look like names (e.g. "YOUNG GUNS")
            if parts.contains("YOUNG") && parts.contains(where: { $0.hasPrefix("GUN") }) {
                continue
            }

            // Exclude team/city words (we want a person name, not a team)
            if parts.allSatisfy({ teamCityWords.contains($0) }) { continue }
            if parts.contains(where: { teamCityWords.contains($0) }) {
                continue
            }

            return parts.joined(separator: " ")
        }

        return nil
    }
    private static func findLikelyLastName(in upperLines: [String]) -> String? {
        let stop = Set(["UPPER", "DECK", "YOUNG", "GUNS", "...ERIES", "SERIES", "ROOKIE", "RC", "NHL",
                        "CARD", "TRADER", "SPORTS", "GAMES", "REMI", "RÉMI", "RÉMÍ",
                        "RANGERS", "NEW", "YORK", "CCM"])
        var best: String? = nil
        var bestScore = -1

        for l in upperLines {
            let parts = l
                .replacingOccurrences(of: "•", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { String($0).trimmedLocal }

            for p in parts {
                guard p.count >= 6 else { continue }
                guard p.allSatisfy({ $0.isLetter }) else { continue }
                guard !stop.contains(p) else { continue }

                let score = p.count
                if score > bestScore {
                    bestScore = score
                    best = p
                }
            }
        }

        return best.map { FrontOCRParser.titleCasedName($0) }
    }

    private static func parseCardNumberInt(_ s: String?) -> Int? {
        guard let s else { return nil }
        let digits = s.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(digits)
    }

    private static func firstRegexMatch(_ pattern: String, in text: String) -> String? {
        do {
            let re = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let m = re.firstMatch(in: text, options: [], range: range), let r = Range(m.range, in: text) {
                return String(text[r])
            }
        } catch { }
        return nil
    }

    private static func regexMatches(_ pattern: String, in text: String) -> [String] {
        do {
            let r = try NSRegularExpression(pattern: pattern, options: [])
            let ns = text as NSString
            let matches = r.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            return matches.compactMap { m in
                guard m.numberOfRanges > 0 else { return nil }
                return ns.substring(with: m.range(at: 0))
            }
        } catch {
            return []
        }
    }
}

// MARK: - String helpers

private extension String {
    var trimmedLocal: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - UIImage helpers

private extension UIImage {
    func fixedOrientation() -> UIImage {
        if imageOrientation == .up { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalized ?? self
    }
}