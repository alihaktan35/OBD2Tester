import SwiftUI
import AppKit

struct AboutView: View {
    @AppStorage("obd2tester.theme") private var themeRaw: String = AppTheme.light.rawValue
    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .light }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "car.badge.gearshape")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            VStack(spacing: 2) {
                Text("OBD2Tester")
                    .font(.title3.bold())
                Text("v1.0")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("by alihaktan35")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                linkRow(title: "github.com/alihaktan35", url: "https://github.com/alihaktan35")
                linkRow(title: "ahsdev.com.tr", url: "https://ahsdev.com.tr")
            }
        }
        .padding(24)
        .frame(width: 260)
        .preferredColorScheme(theme.colorScheme)
    }

    private func linkRow(title: String, url: String) -> some View {
        Button {
            if let target = URL(string: url) {
                NSWorkspace.shared.open(target)
            }
        } label: {
            Text(title)
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AboutView()
}
