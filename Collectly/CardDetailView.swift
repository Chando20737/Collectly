import SwiftUI
import SwiftData
import UIKit

// CardDetailView: Hero mode + swipe between cards + optional "Vitrine" + eBay pricing range
struct CardDetailView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\CardItem.createdAt, order: .reverse)]) private var cards: [CardItem]

    let card: CardItem

    @State private var index: Int = 0
    @State private var showBack: Bool = false

    // Pricing (eBay)
    @State private var isRefreshingPrice: Bool = false
    @State private var priceErrorText: String? = nil

    // Showcase (Vitrine)
    enum ShowcaseBackground: String, CaseIterable, Identifiable {
        case studioDark
        case studioGray
        case studioLight

        var id: String { rawValue }

        var label: String {
            switch self {
            case .studioDark: return "Studio (foncé)"
            case .studioGray: return "Studio (gris)"
            case .studioLight: return "Studio (clair)"
            }
        }

        var color: Color {
            switch self {
            case .studioDark: return .black
            case .studioGray: return Color(white: 0.12)
            case .studioLight: return Color(white: 0.96)
            }
        }

        var foreground: Color {
            switch self {
            case .studioLight: return .black
            default: return .white
            }
        }
    }

    @State private var showShowcase: Bool = false
    @State private var showcaseBackground: ShowcaseBackground = .studioDark
    @State private var showcaseShowInfo: Bool = true

    private var currentCard: CardItem? {
        guard cards.indices.contains(index) else { return nil }
        return cards[index]
    }

    var body: some View {
        GeometryReader { geo in
            TabView(selection: $index) {
                ForEach(cards.indices, id: \.self) { i in
                    heroCard(cards[i], size: geo.size)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onAppear {
                if let idx = cards.firstIndex(where: { $0.id == card.id }) {
                    index = idx
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showShowcase = true
                } label: {
                    Image(systemName: "sparkles")
                }

                Button {
                    withAnimation { showBack.toggle() }
                } label: {
                    Text(showBack ? "Recto" : "Verso")
                }
            }
        }
        .fullScreenCover(isPresented: $showShowcase) {
            if let c = currentCard {
                CardShowcaseView(
                    card: c,
                    showBack: $showBack,
                    showcaseBackground: $showcaseBackground,
                    showInfo: $showcaseShowInfo
                ) {
                    showShowcase = false
                }
            } else {
                Color.black.ignoresSafeArea()
                    .onTapGesture { showShowcase = false }
            }
        }
    }

    @ViewBuilder
    private func heroCard(_ card: CardItem, size: CGSize) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)

            ZStack {
                if showBack, let data = card.backImageData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                } else if let data = card.frontImageData, let img = UIImage(data: data) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.secondary.opacity(0.2))
                        .overlay(Image(systemName: "photo"))
                }
            }
            .frame(width: size.width * 0.92)
            .frame(maxHeight: size.height * 0.55)  // ✅ Limite hauteur à 55%
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(radius: 10)

            VStack(spacing: 6) {
                Text(card.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                let metaParts = [
                    (card.cardYear ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    (card.setName ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    (card.cardNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                ].filter { !$0.isEmpty }

                if !metaParts.isEmpty {
                    Text(metaParts.joined(separator: " • "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // ✅ Pricing (discret)
                priceSection(card: card)
            }
            .padding(.horizontal)
            .padding(.bottom, 20)  // ✅ Padding bottom pour éviter la tab bar

            Spacer(minLength: 20)  // ✅ Spacer réduit à 20 minimum
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.02))
    }

    // MARK: - Pricing (eBay)

    @ViewBuilder
    private func priceSection(card: CardItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Prix")
                    .font(.headline)

                Spacer()

                Button {
                    Task { await refreshPrice(card: card) }
                } label: {
                    if isRefreshingPrice {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshingPrice)
            }

            if let med = card.priceMedianCAD ?? card.estimatedPriceCAD {
                let minV = card.priceMinCAD
                let maxV = card.priceMaxCAD
                let n = card.priceSampleCount ?? 0
                let conf = card.priceConfidence

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(formatCurrency(med, code: "CAD"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    if let minV, let maxV, maxV > 0 {
                        Text("(\(formatCurrency(minV, code: "CAD")) – \(formatCurrency(maxV, code: "CAD")))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    if n > 0 {
                        Label("\(n) annonces", systemImage: "chart.bar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let conf {
                        Label("Confiance \(Int((conf * 100).rounded()))%", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let dt = card.lastPriceUpdate {
                        Label(relativeDate(dt), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let src = card.priceSourceRaw, !src.isEmpty {
                    Text("Source: \(src.uppercased())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Aucune estimation pour l’instant.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let priceErrorText, !priceErrorText.isEmpty {
                Text(priceErrorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, 6)
    }

    private func refreshPrice(card: CardItem) async {
        guard !isRefreshingPrice else { return }
        isRefreshingPrice = true
        priceErrorText = nil

        do {
            let estimate = try await EbayPriceEstimator.estimateActiveListingPrice(
                year: card.cardYear,
                company: card.companyName,
                setName: card.setName,
                cardNumber: card.cardNumber,
                playerName: card.playerName,
                isGraded: card.isGraded,
                gradingCompany: card.gradingCompany,  // ✅ Ajouté
                gradeValue: card.gradeValue           // ✅ Ajouté
            )

            guard let e = estimate else {
                priceErrorText = "Pas assez d’annonces comparables."
                isRefreshingPrice = false
                return
            }

            // Store on card (SwiftData)
            card.priceMinCAD = e.min
            card.priceMedianCAD = e.median
            card.priceMaxCAD = e.max
            card.priceSampleCount = e.sampleCount

            card.estimatedPriceCAD = e.median
            card.priceSourceRaw = "ebay_active"
            card.priceConfidence = e.confidence
            card.lastPriceUpdate = Date()

            try modelContext.save()
        } catch {
            priceErrorText = error.localizedDescription
        }

        isRefreshingPrice = false
    }

    private func formatCurrency(_ value: Double, code: String) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = code
        nf.maximumFractionDigits = 0
        nf.minimumFractionDigits = 0
        return nf.string(from: NSNumber(value: value)) ?? "\(Int(value.rounded())) \(code)"
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Fullscreen Showcase view (Vitrine)

private struct CardShowcaseView: View {
    let card: CardItem
    @Binding var showBack: Bool
    @Binding var showcaseBackground: CardDetailView.ShowcaseBackground
    @Binding var showInfo: Bool
    let onClose: () -> Void

    private var imageData: Data? {
        showBack ? card.backImageData : card.frontImageData
    }

    var body: some View {
        ZStack {
            showcaseBackground.color.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top controls
                HStack(spacing: 14) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .padding(10)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                    }

                    Spacer()

                    Menu {
                        Picker("Fond", selection: $showcaseBackground) {
                            ForEach(CardDetailView.ShowcaseBackground.allCases) { bg in
                                Text(bg.label).tag(bg)
                            }
                        }
                        Toggle("Afficher les infos", isOn: $showInfo)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.headline)
                            .padding(10)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                    }

                    Button {
                        withAnimation(.easeInOut) { showBack.toggle() }
                    } label: {
                        Text(showBack ? "Recto" : "Verso")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial)
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)

                // Image
                ZStack {
                    if let data = imageData, let ui = UIImage(data: data) {
                        ZoomPanImage(uiImage: ui, shadowOpacity: showcaseBackground == .studioLight ? 0.12 : 0.25)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(showcaseBackground.foreground.opacity(0.7))
                            Text("Aucune image")
                                .foregroundStyle(showcaseBackground.foreground.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if showInfo {
                        VStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Text(card.title)
                                    .font(.headline)
                                    .foregroundStyle(showcaseBackground.foreground)
                                    .multilineTextAlignment(.center)

                                let meta = [
                                    (card.cardYear ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                    (card.setName ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                    (card.cardNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                ].filter { !$0.isEmpty }

                                if !meta.isEmpty {
                                    Text(meta.joined(separator: " • "))
                                        .font(.caption)
                                        .foregroundStyle(showcaseBackground.foreground.opacity(0.85))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.thinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.bottom, 18)
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .statusBarHidden(true)
    }
}

// MARK: - Zoom + pan (for quality inspection)

private struct ZoomPanImage: View {
    let uiImage: UIImage
    let shadowOpacity: Double

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let proposed = lastScale * value
                                scale = clamp(proposed, minScale, maxScale)
                            }
                            .onEnded { _ in
                                lastScale = scale
                                offset = clampedOffset(offset, in: size, scale: scale)
                                lastOffset = offset
                            },
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                let proposed = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                                offset = clampedOffset(proposed, in: size, scale: scale)
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        if scale < 2 {
                            scale = 3
                            lastScale = 3
                        } else {
                            scale = 1
                            lastScale = 1
                            offset = .zero
                            lastOffset = .zero
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.black.opacity(shadowOpacity), radius: 18, x: 0, y: 10)
        }
    }

    private func clamp(_ v: CGFloat, _ mn: CGFloat, _ mx: CGFloat) -> CGFloat {
        min(max(v, mn), mx)
    }

    private func clampedOffset(_ proposed: CGSize, in container: CGSize, scale: CGFloat) -> CGSize {
        let maxX = (container.width * (scale - 1)) / 2
        let maxY = (container.height * (scale - 1)) / 2
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}
