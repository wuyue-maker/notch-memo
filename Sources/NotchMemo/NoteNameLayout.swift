import AppKit
import MemoCore

/// A name is limited by rendered width, not by its character count.
enum NoteNameLayout {
    static func font(size: CGFloat = 23) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        return font.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }

    static func maximumWidth(font: NSFont) -> CGFloat {
        width(String(repeating: "中", count: 8), font: font)
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func fittingPrefix(_ text: String) -> String {
        let font = font()
        let limit = maximumWidth(font: font)
        let singleLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        var fitted = ""
        for character in singleLine {
            let candidate = fitted + String(character)
            guard width(candidate, font: font) <= limit + 0.01 else { break }
            fitted = candidate
        }
        return fitted
    }
}

extension MemoNote {
    var labelName: String { NoteNameLayout.fittingPrefix(name ?? "未命名便签") }
}
