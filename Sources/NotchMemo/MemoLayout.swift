import CoreGraphics

/// One inset and one icon/text grid for every paper section.
enum MemoLayout {
    /// The panel window, including the shadow margin around the paper.
    static let panelWidth: CGFloat = 396
    /// Transparent margin between the window edge and the paper.
    static let paperMargin: CGFloat = 14
    /// Space under the paper, kept for the paper's soft shadow.
    static let paperBottomPadding: CGFloat = 20

    static let paperWidth: CGFloat = panelWidth - 2 * paperMargin
    static let paperCornerRadius: CGFloat = 17

    /// Black tab that visually joins the paper to the notch.
    static let bridgeExtraHeight: CGFloat = 18
    /// The bridge overlaps the paper slightly so the two never split apart.
    static let bridgeSpacing: CGFloat = 3
    /// Distance from the top of the view to the top of the paper.
    static var paperTopOffset: CGFloat { bridgeExtraHeight - bridgeSpacing }

    static let horizontalInset: CGFloat = 22
    static let rowInset: CGFloat = 9
    static let iconColumn: CGFloat = 28
    static let contentSpacing: CGFloat = 10
    static let headerButtonSize: CGFloat = 29
    static let gripWidth: CGFloat = 18
    static let titleIndicatorDiameter: CGFloat = 20

    // Align the visible title control edge with the paper's common outer inset.
    static var titleLeadingInset: CGFloat {
        horizontalInset - (iconColumn - titleIndicatorDiameter) / 2
    }

    static var contentInset: CGFloat { horizontalInset + rowInset }
    static var textLeading: CGFloat { contentInset + iconColumn + contentSpacing }

    static func taskTextWidth(completed: Bool) -> CGFloat {
        paperWidth - 2 * contentInset - iconColumn - contentSpacing
            - (completed ? 0 : contentSpacing + gripWidth)
    }

    static func panelHeight(topInset: CGFloat, cardHeight: CGFloat) -> CGFloat {
        topInset + paperTopOffset + cardHeight + paperBottomPadding
    }
}
