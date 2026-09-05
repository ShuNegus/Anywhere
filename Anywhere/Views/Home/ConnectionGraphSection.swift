//
//  ConnectionGraphSection.swift
//  Anywhere
//
//  Оболочка над графом: развёрнут он или свёрнут — решает только пользователь.
//  Состояние переживает смену этапа и перезапуск приложения.
//  Спека: design for anywhere/SPEC.md, раздел 3.5.
//

import SwiftUI

struct ConnectionGraphSection: View {

    let stage: ConnectionStage

    /// Граф не разворачивается и не сворачивается сам: подключение, ошибка и
    /// возврат в покой меняют только его содержимое, но не то, раскрыт ли он.
    @AppStorage("connectionGraphExpanded") private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) {
                isExpanded.toggle()
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
    }
}
