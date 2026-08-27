//
//  VoyagerStubs.swift
//  Local stand-ins for views missing from the public repository.
//

import SwiftUI

struct AnywhereVoyagerView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack {
            Text("Voyager is unavailable in this build.")
            Button("Close") { dismiss() }
        }
    }
}

struct VoyagerSettingsCard: View {
    var body: some View { EmptyView() }
}

struct VoyagerCardBackground: View {
    var body: some View { Color.clear }
}
