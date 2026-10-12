import CoreTransferable
import ParolaCore

struct TranscriptShareItem: Transferable {
    let transcript: Transcript

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { $0.transcript.text }
    }
}
