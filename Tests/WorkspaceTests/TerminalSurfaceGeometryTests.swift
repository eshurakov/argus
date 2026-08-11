import AppKit
import Testing

@testable import Argus

@Suite
struct TerminalSurfaceGeometryTests {
    @Test
    @MainActor
    func rememberedPaneSizeIsUsedWhenBoundsAreStillZero() {
        let surface = TerminalSurface(workspaceId: UUID())
        let view = surface.hostedView

        #expect(view.resolvedPointSize(from: .zero) == nil)
        #expect(view.resolvedPointSize(from: nil) == nil)

        let paneSize = CGSize(width: 960, height: 640)
        #expect(view.resolvedPointSize(from: paneSize) == paneSize)
        #expect(view.resolvedPointSize(from: .zero) == paneSize)
        #expect(view.resolvedPointSize(from: nil) == paneSize)

        view.synchronizeSurfaceGeometry(to: CGSize(width: 1200, height: 800))
        #expect(view.lastResolvedSize == CGSize(width: 1200, height: 800))
        #expect(view.resolvedPointSize(from: nil) == CGSize(width: 1200, height: 800))
    }
}
