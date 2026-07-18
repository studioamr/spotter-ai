// SPOTTER AI — app nativa de Mac (WKWebView). Su propia ventana, sin navegador.
import Cocoa
import WebKit
import UserNotifications

class Delegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 840)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "SPOTTER AI"
        window.center()
        window.setFrameAutosaveName("SpotterMain")
        window.backgroundColor = .black
        window.minSize = NSSize(width: 900, height: 600)

        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "spotter")     // puente: el botón Start Session lanza el Spotter
        ucc.add(self, name: "status")      // puente: estado de sesión → Spotter de la barra de menú
        cfg.userContentController = ucc
        webView = WKWebView(frame: rect, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground") // fondo negro sin flash blanco
        window.contentView = webView

        if let res = Bundle.main.resourceURL {
            let index = res.appendingPathComponent("index.html")
            webView.loadFileURL(index, allowingReadAccessTo: res)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        setupStatusItem()    // Spotter en la barra de menú (siempre visible)
        startLive()          // consulta periódica del estado EN VIVO
        scheduleReminders()  // recordatorios (apertura de Nueva York)
    }

    // Spotter de la barra de menú: refleja el estado de tu sesión aunque la ventana esté cerrada/atrás.
    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.title = "◉ SPOTTER"
            btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Abrir SPOTTER AI", action: #selector(openApp), keyEquivalent: "")
        menu.addItem(withTitle: "Empieza tu sesión", action: #selector(openApp), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Salir de SPOTTER AI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        statusItem = item
    }
    @objc func openApp() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func updateStatus(_ s: String) {
        DispatchQueue.main.async { self.statusItem?.button?.title = s.isEmpty ? "◉ SPOTTER" : s }
    }

    // Recordatorios nativos: te avisa aunque la app esté cerrada.
    func scheduleReminders() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.removeAllPendingNotificationRequests()
            // 1) 15 min antes de la apertura de Nueva York (9:15 AM hora de NY, cada día hábil)
            let ny = TimeZone(identifier: "America/New_York")
            let reminders: [(String, Int, Int, String)] = [
                ("ny-open", 9, 15, "En 15 min abre Nueva York. ¿Listo con tu setup? Una bala."),
                ("ny-recap", 16, 30, "Cerró la sesión. Registra tu trade y deja que el Spotter te califique.")
            ]
            for (id, h, m, body) in reminders {
                let c = UNMutableNotificationContent()
                c.title = "SPOTTER AI"; c.body = body; c.sound = .default
                var comps = DateComponents(); comps.hour = h; comps.minute = m; comps.timeZone = ny
                let trig = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                center.add(UNNotificationRequest(identifier: id, content: c, trigger: trig), withCompletionHandler: nil)
            }
        }
    }
    // Mostrar la notificación aunque la app esté al frente.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // Al volver a la app (tras una sesión), importa lo que el Spotter dejó en el journal.
    func applicationDidBecomeActive(_ n: Notification) { importJournal() }
    // Al terminar de cargar la plataforma, importa el journal y checa si André está EN VIVO.
    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) { importJournal(); pollLive() }

    // El app nativo (file://) no puede fetch a github.io por CORS → lo consulta Swift y lo inyecta.
    var liveTimer: Timer?
    func startLive() {
        pollLive()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.pollLive() }
    }
    func pollLive() {
        guard let url = URL(string: "https://studioamr.github.io/spotter-ai/live.json?t=\(Int(Date().timeIntervalSince1970))") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.webView?.evaluateJavaScript("window.__liveStatus&&window.__liveStatus(\(s))", completionHandler: nil) }
        }.resume()
    }

    // Lee ~/Library/Application Support/SpotterAI/journal/<fecha>.json (+ .png) que guardó el
    // Spotter y los inyecta al journal de la app (captura como data-URI + resumen de sesión).
    func importJournal() {
        guard let wv = webView else { return }
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/SpotterAI/journal")
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let fecha = obj["fecha"] as? String else { continue }
            let png = dir.appendingPathComponent(fecha + ".png")
            if let img = try? Data(contentsOf: png) {
                obj["shot"] = "data:image/png;base64," + img.base64EncodedString()
            }
            guard let payload = try? JSONSerialization.data(withJSONObject: obj),
                  var payloadStr = String(data: payload, encoding: .utf8) else { continue }
            payloadStr = payloadStr.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                                   .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            let done = f.appendingPathExtension("done")
            DispatchQueue.main.async {
                wv.evaluateJavaScript("window.__spotterImport(\(payloadStr))") { result, error in
                    if error == nil, (result as? String) == "ok" { try? fm.moveItem(at: f, to: done) }
                }
            }
        }
    }

    // Start Session pide lanzar el Spotter (Claude Code vigilando la pantalla)
    func userContentController(_ u: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "spotter" { launchSpotter(profile: message.body as? String ?? "") }
        else if message.name == "status" { updateStatus(message.body as? String ?? "") }
    }
    func launchSpotter(profile: String) {
        guard let res = Bundle.main.resourceURL else { return }
        let fm = FileManager.default
        // Carpeta de trabajo del Spotter en Application Support.
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/SpotterAI")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 1) escribir el perfil que mandó la app (para que el Spotter te conozca)
        if !profile.isEmpty && profile != "start" {
            try? profile.write(to: dir.appendingPathComponent("profile.json"), atomically: true, encoding: .utf8)
        }
        // 2) copiar script + playbook (self-heal de cuarentena para que Gatekeeper no bloquee)
        for name in ["start-watch.command", "SPOTTER-PLAYBOOK.md"] {
            let src = res.appendingPathComponent(name)
            let dst = dir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
        let scriptPath = dir.appendingPathComponent("start-watch.command").path
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-cr", dir.path]     // limpia cuarentena de toda la carpeta
        try? strip.run(); strip.waitUntilExit()
        // 3) abrir la copia limpia en Terminal → arranca Claude
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [scriptPath]
        try? p.run()
    }

    // enlaces externos (http/https: Discord, WhatsApp, TradingView) → navegador del sistema
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler d: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = a.request.url, let s = u.scheme?.lowercased(), s == "http" || s == "https" {
            NSWorkspace.shared.open(u); d(.cancel); return
        }
        d(.allow)
    }
    // target=_blank
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url { NSWorkspace.shared.open(u) }
        return nil
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let del = Delegate()
app.delegate = del

// menú mínimo para Cmd+Q / Cmd+W
let menu = NSMenu()
let appItem = NSMenuItem(); menu.addItem(appItem)
let appSub = NSMenu()
appSub.addItem(withTitle: "Ocultar SPOTTER AI", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appSub.addItem(NSMenuItem.separator())
appSub.addItem(withTitle: "Salir de SPOTTER AI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appSub
let editItem = NSMenuItem(); menu.addItem(editItem)
let editSub = NSMenu(title: "Editar")
editSub.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editSub.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editSub.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editSub.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
editItem.submenu = editSub
app.mainMenu = menu

app.run()
