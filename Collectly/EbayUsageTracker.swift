import Foundation

// MARK: - eBay API Usage Tracker

/// Suit l'utilisation de l'API eBay (compteurs locaux + statistiques)
class EbayUsageTracker {
    
    // MARK: - Singleton
    static let shared = EbayUsageTracker()
    private init() {
        loadStats()
    }
    
    // MARK: - Storage Keys
    private let statsKey = "ebay_api_stats"
    
    // MARK: - Stats Model
    struct Stats: Codable {
        var imageSearchCount: Int = 0
        var textSearchCount: Int = 0
        var hybridSearchCount: Int = 0
        var totalCalls: Int = 0
        var successCount: Int = 0
        var errorCount: Int = 0
        var lastResetDate: Date = Date()
        
        // Compteurs par jour
        var dailyStats: [String: DailyStats] = [:]
        
        struct DailyStats: Codable {
            var imageSearch: Int = 0
            var textSearch: Int = 0
            var totalCalls: Int = 0
        }
    }
    
    // MARK: - Current Stats
    private(set) var stats = Stats()
    
    // MARK: - Track Methods
    
    /// Enregistrer un appel Image Search
    func trackImageSearch(success: Bool) {
        stats.imageSearchCount += 1
        stats.totalCalls += 1
        if success {
            stats.successCount += 1
        } else {
            stats.errorCount += 1
        }
        
        trackDaily(type: .imageSearch)
        saveStats()
    }
    
    /// Enregistrer un appel Text Search (Finding API)
    func trackTextSearch(success: Bool) {
        stats.textSearchCount += 1
        stats.totalCalls += 1
        if success {
            stats.successCount += 1
        } else {
            stats.errorCount += 1
        }
        
        trackDaily(type: .textSearch)
        saveStats()
    }
    
    /// Enregistrer un appel Hybride (Image + Text)
    func trackHybridSearch(success: Bool) {
        stats.hybridSearchCount += 1
        stats.totalCalls += 1
        if success {
            stats.successCount += 1
        } else {
            stats.errorCount += 1
        }
        
        trackDaily(type: .textSearch)  // Compte comme text pour daily
        saveStats()
    }
    
    // MARK: - Daily Tracking
    
    enum SearchType {
        case imageSearch
        case textSearch
    }
    
    private func trackDaily(type: SearchType) {
        let today = dayKey(for: Date())
        var todayStats = stats.dailyStats[today] ?? Stats.DailyStats()
        
        switch type {
        case .imageSearch:
            todayStats.imageSearch += 1
        case .textSearch:
            todayStats.textSearch += 1
        }
        
        todayStats.totalCalls += 1
        stats.dailyStats[today] = todayStats
        
        // Nettoyer les vieux stats (garder 30 jours)
        cleanOldStats()
    }
    
    private func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    private func cleanOldStats() {
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let cutoffKey = dayKey(for: thirtyDaysAgo)
        
        stats.dailyStats = stats.dailyStats.filter { key, _ in
            key >= cutoffKey
        }
    }
    
    // MARK: - Reset
    
    func resetStats() {
        stats = Stats()
        saveStats()
    }
    
    // MARK: - Persistence
    
    private func saveStats() {
        if let encoded = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(encoded, forKey: statsKey)
        }
    }
    
    private func loadStats() {
        if let data = UserDefaults.standard.data(forKey: statsKey),
           let decoded = try? JSONDecoder().decode(Stats.self, from: data) {
            stats = decoded
        }
    }
    
    // MARK: - Reporting
    
    /// Stats formatées pour affichage
    var report: String {
        let successRate = stats.totalCalls > 0 
            ? Int((Double(stats.successCount) / Double(stats.totalCalls)) * 100)
            : 0
        
        let today = dayKey(for: Date())
        let todayStats = stats.dailyStats[today] ?? Stats.DailyStats()
        
        return """
        📊 Statistiques eBay API
        
        Total depuis installation:
        • Recherches Image: \(stats.imageSearchCount)
        • Recherches Texte: \(stats.textSearchCount)
        • Recherches Hybrides: \(stats.hybridSearchCount)
        • Total: \(stats.totalCalls) appels
        
        Taux de succès: \(successRate)%
        ✅ Succès: \(stats.successCount)
        ❌ Erreurs: \(stats.errorCount)
        
        Aujourd'hui:
        • Image: \(todayStats.imageSearch)
        • Texte: \(todayStats.textSearch)
        • Total: \(todayStats.totalCalls)
        
        Dernière réinitialisation: \(formattedDate(stats.lastResetDate))
        """
    }
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter.string(from: date)
    }
    
    /// Stats des 7 derniers jours
    var last7DaysStats: [(day: String, imageSearch: Int, textSearch: Int, total: Int)] {
        var result: [(String, Int, Int, Int)] = []
        
        for i in 0..<7 {
            if let date = Calendar.current.date(byAdding: .day, value: -i, to: Date()) {
                let key = dayKey(for: date)
                let stat = stats.dailyStats[key] ?? Stats.DailyStats()
                result.append((key, stat.imageSearch, stat.textSearch, stat.totalCalls))
            }
        }
        
        return result.reversed()
    }
}

// MARK: - SwiftUI View pour afficher les stats

import SwiftUI

struct EbayStatsView: View {
    @State private var stats = EbayUsageTracker.shared.stats
    @State private var showResetAlert = false
    
    var body: some View {
        List {
            // Résumé
            Section("Résumé") {
                StatRow(icon: "camera.fill", label: "Image Search", value: "\(stats.imageSearchCount)")
                StatRow(icon: "text.magnifyingglass", label: "Text Search", value: "\(stats.textSearchCount)")
                StatRow(icon: "wand.and.stars", label: "Hybride", value: "\(stats.hybridSearchCount)")
                
                Divider()
                
                StatRow(icon: "sum", label: "Total", value: "\(stats.totalCalls)", bold: true)
            }
            
            // Taux de succès
            Section("Fiabilité") {
                let successRate = stats.totalCalls > 0 
                    ? Int((Double(stats.successCount) / Double(stats.totalCalls)) * 100)
                    : 0
                
                HStack {
                    Label("Taux de succès", systemImage: "checkmark.circle")
                    Spacer()
                    Text("\(successRate)%")
                        .foregroundStyle(successRate >= 80 ? .green : .orange)
                        .fontWeight(.semibold)
                }
                
                StatRow(icon: "checkmark", label: "Succès", value: "\(stats.successCount)")
                StatRow(icon: "xmark", label: "Erreurs", value: "\(stats.errorCount)")
            }
            
            // Graphique 7 jours
            Section("Derniers 7 jours") {
                let last7Days = EbayUsageTracker.shared.last7DaysStats
                
                if last7Days.allSatisfy({ $0.total == 0 }) {
                    Text("Aucune donnée")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(last7Days, id: \.day) { day, image, text, total in
                        HStack {
                            Text(formatDay(day))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            
                            ProgressView(value: Double(total), total: Double(maxLast7Days))
                                .tint(.blue)
                            
                            Text("\(total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                }
            }
            
            // Actions
            Section {
                Button(role: .destructive) {
                    showResetAlert = true
                } label: {
                    Label("Réinitialiser les stats", systemImage: "arrow.counterclockwise")
                }
            }
        }
        .navigationTitle("Stats eBay")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Réinitialiser?", isPresented: $showResetAlert) {
            Button("Annuler", role: .cancel) { }
            Button("Réinitialiser", role: .destructive) {
                EbayUsageTracker.shared.resetStats()
                stats = EbayUsageTracker.shared.stats
            }
        } message: {
            Text("Cela effacera toutes les statistiques d'utilisation eBay.")
        }
        .onAppear {
            stats = EbayUsageTracker.shared.stats
        }
    }
    
    private var maxLast7Days: Int {
        EbayUsageTracker.shared.last7DaysStats.map { $0.total }.max() ?? 1
    }
    
    private func formatDay(_ dayKey: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        guard let date = formatter.date(from: dayKey) else {
            return dayKey
        }
        
        formatter.dateFormat = "EEE dd"
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter.string(from: date)
    }
}

struct StatRow: View {
    let icon: String
    let label: String
    let value: String
    var bold: Bool = false
    
    var body: some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .fontWeight(bold ? .semibold : .regular)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        EbayStatsView()
    }
}
