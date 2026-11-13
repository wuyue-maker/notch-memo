# 上传到 GitHub

仓库内容已整理好：README、MIT 许可证、`.gitignore`、文档、截图、安装包生成脚本都在。安装包本身（`dist/`）不会进入 git，作为 Release 附件上传。

仓库地址：`https://github.com/wuyue-maker/notch-memo`（已初始化并推送过 0.1.29）。

## 1. 仓库信息

仓库已建好，下面是当时填写的建议值，改名或换账号时同步修改命令里的地址。

- 仓库名：`notch-memo`
- 描述：`一张住在 MacBook 刘海里的任务便签 · macOS 14+ · SwiftUI + AppKit + Metal`
- 可见性：公开或私有都可以

Topics：

```
macos swift swiftui appkit metal menubar notch macbook productivity todo
```

## 2. 推送源码

本项目已是独立仓库（`git rev-parse --show-toplevel` 指向项目目录本身），`origin` 也已配置好，日常只需提交并推送：

```sh
cd "/Users/wuyue/资源（软件）/这是ai coding/cursor/项目/桌面插件 任务标签 备忘录"

git add -A
git commit -m "刘海便签 0.1.30"
git push origin main
```

首次在新机器上克隆或重配远端时：

```sh
git remote add origin https://github.com/wuyue-maker/notch-memo.git
```

> 父目录 `cursor` 本身也是一个仓库；项目目录已是独立仓库，父仓库会把它当作嵌套仓库，互不影响。

## 3. 创建 Release（上传安装包）

0.1.29 的 Release 已发布，0.1.30 发布前需要先完成第 5 节的打包与校验：

1. GitHub 仓库 → Releases → Draft a new release。
2. Tag：`v0.1.30`；标题：`刘海便签 0.1.30`。
3. 说明直接粘贴 [docs/发布说明-0.1.30.md](docs/发布说明-0.1.30.md) 的内容。
4. 上传附件：`dist/NotchMemo-0.1.30.dmg`。
5. 发布。

README 里的 `Releases` 链接会指向本仓库的 Releases 页面，下载文件名与安装说明一致。

## 4. 需要的话也可以只上传源码

`dist/notch-memo-<版本>-source.zip` 是同一套仓库文件的压缩包（不含安装包和构建产物），适合在 GitHub 网页上直接拖拽上传。用 git 推送时不需要它。

## 5. 发布前检查

- `git status` 里不应出现 `build/`、`dist/`、`.build/`、`数据备份`、`.DS_Store`；
- 确认 README 顶部的版本号和 `Resources/Info.plist` 一致（当前 0.1.30，构建号 31）；
- `docs/安装与使用.pdf` 是打包进 DMG 的说明书。`scripts/make_guide.py` 已加入开机自启章节，但导出 PDF 需要 LibreOffice，当前环境未安装；发版前先补导出，否则 DMG 里的说明书仍是旧版；
- Release 附件的 SHA-256 与 `docs/发布说明-0.1.30.md` 中一致（当前该行仍待 `zsh scripts/package-dmg.sh` 打印后回填）；
- 许可证按你的意愿选择，当前为 MIT，可在 `LICENSE` 中修改版权人。

## 6. 开机自启的发布验证

0.1.30 新增的开机自启由系统登录项（`SMAppService`）管理，装到「应用程序」后可这样核对：

```sh
# 查看当前状态
/Applications/刘海便签.app/Contents/MacOS/NotchMemo --launch-at-login status

# 开启 / 关闭
/Applications/刘海便签.app/Contents/MacOS/NotchMemo --launch-at-login on
/Applications/刘海便签.app/Contents/MacOS/NotchMemo --launch-at-login off

# 确认系统登记的登录项
sfltool dumpbtm | grep -A8 "local.notchmemo.app"
```

`on` 之后 `Disposition` 应为 `[enabled, allowed, notified]`，`off` 之后应为 `[disabled, ...]`。

注意：登录项状态以系统为准。如果「系统设置 → 通用 → 登录项与扩展」面板开着，在里面手动开关会直接改变状态，菜单下次打开时显示的就是新的系统状态。这属于预期行为。

发版后还需重启一次确认登录时真的自动打开；`docs/验证记录.md` 里记录了这项待验证项。
