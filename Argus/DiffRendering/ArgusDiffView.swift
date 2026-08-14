import SwiftDiffs
import SwiftUI

struct ArgusDiffView: View {
    let input: ArgusDiffInput

    var body: some View {
        DiffView(input.packageInput, configuration: input.packageConfiguration)
    }
}
