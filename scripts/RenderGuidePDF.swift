// 把 make_guide.py 生成的 DOCX 排版成 A4 PDF。
// 用法：swift scripts/guide-export-docx.py 生成 JSON 后，由 make_guide.sh 调用本脚本。
// 直接依赖：dist/guide.json（结构化内容）、build/AppIcon.iconset/icon_128x128.png、输出路径。
import AppKit
import CoreText

// ---- 读取结构化内容 ----
struct Run: Decodable { let t: String; let b: Bool?; let c: String?; let s: Double? }
struct Block: Decodable {
    let type: String
    let text: String?
    let align: String?
    let size: Double?
    let runs: [Run]?
    let rows: [[String]]?
}
let jsonPath = CommandLine.arguments[1]
let pdfPath = CommandLine.arguments[2]
let iconPath = CommandLine.arguments[3]
let blocks = try! JSONDecoder().decode([Block].self, from: Data(contentsOf: URL(fileURLWithPath: jsonPath)))

let cm: CGFloat = 28.3465
let pageSize = CGSize(width: 21.0 * cm, height: 29.7 * cm)
let ml = 2.2 * cm, mr = 2.2 * cm, mt = 2.0 * cm, mb = 2.0 * cm
let contentWidth = pageSize.width - ml - mr
let ink = NSColor(srgbRed: 0x2C/255, green: 0x2E/255, blue: 0x2A/255, alpha: 1)
let muted = NSColor(srgbRed: 0x6E/255, green: 0x6C/255, blue: 0x60/255, alpha: 1)
let accent = NSColor(srgbRed: 0x9A/255, green: 0x47/255, blue: 0x28/255, alpha: 1)

func nsColor(_ hex: String?) -> NSColor {
    guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return ink }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF)/255, green: CGFloat((v >> 8) & 0xFF)/255,
                   blue: CGFloat(v & 0xFF)/255, alpha: 1)
}
func font(_ size: CGFloat, bold: Bool) -> NSFont {
    let name = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
    return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
}
func monoFont(_ size: CGFloat) -> NSFont { NSFont(name: "Menlo-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }

// ---- 画布 ----
let pdf = NSMutableData()
var mediaBox = CGRect(origin: .zero, size: pageSize)
let consumer = CGDataConsumer(data: pdf)!
let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!

let paragraph = NSMutableParagraphStyle()
paragraph.lineSpacing = 3.2
var y = pageSize.height - mt
var pageIndex = 0

func newPage() {
    ctx.endPDFPage()
    pageIndex += 1
    ctx.beginPDFPage(nil)
    y = pageSize.height - mt
}
func ensure(_ h: CGFloat) { if y - h < mb { newPage() } }

ctx.beginPDFPage(nil)

// 首页图标
if let icon = NSImage(contentsOfFile: iconPath),
   let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let s = 1.6 * cm
    let rect = CGRect(x: ml + (contentWidth - s)/2, y: y - s, width: s, height: s)
    ctx.draw(cg, in: rect)
    y -= s + 8
}

func draw(_ attr: NSAttributedString, x: CGFloat, width: CGFloat, bottomLimit: CGFloat) -> CGFloat {
    let fs = CTFramesetterCreateWithAttributedString(attr)
    let h = ceil(CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                              CGSize(width: width, height: .greatestFiniteMagnitude), nil).height)
    let rect = CGRect(x: x, y: bottomLimit - h, width: width, height: h)
    let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, ctx)
    return h
}

for (bi, block) in blocks.enumerated() {
    switch block.type {
    case "space":
        y -= 6
    case "heading":
        // 标题后若紧跟表格，两者必须同页，避免标题孤零零留在页尾
        var need = CGFloat(30)
        if bi + 1 < blocks.count, blocks[bi + 1].type == "table",
           let rows = blocks[bi + 1].rows {
            need += CGFloat(rows.count) * 24 + 12
        }
        if y - need < mb { newPage() }
        y -= 12
        let a = NSAttributedString(string: block.text ?? "", attributes: [
            .font: font(13, bold: true), .foregroundColor: accent, .paragraphStyle: paragraph])
        y -= draw(a, x: ml, width: contentWidth, bottomLimit: y); y -= 4
    case "bullet":
        let text = (block.text ?? "").replacingOccurrences(of: "^•\\s*", with: "", options: .regularExpression)
        let indent: CGFloat = 15.6
        let a = NSMutableAttributedString(string: "•  ", attributes: [
            .font: font(10.5, bold: true), .foregroundColor: accent, .paragraphStyle: paragraph])
        a.append(NSAttributedString(string: text, attributes: [
            .font: font(10.5, bold: false), .foregroundColor: ink, .paragraphStyle: paragraph]))
        let h = ceil(CTFramesetterSuggestFrameSizeWithConstraints(
            CTFramesetterCreateWithAttributedString(a), CFRange(location: 0, length: 0), nil,
            CGSize(width: contentWidth - indent, height: .greatestFiniteMagnitude), nil).height)
        ensure(h + 4)
        _ = draw(a, x: ml + indent, width: contentWidth - indent, bottomLimit: y)
        y -= h + 4
    case "mono":
        let a = NSAttributedString(string: block.text ?? "", attributes: [
            .font: monoFont(9), .foregroundColor: muted, .paragraphStyle: paragraph])
        let h = ceil(CTFramesetterSuggestFrameSizeWithConstraints(
            CTFramesetterCreateWithAttributedString(a), CFRange(location: 0, length: 0), nil,
            CGSize(width: contentWidth - 15.6, height: .greatestFiniteMagnitude), nil).height)
        ensure(h + 6)
        _ = draw(a, x: ml + 15.6, width: contentWidth - 15.6, bottomLimit: y)
        y -= h + 6
    case "text":
        let size = CGFloat(block.size ?? 10.5)
        let color = nsColor(block.runs?.first?.c)
        let bold = block.runs?.first?.b ?? false
        let p = paragraph.mutableCopy() as! NSMutableParagraphStyle
        switch block.align {
        case "center": p.alignment = .center
        case "right": p.alignment = .right
        default: p.alignment = .left
        }
        let a = NSAttributedString(string: block.text ?? "", attributes: [
            .font: font(size, bold: bold), .foregroundColor: color, .paragraphStyle: p])
        let h = ceil(CTFramesetterSuggestFrameSizeWithConstraints(
            CTFramesetterCreateWithAttributedString(a), CFRange(location: 0, length: 0), nil,
            CGSize(width: contentWidth, height: .greatestFiniteMagnitude), nil).height)
        ensure(h)
        _ = draw(a, x: ml, width: contentWidth, bottomLimit: y)
        y -= h + 2
    case "table":
        guard let rows = block.rows else { break }
        let colX: CGFloat = 4.6 * cm
        let rowH: CGFloat = 24
        let tableHeight = CGFloat(rows.count) * rowH + 6
        if y - tableHeight < mb { newPage() }
        y -= 6
        for (i, row) in rows.enumerated() {
            if y - rowH < mb { newPage() }
            let isHeader = i == 0
            let rect = CGRect(x: ml, y: y - rowH, width: contentWidth, height: rowH)
            if isHeader {
                ctx.setFillColor(NSColor(srgbRed: 0xF1/255, green: 0xEC/255, blue: 0xE2/255, alpha: 1).cgColor)
                ctx.fill(rect)
            }
            ctx.setStrokeColor(NSColor(srgbRed: 0xBF/255, green: 0xBF/255, blue: 0xBF/255, alpha: 1).cgColor)
            ctx.setLineWidth(0.6)
            ctx.stroke(rect)
            ctx.move(to: CGPoint(x: ml + colX, y: y - rowH)); ctx.addLine(to: CGPoint(x: ml + colX, y: y)); ctx.strokePath()
            for (ci, cell) in row.enumerated() {
                let cx = ci == 0 ? ml + 6 : ml + colX + 6
                let cw = (ci == 0 ? colX : contentWidth - colX) - 12
                let a = NSAttributedString(string: cell, attributes: [
                    .font: font(10, bold: isHeader), .foregroundColor: ink,
                    .paragraphStyle: { let p = NSMutableParagraphStyle(); return p }()])
                let h = ceil(CTFramesetterSuggestFrameSizeWithConstraints(
                    CTFramesetterCreateWithAttributedString(a), CFRange(location: 0, length: 0), nil,
                    CGSize(width: cw, height: .greatestFiniteMagnitude), nil).height)
                _ = draw(a, x: cx, width: cw, bottomLimit: y - (rowH - h)/2)
            }
            y -= rowH
        }
        y -= 6
    default:
        break
    }
}
ctx.endPDFPage()
ctx.closePDF()
try! pdf.write(to: URL(fileURLWithPath: pdfPath))
print("pages=\(pageIndex + 1) bytes=\(pdf.length)")
