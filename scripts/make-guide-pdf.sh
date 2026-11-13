#!/bin/zsh
# 重新生成发行版 PDF 说明书（DMG 内附带的那份）。
# 原先依赖 LibreOffice 导出 PDF；本机没有时改用 python-docx 读结构 + Swift/CoreText 排版，
# 输出保持 A4、与 DOCX 同版式。有 LibreOffice 时优先用它，保真度最高。
set -euo pipefail
cd "${0:A:h:h}"

docx="dist/安装与使用.docx"
pdf="docs/安装与使用.pdf"
icon="build/AppIcon.iconset/icon_128x128.png"

python="$(command -v python3)"
if ! "$python" -c "import docx" >/dev/null 2>&1; then
  python="${DSH_PYTHON:-/Users/wuyue/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3}"
fi

"$python" scripts/make_guide.py

if command -v soffice >/dev/null 2>&1; then
  print "用 LibreOffice 导出 PDF"
  soffice --headless --convert-to pdf --outdir dist "$docx" >/dev/null
  cp "dist/安装与使用.pdf" "$pdf"
else
  print "未找到 LibreOffice，改用 Swift + CoreText 排版"
  "$python" scripts/guide-to-json.py
  if [[ ! -f "$icon" ]]; then
    print -u2 "缺少图标 $icon，先运行 zsh scripts/build.sh"
    exit 1
  fi
  mkdir -p .build/pdfcache
  CLANG_MODULE_CACHE_PATH="$PWD/.build/pdfcache" \
    swiftc -O -module-cache-path "$PWD/.build/pdfcache" \
    scripts/RenderGuidePDF.swift -o .build/render-guide
  .build/render-guide dist/guide.json "$pdf" "$icon"
fi

print "已生成：$pdf"
