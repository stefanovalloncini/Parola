import Foundation
import ParolaCore
import QuickLookUI
import UniformTypeIdentifiers

class ParolaPreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let doc: ParolaDocument
        do {
            doc = try ParolaDocument.read(at: url)
        } catch {
            return errorReply(message: "Couldn't open this Parola document: \(error.localizedDescription)")
        }
        let data: Data
        do {
            data = try HtmlExporter().render(doc.transcript)
        } catch {
            return errorReply(message: "Couldn't render this transcript: \(error.localizedDescription)")
        }

        return QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 800, height: 1000)
        ) { _ in
            return data
        }
    }

    private func errorReply(message: String) -> QLPreviewReply {
        let html = """
        <html><head><meta charset="utf-8"><title>Parola</title>
        <style>body{font-family:-apple-system,sans-serif;padding:2rem;color:#888}</style>
        </head><body><p>\(Format.escapeHTML(message))</p></body></html>
        """
        return QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 600, height: 200)
        ) { _ in
            Data(html.utf8)
        }
    }
}
