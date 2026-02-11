import SwiftUI

/// Simple debug screen to validate:
/// 1) App token works
/// 2) Browse API search works
///
/// Uses `EbayAuthService.getAppToken()` + `EbayBrowseService.searchActiveListings(...)`.
struct EbayBrowseDebugView: View {

    @State private var query: String = "Juraj Slafkovsky Young Guns"
    @State private var limit: Int = 10

    @State private var isLoading: Bool = false
    @State private var errorText: String? = nil
    @State private var items: [EbayBrowseService.ItemSummary] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {

                inputPanel

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                List {
                    if items.isEmpty {
                        Text("No results yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(items.indices, id: \.self) { idx in
                            EbayItemRow(item: items[idx])
                        }
                    }
                }
            }
            .navigationTitle("eBay Browse Debug")
        }
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Query")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Search...", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(.roundedBorder)

            HStack {
                Stepper("Limit: \(limit)", value: $limit, in: 1...50)
                Spacer()
                Button {
                    Task { await runSearch() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Search")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
    }

    @MainActor
    private func runSearch() async {
        isLoading = true
        errorText = nil
        items = []

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isLoading = false
            return
        }

        do {
            let token = try await EbayAuthService().getAppToken()
            let results = try await EbayBrowseService().searchActiveListings(
                query: trimmed,
                limit: limit,
                token: token
            )
            items = results
        } catch {
            errorText = String(describing: error)
        }

        isLoading = false
    }
}

private struct EbayItemRow: View {
    let item: EbayBrowseService.ItemSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title ?? "(no title)")
                .font(.body)

            if let priceText = priceLine {
                Text(priceText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let url = item.itemWebUrl, !url.isEmpty {
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var priceLine: String? {
        guard let price = item.price else { return nil }
        let value = price.value
        let currency = price.currency
        if currency.isEmpty {
            return "Price: \(value)"
        }
        return "Price: \(value) \(currency)"
    }
}
