"""把 dist/安装与使用.docx 导出为结构化 JSON，供 RenderGuidePDF.swift 排版。

本机没有 LibreOffice 时，用它代替「DOCX → PDF」这一步：
    python3 scripts/guide-to-json.py
    swift scripts/RenderGuidePDF.swift dist/guide.json docs/安装与使用.pdf build/AppIcon.iconset/icon_128x128.png
"""
import json
import sys
from pathlib import Path

import docx
from docx.oxml.ns import qn

ROOT = Path(__file__).resolve().parent.parent
src = ROOT / "dist" / "安装与使用.docx"
out = ROOT / "dist" / "guide.json"


def run_color(run):
    try:
        color = run.font.color
        return str(color.rgb) if color and color.rgb else None
    except Exception:
        return None


def main():
    if not src.exists():
        sys.exit(f"缺少 {src}，先运行 python3 scripts/make_guide.py")

    document = docx.Document(str(src))
    paragraphs, tables = document.paragraphs, document.tables
    blocks = []
    pi = ti = 0

    for child in document.element.body.iterchildren():
        if child.tag == qn("w:p"):
            paragraph = paragraphs[pi]
            pi += 1
            text = paragraph.text.strip()
            if not text:
                blocks.append({"type": "space"})
                continue
            first = paragraph.runs[0] if paragraph.runs else None
            size = first.font.size.pt if first and first.font.size else None
            align = {0: "left", 1: "center", 2: "right"}.get(
                int(paragraph.alignment) if paragraph.alignment is not None else 0, "left")
            if size == 13.0:
                kind = "heading"
            elif first is not None and first.font.name == "Menlo":
                kind = "mono"
            elif text.startswith("•"):
                kind = "bullet"
            else:
                kind = "text"
            blocks.append({
                "type": kind, "text": text, "align": align, "size": size,
                "runs": [{"t": r.text, "b": bool(r.bold), "c": run_color(r),
                          "s": r.font.size.pt if r.font.size else None} for r in paragraph.runs],
            })
        elif child.tag == qn("w:tbl"):
            table = tables[ti]
            ti += 1
            blocks.append({"type": "table", "rows": [[c.text for c in row.cells] for row in table.rows]})

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(blocks, ensure_ascii=False, indent=1), encoding="utf-8")
    print(out)


if __name__ == "__main__":
    main()
