# 上传到 GitHub

仓库内容已整理好：README、MIT 许可证、`.gitignore`、文档、截图、安装包生成脚本都在。安装包本身（`dist/`）不会进入 git，作为 Release 附件上传。

## 1. 新建仓库

本地 `gh` 配置里的账号是 `wuyue-maker`，下面直接按这个账号写；如果换账号或换仓库名，把命令里的地址一起改掉。

在 GitHub 新建一个空仓库，建议：

- 仓库名：`notch-memo`
- 描述：`一张住在 MacBook 刘海里的任务便签 · macOS 14+ · SwiftUI + AppKit + Metal`
- 可见性：公开或私有都可以
- **不要**勾选自动生成 README、.gitignore、License（本地已经有）

Topics 建议：

```
macos swift swiftui appkit metal menubar notch macbook productivity todo
```

## 2. 推送源码

项目目录目前位于一个更大的本地仓库下面，直接在本项目里初始化独立仓库即可：

```sh
cd "你的本地项目目录（含 Package.swift 的这一层）"

git init -b main
git config user.name "你的名字"
git config user.email "你的 GitHub 邮箱"
git add .
git commit -m "刘海便签 0.1.29"

git remote add origin git@github.com:wuyue-maker/notch-memo.git
git push -u origin main
```

如果还没配置 SSH，也可以使用 HTTPS：

```sh
git remote add origin https://github.com/wuyue-maker/notch-memo.git
```

> 父目录本身也是一个空仓库；在项目内初始化独立仓库后，父仓库会把它当作一个未跟踪的嵌套仓库。若不需要父目录的 git，可以忽略。

## 3. 创建 Release（上传安装包）

1. GitHub 仓库 → Releases → Draft a new release。
2. Tag：`v0.1.29`；标题：`刘海便签 0.1.29`。
3. 说明直接粘贴 [docs/发布说明-0.1.29.md](docs/发布说明-0.1.29.md) 的内容。
4. 上传附件：`dist/NotchMemo-0.1.29.dmg`。
5. 发布。

README 里的 `Releases` 链接会指向本仓库的 Releases 页面，下载文件名与安装说明一致。

## 4. 需要的话也可以只上传源码

`dist/notch-memo-0.1.29-source.zip` 是同一套仓库文件的压缩包（不含安装包和构建产物），适合在 GitHub 网页上直接拖拽上传。用 git 推送时不需要它。

## 5. 发布前检查

- `git status` 里不应出现 `build/`、`dist/`、`.build/`、`数据备份`、`.DS_Store`；
- 确认 README 顶部的版本号和 `Resources/Info.plist` 一致（当前 0.1.29）；
- Release 附件的 SHA-256 与 `docs/发布说明-0.1.29.md` 中一致；
- 许可证按你的意愿选择，当前为 MIT，可在 `LICENSE` 中修改版权人。

> 说明：当前运行环境访问 github.com 超时，我无法代你推送。上面的命令在你的终端或 GitHub Desktop 里执行即可；如果之后网络恢复并把仓库地址发我，我也可以继续处理 Release。
