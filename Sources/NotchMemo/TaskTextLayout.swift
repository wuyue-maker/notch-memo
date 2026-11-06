import AppKit
import MemoCore

enum TaskTextLayout {
    static let font = NSFont.systemFont(ofSize: 13)
    static let lineSpacing: CGFloat = 4
    static let previewRowHeight: CGFloat = 64
    static var twoLineHeight: CGFloat {
        ceil((font.ascender - font.descender + font.leading) * 2 + lineSpacing)
    }

    static func fullHeight(for task: MemoTask) -> CGFloat {
        fullHeight(text: task.text, completed: task.completedAt != nil)
    }

    static func textWidth(completed: Bool) -> CGFloat { MemoLayout.taskTextWidth(completed: completed) }

    static func fullHeight(text: String, completed: Bool) -> CGFloat {
        // 368 pt paper minus list/row padding, checkbox, gaps and the active drag handle.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: textWidth(completed: completed), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        return ceil(bounds.height)
    }

    static func editorHeight(text: String, completed: Bool) -> CGFloat {
        let measured = text.isEmpty ? " " : (text.hasSuffix("\n") ? text + " " : text)
        return max(25, fullHeight(text: measured, completed: completed))
    }

    static func canExpand(_ task: MemoTask) -> Bool {
        fullHeight(for: task) > twoLineHeight + 1
    }

    static func rowHeight(for task: MemoTask, expanded: Bool) -> CGFloat {
        guard expanded else { return previewRowHeight }
        return max(previewRowHeight - 20, fullHeight(for: task)) + 20
    }
}
