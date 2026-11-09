// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Diego Ledesma (TRN1) — Minimo OS
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "livewall.js" as LW

// Fondo animado con mpvpaper (opcional, AUR): un solo proceso para todos los monitores,
// decodificación por hardware, sin audio. Para gastar lo mínimo se pausa (IPC de mpv):
//   · cuando todos los monitores muestran un escritorio con ventanas (si la opción está activa),
//   · cuando nadie usa la PC (inactividad).
// Las ventanas se re-evalúan solo con eventos de Hyprland (sin sondeo) y solo con el fondo activo.
// Si el archivo guardado no existe (al iniciar o al elegirlo), se limpia liveWallpaper y
// vuelve el fondo estático. Tras pedir stop, un watchdog de 2 s (una sola vez) manda
// SIGTERM y luego SIGKILL si el proceso no termina, para liberar stopping.
Singleton {
    id: root
    property bool available: false
    readonly property bool active: available && DisplayState.liveWallpaper !== ""
    readonly property bool running: player.running
    readonly property string sock: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/minimo-wallpaper.sock"
    property bool covered: false
    readonly property bool paused: (DisplayState.livePauseCovered && covered) || IdleState.idle
    readonly property var extensions: ["mp4", "webm", "mkv", "mov", "gif"]

    Process { running: true; command: ["sh", "-c", "command -v mpvpaper >/dev/null"]; onExited: code => root.available = code === 0 }

    // Sin bindings en running/command: antes \`running: root.active\` se rompía al asignar
    // \`player.running = false\` para cambiar de archivo, y después de Quitar ya no arrancaba otro.
    // Ahora el ciclo lo decide Common/livewall.js (nunca dos procesos; reinicio tras exited).
    property var lw: LW.initial()
    readonly property string wanted: active ? DisplayState.liveWallpaper : ""
    property string checking: ""
    property int checkGen: 0
    onWantedChanged: sync()
    function sync() {
        const path = wanted
        if (path !== "") {
            if (lw.running && lw.current === path && !lw.stopping) return
            root.checkGen++
            root.checking = path
            existsCheck.running = false
            // test no acepta -- (sale 2 aunque el archivo exista). Las rutas son absolutas.
            existsCheck.command = ["test", "-f", path]
            existsCheck.gen = root.checkGen
            existsCheck.running = true
            return
        }
        root.checkGen++
        root.checking = ""
        existsCheck.running = false
        applyWant("")
    }
    function applyWant(path) {
        const r = LW.want(lw, path, Date.now())
        lw = r.state
        if (r.act === "start") {
            // Borra un socket viejo (de un mpvpaper que murió) y \`exec\`: el PID es el de mpvpaper,
            // así que detener el Process le llega directo a él.
            player.command = ["sh", "-c", 'rm -f "$1"; shift; exec mpvpaper "$@"', "mpvwall", root.sock,
                              "-o", "no-audio loop-file=inf hwdec=auto panscan=1.0 input-ipc-server=" + root.sock, "*", lw.current]
            player.running = true
            stopWatch.stop()
            killWatch.stop()
        } else if (r.act === "stop") {
            player.running = false
            stopWatch.restart()
        }
    }
    Process {
        id: existsCheck
        property int gen: 0
        onExited: code => {
            if (gen !== root.checkGen) return
            const path = root.checking
            root.checking = ""
            if (path === "" || root.wanted !== path) { Qt.callLater(root.sync); return }
            // 1 = no existe; otro no-cero (p. ej. uso inválido de test) no debe impedir el arranque.
            if (code === 1) {
                if (DisplayState.liveWallpaper !== "") DisplayState.setLiveWallpaper("")
                return
            }
            root.applyWant(path)
        }
    }
    Process {
        id: player
        onRunningChanged: if (running) sendLater.restart()
        onExited: {
            stopWatch.stop()
            killWatch.stop()
            root.lw = LW.exited(root.lw, Date.now())
            Qt.callLater(root.sync)
        }
    }
    // Solo corre después de un stop: 2 s, si sigue vivo SIGTERM; 400 ms después, SIGKILL.
    Timer { id: stopWatch; interval: 2000; repeat: false; onTriggered: {
        if (!player.running) return
        player.signal(15)
        killWatch.restart()
    } }
    Timer { id: killWatch; interval: 400; repeat: false; onTriggered: { if (player.running) player.signal(9) } }

    onPausedChanged: send()
    // El socket aparece un instante después de arrancar mpv.
    Timer { id: sendLater; interval: 800; onTriggered: root.send() }
    function send() {
        if (!player.running) return
        Quickshell.execDetached(["python3", "-c",
            "import socket,sys\ns=socket.socket(socket.AF_UNIX)\ntry:\n s.connect(sys.argv[1]); s.send(sys.argv[2].encode()+b'\\n')\nexcept OSError: pass",
            root.sock, JSON.stringify({ command: ["set_property", "pause", root.paused] })])
    }

    function evaluate() {
        const mons = Hyprland.monitors.values
        root.covered = mons.length > 0 && mons.every(m => m.activeWorkspace && m.activeWorkspace.toplevels.values.length > 0)
    }
    Connections {
        target: Hyprland
        enabled: root.active && DisplayState.livePauseCovered
        function onRawEvent(ev) {
            const n = ev.name
            if (n === "openwindow" || n === "closewindow" || n === "movewindowv2" || n === "workspacev2" || n === "focusedmonv2") refresh.restart()
        }
    }
    // Una sola actualización por ráfaga de eventos.
    Timer { id: refresh; interval: 250; onTriggered: { Hyprland.refreshToplevels(); Qt.callLater(root.evaluate) } }
    onActiveChanged: if (active) refresh.restart()

    function isAnimated(path) {
        const m = path.toLowerCase().match(/\.([a-z0-9]+)$/)
        return !!m && extensions.indexOf(m[1]) >= 0
    }
}
