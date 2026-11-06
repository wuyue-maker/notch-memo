"""Generate the install/usage guide that ships inside the DMG.

Run with the bundled Python (python-docx) and export the PDF with LibreOffice:
    python3 scripts/make_guide.py
"""

from pathlib import Path

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "dist" / "安装与使用.docx"
ICON = ROOT / "Resources" / "AppIcon.iconset" / "icon_128x128.png"
if not ICON.exists():
    ICON = ROOT / "build" / "AppIcon.iconset" / "icon_128x128.png"

INK = RGBColor(0x2C, 0x2E, 0x2A)
MUTED = RGBColor(0x6E, 0x6C, 0x60)
ACCENT = RGBColor(0x9A, 0x47, 0x28)
RULE = "D8D2C4"


def east_asia(run, name="PingFang SC"):
    run.font.name = name
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:eastAsia"), name)


def style_run(run, size, color=INK, bold=False):
    run.font.size = Pt(size)
    run.font.color.rgb = color
    run.bold = bold
    east_asia(run)


def paragraph(doc, text="", size=10.5, color=INK, bold=False, space_before=0,
              space_after=4, line=1.35, align=None):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(space_before)
    p.paragraph_format.space_after = Pt(space_after)
    p.paragraph_format.line_spacing = line
    if align is not None:
        p.alignment = align
    if text:
        style_run(p.add_run(text), size, color, bold)
    return p


def heading(doc, text, number=None):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(14)
    p.paragraph_format.space_after = Pt(5)
    run = p.add_run((f"{number}  " if number else "") + text)
    style_run(run, 13, ACCENT, True)
    # thin rule under the heading
    pPr = p._p.get_or_add_pPr()
    borders = OxmlElement("w:pBdr")
    bottom = OxmlElement("w:bottom")
    bottom.set(qn("w:val"), "single")
    bottom.set(qn("w:sz"), "4")
    bottom.set(qn("w:space"), "2")
    bottom.set(qn("w:color"), RULE)
    borders.append(bottom)
    pPr.append(borders)
    return p


def bullet(doc, text, bold_prefix=None):
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Cm(0.55)
    p.paragraph_format.first_line_indent = Cm(-0.35)
    p.paragraph_format.space_before = Pt(0)
    p.paragraph_format.space_after = Pt(2.5)
    p.paragraph_format.line_spacing = 1.3
    style_run(p.add_run("•  "), 10.5, ACCENT, True)
    if bold_prefix:
        style_run(p.add_run(bold_prefix), 10.5, INK, True)
    style_run(p.add_run(text), 10.5, INK)
    return p


def mono(doc, text):
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Cm(0.55)
    p.paragraph_format.space_before = Pt(2)
    p.paragraph_format.space_after = Pt(6)
    run = p.add_run(text)
    run.font.size = Pt(9)
    run.font.color.rgb = MUTED
    east_asia(run, "Menlo")
    run.font.name = "Menlo"
    return p


def shade(cell, color):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:fill"), color)
    tcPr.append(shd)


def main():
    doc = Document()
    section = doc.sections[0]
    section.page_height = Cm(29.7)
    section.page_width = Cm(21.0)
    section.top_margin = Cm(2.0)
    section.bottom_margin = Cm(2.0)
    section.left_margin = Cm(2.2)
    section.right_margin = Cm(2.2)

    normal = doc.styles["Normal"]
    normal.font.name = "PingFang SC"
    normal.font.size = Pt(10.5)
    normal.element.rPr.rFonts.set(qn("w:eastAsia"), "PingFang SC")

    if ICON.exists():
        p = doc.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_after = Pt(6)
        p.add_run().add_picture(str(ICON), width=Cm(1.6))

    title = doc.add_paragraph()
    title.alignment = WD_ALIGN_PARAGRAPH.CENTER
    title.paragraph_format.space_after = Pt(2)
    style_run(title.add_run("刘海便签"), 25, INK, True)

    sub = doc.add_paragraph()
    sub.alignment = WD_ALIGN_PARAGRAPH.CENTER
    sub.paragraph_format.space_after = Pt(10)
    style_run(sub.add_run("安装与使用  ·  0.1.29"), 10, MUTED)

    paragraph(doc, "一个驻留在 MacBook 刘海里的任务便签：平时完全隐藏，鼠标靠近屏幕顶部即刻展开；"
                   "记任务、勾完成、拖排序，全部完成后纸面揉成纸团归档。",
              size=10.5, color=MUTED, align=WD_ALIGN_PARAGRAPH.CENTER, space_after=8)

    heading(doc, "安装", "1")
    bullet(doc, "双击打开安装包 刘海便签-0.1.29.dmg。")
    bullet(doc, "把「刘海便签」拖进「应用程序」文件夹，然后推出磁盘映像。")

    heading(doc, "首次打开", "2")
    bullet(doc, "本版本使用本机临时签名，未经过 Apple 公证。首次请到「应用程序」里"
                "右键点「刘海便签」→「打开」，在系统提示中再点一次「打开」。之后可直接双击。")
    bullet(doc, "如果右键菜单里没有「打开」，到「系统设置 → 隐私与安全性」点「仍要打开」；"
                "也可以在「终端」执行下面的命令后再打开：")
    mono(doc, "xattr -dr com.apple.quarantine /Applications/刘海便签.app")

    heading(doc, "日常使用", "3")
    bullet(doc, "启动后没有 Dock 图标，菜单栏会出现清单图标。")
    bullet(doc, "把鼠标移到屏幕最顶部、刘海下沿附近，停留约 0.3 秒，便签展开；"
                "鼠标移开后自动收起。")
    bullet(doc, "在底部输入框输入任务，按回车添加；点左侧圆圈完成任务，"
                "点任务文字可展开全文。")
    bullet(doc, "按住任务右侧的六点手柄拖动可调整顺序；只在这个手柄上才能拖动。")
    bullet(doc, "点顶部图钉可固定展开；点「收起」或按 Esc 收起。")
    bullet(doc, "全部任务勾完后，纸面会揉成纸团归档，并自动打开下一张空白便签。")
    bullet(doc, "菜单栏「我的便签」可以切换进行中的便签、查看已归档便签。")

    doc.add_page_break()
    heading(doc, "快捷键", "4")
    table = doc.add_table(rows=1, cols=2)
    table.style = "Table Grid"
    table.alignment = WD_TABLE_ALIGNMENT.LEFT
    table.autofit = True
    header = table.rows[0].cells
    for cell, text in zip(header, ("快捷键", "作用")):
        cell.text = ""
        run = cell.paragraphs[0].add_run(text)
        style_run(run, 10, INK, True)
        shade(cell, "F1ECE2")
    for keys, action in (("⌘N", "新建便签"), ("Esc", "收起便签"),
                         ("⌘Q", "退出刘海便签"), ("⌘Z / ⇧⌘Z", "编辑文字时撤销 / 重做")):
        cells = table.add_row().cells
        for cell, text in zip(cells, (keys, action)):
            cell.text = ""
            style_run(cell.paragraphs[0].add_run(text), 10, INK)

    heading(doc, "数据与备份", "5")
    bullet(doc, "任务只保存在本机，不需要登录，也不会上传网络：")
    mono(doc, "~/Library/Application Support/NotchMemo/tasks.json")
    bullet(doc, "菜单栏 →「打开数据文件夹」可以直接查看；每次保存都会保留上一版 "
                "tasks.backup.json。")

    heading(doc, "卸载", "6")
    bullet(doc, "从菜单栏退出便签，删除「应用程序」里的刘海便签即可。")
    bullet(doc, "如果还要清空任务，删除上面提到的 NotchMemo 数据文件夹。")

    heading(doc, "系统要求与已知限制", "7")
    bullet(doc, "需要 macOS 14 或更高版本（Apple Silicon / arm64）；为带刘海的 MacBook 设计，"
                "无刘海屏幕上热区位于屏幕顶部中央。")
    bullet(doc, "全屏应用和多个 Spaces 下都能唤出；合盖或只接外接屏时使用主屏幕。")
    bullet(doc, "遵循系统「减少动态效果」；纸面固定浅色以保持纸张质感。")
    bullet(doc, "当前为本机临时签名版本，未做 Apple 公证；暂不含开机自启动和 iCloud 同步。")

    paragraph(doc, "更完整的说明见项目仓库的 docs/ 目录（产品方案、使用说明、验证记录）。",
              size=9, color=MUTED, space_before=10)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    doc.save(OUT)
    print(OUT)


if __name__ == "__main__":
    main()
