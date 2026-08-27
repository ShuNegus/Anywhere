//
//  DetailRevealScrollView.swift
//  Anywhere
//
//  Created by NodePassProject on 7/5/26.
//

import SwiftUI

struct DetailRevealScrollView<Fold: View, Detail: View>: View {
    private let revealsDetail: Bool
    private let fold: Fold
    private let detail: Detail

    @State private var viewport = DetailRevealViewport()
    @State private var metrics = DetailRevealMetrics()
    @State private var scrollPosition = ScrollPosition()
    @State private var snapFeedbackCount = 0
    @State private var isSettledOnDetail = false

    init(
        revealsDetail: Bool,
        @ViewBuilder fold: () -> Fold,
        @ViewBuilder detail: () -> Detail
    ) {
        self.revealsDetail = revealsDetail
        self.fold = fold()
        self.detail = detail()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                fold
                    .frame(maxWidth: .infinity, minHeight: viewport.height, alignment: .top)
                    .overlay(alignment: .bottom) {
                        if revealsDetail && !isSettledOnDetail {
                            PullUpIndicator()
                                .transition(.blurReplace)
                        }
                    }
                    .padding(.bottom, revealsDetail ? viewport.bottomInset : 0)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .scrollView)
                    } action: { frame in
                        let previousHeight = metrics.foldHeight
                        metrics.foldHeight = frame.height
                        metrics.offset = -frame.minY
                        if -frame.minY <= metrics.foldRestOffset + DetailRevealSnapBehavior.boundaryTolerance {
                            metrics.settledPage = .fold
                            if isSettledOnDetail {
                                withAnimation { isSettledOnDetail = false }
                            }
                        }
                        if previousHeight > 0,
                           abs(frame.height - previousHeight) > DetailRevealSnapBehavior.boundaryTolerance {
                            realignAfterResize()
                        }
                    }
                    .id(DetailRevealPage.fold)

                if revealsDetail {
                    detail
                        .transition(.blurReplace)
                        .id(DetailRevealPage.detail)
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                let previousHeight = metrics.contentHeight
                metrics.contentHeight = height
                if previousHeight > 0,
                   abs(height - previousHeight) > DetailRevealSnapBehavior.boundaryTolerance {
                    realignAfterResize()
                }
            }
        }
        .scrollIndicators(.never)
        .scrollTargetBehavior(DetailRevealSnapBehavior(
            metrics: metrics,
            isEnabled: revealsDetail
        ))
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollPosition($scrollPosition)
        .onScrollPhaseChange { _, newPhase in
            handlePhaseChange(newPhase)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: snapFeedbackCount)
        .onGeometryChange(for: DetailRevealViewport.self) { proxy in
            DetailRevealViewport(
                height: proxy.size.height,
                bottomInset: proxy.safeAreaInsets.bottom
            )
        } action: { newViewport in
            let previousHeight = viewport.height
            viewport = newViewport
            if previousHeight > 0,
               abs(newViewport.height - previousHeight) > DetailRevealSnapBehavior.boundaryTolerance {
                realignAfterResize()
            }
        }
    }

    private func handlePhaseChange(_ phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting:
            metrics.pendingSnap = nil
            metrics.snapInFlight = false
        case .decelerating, .idle:
            if phase == .idle { metrics.snapInFlight = false }
            guard let page = metrics.pendingSnap else { return }
            metrics.pendingSnap = nil
            let isPageChange = page != metrics.settledPage
            metrics.settledPage = page
            snap(to: page, playFeedback: isPageChange)
        default:
            break
        }
    }

    private func snap(to page: DetailRevealPage, playFeedback: Bool) {
        metrics.snapInFlight = true
        withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
            isSettledOnDetail = page == .detail
        }
        Task { @MainActor in
            if playFeedback { snapFeedbackCount += 1 }
            withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
                scrollPosition.scrollTo(y: page == .detail ? metrics.commitOffset : metrics.foldRestOffset)
            }
        }
    }
    
    private func realignAfterResize() {
        guard revealsDetail else { return }
        Task { @MainActor in
            let boundary = min(
                metrics.foldHeight,
                max(metrics.contentHeight - viewport.height, 0)
            )
            metrics.commitOffset = boundary
            metrics.foldRestOffset = min(
                max(min(metrics.foldHeight, metrics.contentHeight) - viewport.height, 0),
                boundary
            )
            guard metrics.settledPage == .detail,
                  abs(metrics.offset - boundary) > DetailRevealSnapBehavior.boundaryTolerance
            else { return }
            metrics.pendingSnap = nil
            snap(to: .detail, playFeedback: false)
        }
    }
}

private nonisolated struct DetailRevealViewport: Equatable {
    var height: CGFloat = 0
    var bottomInset: CGFloat = 0
}

// MARK: - Snapping

private nonisolated enum DetailRevealPage: Hashable {
    case fold
    case detail
}

private final class DetailRevealMetrics {
    /// Height of the fold page — the offset at which detail is fully revealed.
    var foldHeight: CGFloat = 0
    /// Total height of the scroll content, for capping the detail boundary.
    var contentHeight: CGFloat = 0
    /// Current scroll offset (0 = fold page flush with the top).
    var offset: CGFloat = 0
    /// The page the scroll view last settled on.
    var settledPage: DetailRevealPage = .fold
    /// Page picked for the gesture in flight; consumed when the finger lifts.
    var pendingSnap: DetailRevealPage?
    /// Offset of the detail page boundary, stashed by the snap behavior so the
    /// explicit snap animation can target it.
    var commitOffset: CGFloat = 0
    /// Offset at which the fold page rests: 0 while the fold fits the viewport,
    /// otherwise the offset that puts the bottom of the fold at the bottom of
    /// the viewport, so a taller-than-viewport fold can scroll on its own.
    var foldRestOffset: CGFloat = 0
    /// True while the explicit snap animation is driving the scroll; the snap
    /// behavior stays passive so the two never fight.
    var snapInFlight = false
}

private struct DetailRevealSnapBehavior: ScrollTargetBehavior {
    /// Slack for float comparisons against page boundaries.
    static let boundaryTolerance: CGFloat = 0.5

    let metrics: DetailRevealMetrics
    let isEnabled: Bool

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard isEnabled, !metrics.snapInFlight else { return }

        // Offset at which the detail page is flush with the top, capped by how
        // far the content can actually scroll.
        let commitOffset = min(
            metrics.foldHeight,
            context.contentSize.height - context.containerSize.height
        )
        metrics.commitOffset = max(commitOffset, 0)
        guard commitOffset > 0 else {
            metrics.pendingSnap = nil
            return
        }

        // Offset at which the fold's own content is scrolled to its end. Zero
        // while the fold fits the viewport; taller folds scroll freely up to it
        // before the detail page comes into play.
        let foldRest = min(
            max(
                min(metrics.foldHeight, context.contentSize.height) - context.containerSize.height,
                0
            ),
            commitOffset
        )
        metrics.foldRestOffset = foldRest

        let projected = target.rect.origin.y

        // Scrolled within the detail content: keep flings from sailing back
        // past the fold. Returning to the fold page takes a second gesture
        // once settled at its top.
        if metrics.offset > commitOffset + Self.boundaryTolerance {
            metrics.pendingSnap = nil
            if projected < commitOffset {
                target.rect.origin.y = commitOffset
            }
            return
        }

        // Otherwise only intervene around the fold: the gesture either ends
        // between the two pages or would cross a page in one go.
        let landsBetweenPages = projected > foldRest + Self.boundaryTolerance && projected < commitOffset
        let crossesIntoDetail = metrics.offset < commitOffset - Self.boundaryTolerance && projected >= commitOffset
        let crossesToTop = metrics.offset > foldRest + Self.boundaryTolerance && projected <= foldRest
        guard landsBetweenPages || crossesIntoDetail || crossesToTop else {
            metrics.pendingSnap = nil
            return
        }

        let page: DetailRevealPage = projected >= (foldRest + commitOffset) / 2 ? .detail : .fold
        // Freeze the native deceleration where it is; the explicit snap
        // animation fired on the next phase change is the only thing that
        // moves the scroll from here.
        target.rect.origin.y = metrics.offset
        metrics.pendingSnap = page
    }
}

// MARK: - Pull-Up Indicator

private struct PullUpIndicator: View {
    var body: some View {
        Image(systemName: "chevron.compact.up")
            .font(.title)
            .foregroundStyle(.secondary)
            .phaseAnimator([0.0, -6.0]) { view, offset in
                view.offset(y: offset)
            } animation: { _ in
                .easeInOut(duration: 1.1)
            }
            .padding(.bottom, 8)
    }
}
