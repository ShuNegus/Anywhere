//
//  LatencyLabel.swift
//  Anywhere
//
//  Created by NodePassProject on 6/5/26.
//

import SwiftUI

struct LatencyLabel: View {
    let latency: LatencyResult?

    var body: some View {
        switch latency {
        case .testing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 50, alignment: .trailing)
        case .success(let ms):
            Text(Formatting.formatMilliseconds(ms))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Self.color(ms))
                .frame(minWidth: 50, alignment: .trailing)
        case .failed:
            Text("timeout")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .trailing)
        case .insecure:
            Text("insecure")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .trailing)
        case .rejected:
            Text(Self.rejectedText)
                .font(.caption)
                .foregroundStyle(TurnStatusPalette.warningText)
                .frame(minWidth: 50, alignment: .trailing)
        case nil:
            EmptyView()
        }
    }

    /// The server refused our REALITY handshake (see `RealityRejectionGate`).
    static var rejectedText: String {
        String(localized: "latency.rejected", defaultValue: "rejected", comment: "Пинг: сервер отклонил подключение (REALITY)")
    }

    static func color(_ ms: Int) -> Color {
        if ms < 300 { return .green }
        if ms < 500 { return .yellow }
        return .red
    }
}
