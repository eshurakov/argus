import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct ClipboardConfirmationTests {
    @Test
    func decisionsSupportApprovalCancellationAndSurfaceClosure() {
        let store = TerminalClipboardDecisionStore()
        let readSurface = UUID()
        let writeSurface = UUID()
        var readDecision: Bool?
        var writeDecision: Bool?

        store.register(surfaceId: readSurface) { readDecision = $0 }
        store.register(surfaceId: writeSurface) { writeDecision = $0 }
        store.resolve(surfaceId: readSurface, approved: true)
        store.cancel(surfaceId: writeSurface)

        #expect(readDecision == true)
        #expect(writeDecision == false)
        #expect(
            TerminalClipboardConfirmationKind.terminalRead.title
                != TerminalClipboardConfirmationKind.terminalWrite.title
        )
    }

    @Test
    func replacingAPendingDecisionCancelsTheOlderRequest() {
        let store = TerminalClipboardDecisionStore()
        let surfaceId = UUID()
        var decisions: [Bool] = []

        store.register(surfaceId: surfaceId) { decisions.append($0) }
        store.register(surfaceId: surfaceId) { decisions.append($0) }
        store.resolve(surfaceId: surfaceId, approved: true)

        #expect(decisions == [false, true])
    }
}
