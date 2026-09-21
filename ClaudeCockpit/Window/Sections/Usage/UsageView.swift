import SwiftUI

struct UsageView: View {
    @Environment(CockpitStore.self) private var store
    var body: some View {
        Text("Usage — en construction").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
