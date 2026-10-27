import SwiftUI

struct MenuBarView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Musiczy")
                .font(.headline)
            Text("Menu bar is working.")
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 260)
    }
}
