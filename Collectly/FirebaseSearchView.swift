//
//  FirebaseSearchView.swift
//  Collectly
//
//  Created by Claude on 2026-02-08.
//

import SwiftUI
import FirebaseFirestore
import FirebaseStorage

struct FirebaseSearchView: View {
    @State private var searchText = ""
    @State private var searchResults: [FirebaseScanResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    
    @State private var selectedTab = 0 // 0 = Recherche, 1 = Récents
    @State private var recentScans: [FirebaseScanResult] = []
    @State private var isLoadingRecent = false
    
    private let db = Firestore.firestore()
    
    var body: some View {
        VStack(spacing: 0) {
            // Tabs
            Picker("Mode", selection: $selectedTab) {
                Text("Recherche").tag(0)
                Text("Récents").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            
            if selectedTab == 0 {
                searchView
            } else {
                recentScansView
            }
        }
        .navigationTitle("Firebase Scans")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Search View
    
    private var searchView: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Nom du joueur", text: $searchText)
                    .textInputAutocapitalization(.words)
                    .onSubmit {
                        Task { await searchByPlayerName() }
                    }
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding()
            
            // Results
            if isSearching {
                ProgressView("Recherche...")
                    .padding()
                Spacer()
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else if searchResults.isEmpty && !searchText.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Aucun résultat pour \"\(searchText)\"")
                        .foregroundColor(.secondary)
                }
                .padding()
                Spacer()
            } else if searchResults.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Entre un nom de joueur")
                        .foregroundColor(.secondary)
                }
                .padding()
                Spacer()
            } else {
                List(searchResults) { result in
                    ScanResultRow(result: result)
                }
                .listStyle(.plain)
            }
        }
    }
    
    // MARK: - Recent Scans View
    
    private var recentScansView: some View {
        VStack(spacing: 0) {
            if isLoadingRecent {
                ProgressView("Chargement...")
                    .padding()
                Spacer()
            } else if recentScans.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Aucun scan récent")
                        .foregroundColor(.secondary)
                }
                .padding()
                Spacer()
            } else {
                List(recentScans) { result in
                    ScanResultRow(result: result)
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            if recentScans.isEmpty {
                Task { await loadRecentScans() }
            }
        }
    }
    
    // MARK: - Search Functions
    
    private func searchByPlayerName() async {
        guard !searchText.isEmpty else { return }
        
        await MainActor.run {
            isSearching = true
            errorMessage = nil
        }
        
        do {
            let snapshot = try await db.collection("scans")
                .whereField("playerName", isEqualTo: searchText)
                .order(by: "timestamp", descending: true)
                .limit(to: 20)
                .getDocuments()
            
            let results = snapshot.documents.compactMap { doc -> FirebaseScanResult? in
                guard let playerName = doc.data()["playerName"] as? String,
                      let cardNumber = doc.data()["cardNumber"] as? String,
                      let setName = doc.data()["setName"] as? String,
                      let frontUrl = doc.data()["frontUrl"] as? String,
                      let timestamp = doc.data()["timestamp"] as? Timestamp else {
                    return nil
                }
                
                let year = doc.data()["year"] as? String
                let company = doc.data()["company"] as? String
                
                return FirebaseScanResult(
                    id: doc.documentID,
                    playerName: playerName,
                    cardNumber: cardNumber,
                    setName: setName,
                    year: year,
                    company: company,
                    frontUrl: frontUrl,
                    timestamp: timestamp.dateValue()
                )
            }
            
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "Erreur: \(error.localizedDescription)"
                isSearching = false
            }
        }
    }
    
    private func loadRecentScans() async {
        await MainActor.run {
            isLoadingRecent = true
        }
        
        do {
            let snapshot = try await db.collection("scans")
                .order(by: "timestamp", descending: true)
                .limit(to: 20)
                .getDocuments()
            
            let results = snapshot.documents.compactMap { doc -> FirebaseScanResult? in
                guard let playerName = doc.data()["playerName"] as? String,
                      let cardNumber = doc.data()["cardNumber"] as? String,
                      let setName = doc.data()["setName"] as? String,
                      let frontUrl = doc.data()["frontUrl"] as? String,
                      let timestamp = doc.data()["timestamp"] as? Timestamp else {
                    return nil
                }
                
                let year = doc.data()["year"] as? String
                let company = doc.data()["company"] as? String
                
                return FirebaseScanResult(
                    id: doc.documentID,
                    playerName: playerName,
                    cardNumber: cardNumber,
                    setName: setName,
                    year: year,
                    company: company,
                    frontUrl: frontUrl,
                    timestamp: timestamp.dateValue()
                )
            }
            
            await MainActor.run {
                recentScans = results
                isLoadingRecent = false
            }
        } catch {
            await MainActor.run {
                isLoadingRecent = false
            }
        }
    }
}

// MARK: - Result Row

struct ScanResultRow: View {
    let result: FirebaseScanResult
    @State private var frontImage: UIImage?
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            if let image = frontImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 60, height: 80)
                    .overlay {
                        ProgressView()
                    }
                    .onAppear {
                        loadImage()
                    }
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(result.playerName)
                    .font(.headline)
                
                Text(result.cardNumber)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let year = result.year {
                    Text(year)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text(result.setName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                // Scan ID Firebase
                Text("ID: \(result.id)")
                    .font(.caption2)
                    .foregroundColor(.blue)
                    .textSelection(.enabled)
                
                Text(formatDate(result.timestamp))
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    private func loadImage() {
        guard let url = URL(string: result.frontUrl) else { return }
        
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let image = UIImage(data: data) {
                    await MainActor.run {
                        frontImage = image
                    }
                }
            } catch {
                print("Failed to load image: \(error)")
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Model

struct FirebaseScanResult: Identifiable {
    let id: String
    let playerName: String
    let cardNumber: String
    let setName: String
    let year: String?
    let company: String?
    let frontUrl: String
    let timestamp: Date
}

#Preview {
    NavigationStack {
        FirebaseSearchView()
    }
}
