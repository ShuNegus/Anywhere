//
//  ConnectionGraphSection.swift
//  Anywhere
//
//  Оболочка над графом: разворачивает его на время подключения,
//  сворачивает в покое и после подключения, тап переключает вручную.
//  Спека: design for anywhere/SPEC.md, раздел 3.5.
//

import SwiftUI

struct ConnectionGraphSection: View {

    let stage: ConnectionStage

    /// Ручное переключение живёт до следующей смены этапа, потом снова автоматика.
    @State private var manualExpanded: Bool?

    /// Развёрнут, пока идёт подключение или пока висит ошибка — ровно тогда,
    /// когда на граф смотрят.
    private var isExpanded: Bool {
        manualExpanded ?? (stage.isBusy || stage.isFailed)
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) {
                manualExpanded = !isExpanded
            }
        } label: {
            if isExpanded {
                ZStack(alignment: .topTrailing) {
                    ConnectionGraphView(stage: stage)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.40))
                }
                .padding(8)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .accessibilityHint(String(localized: "graph.a11y.collapseHint", defaultValue: "Hide connection stages", comment: "VoiceOver-подсказка развёрнутого графа"))
            } else {
                ConnectionGraphCollapsedView(stage: stage)
            }
        }
        .buttonStyle(.plain)
        .onChange(of: stage) { _, _ in
            manualExpanded = nil
        }
    }
}
