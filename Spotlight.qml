import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Search.js" as Search

// Spotlight-style universal search: apps, open windows, Omarchy actions,
// files, a calculator, and web search behind one Omarchy-themed prompt.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string home: Quickshell.env("HOME")
  property var shell: null
  property var manifest: null
  readonly property string pluginId: (manifest && manifest.id) || "jglemusb.spotlight"

  // Third-party plugins don't get the shell's app library, so read desktop
  // entries straight from Quickshell and launch them the way Omarchy does.
  function appEntries() {
    var values = DesktopEntries.applications.values || []
    var out = []
    for (var i = 0; i < values.length; i++) {
      var e = values[i]
      if (e && !e.noDisplay && e.id && e.name) out.push(e)
    }
    return out
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (!value) return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var themed = Quickshell.iconPath(value, true)
    return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
  }

  function launchApp(desktopId) {
    // gtk-launch inside an app-graphical.slice scope, same as Omarchy's launcher.
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(String(desktopId) + ".desktop"))
  }

  property bool opened: false
  property string query: ""
  property int selectedIndex: 0

  property var actions: []
  property var windows: []
  property var fileRows: []
  property string fileQuery: ""
  property var usage: ({})
  property bool usageLoaded: false

  // Calculator state, persisted between sessions.
  property string angleMode: "deg"
  property var lastAnswer: undefined
  property var calcHistory: []
  readonly property int maxCalcHistory: 25
  property bool calcVisible: false

  readonly property int maxApps: 6
  readonly property int maxWindows: 4
  readonly property int maxActions: 5
  readonly property int maxFiles: 8
  readonly property int maxRecent: 8

  // Same [menu] surface tokens as the Omarchy menu, so every theme styles
  // Spotlight exactly like the rest of the shell.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int searchHeight: Math.max(Style.space(46), Style.font.display + Style.spacing.controlPaddingY * 2)
  property int rowHeight: Math.max(Style.space(52), Style.font.heading + Style.font.bodySmall + Style.spacing.rowPaddingX * 2)
  property int sectionHeight: Math.max(Style.space(26), Style.font.caption + Style.space(14))
  property int footerHeight: Math.max(Style.space(24), Style.font.caption + Style.space(10))

  // ---- lifecycle ----------------------------------------------------------

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.opened = true
    root.query = String(payload.query || "")
    root.selectedIndex = 0
    root.fileRows = []
    root.fileQuery = ""
    root.refreshWindows()
    root.rebuild()
    if (root.query) fileTimer.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function refreshWindows() {
    if (windowsProc.running) windowsProc.again = true
    else windowsProc.running = true
  }

  // Start fd for the current query. If a search is still running, stop it
  // and start the new one once it has exited, so a killed search's partial
  // output can never be shown under a newer query.
  function startFileSearch(q) {
    filesProc.pending = q
    if (filesProc.running) {
      filesProc.running = false
      return
    }
    filesProc.launchPending()
  }

  function close() {
    root.opened = false
    fileTimer.stop()
    filesProc.pending = ""
    filesProc.running = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function setQuery(next) {
    root.query = next
    root.selectedIndex = 0
    root.rebuild()
    fileTimer.restart()
  }

  // ---- usage memory (frecency) ------------------------------------------

  function usageBoost(key) {
    var u = root.usage[key]
    if (!u) return 0
    var ageDays = (Date.now() - (u.last || 0)) / 86400000
    var recency = ageDays < 1 ? 6 : (ageDays < 7 ? 3 : 0)
    return Math.min(18, (u.count || 0) * 3) + recency
  }

  function recordUsage(row) {
    // Calculator, web and window rows aren't worth remembering: window
    // addresses die with the window.
    if (!row || !row.key || row.kind === "calc" || row.kind === "web" || row.kind === "window") return
    var next = ({})
    for (var k in root.usage) next[k] = root.usage[k]
    var prev = next[row.key] || { count: 0 }
    next[row.key] = {
      count: (prev.count || 0) + 1,
      last: Date.now(),
      row: {
        kind: row.kind, key: row.key, label: row.label, detail: row.detail,
        icon: row.icon, iconFont: row.iconFont, appIcon: row.appIcon, appId: row.appId,
        action: row.action, path: row.path, isDir: row.isDir
      }
    }
    // Keep the file small: drop the least recently used beyond 200 entries.
    var keys = Object.keys(next)
    if (keys.length > 200) {
      keys.sort(function(a, b) { return (next[a].last || 0) - (next[b].last || 0) })
      for (var i = 0; i < keys.length - 200; i++) delete next[keys[i]]
    }
    root.usage = next
    usageFile.setText(JSON.stringify(next) + "\n")
  }

  // ---- calculator ---------------------------------------------------------

  function saveCalcState() {
    calcFile.setText(JSON.stringify({
      mode: root.angleMode,
      ans: typeof root.lastAnswer === "number" && isFinite(root.lastAnswer) ? root.lastAnswer : null,
      history: root.calcHistory
    }) + "\n")
  }

  function rememberCalc(expr, text, plain, value) {
    var next = [{ expr: expr, text: text, plain: plain }]
    for (var i = 0; i < root.calcHistory.length && next.length < root.maxCalcHistory; i++) {
      if (root.calcHistory[i].expr !== expr) next.push(root.calcHistory[i])
    }
    root.calcHistory = next
    root.lastAnswer = value
    root.saveCalcState()
  }

  function toggleAngleMode() {
    root.angleMode = root.angleMode === "deg" ? "rad" : "deg"
    root.saveCalcState()
    root.rebuild()
  }

  function calcRows(q) {
    var rows = []
    // "=" on its own: history, or a function reference when there's none yet.
    if (q === "=") {
      if (root.calcHistory.length === 0) {
        for (var h = 0; h < Search.CALC_HELP.length; h++) {
          rows.push(root.row({
            section: "Scientific Calculator", kind: "help", key: "help:" + h,
            label: Search.CALC_HELP[h][1], detail: Search.CALC_HELP[h][0], icon: "󰪚"
          }))
        }
      } else {
        for (var i = 0; i < root.calcHistory.length; i++) {
          var item = root.calcHistory[i]
          rows.push(root.row({
            section: "Calculator History  ·  " + root.angleMode.toUpperCase(), kind: "calc",
            key: "calchist:" + i, label: "= " + item.text, detail: item.expr,
            icon: "󰄨", value: item.plain, path: item.expr, hint: "Copy"
          }))
        }
      }
      return rows
    }
    var r = Search.calculate(q, { mode: root.angleMode, ans: root.lastAnswer })
    if (!r) return rows
    rows.push(root.row({
      section: "Calculator  ·  " + root.angleMode.toUpperCase(), kind: "calc", key: "calc",
      label: "= " + r.text,
      detail: r.expr + (r.bases ? "    " + r.bases : ""),
      icon: "󰪚", value: r.plain, path: r.expr, hint: "Copy",
      // Stash the full-precision value for `ans`.
      address: String(r.value)
    }))
    return rows
  }

  // ---- result building ----------------------------------------------------

  function row(fields) {
    return {
      section: fields.section || "",
      kind: fields.kind || "",
      key: fields.key || "",
      label: String(fields.label || ""),
      detail: String(fields.detail || ""),
      icon: String(fields.icon || ""),
      iconFont: String(fields.iconFont || ""),
      appIcon: String(fields.appIcon || ""),
      appId: String(fields.appId || ""),
      action: String(fields.action || ""),
      path: String(fields.path || ""),
      isDir: fields.isDir === true,
      address: String(fields.address || ""),
      value: String(fields.value || ""),
      hint: String(fields.hint || ""),
      score: Number(fields.score || 0)
    }
  }

  function appRows(q) {
    var entries = root.appEntries()
    var out = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var name = String(entry.name)
      var generic = String(entry.genericName || "")
      var keywords = ""
      try { if (entry.keywords && entry.keywords.join) keywords = entry.keywords.join(" ") } catch (e) { }
      var s = q ? Search.score(q, name, generic + " " + keywords + " " + (entry.comment || "") + " " + entry.id) : 1
      if (s === 0) continue
      var key = "app:" + entry.id
      out.push(root.row({
        kind: "app", key: key, label: name, detail: generic || entry.comment || "Application",
        appIcon: String(entry.icon || ""), appId: String(entry.id), hint: "Open",
        score: s + root.usageBoost(key)
      }))
    }
    return out
  }

  function windowRows(q) {
    var out = []
    for (var i = 0; i < root.windows.length; i++) {
      var w = root.windows[i]
      var title = w.title || w.cls
      var s = q ? Math.max(Search.score(q, title, ""), Search.score(q, w.cls, "")) : 1
      if (q && s === 0) continue
      out.push(root.row({
        kind: "window", key: "window:" + w.address, label: title,
        detail: (w.appName || w.cls) + "  ·  workspace " + w.workspace,
        appIcon: w.icon, hint: "Switch", address: w.address, score: s - 5
      }))
    }
    return out
  }

  function actionRows(q) {
    var out = []
    if (!q) return out
    for (var i = 0; i < root.actions.length; i++) {
      var a = root.actions[i]
      var s = Search.score(q, a.label, a.extra)
      if (s === 0) continue
      out.push(root.row({
        kind: "action", key: a.key, label: a.label, detail: a.detail,
        icon: a.icon, iconFont: a.iconFont, action: a.action, hint: "Run",
        score: s - 3 + root.usageBoost(a.key)
      }))
    }
    return out
  }

  function byScore(a, b) { return b.score - a.score }

  function rebuild() {
    var q = root.query.trim()
    var rows = []

    if (!q) {
      root.calcVisible = false
      // Empty prompt: recently used items, then open windows.
      var recent = []
      for (var k in root.usage) {
        var u = root.usage[k]
        if (u && u.row) recent.push({ row: u.row, last: u.last || 0, count: u.count || 0 })
      }
      recent.sort(function(a, b) { return (b.last + b.count * 3600000) - (a.last + a.count * 3600000) })
      for (var r = 0; r < Math.min(root.maxRecent, recent.length); r++) {
        var saved = recent[r].row
        var hint = saved.kind === "app" ? "Open" : (saved.kind === "action" ? "Run" : "Open")
        var rr = root.row(saved)
        rr.section = "Recent"
        rr.hint = hint
        rows.push(rr)
      }
      var wins = root.windowRows("")
      for (var w = 0; w < wins.length; w++) { wins[w].section = "Open Windows"; rows.push(wins[w]) }
      root.publish(rows)
      return
    }

    var webOnly = q.charAt(0) === "?"
    // A leading "=" means calculator only.
    var calcOnly = q.charAt(0) === "="
    var calc = webOnly ? [] : root.calcRows(q)
    root.calcVisible = calc.length > 0 || calcOnly
    for (var c = 0; c < calc.length; c++) rows.push(calc[c])
    if (calcOnly) { root.publish(rows); return }

    var apps = webOnly ? [] : root.appRows(q).sort(byScore)
    var wins2 = webOnly ? [] : root.windowRows(q).sort(byScore)
    var acts = webOnly ? [] : root.actionRows(q).sort(byScore)
    var files = webOnly ? [] : (root.fileQuery === q ? root.fileRows.slice() : [])
    for (var f = 0; f < files.length; f++) files[f] = root.row(files[f])

    // Top Hit: the single strongest match across every source.
    var top = null
    var pools = [apps, wins2, acts, files]
    for (var p = 0; p < pools.length; p++) {
      if (pools[p].length && pools[p][0].score >= 55 && (!top || pools[p][0].score > top.score)) top = pools[p][0]
    }
    if (top) {
      for (var p2 = 0; p2 < pools.length; p2++) {
        var ix = pools[p2].indexOf(top)
        if (ix >= 0) pools[p2].splice(ix, 1)
      }
      top.section = "Top Hit"
      rows.push(top)
    }

    function add(list, name, max) {
      for (var i = 0; i < Math.min(max, list.length); i++) { list[i].section = name; rows.push(list[i]) }
    }
    add(apps, "Applications", root.maxApps)
    add(wins2, "Open Windows", root.maxWindows)
    add(acts, "Omarchy", root.maxActions)
    add(files, "Files & Folders", root.maxFiles)

    var term = webOnly ? q.slice(1).trim() : q
    if (term) {
      rows.push(root.row({
        section: "Web", kind: "web", key: "web", label: "Search the web for “" + term + "”",
        detail: "Opens in your default browser", icon: "󰖟", value: term, hint: "Search"
      }))
    }

    root.publish(rows)
  }

  function publish(rows) {
    var keepKey = (resultsModel.count > 0 && root.selectedIndex < resultsModel.count)
      ? resultsModel.get(root.selectedIndex).key : ""
    resultsModel.clear()
    for (var i = 0; i < rows.length; i++) resultsModel.append(rows[i])
    // A late file batch shouldn't yank the cursor off what you were looking at.
    var next = 0
    if (keepKey && root.selectedIndex > 0) {
      for (var j = 0; j < resultsModel.count; j++) if (resultsModel.get(j).key === keepKey) { next = j; break }
    }
    root.selectedIndex = Math.min(next, Math.max(0, resultsModel.count - 1))
    Qt.callLater(function() { if (resultsModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain) })
  }

  // ---- navigation & activation -------------------------------------------

  function move(delta) {
    if (resultsModel.count === 0) return
    root.selectedIndex = (root.selectedIndex + delta + resultsModel.count) % resultsModel.count
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  // Tab jumps to the first row of the next section.
  function jumpSection(delta) {
    var n = resultsModel.count
    if (n === 0) return
    var current = resultsModel.get(root.selectedIndex).section
    var i = root.selectedIndex
    for (var step = 0; step < n; step++) {
      i = (i + delta + n) % n
      var s = resultsModel.get(i).section
      if (s !== current) {
        // Walking backwards lands on the section's last row; snap to its first.
        while (delta < 0 && i > 0 && resultsModel.get(i - 1).section === s) i--
        root.selectedIndex = i
        resultList.positionViewAtIndex(i, ListView.Contain)
        return
      }
    }
  }

  function activate(index, alternate) {
    if (index < 0 || index >= resultsModel.count) return
    var r = resultsModel.get(index)
    if (r.kind === "help") return
    if (r.kind === "calc") {
      var fromHistory = r.key.indexOf("calchist:") === 0
      var value = fromHistory ? Number(r.value) : Number(r.address)
      if (!fromHistory) root.rememberCalc(r.path, r.label.replace(/^= /, ""), r.value, value)
      else root.lastAnswer = value
      if (alternate) {
        // Ctrl+Enter keeps calculating: history rows load their expression,
        // a live result carries forward as the start of the next one.
        root.setQuery("=" + (fromHistory ? r.path : r.value))
        return
      }
      root.dismiss()
      Util.execArgv(["wl-copy", r.value])
      return
    }
    var snapshot = ({})
    for (var k in r) snapshot[k] = r[k]
    root.dismiss()
    root.recordUsage(snapshot)

    if (r.kind === "app") {
      root.launchApp(r.appId)
    } else if (r.kind === "window") {
      Util.execArgv(["hyprctl", "dispatch", "hl.dsp.focus({ window = \"address:" + r.address + "\" })"])
    } else if (r.kind === "action") {
      Util.execDetached(r.action)
    } else if (r.kind === "file") {
      if (alternate) {
        // Ctrl+Enter: reveal the item in the file manager instead of opening it.
        Util.execArgv(["gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1",
                       "--object-path", "/org/freedesktop/FileManager1",
                       "--method", "org.freedesktop.FileManager1.ShowItems",
                       "['" + Util.fileUrl(r.path).replace(/'/g, "%27") + "']", ""])
      } else {
        Util.execArgv(["xdg-open", r.path])
      }
    } else if (r.kind === "web") {
      Util.execArgv(["xdg-open", "https://www.google.com/search?q=" + encodeURIComponent(r.value)])
    }
  }

  // ---- data sources -------------------------------------------------------

  ListModel { id: resultsModel }

  property string defaultMenuText: ""
  property string userMenuText: ""
  function reloadActions() { root.actions = Search.menuActions(root.defaultMenuText, root.userMenuText) }

  FileView {
    path: root.omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: { root.defaultMenuText = text(); root.reloadActions() }
    onFileChanged: reload()
  }

  FileView {
    path: root.home + "/.config/omarchy/extensions/omarchy-menu.jsonc"
    watchChanges: true
    printErrors: false
    onLoaded: { root.userMenuText = text(); root.reloadActions() }
    onFileChanged: reload()
  }

  FileView {
    id: usageFile
    path: root.home + "/.local/state/omarchy-spotlight-usage.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try { root.usage = JSON.parse(text() || "{}") || ({}) } catch (e) { root.usage = ({}) }
      root.usageLoaded = true
    }
    onLoadFailed: { root.usage = ({}); root.usageLoaded = true }
  }

  FileView {
    id: calcFile
    path: root.home + "/.local/state/omarchy-spotlight-calc.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var state = JSON.parse(text() || "{}") || ({})
        root.angleMode = state.mode === "rad" ? "rad" : "deg"
        root.lastAnswer = typeof state.ans === "number" ? state.ans : undefined
        root.calcHistory = Array.isArray(state.history) ? state.history : []
      } catch (e) { }
    }
  }

  // Map a window class to its desktop entry's icon and name.
  function desktopInfoForClass(cls) {
    var c = String(cls || "").toLowerCase()
    if (!c) return { icon: "", name: cls }
    var entries = root.appEntries()
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      var id = String(e.id || "").toLowerCase()
      var startup = ""
      try { startup = String(e.startupClass || "").toLowerCase() } catch (err) { }
      if (id === c || startup === c || id.split(".").pop() === c)
        return { icon: String(e.icon || c), name: String(e.name) }
    }
    return { icon: c, name: cls }
  }

  Process {
    id: windowsProc
    property bool again: false
    command: ["hyprctl", "clients", "-j"]
    onExited: if (again) { again = false; running = true }
    stdout: StdioCollector {
      onStreamFinished: {
        var list = []
        try {
          var clients = JSON.parse(this.text || "[]")
          for (var i = 0; i < clients.length; i++) {
            var c = clients[i]
            if (!c.mapped || c.hidden || !c.address) continue
            if (!c.class && !c.title) continue
            var info = root.desktopInfoForClass(c.class)
            list.push({
              address: c.address, title: String(c.title || ""), cls: String(c.class || ""),
              appName: info.name, icon: info.icon,
              workspace: (c.workspace && c.workspace.name) || "?",
              focusHistory: c.focusHistoryID === undefined ? 99 : c.focusHistoryID
            })
          }
          list.sort(function(a, b) { return a.focusHistory - b.focusHistory })
          // The window you came from is focusHistory 0 — skip it; you're already there.
          if (list.length && list[0].focusHistory === 0) list.shift()
        } catch (e) { }
        root.windows = list
        if (root.opened) root.rebuild()
      }
    }
  }

  Timer {
    id: fileTimer
    interval: 160
    onTriggered: {
      var q = root.query.trim()
      if (q.length < 2 || q.charAt(0) === "?" || q.charAt(0) === "=" || Search.calculate(q)) {
        root.fileRows = []
        root.fileQuery = q
        return
      }
      root.startFileSearch(q)
    }
  }

  Process {
    id: filesProc
    property string searchFor: ""
    property string pending: ""
    // Set when this run was killed for a newer query; its output is partial.
    property bool cancelled: false

    function launchPending() {
      if (!pending) return
      searchFor = pending
      pending = ""
      cancelled = false
      command = ["fd", "--color=never", "--ignore-case", "--fixed-strings",
                 "--max-results", "300", "--exclude", "node_modules",
                 "--exclude", "Games", "--exclude", "drive_c", "--", searchFor, root.home]
      running = true
    }

    onRunningChanged: if (!running && pending) { cancelled = true; Qt.callLater(launchPending) }

    stdout: StdioCollector {
      onStreamFinished: {
        // Ignore killed runs and results for a query that has since changed.
        if (filesProc.cancelled || filesProc.searchFor !== root.query.trim()) return
        var ranked = Search.rankFiles(this.text, filesProc.searchFor, root.home, 40)
        for (var i = 0; i < ranked.length; i++) {
          ranked[i].kind = "file"
          ranked[i].hint = ranked[i].isDir ? "Open folder" : "Open"
          ranked[i].score += root.usageBoost(ranked[i].key)
        }
        ranked.sort(root.byScore)
        root.fileRows = ranked
        root.fileQuery = filesProc.searchFor
        if (root.opened) root.rebuild()
      }
    }
  }

  Process {
    id: pasteProc
    command: ["wl-paste", "--no-newline", "--type", "text"]
    stdout: StdioCollector {
      onStreamFinished: {
        var text = String(this.text || "").split("\n")[0]
        if (text) root.setQuery(root.query + text)
      }
    }
  }

  // ---- UI -----------------------------------------------------------------

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-spotlight"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: Math.min(Style.space(680), panel.width - Style.gapsOut * 2)
      readonly property int listHeight: resultsModel.count === 0 ? 0
        : Math.min(resultList.contentHeight, Math.round(panel.height * 0.58))
      height: card.contentTopInset + card.contentBottomInset + root.searchHeight
        + (resultsModel.count > 0 ? Style.spacing.md + listHeight + root.footerHeight : 0)
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.round(panel.height * 0.2)
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          if (event.key === Qt.Key_Escape) {
            if (root.query) root.setQuery("")
            else root.dismiss()
          } else if (ctrl && event.key === Qt.Key_V) {
            pasteProc.running = true
          } else if (ctrl && event.key === Qt.Key_D) {
            root.toggleAngleMode()
          } else if (Util.editsFilter(event, root.query)) {
            root.setQuery(Util.editedFilter(event, root.query))
          } else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K) || (ctrl && event.key === Qt.Key_P)) {
            root.move(-1)
          } else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J) || (ctrl && event.key === Qt.Key_N)) {
            root.move(1)
          } else if (event.key === Qt.Key_Tab) {
            root.jumpSection(1)
          } else if (event.key === Qt.Key_Backtab) {
            root.jumpSection(-1)
          } else if (event.key === Qt.Key_PageUp) {
            root.move(-5)
          } else if (event.key === Qt.Key_PageDown) {
            root.move(5)
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(root.selectedIndex, ctrl)
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32
                     && event.text.charCodeAt(0) !== 127
                     && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
            root.setQuery(root.query + event.text)
          } else {
            return
          }
          event.accepted = true
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // Search prompt
        Item {
          width: parent.width
          height: root.searchHeight

          Text {
            id: searchGlyph
            text: "󰍉"
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: queryText
            textFormat: Text.PlainText
            anchors.left: searchGlyph.right
            anchors.leftMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width - searchGlyph.width - Style.space(40))
            text: root.query || "Search apps, files, windows, actions…"
            color: root.foreground
            opacity: root.query ? 1 : 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            elide: Text.ElideLeft
          }

          Rectangle {
            id: caret
            width: Math.max(2, Style.space(2))
            height: Style.font.display + Style.space(4)
            color: root.foreground
            anchors.verticalCenter: parent.verticalCenter
            x: root.query ? queryText.x + queryText.width + Style.space(2) : queryText.x - Style.space(2)
            visible: root.opened
            SequentialAnimation on opacity {
              running: root.opened
              loops: Animation.Infinite
              NumberAnimation { from: 1; to: 0; duration: 530; easing.type: Easing.InOutQuad }
              NumberAnimation { from: 0; to: 1; duration: 530; easing.type: Easing.InOutQuad }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: Util.alpha(root.foreground, 0.15)
          visible: resultsModel.count > 0
        }

        ListView {
          id: resultList
          width: parent.width
          height: card.listHeight
          visible: resultsModel.count > 0
          model: resultsModel
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          section.property: "section"
          section.criteria: ViewSection.FullString
          section.delegate: Item {
            required property string section
            width: ListView.view.width
            height: root.sectionHeight
            Text {
              textFormat: Text.PlainText
              text: parent.section.toUpperCase()
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.weight: Font.DemiBold
              font.letterSpacing: Style.space(1)
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(4)
            }
          }

          delegate: BorderSurface {
            id: rowItem
            required property int index
            required property string kind
            required property string key
            required property string label
            required property string detail
            required property string icon
            required property string iconFont
            required property string appIcon
            required property string hint

            readonly property bool selected: index === root.selectedIndex
            readonly property bool useImage: kind === "app" || kind === "window"
            // The live calculator answer gets a big, display-size line.
            readonly property bool bigAnswer: kind === "calc" && key === "calc"

            width: ListView.view.width
            height: bigAnswer ? Math.max(root.rowHeight, Style.font.display + Style.font.bodySmall + Style.space(26)) : root.rowHeight
            radius: root.cornerRadius
            color: selected ? root.selectedBackground : "transparent"
            borderSpec: selected ? root.selectedBorderSpec : Border.none()

            Item {
              id: iconBox
              width: Style.space(36)
              height: Style.space(36)
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter

              Image {
                anchors.centerIn: parent
                visible: rowItem.useImage
                width: Style.space(28)
                height: Style.space(28)
                fillMode: Image.PreserveAspectFit
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: rowItem.useImage ? root.iconSource(rowItem.appIcon) : ""
                asynchronous: true
              }

              Text {
                anchors.centerIn: parent
                visible: !rowItem.useImage
                textFormat: Text.PlainText
                text: rowItem.icon || "󰘳"
                color: rowItem.selected ? root.selectedText : root.foreground
                font.family: rowItem.iconFont.length > 0 ? rowItem.iconFont : root.fontFamily
                font.pixelSize: Style.font.iconLarge + Style.space(2)
              }
            }

            Column {
              anchors.left: iconBox.right
              anchors.leftMargin: Style.space(10)
              anchors.right: hintText.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: rowItem.label
                color: rowItem.selected ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: rowItem.bigAnswer ? Style.font.display : Style.font.heading
                font.weight: Font.Medium
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: rowItem.detail
                visible: text.length > 0
                color: rowItem.selected ? root.selectedText : root.foreground
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
              }
            }

            Text {
              id: hintText
              textFormat: Text.PlainText
              text: rowItem.selected && rowItem.hint ? rowItem.hint + "  ↵" : ""
              color: rowItem.selected ? root.selectedText : root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.right: parent.right
              anchors.rightMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onPositionChanged: root.selectedIndex = rowItem.index
              onClicked: function(mouse) {
                root.selectedIndex = rowItem.index
                root.activate(rowItem.index, (mouse.modifiers & Qt.ControlModifier) !== 0)
              }
            }
          }
        }

        // Footer key hints
        Item {
          width: parent.width
          height: root.footerHeight
          visible: resultsModel.count > 0

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.bottom: parent.bottom
            text: root.calcVisible
              ? "↵ copy result   ctrl↵ keep calculating   ctrl+d " + (root.angleMode === "deg" ? "→ RAD" : "→ DEG") + "   esc close"
              : "↑↓ navigate   ⇥ next section   ↵ open   ctrl↵ reveal file   esc close"
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.bottom: parent.bottom
            text: root.calcVisible ? "= alone shows history" : "? web  ·  = calculator"
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
