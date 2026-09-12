import SwiftUI

struct ContentView: View {
    private let info = BuildInfo(bundle: .main)

    var body: some View {
        NavigationStack {
            List {
                Section("Build") {
                    LabeledContent("Version", value: info.version)
                    LabeledContent("Build", value: info.build)
                    LabeledContent("Commit", value: info.commit)
                }
            }
            .fontDesign(.monospaced)
            .textSelection(.enabled)
            .navigationTitle("Prisma")
        }
    }
}
