import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct DocumentDemoView: View {
    @State private var isDropping = false
    @State private var docId: Int?
    @State private var summary: String = ""
    @State private var progressText: String = "Drop a PDF/DOCX/TXT/HTML to summarize"
    private let indexer = Indexer()
    private let ingestor: FileIngestor
    private let retriever = HybridRetriever()
    private let summarizer = MapReduceSummarizer()

    init() {
        self.ingestor = FileIngestor(indexer: indexer)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(progressText).font(.callout).foregroundStyle(.secondary)
            GlassCard(cornerRadius: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Summary")
                        .font(.headline)
                    if summary.isEmpty {
                        Text("(empty)").foregroundStyle(.secondary)
                    } else {
                        MarkdownView(summary)
                    }
                }
                .frame(minHeight: 180)
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropping) { providers in
                handleDrop(providers)
            }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(isDropping ? LG.accent : .clear, lineWidth: 2))
        }
        .padding()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let prov = providers.first, prov.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }
        prov.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                Task { await ingest(url) }
            }
        }
        return true
    }

    private func ingest(_ url: URL) async {
        await MainActor.run { self.progressText = "Parsing…" }
        do {
            let id = try await ingestor.ingest(url: url)
            await MainActor.run { self.docId = id; self.progressText = "Summarizing…" }
            let s = try await summarizer.summarize(docId: id, style: .bullets)
            await MainActor.run { self.summary = s; self.progressText = "Done" }
        } catch {
            await MainActor.run { self.progressText = "Error: \(error.localizedDescription)" }
        }
    }
}
