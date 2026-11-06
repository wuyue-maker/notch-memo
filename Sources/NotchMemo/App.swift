import AppKit
import SwiftUI

@main
enum NotchMemoApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        let verification = Bundle.main.object(forInfoDictionaryKey: "NotchMemoVerificationMode") as? Bool == true
        application.setActivationPolicy(verification ? .regular : .accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: PanelController!
    private var model: MemoModel!
    private var statusItem: NSStatusItem!
    private var pinItem: NSMenuItem!
    private var notesMenu: NSMenu!
    private var visibilityItem: NSMenuItem!
    private var newNoteItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        let directory: URL
        if let configured = Bundle.main.object(forInfoDictionaryKey: "NotchMemoDataDirectory") as? String {
            directory = URL(fileURLWithPath: configured, isDirectory: true)
        } else if let index = args.firstIndex(of: "--data-directory"), args.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("NotchMemo", isDirectory: true)
        }
        model = MemoModel(directory: directory)
        controller = PanelController(model: model)
        PaperCrumpleWarmup.prepare()
        configureMainMenu()
        configureMenu()
        if args.contains("--diagnostics") { print(controller.diagnostics()) }
        if args.contains("--preview") || Bundle.main.object(forInfoDictionaryKey: "NotchMemoVerificationMode") as? Bool == true {
            controller.show(fromMenu: true, pin: true)
        }
    }

    private func configureMainMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let applicationMenu = NSMenu(title: "刘海便签")
        applicationMenu.delegate = self
        let newNote = addItem("新建便签", action: #selector(newNote), to: applicationMenu)
        newNote.keyEquivalent = "n"
        newNoteItems.append(newNote)
        let about = addItem("关于刘海便签", action: #selector(about), to: applicationMenu)
        about.keyEquivalent = ""
        let notes = NSMenuItem(title: "我的便签", action: nil, keyEquivalent: "")
        notes.submenu = makeNotesMenu()
        applicationMenu.addItem(notes)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出刘海便签", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationMenu.addItem(quit)
        application.submenu = applicationMenu
        main.addItem(application)
        let editing = NSMenuItem()
        let editingMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [
            ("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
            ("剪切", "cut:", "x"), ("拷贝", "copy:", "c"),
            ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")
        ] {
            editingMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        editing.submenu = editingMenu
        main.addItem(editing)
        NSApp.mainMenu = main
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "checklist", accessibilityDescription: "刘海便签")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "刘海便签 · 靠近刘海即可展开"
        let menu = NSMenu()
        menu.delegate = self
        newNoteItems.append(addItem("新建便签", action: #selector(newNote), to: menu))
        visibilityItem = addItem("展开便签", action: #selector(toggleVisibility), to: menu)
        pinItem = addItem("固定展开", action: #selector(togglePin), to: menu)
        menu.addItem(.separator())
        let notesItem = NSMenuItem(title: "我的便签", action: nil, keyEquivalent: "")
        notesMenu = makeNotesMenu()
        notesItem.submenu = notesMenu
        menu.addItem(notesItem)
        menu.addItem(.separator())
        addItem("关于刘海便签", action: #selector(about), to: menu)
        addItem("打开数据文件夹", action: #selector(openData), to: menu)
        addItem("复制运行信息", action: #selector(copyDiagnostics), to: menu)
        menu.addItem(.separator())
        let quit = addItem("退出刘海便签", action: #selector(quit), to: menu)
        quit.keyEquivalent = "q"
        statusItem.menu = menu
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func makeNotesMenu() -> NSMenu {
        let menu = NSMenu(title: "我的便签")
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pinItem?.state = model.isPinned ? .on : .off
        visibilityItem?.title = model.isPresented ? "收起便签" : "展开便签"
        newNoteItems.forEach { $0.isEnabled = !model.storageBlocked }
        guard menu.title == "我的便签" else { return }
        menu.autoenablesItems = false
        menu.removeAllItems()
        let ongoingTitle = NSMenuItem(title: "进行中", action: nil, keyEquivalent: "")
        ongoingTitle.isEnabled = false
        menu.addItem(ongoingTitle)
        for note in model.inProgressNotes {
            let item = addItem(note.labelName, action: #selector(selectNote(_:)), to: menu)
            item.representedObject = note.id.uuidString
            item.state = model.displayedNote.id == note.id ? .on : .off
        }
        menu.addItem(.separator())
        let historyTitle = NSMenuItem(title: "已归档", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu(title: "已归档")
        historyMenu.autoenablesItems = false
        historyTitle.submenu = historyMenu
        menu.addItem(historyTitle)
        if model.notebook.history.isEmpty {
            let empty = NSMenuItem(title: "暂无归档便签", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
        }
        for note in model.notebook.history.reversed() {
            let label = "\(note.labelName)  \(note.archiveDateLabel)"
            let item = addItem(label, action: #selector(selectNote(_:)), to: historyMenu)
            let font = NSFont.menuFont(ofSize: 0)
            let title = NSMutableAttributedString(string: note.labelName,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            title.append(NSAttributedString(string: "  " + note.archiveDateLabel,
                attributes: [.font: NSFont.menuFont(ofSize: max(10, font.pointSize - 2)),
                             .foregroundColor: NSColor.secondaryLabelColor]))
            item.attributedTitle = title
            item.representedObject = note.id.uuidString
            item.state = model.selectedHistoryID == note.id ? .on : .off
        }
    }
    @objc private func selectNote(_ sender: NSMenuItem) {
        controller.selectNote((sender.representedObject as? String).flatMap(UUID.init(uuidString:)))
    }
    @objc private func newNote() { controller.createNote() }
    @objc private func toggleVisibility() {
        if model.isPresented { controller.hide() }
        else { controller.show(fromMenu: true) }
    }
    @objc private func togglePin() {
        if model.isPinned { model.isPinned = false }
        else { controller.show(fromMenu: true, pin: true) }
    }
    @objc private func about() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        let alert = NSAlert()
        alert.messageText = "刘海便签 \(version)"
        alert.informativeText = """
        鼠标移到刘海下沿即可展开的常驻任务便签。
        构建 \(build) · \(ProcessInfo.processInfo.operatingSystemVersionString)
        数据目录：\(model.repository.directory.path)
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func openData() {
        do { try FileManager.default.createDirectory(at: model.repository.directory, withIntermediateDirectories: true) }
        catch { model.banner = "无法打开数据目录：\(error.localizedDescription)"; controller.show(fromMenu: true); return }
        model.revealDataFolder()
    }
    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.diagnostics(), forType: .string)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.panel.makeFirstResponder(nil)
        if !model.storageBlocked { model.persist() }
        guard model.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "有任务尚未保存"
        alert.informativeText = "请先重试保存，或选择退出并放弃本次尚未写入的更改。"
        alert.addButton(withTitle: "继续使用")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show(fromMenu: true)
        return true
    }
}
