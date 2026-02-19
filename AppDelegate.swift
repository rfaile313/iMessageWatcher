import Cocoa
import SQLite3
import EventKit

// ════════════════════════════════════════════════════════════════════
// MARK: - Data Models
// ════════════════════════════════════════════════════════════════════

struct LLMResponse: Codable {
    let items: [LLMItem]
}

struct LLMItem: Codable {
    let type: String            // "event" or "task"
    let title: String
    let start: String?          // ISO 8601 for events
    let end: String?            // ISO 8601 for events
    let all_day: Bool?          // for events
    let due_minutes: Int?       // for tasks
}

// ════════════════════════════════════════════════════════════════════
// MARK: - Settings
// ════════════════════════════════════════════════════════════════════

final class Settings {
    static let shared = Settings()

    private let d = UserDefaults.standard

    private enum Key: String {
        case contactPhone       = "contactPhone"
        case pollInterval       = "pollInterval"
        case ollamaModel        = "ollamaModel"
        case ntfyTopic          = "ntfyTopic"
        case calendarID         = "calendarID"
        case useCalendar        = "useCalendar"
        case useDueReminders    = "useDueReminders"
        case useAppleReminders  = "useAppleReminders"
        case useNtfy            = "useNtfy"
        case contextCount       = "contextCount"
        case reminderListID     = "reminderListID"
    }

    private init() {
        d.register(defaults: [
            Key.contactPhone.rawValue:    "",
            Key.pollInterval.rawValue:    60.0,
            Key.ollamaModel.rawValue:     "deepseek-r1:latest",
            Key.ntfyTopic.rawValue:       "",
            Key.calendarID.rawValue:      "",
            Key.useCalendar.rawValue:     true,
            Key.useDueReminders.rawValue: false,
            Key.useAppleReminders.rawValue: false,
            Key.useNtfy.rawValue:         false,
            Key.contextCount.rawValue:    5,
            Key.reminderListID.rawValue:  "",
        ])
    }

    var contactPhone: String {
        get { d.string(forKey: Key.contactPhone.rawValue) ?? "" }
        set { d.set(newValue, forKey: Key.contactPhone.rawValue) }
    }
    var pollInterval: TimeInterval {
        get { d.double(forKey: Key.pollInterval.rawValue) }
        set { d.set(newValue, forKey: Key.pollInterval.rawValue) }
    }
    var ollamaModel: String {
        get { d.string(forKey: Key.ollamaModel.rawValue) ?? "" }
        set { d.set(newValue, forKey: Key.ollamaModel.rawValue) }
    }
    var ntfyTopic: String {
        get { d.string(forKey: Key.ntfyTopic.rawValue) ?? "" }
        set { d.set(newValue, forKey: Key.ntfyTopic.rawValue) }
    }
    var calendarID: String {
        get { d.string(forKey: Key.calendarID.rawValue) ?? "" }
        set { d.set(newValue, forKey: Key.calendarID.rawValue) }
    }
    var useCalendar: Bool {
        get { d.bool(forKey: Key.useCalendar.rawValue) }
        set { d.set(newValue, forKey: Key.useCalendar.rawValue) }
    }
    var useDueReminders: Bool {
        get { d.bool(forKey: Key.useDueReminders.rawValue) }
        set { d.set(newValue, forKey: Key.useDueReminders.rawValue) }
    }
    var useAppleReminders: Bool {
        get { d.bool(forKey: Key.useAppleReminders.rawValue) }
        set { d.set(newValue, forKey: Key.useAppleReminders.rawValue) }
    }
    var reminderListID: String {
        get { d.string(forKey: Key.reminderListID.rawValue) ?? "" }
        set { d.set(newValue, forKey: Key.reminderListID.rawValue) }
    }
    var useNtfy: Bool {
        get { d.bool(forKey: Key.useNtfy.rawValue) }
        set { d.set(newValue, forKey: Key.useNtfy.rawValue) }
    }
    var contextCount: Int {
        get { d.integer(forKey: Key.contextCount.rawValue) }
        set { d.set(newValue, forKey: Key.contextCount.rawValue) }
    }
}

// ════════════════════════════════════════════════════════════════════
// MARK: - Logger
// ════════════════════════════════════════════════════════════════════

final class Logger {
    enum Level: String { case DEBUG, INFO, WARN, ERROR }

    static let shared = Logger()

    let logFilePath: String = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("iMessageWatcher.log").path
    }()

    private let queue = DispatchQueue(label: "com.imessagewatcher.logger")

    func log(_ msg: String, level: Level = .INFO) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(f.string(from: Date()))] [\(level.rawValue)] \(msg)\n"
        print("[\(level.rawValue)] \(msg)")
        queue.async {
            if let h = FileHandle(forWritingAtPath: self.logFilePath) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                h.closeFile()
            } else {
                FileManager.default.createFile(atPath: self.logFilePath,
                                                contents: line.data(using: .utf8))
            }
        }
    }
}

private func log(_ msg: String, level: Logger.Level = .INFO) {
    Logger.shared.log(msg, level: level)
}

private func cleanAndValidatePhone(_ input: String) -> String? {
    let digits = input.filter { $0.isNumber }
    guard digits.count == 10 else { return nil }
    return digits
}

// ════════════════════════════════════════════════════════════════════
// MARK: - Preferences Window
// ════════════════════════════════════════════════════════════════════

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let eventStore: EKEventStore
    private var calendarPopup: NSPopUpButton!
    private var reminderPopup: NSPopUpButton!

    init(eventStore: EKEventStore) {
        self.eventStore = eventStore
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        w.title = "iMessageWatcher Preferences"
        w.isReleasedWhenClosed = false
        w.center()
        super.init(window: w)
        w.delegate = self
        buildUI()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let s = Settings.shared

        var y: CGFloat = 340

        func addRow(_ label: String, _ field: NSView) {
            let lbl = NSTextField(labelWithString: label)
            lbl.frame = NSRect(x: 20, y: y, width: 140, height: 22)
            lbl.alignment = .right
            content.addSubview(lbl)
            field.frame = NSRect(x: 170, y: y, width: 250, height: 24)
            content.addSubview(field)
            y -= 40
        }

        let phoneField = NSTextField(string: s.contactPhone)
        phoneField.tag = 1
        phoneField.target = self
        phoneField.action = #selector(fieldChanged(_:))
        addRow("Contact Phone:", phoneField)

        let intervalField = NSTextField(string: "\(Int(s.pollInterval))")
        intervalField.tag = 2
        intervalField.target = self
        intervalField.action = #selector(fieldChanged(_:))
        addRow("Poll Interval (s):", intervalField)

        let modelField = NSTextField(string: s.ollamaModel)
        modelField.tag = 3
        modelField.target = self
        modelField.action = #selector(fieldChanged(_:))
        addRow("Ollama Model:", modelField)

        let ntfyField = NSTextField(string: s.ntfyTopic)
        ntfyField.tag = 4
        ntfyField.target = self
        ntfyField.action = #selector(fieldChanged(_:))
        addRow("ntfy Topic:", ntfyField)

        // Calendar picker
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.tag = 5
        popup.target = self
        popup.action = #selector(calendarChanged(_:))
        calendarPopup = popup
        populateCalendars()
        addRow("Calendar:", popup)

        // Reminder list picker
        let remPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        remPopup.tag = 6
        remPopup.target = self
        remPopup.action = #selector(reminderListChanged(_:))
        reminderPopup = remPopup
        populateReminderLists()
        addRow("Reminder List:", remPopup)
    }

    private func populateCalendars() {
        calendarPopup.removeAllItems()
        let calendars = eventStore.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .sorted { $0.title < $1.title }
        calendarPopup.addItem(withTitle: "(Default)")
        calendarPopup.item(at: 0)?.representedObject = "" as NSString
        for cal in calendars {
            calendarPopup.addItem(withTitle: cal.title)
            calendarPopup.lastItem?.representedObject = cal.calendarIdentifier as NSString
        }
        // Select current
        let currentID = Settings.shared.calendarID
        if let idx = (0..<calendarPopup.numberOfItems).first(where: {
            (calendarPopup.item(at: $0)?.representedObject as? String) == currentID
        }) {
            calendarPopup.selectItem(at: idx)
        }
    }

    @objc private func fieldChanged(_ sender: NSTextField) {
        let s = Settings.shared
        switch sender.tag {
        case 1:
            let raw = sender.stringValue
            if let cleaned = cleanAndValidatePhone(raw) {
                s.contactPhone = cleaned
                sender.stringValue = cleaned
            } else if raw.isEmpty {
                s.contactPhone = ""
            } else {
                sender.stringValue = s.contactPhone
                let a = NSAlert()
                a.messageText = "Invalid Phone Number"
                a.informativeText = "Enter exactly 10 digits."
                a.alertStyle = .warning
                a.runModal()
            }
        case 2: s.pollInterval = max(10, Double(sender.stringValue) ?? 60)
        case 3: s.ollamaModel = sender.stringValue
        case 4: s.ntfyTopic = sender.stringValue
        default: break
        }
    }

    private func populateReminderLists() {
        reminderPopup.removeAllItems()
        let lists = eventStore.calendars(for: .reminder)
            .filter { $0.allowsContentModifications }
            .sorted { $0.title < $1.title }
        reminderPopup.addItem(withTitle: "(Default)")
        reminderPopup.item(at: 0)?.representedObject = "" as NSString
        for list in lists {
            reminderPopup.addItem(withTitle: list.title)
            reminderPopup.lastItem?.representedObject = list.calendarIdentifier as NSString
        }
        let currentID = Settings.shared.reminderListID
        if let idx = (0..<reminderPopup.numberOfItems).first(where: {
            (reminderPopup.item(at: $0)?.representedObject as? String) == currentID
        }) {
            reminderPopup.selectItem(at: idx)
        }
    }

    @objc private func reminderListChanged(_ sender: NSPopUpButton) {
        if let id = sender.selectedItem?.representedObject as? String {
            Settings.shared.reminderListID = id
        }
    }

    @objc private func calendarChanged(_ sender: NSPopUpButton) {
        if let id = sender.selectedItem?.representedObject as? String {
            Settings.shared.calendarID = id
        }
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .preferencesDidClose, object: nil)
    }
}

extension Notification.Name {
    static let preferencesDidClose = Notification.Name("preferencesDidClose")
}

// ════════════════════════════════════════════════════════════════════
// MARK: - App Delegate
// ════════════════════════════════════════════════════════════════════

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let ollamaEndpoint = URL(string: "http://localhost:11434/api/chat")!

    private var chatDbPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/Library/Messages/chat.db"
    }
    private var stateFilePath: String {
        FileManager.default.homeDirectoryForCurrentUser.path
            + "/.imessage_watcher_state"
    }

    // State
    private var statusItem  : NSStatusItem!
    private var lastRowId   : Int64 = 0
    private var recentActions: [(String, Date)] = []
    private var isProcessing = false
    private var lastScanTime: Date?
    private var hasUnseenActions = false
    private var hasFullDiskAccess = false
    private var hasShownPermissionAlert = false
    private var ollamaAvailable = false
    private var pollTimer: Timer?
    private var prefsWC: PreferencesWindowController?

    // EventKit
    private let eventStore = EKEventStore()
    private var hasCalendarAccess = false
    private var hasRemindersAccess = false

    // ── Lifecycle ─────────────────────────────────────────────────

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        loadState()

        checkFullDiskAccess()
        requestCalendarAccess()
        requestRemindersAccess()

        if lastRowId == 0 { setBaseline() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            log("Wake detected")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self?.scanMessages()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .preferencesDidClose, object: nil, queue: .main
        ) { [weak self] _ in
            self?.restartTimer()
        }

        refreshOllamaStatus()

        if Settings.shared.contactPhone.isEmpty {
            promptForPhoneNumber()
        }
        if !Settings.shared.contactPhone.isEmpty {
            startTimer()
            scanMessages()
        }
    }

    private func startTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(
            timeInterval: Settings.shared.pollInterval,
            target: self,
            selector: #selector(scanMessages),
            userInfo: nil, repeats: true)
    }

    private func restartTimer() {
        log("Restarting poll timer (interval: \(Int(Settings.shared.pollInterval))s)")
        startTimer()
    }

    // ── Full Disk Access ──────────────────────────────────────────

    private func checkFullDiskAccess() {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(chatDbPath, &db, SQLITE_OPEN_READONLY, nil)
        if rc == SQLITE_OK {
            var stmt: OpaquePointer?
            let canRead = sqlite3_prepare_v2(
                db, "SELECT COUNT(*) FROM message LIMIT 1", -1, &stmt, nil) == SQLITE_OK
            sqlite3_finalize(stmt)
            sqlite3_close(db)
            if canRead {
                hasFullDiskAccess = true
                log("Full Disk Access: OK")
                return
            }
        }
        if db != nil { sqlite3_close(db) }
        hasFullDiskAccess = false
        log("Full Disk Access: DENIED", level: .WARN)
        showPermissionAlert()
    }

    private func showPermissionAlert() {
        guard !hasShownPermissionAlert else { return }
        hasShownPermissionAlert = true

        // Delay slightly so the app finishes launching before we steal focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.messageText = "Full Disk Access Required"
            alert.informativeText = """
                iMessage Watcher needs Full Disk Access to read your messages.

                Click "Open Settings" to go to Privacy & Security, then add \
                this app under Full Disk Access.

                After granting access, relaunch the app.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")

            // Float the alert above all other windows so it can't be missed
            alert.window.level = .floating

            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func promptForPhoneNumber() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Set Up Contact to Monitor"
        alert.informativeText = """
            Enter the 10-digit phone number of the contact whose messages \
            you want to turn into calendar events and reminders.

            You can change this later in Preferences.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        field.placeholderString = "9495551234"
        alert.accessoryView = field
        alert.window.level = .floating
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let cleaned = cleanAndValidatePhone(field.stringValue) {
                Settings.shared.contactPhone = cleaned
                log("Contact phone set to \(cleaned)")
            } else {
                let err = NSAlert()
                err.messageText = "Invalid Phone Number"
                err.informativeText = "Please enter exactly 10 digits."
                err.alertStyle = .warning
                err.runModal()
                promptForPhoneNumber()
                return
            }
        }

        NSApp.setActivationPolicy(.accessory)
    }

    // ── Calendar Access ───────────────────────────────────────────

    private func requestCalendarAccess() {
        eventStore.requestFullAccessToEvents { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.hasCalendarAccess = granted
                if granted {
                    log("Calendar access: OK")
                } else {
                    log("Calendar access: DENIED — \(error?.localizedDescription ?? "")",
                        level: .WARN)
                }
                self?.refreshMenu()
            }
        }
    }

    // ── Reminders Access ─────────────────────────────────────────

    private func requestRemindersAccess() {
        eventStore.requestFullAccessToReminders { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.hasRemindersAccess = granted
                if granted {
                    log("Reminders access: OK")
                } else {
                    log("Reminders access: DENIED — \(error?.localizedDescription ?? "")",
                        level: .WARN)
                }
                self?.refreshMenu()
            }
        }
    }

    // ── Ollama Check ──────────────────────────────────────────────

    private func refreshOllamaStatus() {
        var req = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let ok = data != nil
            DispatchQueue.main.async {
                self?.ollamaAvailable = ok
                self?.refreshMenu()
            }
        }.resume()
    }

    // ── Menu Bar ──────────────────────────────────────────────────

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("bubble.left")
        refreshMenu()
    }

    private func setIcon(_ symbolName: String) {
        guard let btn = statusItem.button else { return }
        if let img = NSImage(systemSymbolName: symbolName,
                             accessibilityDescription: "iMessage Watcher") {
            img.isTemplate = true
            btn.image = img
        } else {
            btn.title = "iMsg"
        }
    }

    private func markUnseen() {
        hasUnseenActions = true
        DispatchQueue.main.async {
            self.setIcon("bubble.left.fill")
            NSSound(named: "Glass")?.play()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if hasUnseenActions {
            hasUnseenActions = false
            setIcon("bubble.left")
        }
    }

    private func refreshMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let s = Settings.shared

        // ── Permission status ──
        menu.addItem(disabled("Permissions:"))
        menu.addItem(disabled("  Full Disk Access: \(hasFullDiskAccess ? "OK" : "DENIED")"))
        menu.addItem(disabled("  Calendar: \(hasCalendarAccess ? "OK" : "DENIED")"))
        menu.addItem(disabled("  Reminders: \(hasRemindersAccess ? "OK" : "DENIED")"))
        menu.addItem(disabled("  Ollama: \(ollamaAvailable ? "OK" : "UNAVAILABLE")"))
        menu.addItem(.separator())

        if Settings.shared.contactPhone.isEmpty {
            menu.addItem(disabled("  \u{26A0} No contact configured — open Preferences"))
            menu.addItem(.separator())
        }

        // ── Toggle switches ──
        let calToggle = NSMenuItem(title: "Use Calendar", action: #selector(toggleCalendar(_:)),
                                   keyEquivalent: "")
        calToggle.target = self
        calToggle.state = s.useCalendar ? .on : .off
        menu.addItem(calToggle)

        let dueToggle = NSMenuItem(title: "Use Due Reminders",
                                   action: #selector(toggleDue(_:)), keyEquivalent: "")
        dueToggle.target = self
        dueToggle.state = s.useDueReminders ? .on : .off
        menu.addItem(dueToggle)

        let appleRemToggle = NSMenuItem(title: "Use Apple Reminders",
                                        action: #selector(toggleAppleReminders(_:)),
                                        keyEquivalent: "")
        appleRemToggle.target = self
        appleRemToggle.state = s.useAppleReminders ? .on : .off
        menu.addItem(appleRemToggle)

        let ntfyToggle = NSMenuItem(title: "Use ntfy Notifications",
                                    action: #selector(toggleNtfy(_:)), keyEquivalent: "")
        ntfyToggle.target = self
        ntfyToggle.state = s.useNtfy ? .on : .off
        menu.addItem(ntfyToggle)

        menu.addItem(.separator())

        // ── Status ──
        if isProcessing {
            menu.addItem(disabled("Scanning…"))
        } else if let t = lastScanTime {
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            menu.addItem(disabled("Last scan: \(f.string(from: t))"))
        }
        menu.addItem(.separator())

        // ── Recent actions ──
        if recentActions.isEmpty {
            menu.addItem(disabled("No recent actions"))
        } else {
            menu.addItem(disabled("Recent:"))
            let f = DateFormatter(); f.dateFormat = "MMM d h:mm a"
            for (action, date) in recentActions.suffix(10).reversed() {
                menu.addItem(disabled("  \(f.string(from: date)) — \(action)"))
            }
        }
        menu.addItem(.separator())

        // ── Actions ──
        let scan = NSMenuItem(title: "Scan Now", action: #selector(scanMessages),
                              keyEquivalent: "r")
        scan.target = self
        menu.addItem(scan)

        let rescan = NSMenuItem(title: "Reprocess Last 5",
                                action: #selector(reprocessLast), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)

        let viewLogs = NSMenuItem(title: "View Logs", action: #selector(openLogs),
                                  keyEquivalent: "l")
        viewLogs.target = self
        menu.addItem(viewLogs)

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferences),
                               keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // ── Toggle Actions ────────────────────────────────────────────

    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        Settings.shared.useCalendar.toggle()
        log("Calendar toggled \(Settings.shared.useCalendar ? "ON" : "OFF")")
        refreshMenu()
    }

    @objc private func toggleDue(_ sender: NSMenuItem) {
        Settings.shared.useDueReminders.toggle()
        log("Due Reminders toggled \(Settings.shared.useDueReminders ? "ON" : "OFF")")
        refreshMenu()
    }

    @objc private func toggleAppleReminders(_ sender: NSMenuItem) {
        Settings.shared.useAppleReminders.toggle()
        log("Apple Reminders toggled \(Settings.shared.useAppleReminders ? "ON" : "OFF")")
        refreshMenu()
    }

    @objc private func toggleNtfy(_ sender: NSMenuItem) {
        Settings.shared.useNtfy.toggle()
        log("ntfy toggled \(Settings.shared.useNtfy ? "ON" : "OFF")")
        refreshMenu()
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Logger.shared.logFilePath))
    }

    @objc private func openPreferences() {
        if prefsWC == nil {
            prefsWC = PreferencesWindowController(eventStore: eventStore)
        }
        prefsWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reprocessLast() {
        // Back up ROWID to re-scan the last 5 messages from the monitored contact
        var db: OpaquePointer?
        guard sqlite3_open_v2(chatDbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_close(db) }
        let phone = Settings.shared.contactPhone
        let sql = """
            SELECT m.ROWID FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE c.chat_identifier LIKE ?
              AND m.text IS NOT NULL AND length(m.text) > 0
              AND m.associated_message_type = 0
              AND m.is_from_me = 0
            ORDER BY m.ROWID DESC LIMIT 5
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let pattern = "%\(phone)"
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
        var minRowId: Int64 = lastRowId
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rid = sqlite3_column_int64(stmt, 0)
            if rid < minRowId { minRowId = rid }
        }
        if minRowId < lastRowId {
            lastRowId = minRowId - 1
            saveState()
            log("Rewound ROWID to \(lastRowId) for reprocessing")
            scanMessages()
        } else {
            log("Nothing to reprocess", level: .WARN)
        }
    }

    // ── Scanning ──────────────────────────────────────────────────

    @objc func scanMessages() {
        guard !Settings.shared.contactPhone.isEmpty else {
            log("No contact phone configured — skipping scan", level: .WARN)
            return
        }
        guard !isProcessing else { return }
        isProcessing = true
        refreshOllamaStatus()
        DispatchQueue.main.async { self.refreshMenu() }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer {
                isProcessing = false
                lastScanTime = Date()
                DispatchQueue.main.async { self.refreshMenu() }
            }

            let newMessages = fetchMessages(
                where: "m.ROWID > ?", params: [.int64(lastRowId)], includeOwn: true)

            guard !newMessages.isEmpty else { return }
            log("Processing \(newMessages.count) new message(s)")

            let context = fetchMessages(
                where: "m.ROWID < ?",
                params: [.int64(newMessages.first!.rowId)],
                includeOwn: true,
                limit: Settings.shared.contextCount,
                descending: true
            ).reversed()

            guard let items = classify(
                context: Array(context), newMessages: newMessages) else {
                log("Classification failed — will retry next poll", level: .WARN)
                return
            }

            var report: [String] = []
            for item in items {
                switch item.type {
                case "event":
                    if Settings.shared.useCalendar {
                        if createCalendarEvent(item) {
                            let a = "Event: \(item.title)"
                            DispatchQueue.main.async { self.recentActions.append((a, Date())) }
                            report.append(a)
                            log(a)
                        }
                    } else {
                        log("Skipping event (Calendar disabled): \(item.title)", level: .DEBUG)
                    }

                case "task":
                    var taskHandled = false
                    if Settings.shared.useDueReminders {
                        if openDueReminder(item) {
                            let a = "Due Reminder: \(item.title)"
                            DispatchQueue.main.async { self.recentActions.append((a, Date())) }
                            report.append(a)
                            log(a)
                            taskHandled = true
                        }
                    }
                    if Settings.shared.useAppleReminders {
                        if createAppleReminder(item) {
                            let a = "Apple Reminder: \(item.title)"
                            DispatchQueue.main.async { self.recentActions.append((a, Date())) }
                            report.append(a)
                            log(a)
                            taskHandled = true
                        }
                    }
                    if !taskHandled {
                        log("Skipping task (no reminder system enabled): \(item.title)",
                            level: .DEBUG)
                    }

                default:
                    log("Unknown item type '\(item.type)': \(item.title)", level: .WARN)
                }
            }

            lastRowId = newMessages.last!.rowId
            saveState()

            if !report.isEmpty {
                if Settings.shared.useNtfy { sendNtfy(report) }
                markUnseen()
            }

            DispatchQueue.main.async {
                if self.recentActions.count > 50 {
                    self.recentActions = Array(self.recentActions.suffix(50))
                }
            }
        }
    }

    // ── SQLite ────────────────────────────────────────────────────

    struct Message {
        let rowId: Int64
        let text: String
        let date: String
        let isFromMe: Bool
    }

    enum SQLParam {
        case int64(Int64)
        case string(String)
    }

    private func fetchMessages(
        where clause: String,
        params: [SQLParam],
        includeOwn: Bool,
        limit: Int? = nil,
        descending: Bool = false
    ) -> [Message] {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(chatDbPath, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK else {
            let errMsg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            log("Cannot open chat.db (rc=\(rc)): \(errMsg)", level: .ERROR)
            if db != nil { sqlite3_close(db) }
            if !hasShownPermissionAlert {
                DispatchQueue.main.async { self.showPermissionAlert() }
            }
            return []
        }
        defer { sqlite3_close(db) }

        let phone = Settings.shared.contactPhone
        var sql = """
            SELECT m.ROWID,
                   m.text,
                   datetime(m.date / 1000000000 + 978307200, 'unixepoch', 'localtime'),
                   m.is_from_me
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE c.chat_identifier LIKE ?
              AND m.text IS NOT NULL AND length(m.text) > 0
              AND m.associated_message_type = 0
            """
        if !includeOwn { sql += "  AND m.is_from_me = 0\n" }
        sql += "  AND \(clause)\n"
        sql += "ORDER BY m.ROWID \(descending ? "DESC" : "ASC")\n"
        if let n = limit { sql += "LIMIT \(n)\n" }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("SQL error: \(String(cString: sqlite3_errmsg(db!)))", level: .ERROR)
            return []
        }
        defer { sqlite3_finalize(stmt) }

        // Bind parameters: first is the phone LIKE pattern
        let phonePattern = "%\(phone)"
        sqlite3_bind_text(stmt, 1, (phonePattern as NSString).utf8String, -1, nil)

        // Bind extra params starting at index 2
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 2)
            switch p {
            case .int64(let v):  sqlite3_bind_int64(stmt, idx, v)
            case .string(let v): sqlite3_bind_text(stmt, idx, (v as NSString).utf8String, -1, nil)
            }
        }

        var out: [Message] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cText = sqlite3_column_text(stmt, 1),
                  let cDate = sqlite3_column_text(stmt, 2) else { continue }
            out.append(Message(
                rowId: sqlite3_column_int64(stmt, 0),
                text: String(cString: cText),
                date: String(cString: cDate),
                isFromMe: sqlite3_column_int(stmt, 3) != 0))
        }
        return out
    }

    private func setBaseline() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(chatDbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(ROWID) FROM message",
                                  -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            lastRowId = sqlite3_column_int64(stmt, 0)
            saveState()
            log("Baseline set to ROWID \(lastRowId)")
        }
    }

    // ── LLM Classification ────────────────────────────────────────

    private func classify(context: [Message], newMessages: [Message]) -> [LLMItem]? {
        var transcript = ""
        for m in context {
            transcript += "[\(m.isFromMe ? "me" : "them")] \(m.text)\n"
        }
        transcript += "--- NEW ---\n"
        for m in newMessages {
            transcript += "[\(m.isFromMe ? "me" : "them")] \(m.text)\n"
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let now = df.string(from: Date())

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEEE"
        let dayOfWeek = dayFmt.string(from: Date())

        let prompt = """
            CRITICAL RULES (follow these exactly):
            - ONLY extract items from NEW [them] messages (after "--- NEW ---")
            - NEVER extract items from context messages (before "--- NEW ---")
            - NEVER extract items from [me] messages
            - If a NEW [them] message is just casual conversation with no dates, plans, or \
            requests, return empty items
            - ONLY return items actually found in the NEW messages. NEVER invent items or \
            copy from these instructions.

            You analyze iMessages between a user and a monitored contact.
            Messages marked [them] are from the monitored contact. Messages marked [me] are from the user.
            Only the messages after "--- NEW ---" are unprocessed.

            Current date/time: \(now) (\(dayOfWeek))
            Current year is \(Calendar.current.component(.year, from: Date())). \
            ALL event dates MUST use this year (or next year for dates clearly in the future).

            For each NEW [them] message, determine if it contains:
            1. "event" — a calendar event: dinner, appointment, birthday, meeting, trip, \
            party, recital, game, etc.
            2. "task" — a request or ask directed at the user: pick up X, call Y, fix Z, \
            buy something, etc.

            Rules:
            - Confirmed or stated plans ARE events ("dinner friday at 7", "dentist tuesday 3pm")
            - Someone asking a question is NOT an event ("should we do dinner friday?")
            - Past tense / memories are NOT events ("remember last week's dinner")
            - Casual conversation, greetings, status updates are NEITHER events nor tasks
            - A single message can contain multiple items
            - For events: provide title, ISO 8601 start/end timestamps (no timezone suffix), \
            and all_day boolean. If no end time, default to 1 hour after start. \
            Use the current date/time above to resolve relative dates like "Tuesday" or "tomorrow".
            - If no specific time is mentioned (just a date like "March 7"), set all_day to true \
            and use T00:00:00 for both start and end.
            - Multi-day events: set start to first day T00:00:00 and end to last day T23:59:00, \
            all_day true.
            - For tasks: provide title and due_minutes (how many minutes from now the reminder \
            should fire, default 30).

            Conversation:
            \(transcript)
            Respond ONLY with valid JSON (no markdown, no commentary). Use this exact schema:
            {"items": [{"type": "event", "title": "Dinner with Smiths", \
            "start": "2025-03-15T19:00:00", "end": "2025-03-15T20:00:00", "all_day": false}]}
            Or for tasks: {"items": [{"type": "task", "title": "Pick up groceries", \
            "due_minutes": 30}]}
            If nothing actionable found: {"items": []}
            """

        log("LLM prompt:\n\(prompt)", level: .DEBUG)

        guard let raw = callOllama(prompt) else { return nil }

        log("LLM response:\n\(raw)", level: .DEBUG)

        // Strip markdown code fences if present
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            // Remove opening fence (possibly ```json)
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            // Remove closing fence
            if let lastFence = cleaned.range(of: "```", options: .backwards) {
                cleaned = String(cleaned[..<lastFence.lowerBound])
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = cleaned.data(using: .utf8) else {
            log("Failed to encode LLM response as UTF-8", level: .ERROR)
            return nil
        }

        do {
            let response = try JSONDecoder().decode(LLMResponse.self, from: data)
            let now = Date()
            let valid = response.items.filter { item in
                guard !item.title.isEmpty else {
                    log("Skipping item with empty title", level: .WARN)
                    return false
                }
                if item.type == "event" {
                    guard let startStr = item.start,
                          let startDate = parseISO8601(startStr) else {
                        log("Skipping event with unparseable start: \(item.start ?? "nil")",
                            level: .WARN)
                        return false
                    }
                    // Reject events with wrong year (>1 year from now in either direction)
                    let delta = abs(startDate.timeIntervalSince(now))
                    if delta > 365 * 24 * 3600 {
                        log("Skipping event with wrong year: \"\(item.title)\" \(startStr)",
                            level: .WARN)
                        return false
                    }
                }
                return item.type == "event" || item.type == "task"
            }
            return valid
        } catch {
            log("Failed to decode LLM JSON: \(error) — raw: \(cleaned.prefix(300))", level: .ERROR)
            return nil
        }
    }

    private func callOllama(_ prompt: String) -> String? {
        let body: [String: Any] = [
            "model": Settings.shared.ollamaModel,
            "messages": [["role": "user", "content": prompt]],
            "format": "json",
            "stream": false,
            "options": ["temperature": 0]
        ]

        var request = URLRequest(url: ollamaEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        var result: String?

        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { sem.signal() }
            guard let data = data, error == nil else {
                log("Ollama error: \(error?.localizedDescription ?? "unknown")", level: .ERROR)
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg  = json["message"] as? [String: Any],
               let content = msg["content"] as? String {
                result = content
            }
        }.resume()

        sem.wait()
        return result
    }

    // ── EventKit Calendar Creation ────────────────────────────────

    private func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate,
                           .withColonSeparatorInTime]
        f.timeZone = .current
        return f.date(from: s)
    }

    private func createCalendarEvent(_ item: LLMItem) -> Bool {
        guard hasCalendarAccess else {
            log("Cannot create event — calendar access denied", level: .WARN)
            return false
        }

        guard let startStr = item.start, let startDate = parseISO8601(startStr) else {
            log("Cannot create event — invalid start date: \(item.start ?? "nil")", level: .ERROR)
            return false
        }

        let endDate: Date
        if let endStr = item.end, let d = parseISO8601(endStr) {
            endDate = d
        } else {
            endDate = startDate.addingTimeInterval(3600) // default 1 hour
        }

        // Dedup: check for existing events with same title on the same day
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: startDate)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let predicate = eventStore.predicateForEvents(
            withStart: dayStart, end: dayEnd, calendars: nil)
        let existing = eventStore.events(matching: predicate)
        let isDuplicate = existing.contains { existing in
            existing.title.lowercased() == item.title.lowercased()
            && abs(existing.startDate.timeIntervalSince(startDate)) < 300 // within 5 min
        }
        if isDuplicate {
            log("Skipping duplicate event: \"\(item.title)\" on \(startStr)")
            return false
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = item.title
        event.startDate = startDate
        event.endDate = endDate

        // Auto-detect all-day: if LLM says all_day, or if start time is midnight
        // (meaning no specific time was given)
        let hour = cal.component(.hour, from: startDate)
        let minute = cal.component(.minute, from: startDate)
        let isAllDay = (item.all_day ?? false) || (hour == 0 && minute == 0)
        event.isAllDay = isAllDay

        // Pick calendar
        let calID = Settings.shared.calendarID
        if !calID.isEmpty, let cal = eventStore.calendar(withIdentifier: calID) {
            event.calendar = cal
        } else if let defaultCal = eventStore.defaultCalendarForNewEvents {
            event.calendar = defaultCal
        } else {
            // Last resort: find any writable calendar
            let writable = eventStore.calendars(for: .event).first { $0.allowsContentModifications }
            guard let fallback = writable else {
                log("No writable calendar found — open Preferences and select a calendar",
                    level: .ERROR)
                return false
            }
            event.calendar = fallback
            log("No default calendar set — using \"\(fallback.title)\". " +
                "Set a calendar in Preferences to avoid this.", level: .WARN)
        }

        do {
            try eventStore.save(event, span: .thisEvent)
            log("EventKit saved: \"\(item.title)\" \(startStr) → \(item.end ?? "default end")")
            return true
        } catch {
            log("EventKit save failed: \(error)", level: .ERROR)
            return false
        }
    }

    // ── Apple Reminders ─────────────────────────────────────────

    private func createAppleReminder(_ item: LLMItem) -> Bool {
        guard hasRemindersAccess else {
            log("Cannot create reminder — reminders access denied", level: .WARN)
            return false
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = item.title

        // Pick reminder list
        let listID = Settings.shared.reminderListID
        if !listID.isEmpty, let list = eventStore.calendar(withIdentifier: listID) {
            reminder.calendar = list
        } else {
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
        }

        // Set due date
        let minutes = item.due_minutes ?? 30
        let dueDate = Date().addingTimeInterval(Double(minutes) * 60)
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: dueDate)

        // Add alarm so user gets notified
        reminder.addAlarm(EKAlarm(absoluteDate: dueDate))

        do {
            try eventStore.save(reminder, commit: true)
            log("Apple Reminder saved: \"\(item.title)\" due in \(minutes)m")
            return true
        } catch {
            log("Apple Reminder save failed: \(error)", level: .ERROR)
            return false
        }
    }

    // ── Due URL Scheme ────────────────────────────────────────────

    private func openDueReminder(_ item: LLMItem) -> Bool {
        let minutes = item.due_minutes ?? 30
        let seconds = minutes * 60

        guard let title = item.title.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) else {
            log("Failed to encode Due title", level: .ERROR)
            return false
        }

        let urlString = "due://x-callback-url/add?title=\(title)&secslater=\(seconds)"
        guard let url = URL(string: urlString) else {
            log("Failed to create Due URL: \(urlString)", level: .ERROR)
            return false
        }

        // Check if Due is installed
        if NSWorkspace.shared.urlForApplication(toOpen: url) == nil {
            log("Due app may not be installed — attempting to open URL anyway", level: .WARN)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false

        let sem = DispatchSemaphore(value: 0)
        var success = false

        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if let error = error {
                log("Due URL open failed: \(error)", level: .ERROR)
            } else {
                log("Due reminder opened: \"\(item.title)\" in \(minutes)m")
                success = true
            }
            sem.signal()
        }

        sem.wait()
        return success
    }

    // ── ntfy ──────────────────────────────────────────────────────

    private func sendNtfy(_ report: [String]) {
        let topic = Settings.shared.ntfyTopic
        guard !topic.isEmpty,
              let url = URL(string: "https://ntfy.sh/\(topic)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = report.joined(separator: "\n").data(using: .utf8)
        req.setValue("iMessage Watcher", forHTTPHeaderField: "Title")
        URLSession.shared.dataTask(with: req) { _, _, err in
            if let err = err { log("ntfy error: \(err)", level: .ERROR) }
        }.resume()
    }

    // ── State Persistence ─────────────────────────────────────────

    private func loadState() {
        guard let s = try? String(contentsOfFile: stateFilePath, encoding: .utf8),
              let n = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        lastRowId = n
        log("Loaded state: ROWID \(lastRowId)")
    }

    private func saveState() {
        try? "\(lastRowId)".write(toFile: stateFilePath, atomically: true, encoding: .utf8)
    }
}
