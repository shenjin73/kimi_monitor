import SwiftUI

/// Single-page dashboard: sessions / quota / system stacked vertically,
/// each section internally adapts to the window width.
struct MainView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SessionsSection()
                QuotaSection()
                SystemSection()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 540, minHeight: 420)
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}
