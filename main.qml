import QtQuick
import QtQuick.Controls
import QtQuick.Window

ApplicationWindow {
    id: root
    visible: true
    title: "IC-7000"
    visibility: Window.FullScreen
    color: "#0a0c0e"

    // Hide system cursor - touchscreen only
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        cursorShape: Qt.BlankCursor
        propagateComposedEvents: true
    }

    // -- palette ---------------------------------------------------------------
    readonly property color cBg:       "#0a0c0e"
    readonly property color cSurface:  "#111518"
    readonly property color cCard:     "#181d21"
    readonly property color cRaised:   "#222b32"
    readonly property color cBorder:   "#38484f"
    readonly property color cText:     "#e8f0f4"
    readonly property color cMuted:    "#a5bfcc"
    readonly property color cDim:      "#7f99a8"
    readonly property color cBlue:     "#1e90d8"
    readonly property color cCyan:     "#00d4e8"
    readonly property color cGreen:    "#18d060"
    readonly property color cRed:      "#f03050"
    readonly property color cAmber:    "#f0a020"
    readonly property color cViolet:   "#9070ff"
    readonly property color cLcdBg:    "#040d06"
    readonly property color cLcdGreen: "#20f060"
    readonly property color cLcdDim:   "#2f8a52"

    // -- state -----------------------------------------------------------------
    property string page:        "radio"
    property string curBand:     "20m"
    property string curMode:     "USB"
    property int    curFilt:     1
    property int    curAgc:      2
    property bool   isConn:      false
    property bool   isTx:        false
    property string freqText:    "14.200.000"
    property string utcText:     "00:00:00"
    property string statusText:  "Offline"
    property int    maxPwr:      100
    property int    setPwrPct:   78
    property int    micPct:      50
    property bool   civActive:   false
    property real   civAngle:    0
    property real   audioInLvl:  0.0
    property real   audioOutLvl: 0.0
    property int    audioInGain:  50
    property int    audioOutGain: 50

    property string sol_sfi:     "---"
    property string sol_ssn:     "---"
    property string sol_ki:      "---"
    property string sol_ai:      "---"
    property string sol_xray:    "---"
    property string sol_noise:   "---"
    property string sol_wind:    "---"
    property string sol_geo:     "---"
    property string sol_updated: "---"
    property var    sol_bands:   ({})
    property bool   sol_busy:    false

    // -- virtual keyboard state ---------------------------------------------
    // mode: "" = hidden, "alpha" = full alpha+num, "num" = digits only
    property string vkbMode:    ""
    property var    vkbTarget:  null   // the TextField receiving input
    property bool   vkbLower:   false  // shift: male litery (np. /dev/ttyUSB0)

    // -- radio state synced from backend ------------------------------------
    property bool   compOn:      false
    property bool   scanOn:      false
    property int    vfoMem:      0      // 0 = VFO, 1 = MEM
    property real   meterLvl:    0.0
    property string meterText:   "S -"
    property string toastText:   ""

    // -- CI-V activity timer ------------------------------------------------
    Timer {
        id: civTimer
        interval: 600; repeat: false
        onTriggered: root.civActive = false
    }
    Timer {
        id: toastTimer
        interval: 3500; repeat: false
        onTriggered: root.toastText = ""
    }
    function openVkb(target, mode) {
        root.vkbTarget = target
        root.vkbLower  = false
        root.vkbMode   = mode
    }

    ListModel { id: memoryModel }
    ListModel { id: aprsModel  }

    // -- helpers ---------------------------------------------------------------
    function txWatts()     { return Math.round(root.setPwrPct / 100.0 * root.maxPwr) }
    function levelRaw(pct) { return Math.max(0, Math.min(255, Math.round(pct / 100.0 * 255))) }
    function sendPower(pct){ backend.setLevel(0x0A, root.levelRaw(Math.max(0,Math.min(100,Math.round(pct))))) }
    function sendMic(pct)  { backend.setLevel(0x0B, root.levelRaw(Math.max(0,Math.min(100,Math.round(pct))))) }

    // Dotyk na luku (145 deg .. 395 deg) -> procent. Zwraca -1, gdy dotyk
    // nalezy zignorowac. FIX: wczesniej cala dolna przerwa (i napis w srodku)
    // dawaly 100% mocy, bo warunek "rel<390" byl zawsze prawdziwy.
    function arcPct(cv, x, y, strict) {
        var cx = cv.width/2, cy = cv.height*0.58, r = Math.min(cx,cy)*0.88
        var dx = x-cx, dy = y-cy, d = Math.sqrt(dx*dx+dy*dy)
        if (d < r*0.55) return -1                 // srodek z napisem
        if (strict && d > r*1.35) return -1       // tap daleko od pierscienia
        var a = Math.atan2(dy,dx)*180/Math.PI
        if (a < 0) a += 360
        var rel = a-145; if (rel < 0) rel += 360
        if (rel > 250) {
            if (strict) return -1                 // tap w przerwie: ignoruj
            rel = rel < 305 ? 250 : 0             // drag: najblizszy koniec skali
        }
        return Math.round(rel/250*100)
    }
    function showToast(t) {
        if (!t) return
        root.toastText = t
        toastTimer.restart()
    }

    function arcColor(pct) {
        if (pct > 80) return root.cRed
        if (pct > 50) return root.cAmber
        return root.cGreen
    }
    function micColor(pct) {
        if (pct > 80) return root.cAmber
        if (pct > 50) return root.cGreen
        return root.cCyan
    }
    function condColor(c) {
        if (!c || c === "N/A") return root.cDim
        var lo = c.toLowerCase()
        if (lo.indexOf("good")   !== -1 || lo.indexOf("open")   !== -1) return root.cGreen
        if (lo.indexOf("fair")   !== -1)                                 return root.cAmber
        if (lo.indexOf("poor")   !== -1 || lo.indexOf("closed") !== -1) return root.cRed
        return root.cMuted
    }
    function condShort(c) {
        if (!c || c === "N/A" || c === "") return "---"
        var lo = c.toLowerCase()
        if (lo.indexOf("good")   !== -1) return "GOOD"
        if (lo.indexOf("fair")   !== -1) return "FAIR"
        if (lo.indexOf("poor")   !== -1) return "POOR"
        if (lo.indexOf("open")   !== -1) return "OPEN"
        if (lo.indexOf("closed") !== -1) return "CLSD"
        return c.substring(0,5).toUpperCase()
    }
    function bandCond(name,tod) { return root.sol_bands[name+"_"+tod] || "" }
    function num(s) { var v = parseFloat(s); return isNaN(v) ? 0 : v }
    function sfiColor(v)  { return v>=150?root.cGreen : v>=90?root.cAmber : root.cRed }
    function kColor(v)    { return v<=2 ?root.cGreen : v<=4 ?root.cAmber : root.cRed }
    function windColor(v) { return v<400?root.cGreen : v<=600?root.cAmber : root.cRed }
    function geoColor(s)  {
        if (!s) return root.cDim
        var lo = s.toLowerCase()
        if (lo.indexOf("storm")  !== -1) return root.cRed
        if (lo.indexOf("active") !== -1 || lo.indexOf("unsett") !== -1) return root.cAmber
        if (lo.indexOf("quiet")  !== -1) return root.cGreen
        return root.cMuted
    }

    // -- backend connections ---------------------------------------------------
    Connections {
        target: backend
        function onFreqChanged(freq)        { root.freqText    = freq }
        function onModeChanged(mode)        { root.curMode     = mode }
        function onFiltChanged(filt)        { root.curFilt     = filt }
        function onTxChanged(tx)            { root.isTx        = tx  }
        function onConnectedChanged(c)      { root.isConn      = c   }
        function onStatusChanged(t)         { root.statusText  = t; root.showToast(t) }
        function onCompChanged(on)          { root.compOn      = on  }
        function onScanChanged(on)          { root.scanOn      = on  }
        function onVfoMemChanged(mode)      { root.vfoMem      = mode }
        function onMeterChanged(level, text){ root.meterLvl = level; root.meterText = text }
        function onMemoryAddResult(ok, msg) {
            memAddPanel.resultText = msg
            memAddPanel.resultOk   = ok
            if (ok) {
                memNameField.text = ""; memFreqField.text = ""; memToneField.text = ""
            }
        }
        function onUtcChanged(u)            { root.utcText     = u   }
        function onMaxPwrChanged(p)         { root.maxPwr      = p   }
        function onBandChanged(b)           { root.curBand     = b   }
        function onAgcChanged(a)            { root.curAgc      = a   }
        function onSetPwrPctChanged(pct)    { root.setPwrPct   = pct }
        function onMicPctChanged(pct)       { root.micPct      = pct }
        function onConnectError(msg)        { dlg.errorText=msg; dlg.busy=false; modal.visible=true }
        function onBandsReady(bands)        { bandRepeater.model  = bands }
        function onModesReady(modes)        { modeRepeater.model  = modes }
        function onPortsReady(ports)        { dlg.portList        = ports  }
        function onAudioDevicesReady(devs)  { dlg.audioList       = devs   }
        function onCivActivity() {
            root.civActive = true
            root.civAngle  = (root.civAngle + 45) % 360
            civTimer.restart()
        }
        function onMemoriesReady(memories) {
            memoryModel.clear()
            for (var i = 0; i < memories.length; i++) {
                memoryModel.append({
                    "name": memories[i]["name"] || "",
                    "freq": memories[i]["freq"] || "",
                    "tone": memories[i]["tone"] || "",
                    "dup":  memories[i]["dup"]  || "SIMPLEX",
                    "mode": memories[i]["mode"] || ""
                })
            }
        }
        function onSolarChanged(data) {
            root.sol_sfi     = data["sfi"]      || "---"
            root.sol_ssn     = data["sunspots"] || "---"
            root.sol_ki      = data["kindex"]   || "---"
            root.sol_ai      = data["aindex"]   || "---"
            root.sol_xray    = data["xray"]     || "---"
            root.sol_noise   = data["noise"]    || "---"
            root.sol_wind    = data["wind"]     || "---"
            root.sol_geo     = data["geo"]      || "---"
            root.sol_updated = data["updated"]  || "---"
            root.sol_bands   = data["bands"]    || ({})
            root.sol_busy    = false
        }
        function onAudioInLevel(level)  { root.audioInLvl  = level }
        function onAudioOutLevel(level) { root.audioOutLvl = level }
        function onAprsMessagesReady(messages) {
            aprsModel.clear()
            for (var i = messages.length - 1; i >= 0; i--) {
                aprsModel.append({
                    "callsign": messages[i]["callsign"] || "",
                    "comment":  messages[i]["comment"]  || "",
                    "lat":      messages[i]["lat"]      || "",
                    "lng":      messages[i]["lng"]      || "",
                    "time":     messages[i]["time"]     || "",
                    "symbol":   messages[i]["symbol"]   || "",
                    "mine":     messages[i]["mine"]     || false
                })
            }
        }
    }

    // =======================================================================
    //  VIRTUAL KEYBOARD OVERLAY
    // =======================================================================
    Item {
        id: vkbOverlay
        anchors.fill: parent
        visible: root.vkbMode !== ""
        z: 200

        // Dim background - tap outside the panel to dismiss
        Rectangle {
            anchors.fill: parent
            color: "#99000000"
            TapHandler {
                onTapped: function(eventPoint) {
                    var p = vkbPanel.mapFromItem(vkbOverlay,
                                eventPoint.position.x, eventPoint.position.y)
                    if (p.x < 0 || p.y < 0 ||
                        p.x > vkbPanel.width || p.y > vkbPanel.height)
                        root.vkbMode = ""
                }
            }
        }

        Rectangle {
            id: vkbPanel
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            width: Math.min(parent.width - 16, 900)
            height: root.vkbMode === "alpha" ? 368 : 200
            radius: 16
            color: root.cSurface
            border.color: root.cBorder; border.width: 2

            Behavior on height { NumberAnimation { duration: 150 } }

            Column {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8

                // -- podglad wpisywanego tekstu (pole moze byc zasloniete) --
                Rectangle {
                    width: parent.width; height: 40; radius: 8
                    color: root.cLcdBg; border.color: root.cBorder
                    Text {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                        verticalAlignment: Text.AlignVCenter
                        text: (root.vkbTarget ? root.vkbTarget.text : "") + "_"
                        color: root.cLcdGreen; font.family: "DejaVu Sans Mono"
                        font.pixelSize: 20; font.bold: true; elide: Text.ElideLeft
                    }
                }

                // -- digit row always shown ------------------------------
                Row {
                    width: parent.width; spacing: 6
                    Repeater {
                        model: ["1","2","3","4","5","6","7","8","9","0","."]
                        delegate: Rectangle {
                            width: (vkbPanel.width - 20 - 10*6) / 11
                            height: 52; radius: 10
                            color: root.cRaised; border.color: root.cBorder
                            Text { anchors.centerIn: parent; text: modelData
                                   color: root.cText; font.pixelSize: 22; font.bold: true }
                            TapHandler { onTapped: {
                                if (root.vkbTarget) root.vkbTarget.text += modelData
                            }}
                        }
                    }
                }

                // -- alpha rows (alpha mode only) -------------------------
                Repeater {
                    model: root.vkbMode === "alpha" ? ["QWERTYUIOP","ASDFGHJKL:","ZXCVBNM-/_"] : []
                    delegate: Row {
                        width: parent.width; spacing: 5
                        property string rowStr: modelData
                        Repeater {
                            model: rowStr.length
                            delegate: Rectangle {
                                property string ch: root.vkbLower ? rowStr[index].toLowerCase() : rowStr[index]
                                width: (vkbPanel.width - 20 - (rowStr.length-1)*5) / rowStr.length
                                height: 52; radius: 10
                                color: root.cRaised; border.color: root.cBorder
                                Text { anchors.centerIn: parent; text: ch
                                       color: root.cCyan; font.pixelSize: 20; font.bold: true }
                                TapHandler { onTapped: {
                                    if (root.vkbTarget) root.vkbTarget.text += ch
                                }}
                            }
                        }
                    }
                }

                // -- control row ------------------------------------------
                Row {
                    id: vkbCtrlRow
                    width: parent.width; spacing: 6
                    property real avail: vkbPanel.width - 20 - (root.vkbMode === "alpha" ? 3*6 : 6)

                    // SHIFT (alpha only)
                    Rectangle {
                        visible: root.vkbMode === "alpha"
                        width: vkbCtrlRow.avail * 0.15; height: 52; radius: 10
                        color: root.vkbLower ? Qt.darker(root.cCyan, 2.6) : root.cRaised
                        border.color: root.vkbLower ? root.cCyan : root.cBorder
                        Text { anchors.centerIn: parent; text: root.vkbLower ? "abc" : "ABC"
                               color: root.cCyan; font.pixelSize: 16; font.bold: true }
                        TapHandler { onTapped: root.vkbLower = !root.vkbLower }
                    }
                    // SPACE (alpha only)
                    Rectangle {
                        visible: root.vkbMode === "alpha"
                        width: vkbCtrlRow.avail * 0.40; height: 52; radius: 10
                        color: root.cRaised; border.color: root.cBorder
                        Text { anchors.centerIn: parent; text: "SPACE"
                               color: root.cMuted; font.pixelSize: 16; font.bold: true }
                        TapHandler { onTapped: {
                            if (root.vkbTarget) root.vkbTarget.text += " "
                        }}
                    }
                    // BACKSPACE (FIX: znak "?" byl zgubionym symbolem Unicode)
                    Rectangle {
                        width: vkbCtrlRow.avail * (root.vkbMode === "alpha" ? 0.20 : 0.5)
                        height: 52; radius: 10
                        color: Qt.darker(root.cRed, 2.6); border.color: root.cRed
                        Text { anchors.centerIn: parent; text: "\u2190 DEL"
                               color: root.cRed; font.pixelSize: 18; font.bold: true }
                        TapHandler { onTapped: {
                            if (root.vkbTarget && root.vkbTarget.text.length > 0)
                                root.vkbTarget.text = root.vkbTarget.text.slice(0,-1)
                        }}
                    }
                    // OK / CLOSE
                    Rectangle {
                        width: vkbCtrlRow.avail * (root.vkbMode === "alpha" ? 0.25 : 0.5)
                        height: 52; radius: 10
                        color: Qt.darker(root.cGreen, 2.6); border.color: root.cGreen
                        Text { anchors.centerIn: parent; text: "OK"
                               color: root.cGreen; font.pixelSize: 18; font.bold: true }
                        TapHandler { onTapped: root.vkbMode = "" }
                    }
                }
            }
        }
    }

    // =======================================================================
    //  TOAST (komunikaty statusu z backendu)
    // =======================================================================
    Rectangle {
        id: toast
        z: 150
        visible: opacity > 0
        opacity: root.toastText !== "" ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top; anchors.topMargin: 70     // pod gornym paskiem
        width: Math.min(parent.width - 40, toastLbl.implicitWidth + 40)
        height: 48; radius: 24
        color: root.cRaised; border.color: root.cAmber; border.width: 2
        Text {
            id: toastLbl; anchors.centerIn: parent
            width: Math.min(implicitWidth, toast.width - 30)
            text: root.toastText; color: root.cText
            font.pixelSize: 16; font.bold: true; elide: Text.ElideRight
        }
        TapHandler { onTapped: root.toastText = "" }
    }

    // =======================================================================
    //  TOP BAR
    // =======================================================================
    Rectangle {
        id: topBar
        anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
        height: 60; color: root.cSurface; z: 10
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.cBorder }

        Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left; anchors.leftMargin: 12
            spacing: 8

            Text {
                text: "IC-7000 " + appConfig.callsign; color: root.cLcdGreen
                font.pixelSize: 15; font.bold: true; font.letterSpacing: 1
                anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
                width: 62; height: 36; radius: 18; anchors.verticalCenter: parent.verticalCenter
                color: Qt.darker(root.isTx ? root.cRed : root.cGreen, 3.6)
                border.color: root.isTx ? root.cRed : root.cGreen; border.width: 2
                Text { anchors.centerIn: parent; text: root.isTx ? "TX" : "RX"
                       color: root.isTx ? root.cRed : root.cGreen
                       font.pixelSize: 16; font.bold: true; font.letterSpacing: 2 }
            }
            Rectangle {
                width: 104; height: 36; radius: 8; anchors.verticalCenter: parent.verticalCenter
                color: root.cCard; border.color: root.cBorder; border.width: 1
                Text { anchors.centerIn: parent; text: root.utcText; color: root.cCyan
                       font.family: "DejaVu Sans Mono"; font.pixelSize: 16; font.bold: true }
            }
            Rectangle {
                height: 36; radius: 8; anchors.verticalCenter: parent.verticalCenter
                width: stText.implicitWidth + 18
                color: Qt.darker(root.isConn ? root.cGreen : root.cRed, 3.8)
                border.color: root.isConn ? root.cGreen : root.cRed; border.width: 2
                Text {
                    id: stText; anchors.centerIn: parent
                    text: root.isConn ? "ONLINE" : "OFFLINE"
                    color: root.isConn ? root.cGreen : root.cRed
                    font.pixelSize: 12; font.bold: true
                }
            }
        }

        Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right; anchors.rightMargin: 10
            spacing: 6

            Repeater {
                model: [
                    {lbl:"RADIO",  pg:"radio",   ac:"#1e90d8"},
                    {lbl:"MEMORY", pg:"memory",  ac:"#18d060"},
                    {lbl:"PROP",   pg:"weather", ac:"#f0a020"},
                    {lbl:"CW/RTTY",pg:"cwrtty",  ac:"#9070ff"},
                    {lbl:"APRS",   pg:"aprs",    ac:"#00d4e8"},
                ]
                delegate: Rectangle {
                    width: Math.max(60, tabLbl.implicitWidth + 16)
                    height: 36; radius: 8; anchors.verticalCenter: parent.verticalCenter
                    color: root.page === modelData.pg
                           ? Qt.darker(modelData.ac, 2.8) : root.cRaised
                    border.color: root.page === modelData.pg ? modelData.ac : root.cBorder
                    border.width: root.page === modelData.pg ? 2 : 1
                    Text {
                        id: tabLbl; anchors.centerIn: parent; text: modelData.lbl
                        color: root.page === modelData.pg ? modelData.ac : root.cText
                        font.pixelSize: 12; font.bold: true
                    }
                    TapHandler {
                        onTapped: {
                            if (root.page === "aprs" && modelData.pg !== "aprs")
                                backend.stopAprsPolling()
                            root.page = modelData.pg
                            if (modelData.pg === "weather") {
                                root.sol_busy = true; backend.refreshSolarAuto()
                            }
                            if (modelData.pg === "aprs") {
                                backend.startAprsPolling()
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: 100; height: 36; radius: 8; anchors.verticalCenter: parent.verticalCenter
                color: Qt.darker(root.isConn ? root.cRed : root.cGreen, 3.2)
                border.color: root.isConn ? root.cRed : root.cGreen; border.width: 2
                Text { anchors.centerIn: parent
                       text: root.isConn ? "DISCONN" : "CONNECT"
                       color: root.isConn ? root.cRed : root.cGreen
                       font.pixelSize: 12; font.bold: true }
                TapHandler { onTapped: root.isConn ? backend.disconnectRadio() : dlg.openDlg() }
            }
            Rectangle {
                width: 60; height: 36; radius: 8; anchors.verticalCenter: parent.verticalCenter
                color: Qt.darker(root.cRed, 3.2); border.color: root.cRed; border.width: 2
                Text { anchors.centerIn: parent; text: "EXIT"
                       color: root.cRed; font.pixelSize: 13; font.bold: true }
                TapHandler { onTapped: Qt.quit() }
            }
        }
    }

    // =======================================================================
    //  PAGE AREA
    // =======================================================================
    Item {
        anchors.top: topBar.bottom; anchors.left: parent.left
        anchors.right: parent.right; anchors.bottom: parent.bottom

        // == RADIO PAGE ====================================================
        Item {
            anchors.fill: parent; anchors.margins: 8
            visible: root.page === "radio"

            // LEFT COLUMN
            Item {
                id: leftCol
                anchors.top: parent.top; anchors.bottom: parent.bottom
                anchors.left: parent.left; anchors.right: rightCol.left
                anchors.rightMargin: 8

                // -- LCD --------------------------------------------------
                Rectangle {
                    id: lcdRect
                    anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                    height: 146; color: root.cLcdBg; radius: 12
                    border.color: "#1a5c35"; border.width: 2

                    Row {
                        anchors.fill: parent; anchors.margins: 12; spacing: 14

                        Column {
                            width: parent.width - 200 - 28 - 1; height: parent.height; spacing: 3
                            Text { text:"FREQUENCY"; color:root.cLcdDim; font.pixelSize:11; font.bold:true; font.letterSpacing:4 }
                            Text { width:parent.width; text:root.freqText; color:root.cLcdGreen
                                   font.family:"DejaVu Sans Mono"; font.pixelSize:50; font.bold:true; elide:Text.ElideRight }
                            Row { spacing: 6
                                Text { text:"MHz"; color:root.cLcdDim; font.pixelSize:12; font.bold:true; anchors.verticalCenter:parent.verticalCenter }
                                Repeater {
                                    model: [
                                        {lbl:root.curBand,  ac:root.cBlue},
                                        {lbl:root.curMode,  ac:root.cCyan},
                                        {lbl:"F"+root.curFilt, ac:root.cAmber},
                                        {lbl:root.curAgc===1?"AGC F":root.curAgc===2?"AGC M":"AGC S", ac:root.cGreen}
                                    ]
                                    delegate: Rectangle {
                                        height:22; radius:4; width:Math.max(44,bt.implicitWidth+14)
                                        color:Qt.darker(modelData.ac,3.4); border.color:modelData.ac
                                        Text { id:bt; anchors.centerIn:parent; text:modelData.lbl
                                               color:modelData.ac; font.pixelSize:11; font.bold:true; font.family:"DejaVu Sans Mono" }
                                    }
                                }
                            }
                            // S-metr (RX) / Po + SWR (TX)
                            Row { width: parent.width; height: 18; spacing: 8
                                Text { width: 30; text: root.isTx ? "PO" : "S"
                                       color: root.isTx ? root.cRed : root.cLcdDim
                                       font.pixelSize: 12; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
                                Rectangle {
                                    width: parent.width - 30 - 120 - 16; height: 10; radius: 3
                                    anchors.verticalCenter: parent.verticalCenter; color: "#020804"
                                    Rectangle {
                                        width: Math.max(2, root.meterLvl * parent.width); height: parent.height; radius: 3
                                        color: root.isTx ? root.cRed : (root.meterLvl > 0.5 ? root.cAmber : root.cLcdGreen)
                                        Behavior on width { NumberAnimation { duration: 120 } }
                                    }
                                }
                                Text { width: 120; text: root.meterText
                                       color: root.isTx ? root.cRed : root.cLcdGreen
                                       font.family: "DejaVu Sans Mono"; font.pixelSize: 13; font.bold: true
                                       anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight }
                            }
                        }

                        Rectangle { width:1; height:parent.height; color:root.cLcdDim; opacity:0.3 }

                        Column {
                            width: 200; height: parent.height; spacing: 2
                            Text { text:"TX POWER"; color:root.cLcdDim; font.pixelSize:11; font.bold:true; font.letterSpacing:4 }
                            Row {
                                spacing: 6
                                Text { text:root.txWatts(); color:root.isTx?root.cRed:root.cLcdGreen
                                       font.family:"DejaVu Sans Mono"; font.pixelSize:46; font.bold:true }
                                Column {
                                    anchors.bottom: parent.bottom; anchors.bottomMargin: 4; spacing: 2
                                    Text { text:"W"; color:root.cLcdDim; font.pixelSize:17; font.bold:true }
                                    Text {
                                        text: "CI-V"
                                        color: root.civActive ? root.cGreen : root.cDim
                                        font.pixelSize:9; font.bold:true; font.letterSpacing:1
                                        opacity: root.civActive ? 1.0 : 0.3
                                        Behavior on opacity { NumberAnimation{duration:200} }
                                        Behavior on color   { ColorAnimation{duration:200} }
                                        rotation: root.civActive ? root.civAngle : 0
                                        Behavior on rotation { RotationAnimation{duration:120;direction:RotationAnimation.Clockwise} }
                                    }
                                }
                            }
                            Rectangle {
                                width:180; height:6; radius:3; color:"#020804"
                                Rectangle { width:Math.max(4,root.setPwrPct/100.0*parent.width); height:parent.height; radius:3; color:root.arcColor(root.setPwrPct) }
                            }
                            Text { text:root.setPwrPct+"% | "+root.maxPwr+" W MAX"; color:root.cLcdDim; font.family:"DejaVu Sans Mono"; font.pixelSize:10 }
                        }
                    }
                }

                // -- ARC GAUGES --------------------------------------------
                // FIX: no anchors inside Row children; use width only
                Row {
                    id: gaugesRow
                    anchors.top: lcdRect.bottom; anchors.topMargin: 7
                    anchors.left: parent.left; anchors.right: parent.right
                    height: 200; spacing: 8

                    // TX PWR card - arc only, no buttons
                    Rectangle {
                        id: pwrCard
                        width: (parent.width - 8) / 2; height: parent.height
                        color: root.cCard; radius: 12
                        border.color: Qt.darker(root.arcColor(root.setPwrPct),1.8); border.width: 1

                        Column {
                            anchors.fill: parent; anchors.margins: 10; spacing: 6

                            Text { text:"TX PWR"; color:root.cText; font.pixelSize:16; font.bold:true; font.letterSpacing:2; height:20 }

                            // Large arc canvas - touch to set
                            Canvas {
                                id: pwrCanvas
                                width: parent.width
                                height: parent.height - 16 - 6
                                property int pct: root.setPwrPct
                                Connections { target:root
                                    function onSetPwrPctChanged(){ pwrCanvas.pct=root.setPwrPct; pwrCanvas.requestPaint() }
                                    // FIX: napis "xxW" odswiezany takze po zmianie pasma
                                    function onMaxPwrChanged(){ pwrCanvas.requestPaint() } }
                                Component.onCompleted: requestPaint()
                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.clearRect(0,0,width,height)
                                    var cx=width/2, cy=height*0.58, r=Math.min(cx,cy)*0.88
                                    var lw=Math.max(14,r*0.22)
                                    function rad(d){return d*Math.PI/180}
                                    var S=145, W=250
                                    // track
                                    ctx.beginPath(); ctx.arc(cx,cy,r,rad(S),rad(S+W))
                                    ctx.strokeStyle="#141a1e"; ctx.lineWidth=lw; ctx.lineCap="round"; ctx.stroke()
                                    // fill
                                    if(pct>0){
                                        var fc=pct>80?"#f03050":pct>50?"#f0a020":"#18d060"
                                        ctx.beginPath(); ctx.arc(cx,cy,r,rad(S),rad(S+W*(pct/100.0)))
                                        ctx.strokeStyle=fc; ctx.lineWidth=lw; ctx.lineCap="round"; ctx.stroke()
                                        // glow pass
                                        ctx.beginPath(); ctx.arc(cx,cy,r,rad(S),rad(S+W*(pct/100.0)))
                                        ctx.strokeStyle=fc; ctx.lineWidth=lw*0.4; ctx.globalAlpha=0.35; ctx.stroke()
                                        ctx.globalAlpha=1.0
                                    }
                                    // tick marks
                                    for(var i=0;i<=10;i++){
                                        var a=rad(S+W*i/10), r1=r-lw/2-2, r2=r1-(i%5===0?9:5)
                                        ctx.beginPath()
                                        ctx.moveTo(cx+r1*Math.cos(a), cy+r1*Math.sin(a))
                                        ctx.lineTo(cx+r2*Math.cos(a), cy+r2*Math.sin(a))
                                        ctx.strokeStyle="#2a3840"; ctx.lineWidth=2; ctx.globalAlpha=1; ctx.stroke()
                                    }
                                    // centre label
                                    ctx.fillStyle=pct>80?"#f03050":pct>50?"#f0a020":"#18d060"
                                    ctx.font="bold "+Math.round(r*0.38)+"px 'DejaVu Sans Mono'"
                                    ctx.textAlign="center"; ctx.textBaseline="middle"
                                    ctx.fillText(pct+"%", cx, cy-4)
                                    ctx.fillStyle="#4a6070"; ctx.font="bold "+Math.round(r*0.18)+"px sans-serif"
                                    ctx.fillText(root.txWatts()+"W", cx, cy+Math.round(r*0.28))
                                }
                                TapHandler { onTapped: function(e){
                                    var v = root.arcPct(pwrCanvas, e.position.x, e.position.y, true)
                                    if (v >= 0) root.sendPower(v)
                                }}
                                DragHandler { target:null; onCentroidChanged: {
                                    if(!active) return
                                    var p = centroid.position
                                    var v = root.arcPct(pwrCanvas, p.x, p.y, false)
                                    if (v >= 0) root.sendPower(v)
                                }}
                            }
                        }
                    }

                    // MIC GAIN card - arc only, no buttons
                    Rectangle {
                        id: micCard
                        width: (parent.width - 8) / 2; height: parent.height
                        color: root.cCard; radius: 12
                        border.color: Qt.darker(root.micColor(root.micPct),1.8); border.width: 1

                        Column {
                            anchors.fill: parent; anchors.margins: 10; spacing: 6

                            Text { text:"MIC GAIN"; color:root.cText; font.pixelSize:16; font.bold:true; font.letterSpacing:2; height:20 }

                            Canvas {
                                id: micCanvas
                                width: parent.width
                                height: parent.height - 16 - 6
                                property int pct: root.micPct
                                Connections { target:root; function onMicPctChanged(){ micCanvas.pct=root.micPct; micCanvas.requestPaint() } }
                                Component.onCompleted: requestPaint()
                                onPaint: {
                                    var ctx = getContext("2d")
                                    ctx.clearRect(0,0,width,height)
                                    var cx=width/2, cy=height*0.58, r=Math.min(cx,cy)*0.88
                                    var lw=Math.max(14,r*0.22)
                                    function rad(d){return d*Math.PI/180}
                                    var S=145, W=250
                                    ctx.beginPath(); ctx.arc(cx,cy,r,rad(S),rad(S+W))
                                    ctx.strokeStyle="#141a1e"; ctx.lineWidth=lw; ctx.lineCap="round"; ctx.stroke()
                                    if(pct>0){
                                        var fc=pct>80?"#f0a020":pct>50?"#18d060":"#00d4e8"
                                        ctx.beginPath(); ctx.arc(cx,cy,r,rad(S),rad(S+W*(pct/100.0)))
                                        ctx.strokeStyle=fc; ctx.lineWidth=lw; ctx.lineCap="round"; ctx.stroke()
                                        ctx.beginPath(); ctx.arc(cx,cy,r,rad(S),rad(S+W*(pct/100.0)))
                                        ctx.strokeStyle=fc; ctx.lineWidth=lw*0.4; ctx.globalAlpha=0.35; ctx.stroke()
                                        ctx.globalAlpha=1.0
                                    }
                                    for(var i=0;i<=10;i++){
                                        var a=rad(S+W*i/10), r1=r-lw/2-2, r2=r1-(i%5===0?9:5)
                                        ctx.beginPath()
                                        ctx.moveTo(cx+r1*Math.cos(a), cy+r1*Math.sin(a))
                                        ctx.lineTo(cx+r2*Math.cos(a), cy+r2*Math.sin(a))
                                        ctx.strokeStyle="#2a3840"; ctx.lineWidth=2; ctx.globalAlpha=1; ctx.stroke()
                                    }
                                    ctx.fillStyle=pct>80?"#f0a020":pct>50?"#18d060":"#00d4e8"
                                    ctx.font="bold "+Math.round(r*0.38)+"px 'DejaVu Sans Mono'"
                                    ctx.textAlign="center"; ctx.textBaseline="middle"
                                    ctx.fillText(pct+"%", cx, cy-4)
                                    ctx.fillStyle="#4a6070"; ctx.font="bold "+Math.round(r*0.18)+"px sans-serif"
                                    ctx.fillText("GAIN", cx, cy+Math.round(r*0.28))
                                }
                                TapHandler { onTapped: function(e){
                                    var v = root.arcPct(micCanvas, e.position.x, e.position.y, true)
                                    if (v >= 0) root.sendMic(v)
                                }}
                                DragHandler { target:null; onCentroidChanged: {
                                    if(!active) return
                                    var p = centroid.position
                                    var v = root.arcPct(micCanvas, p.x, p.y, false)
                                    if (v >= 0) root.sendMic(v)
                                }}
                            }
                        }
                    }
                }

                // -- MEMORY QUICK RECALL -----------------------------------
                Rectangle {
                    id: memQuickPanel
                    anchors.top: gaugesRow.bottom; anchors.topMargin: 7
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    color: root.cCard; radius: 10
                    border.color: Qt.darker(root.cGreen,2.0); border.width: 1
                    visible: memoryModel.count > 0

                    Column {
                        anchors.fill: parent; anchors.margins: 7; spacing: 5
                        Row { width:parent.width; height:13; spacing:5
                            Rectangle { width:3; height:13; radius:2; color:root.cGreen }
                            Text { text:"QUICK RECALL"; color:root.cGreen; font.pixelSize:13; font.bold:true; font.letterSpacing:3; anchors.verticalCenter:parent.verticalCenter }
                        }
                        Grid {
                            id: memQuickGrid
                            width: parent.width; height: parent.height - 18
                            columns: 5; columnSpacing: 5; rowSpacing: 5
                            property int btnW: Math.floor((width - 4*5) / 5)
                            property int rows: Math.min(3, Math.ceil(Math.min(memoryModel.count,15)/5))
                            property int btnH: rows > 0 ? Math.floor((height-(rows-1)*5)/rows) : 40
                            Repeater {
                                model: Math.min(memoryModel.count, 15)
                                delegate: Rectangle {
                                    width: memQuickGrid.btnW; height: memQuickGrid.btnH; radius: 7
                                    color: root.cRaised; border.color: root.cGreen; border.width: 1
                                    Column { anchors.centerIn:parent; spacing:1
                                        Text { anchors.horizontalCenter:parent.horizontalCenter
                                               text: memoryModel.get(index).name||memoryModel.get(index).freq
                                               color:root.cGreen; font.pixelSize:14; font.bold:true
                                               elide:Text.ElideRight; width:parent.parent.width-8
                                               horizontalAlignment:Text.AlignHCenter }
                                        Text { anchors.horizontalCenter:parent.horizontalCenter
                                               text:memoryModel.get(index).freq
                                               color:root.cLcdGreen; font.family:"DejaVu Sans Mono"; font.pixelSize:13
                                               elide:Text.ElideRight; width:parent.parent.width-8
                                               horizontalAlignment:Text.AlignHCenter }
                                    }
                                    TapHandler { onTapped: backend.recallMemory(index) }
                                }
                            }
                        }
                    }
                }
            }

            // RIGHT COLUMN
            Item {
                id: rightCol
                anchors.top: parent.top; anchors.bottom: parent.bottom
                anchors.right: parent.right; width: 390

                Rectangle {
                    id: bandsPanel
                    anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                    height: 148; color: root.cCard; radius: 10
                    border.color: Qt.darker(root.cBlue,1.8); border.width: 1
                    Column { anchors.fill:parent; anchors.margins:8; spacing:6
                        Row { width:parent.width; height:16; spacing:6
                            Rectangle { width:4; height:16; radius:2; color:root.cBlue }
                            Text { text:"BANDS"; color:root.cBlue; font.pixelSize:11; font.bold:true; font.letterSpacing:3; anchors.verticalCenter:parent.verticalCenter }
                        }
                        Grid { width:parent.width; height:parent.height-22; columns:6; rows:2; columnSpacing:6; rowSpacing:6
                            Repeater { id:bandRepeater; model:[]
                                delegate: Rectangle {
                                    width:(bandsPanel.width-16-5*6)/6; height:(bandsPanel.height-16-6-16-6)/2; radius:8
                                    color:root.curBand===modelData?Qt.darker(root.cBlue,2.6):root.cRaised
                                    border.color:root.curBand===modelData?root.cBlue:root.cBorder
                                    border.width:root.curBand===modelData?2:1
                                    Text { anchors.centerIn:parent; text:modelData
                                           color:root.curBand===modelData?root.cBlue:root.cText
                                           font.pixelSize:modelData.length>3?14:16; font.bold:true }
                                    TapHandler { onTapped: backend.setBand(modelData) }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    id: modesPanel
                    anchors.top: bandsPanel.bottom; anchors.topMargin: 8
                    anchors.left: parent.left; anchors.right: parent.right
                    height: 108; color: root.cCard; radius: 10
                    border.color: Qt.darker(root.cCyan,1.8); border.width: 1
                    Column { anchors.fill:parent; anchors.margins:8; spacing:6
                        Row { width:parent.width; height:16; spacing:6
                            Rectangle { width:4; height:16; radius:2; color:root.cCyan }
                            Text { text:"MODES"; color:root.cCyan; font.pixelSize:11; font.bold:true; font.letterSpacing:3; anchors.verticalCenter:parent.verticalCenter }
                        }
                        Grid { width:parent.width; height:parent.height-22; columns:4; rows:2; columnSpacing:6; rowSpacing:6
                            Repeater { id:modeRepeater; model:[]
                                delegate: Rectangle {
                                    width:(modesPanel.width-16-3*6)/4; height:(modesPanel.height-16-6-16-6)/2; radius:8
                                    color:root.curMode===modelData?Qt.darker(root.cCyan,2.6):root.cRaised
                                    border.color:root.curMode===modelData?root.cCyan:root.cBorder
                                    border.width:root.curMode===modelData?2:1
                                    Text { anchors.centerIn:parent; text:modelData
                                           color:root.curMode===modelData?root.cCyan:root.cText
                                           font.pixelSize:16; font.bold:true }
                                    TapHandler { onTapped: backend.setMode(modelData) }
                                }
                            }
                        }
                    }
                }

                Row {
                    id: filterAgcRow
                    anchors.top: modesPanel.bottom; anchors.topMargin: 8
                    anchors.left: parent.left; anchors.right: parent.right
                    height: 92; spacing: 8

                    Rectangle {
                        width:(parent.width-8)/2; height:parent.height; color:root.cCard; radius:10
                        border.color:Qt.darker(root.cAmber,1.8); border.width:1
                        Column { anchors.fill:parent; anchors.margins:8; spacing:6
                            Row { width:parent.width; height:16; spacing:6
                                Rectangle { width:4; height:16; radius:2; color:root.cAmber }
                                Text { text:"FILTER"; color:root.cAmber; font.pixelSize:11; font.bold:true; font.letterSpacing:3; anchors.verticalCenter:parent.verticalCenter }
                            }
                            Row { width:parent.width; height:parent.height-22; spacing:6
                                Repeater { model:[1,2,3]; delegate:Rectangle {
                                    width:(filterAgcRow.width/2-8-16-12)/3; height:parent.height; radius:8
                                    color:root.curFilt===modelData?Qt.darker(root.cAmber,2.6):root.cRaised
                                    border.color:root.curFilt===modelData?root.cAmber:root.cBorder
                                    border.width:root.curFilt===modelData?2:1
                                    Text { anchors.centerIn:parent; text:"F"+modelData
                                           color:root.curFilt===modelData?root.cAmber:root.cText
                                           font.pixelSize:15; font.bold:true }
                                    TapHandler { onTapped: backend.setFilter(modelData) }
                                }}
                            }
                        }
                    }

                    Rectangle {
                        width:(parent.width-8)/2; height:parent.height; color:root.cCard; radius:10
                        border.color:Qt.darker(root.cGreen,1.8); border.width:1
                        Column { anchors.fill:parent; anchors.margins:8; spacing:6
                            Row { width:parent.width; height:16; spacing:6
                                Rectangle { width:4; height:16; radius:2; color:root.cGreen }
                                Text { text:"AGC"; color:root.cGreen; font.pixelSize:11; font.bold:true; font.letterSpacing:3; anchors.verticalCenter:parent.verticalCenter }
                            }
                            Row { width:parent.width; height:parent.height-22; spacing:6
                                Repeater { model:[{lbl:"FAST",s:1},{lbl:"MED",s:2},{lbl:"SLOW",s:3}]; delegate:Rectangle {
                                    width:(filterAgcRow.width/2-8-16-12)/3; height:parent.height; radius:8
                                    color:root.curAgc===modelData.s?Qt.darker(root.cGreen,2.6):root.cRaised
                                    border.color:root.curAgc===modelData.s?root.cGreen:root.cBorder
                                    border.width:root.curAgc===modelData.s?2:1
                                    Text { anchors.centerIn:parent; text:modelData.lbl
                                           color:root.curAgc===modelData.s?root.cGreen:root.cText
                                           font.pixelSize:13; font.bold:true }
                                    TapHandler { onTapped: backend.setAgc(modelData.s) }
                                }}
                            }
                        }
                    }
                }

                // FUNCTIONS panel
                Rectangle {
                    id: fnPanel
                    anchors.top: filterAgcRow.bottom; anchors.topMargin: 8
                    anchors.left: parent.left; anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    color: root.cCard; radius: 10
                    border.color: Qt.darker(root.cViolet,1.8); border.width: 1

                    Column { anchors.fill:parent; anchors.margins:8; spacing:6
                        Row { width:parent.width; height:16; spacing:6
                            Rectangle { width:4; height:16; radius:2; color:root.cViolet }
                            Text { text:"FUNCTIONS"; color:root.cViolet; font.pixelSize:11; font.bold:true; font.letterSpacing:3; anchors.verticalCenter:parent.verticalCenter }
                        }
                        Row {
                            width: parent.width
                            height: parent.height - 22
                            spacing: 8

                            Rectangle {
                                id: compBtn
                                width: (parent.width-16)/3; height: parent.height; radius: 8
                                property bool checked: root.compOn      // FIX: stan z radia
                                color: checked?Qt.darker(root.cAmber,2.6):root.cRaised
                                border.color: checked?root.cAmber:root.cBorder; border.width: checked?2:1
                                Rectangle { width:8; height:8; radius:4; anchors.top:parent.top; anchors.right:parent.right; anchors.margins:5; color:root.cAmber; visible:parent.checked }
                                Text { anchors.centerIn:parent; text:"COMPRESS"; color:parent.checked?root.cAmber:root.cText; font.pixelSize:13; font.bold:true }
                                TapHandler { onTapped: backend.setToggle("COMP", !root.compOn) }
                            }
                            Rectangle {
                                id: scanBtn
                                width: (parent.width-16)/3; height: parent.height; radius: 8
                                property bool checked: root.scanOn
                                color: checked?Qt.darker(root.cGreen,2.6):root.cRaised
                                border.color: checked?root.cGreen:root.cBorder; border.width: checked?2:1
                                Rectangle { width:8; height:8; radius:4; anchors.top:parent.top; anchors.right:parent.right; anchors.margins:5; color:root.cGreen; visible:parent.checked }
                                Text { anchors.centerIn:parent; text:scanBtn.checked?"SCANNING":"SCAN"; color:scanBtn.checked?root.cGreen:root.cText; font.pixelSize:13; font.bold:true }
                                TapHandler { onTapped: backend.setScan(!root.scanOn) }
                            }
                            Rectangle {
                                width: (parent.width-16)/3; height: parent.height; radius: 8
                                color: root.vfoMem===1 ? Qt.darker(root.cViolet,2.6) : root.cRaised
                                border.color: root.cViolet; border.width: root.vfoMem===1 ? 2 : 1
                                Column { anchors.centerIn:parent; spacing:2
                                    Text { anchors.horizontalCenter:parent.horizontalCenter; text:"V/M"; color:root.cViolet; font.pixelSize:16; font.bold:true }
                                    Text { anchors.horizontalCenter:parent.horizontalCenter
                                           text: root.vfoMem===1 ? "MEM" : "VFO"
                                           color: root.vfoMem===1 ? root.cViolet : root.cDim; font.pixelSize:11; font.bold:true }
                                }
                                TapHandler { onTapped: backend.setVfoMem() }
                            }
                        }
                    }
                }
            }
        }

        // == MEMORY PAGE ==================================================
        Item {
            anchors.fill: parent; anchors.margins: 8
            visible: root.page === "memory"

            Rectangle {
                id: memAddPanel
                anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
                height: 120; color: root.cCard; radius: 10
                border.color: Qt.darker(root.cGreen,1.8); border.width: 1
                property string resultText: ""
                property bool   resultOk:   true

                Column { anchors.fill:parent; anchors.margins:8; spacing:4
                    Row { width:parent.width; height:14; spacing:6
                        Rectangle { width:4; height:14; radius:2; color:root.cGreen }
                        Text { text:"ADD CHANNEL"; color:root.cGreen; font.pixelSize:11; font.bold:true; font.letterSpacing:3; anchors.verticalCenter:parent.verticalCenter }
                        Text { text:memAddPanel.resultText; color:memAddPanel.resultOk?root.cGreen:root.cRed
                               font.pixelSize:11; font.bold:true; anchors.verticalCenter:parent.verticalCenter }
                    }
                    Row { id: memAddRow; width:parent.width; height:parent.height-22; spacing:8

                        // NAME - tap opens alpha keyboard
                        Column { width:150; height:parent.height; spacing:3
                            Text { text:"NAME"; color:root.cMuted; font.pixelSize:10; font.bold:true; font.letterSpacing:2 }
                            Rectangle {
                                width:parent.width; height:parent.height-13-3; radius:6
                                color:root.cRaised; border.color:root.cBorder; border.width:1
                                Text { anchors.fill:parent; anchors.leftMargin:8
                                       text:memNameField.text || " "
                                       color:root.cText; font.pixelSize:16; elide:Text.ElideRight
                                       verticalAlignment:Text.AlignVCenter }
                                TextInput { id:memNameField; visible:false }
                                TapHandler { onTapped: root.openVkb(memNameField, "alpha") }
                            }
                        }

                        // FREQ - puste = biezaca czestotliwosc
                        // FIX: wczesniej pole bylo wypelnione biezaca f, a klawiatura
                        // dopisywala cyfry na koncu ("14.200.0007074")
                        Column { width:170; height:parent.height; spacing:3
                            Text { text:"FREQ"; color:root.cMuted; font.pixelSize:10; font.bold:true; font.letterSpacing:2 }
                            Rectangle {
                                width:parent.width; height:parent.height-13-3; radius:6
                                color:root.cRaised; border.color:root.cBorder; border.width:1
                                Text { anchors.fill:parent; anchors.leftMargin:8
                                       text:memFreqField.text || root.freqText
                                       color:memFreqField.text ? root.cLcdGreen : root.cLcdDim
                                       font.pixelSize:16; font.family:"DejaVu Sans Mono"
                                       verticalAlignment:Text.AlignVCenter }
                                TextInput { id:memFreqField; visible:false }
                                TapHandler { onTapped: { memFreqField.text = ""; root.openVkb(memFreqField, "num") } }
                            }
                        }

                        // MODE
                        Column { width:110; height:parent.height; spacing:3
                            Text { text:"MODE"; color:root.cMuted; font.pixelSize:10; font.bold:true; font.letterSpacing:2 }
                            ComboBox {
                                id: memMode
                                width:parent.width; height:parent.height-13-3
                                model: ["AUTO","LSB","USB","AM","CW","CW-R","RTTY","RTTY-R","FM"]; font.pixelSize:15
                                background: Rectangle { color:root.cRaised; radius:6; border.color:root.cBorder }
                                contentItem: Text { leftPadding:8; text:memMode.displayText; color:root.cText; font.pixelSize:15; verticalAlignment:Text.AlignVCenter }
                            }
                        }

                        // TONE (CTCSS) - tap opens numeric keyboard
                        Column { width:100; height:parent.height; spacing:3
                            Text { text:"TONE Hz"; color:root.cMuted; font.pixelSize:10; font.bold:true; font.letterSpacing:2 }
                            Rectangle {
                                width:parent.width; height:parent.height-13-3; radius:6
                                color:root.cRaised; border.color:root.cBorder; border.width:1
                                Text { anchors.fill:parent; anchors.leftMargin:8
                                       text:memToneField.text || "OFF"
                                       color:memToneField.text ? root.cText : root.cDim; font.pixelSize:16
                                       verticalAlignment:Text.AlignVCenter }
                                TextInput { id:memToneField; visible:false }
                                TapHandler { onTapped: root.openVkb(memToneField, "num") }
                            }
                        }

                        // DUPLEX
                        Column { width:110; height:parent.height; spacing:3
                            Text { text:"DUPLEX"; color:root.cMuted; font.pixelSize:10; font.bold:true; font.letterSpacing:2 }
                            ComboBox {
                                id: memDup
                                width:parent.width; height:parent.height-13-3
                                model: ["SIMPLEX","DUP+","DUP-"]; font.pixelSize:15
                                palette.text:root.cText; palette.buttonText:root.cText; palette.windowText:root.cText
                                background: Rectangle { color:root.cRaised; radius:6; border.color:root.cBorder }
                                contentItem: Text { leftPadding:8; text:memDup.displayText; color:root.cText; font.pixelSize:15; verticalAlignment:Text.AlignVCenter }
                            }
                        }

                        // ADD button
                        Rectangle {
                            width: Math.max(70, memAddRow.width-150-170-110-100-110-5*8)
                            height: parent.height; radius:8
                            color:Qt.darker(root.cGreen,2.8); border.color:root.cGreen; border.width:2
                            Text { anchors.centerIn:parent; text:"ADD"; color:root.cGreen; font.pixelSize:17; font.bold:true }
                            TapHandler { onTapped: backend.addMemory(
                                memNameField.text,
                                memFreqField.text || root.freqText,
                                memToneField.text,
                                memDup.currentText,
                                memMode.currentText === "AUTO" ? "" : memMode.currentText) }
                        }
                    }
                }
            }

            Rectangle {
                anchors.top: memAddPanel.bottom; anchors.topMargin: 8
                anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                color: root.cCard; radius: 10
                border.color: Qt.darker(root.cGreen,1.8); border.width: 1
                Column { anchors.fill:parent; anchors.margins:8; spacing:5
                    Row { width:parent.width; height:14; spacing:6
                        Rectangle { width:4; height:14; radius:2; color:root.cGreen }
                        Text { text:"CHANNELS"; color:root.cGreen; font.pixelSize:11; font.bold:true; font.letterSpacing:3; anchors.verticalCenter:parent.verticalCenter }
                    }
                    ListView {
                        id: memList
                        width:parent.width; height:parent.height-19; spacing:4; clip:true; model:memoryModel
                        delegate: Rectangle {
                            id: memRow
                            width:memList.width; height:52; radius:7
                            color:index%2===0?root.cRaised:root.cCard; border.color:root.cBorder
                            property bool confirmDel: false
                            Timer { id: delTimer; interval: 3000; onTriggered: memRow.confirmDel = false }
                            Row { anchors.fill:parent; anchors.leftMargin:10; anchors.rightMargin:8; spacing:8
                                Rectangle { width:30; height:30; radius:15; anchors.verticalCenter:parent.verticalCenter; color:root.cDim
                                    Text { anchors.centerIn:parent; text:index+1; color:root.cText; font.pixelSize:12; font.bold:true }
                                }
                                Column { width:175; anchors.verticalCenter:parent.verticalCenter; spacing:1
                                    Text { text:model.name; color:root.cText; font.pixelSize:14; font.bold:true; elide:Text.ElideRight; width:parent.width }
                                    Text { text:(model.mode||"")+"  "+model.dup+(model.tone!==""?"  T:"+model.tone:""); color:root.cMuted; font.pixelSize:11 }
                                }
                                Text { width:parent.width-30-175-28-80-66-6*8; anchors.verticalCenter:parent.verticalCenter; text:model.freq; color:root.cLcdGreen; font.family:"DejaVu Sans Mono"; font.pixelSize:18; font.bold:true; horizontalAlignment:Text.AlignRight; elide:Text.ElideRight }
                                Text { width:28; anchors.verticalCenter:parent.verticalCenter; text:"MHz"; color:root.cDim; font.pixelSize:11 }
                                Rectangle { width:80; height:34; radius:7; anchors.verticalCenter:parent.verticalCenter; color:Qt.darker(root.cBlue,2.8); border.color:root.cBlue; border.width:2
                                    Text { anchors.centerIn:parent; text:"RECALL"; color:root.cBlue; font.pixelSize:12; font.bold:true }
                                    TapHandler { onTapped: backend.recallMemory(index) }
                                }
                                Rectangle { width:66; height:34; radius:7; anchors.verticalCenter:parent.verticalCenter; color:Qt.darker(root.cRed,2.8); border.color:root.cRed; border.width:2
                                    Text { anchors.centerIn:parent; text:memRow.confirmDel?"SURE?":"DEL"; color:root.cRed; font.pixelSize:12; font.bold:true }
                                    // dwa dotkniecia = usuniecie (ochrona przed przypadkowym DEL)
                                    TapHandler { onTapped: {
                                        if (memRow.confirmDel) { memRow.confirmDel = false; backend.removeMemory(index) }
                                        else { memRow.confirmDel = true; delTimer.restart() }
                                    }}
                                }
                            }
                        }
                    }
                }
            }
        }

        // == PROPAGATION PAGE (arc gauges) ================================
        Item {
            anchors.fill: parent; anchors.margins: 8
            visible: root.page === "weather"

            Column { anchors.fill:parent; spacing:8

                // Header
                Row { width:parent.width; height:46; spacing:10
                    Text { text:"PROPAGATION"; color:root.cText; font.pixelSize:26; font.bold:true; font.letterSpacing:2; anchors.verticalCenter:parent.verticalCenter }
                    Text { text:root.sol_updated; color:root.cDim; font.family:"DejaVu Sans Mono"; font.pixelSize:12; anchors.verticalCenter:parent.verticalCenter }
                    Item { width:1; height:1}
                    Rectangle { width:130; height:40; radius:8; anchors.verticalCenter:parent.verticalCenter
                        color:Qt.darker(root.cAmber,3.0); border.color:root.cAmber; border.width:2
                        Text { anchors.centerIn:parent; text:root.sol_busy?"LOADING...":"REFRESH"; color:root.cAmber; font.pixelSize:13; font.bold:true }
                        TapHandler { onTapped: { root.sol_busy=true; backend.refreshSolar() } }
                    }
                }

                Row { id:propBody; width:parent.width; height:parent.height-54; spacing:10

                    // ===== LEFT: arc gauges + tiles + geomag banner =====
                    Item {
                        id: propLeft
                        width:(parent.width-10)*0.46; height:parent.height

                        // 3 arc gauges
                        Row {
                            id: gaugeRow3
                            width:parent.width; height:parent.height*0.42; spacing:8
                            Repeater {
                                model:[
                                    {t:"SFI",    val:root.sol_sfi,  min:60,  max:300, unit:"",     kind:"sfi"},
                                    {t:"K-INDEX",val:root.sol_ki,   min:0,   max:9,   unit:"",     kind:"k"},
                                    {t:"SOL WIND",val:root.sol_wind,min:200, max:800, unit:"km/s", kind:"wind"}
                                ]
                                delegate: Rectangle {
                                    id: gaugeTile
                                    width:(gaugeRow3.width-16)/3; height:gaugeRow3.height
                                    color:root.cCard; radius:12
                                    property real v: root.num(modelData.val)
                                    property color gCol: modelData.kind==="sfi"  ? root.sfiColor(v)
                                                     : modelData.kind==="k"    ? root.kColor(v)
                                                     : root.windColor(v)
                                    property real ratio: Math.max(0, Math.min(1,
                                        (v - modelData.min) / (modelData.max - modelData.min)))
                                    border.color:Qt.darker(gCol,2.0); border.width:2

                                    Canvas {
                                        id: gaugeCv
                                        anchors.fill:parent; anchors.margins:6
                                        property real r: gaugeTile.ratio
                                        property color c: gaugeTile.gCol
                                        onRChanged: requestPaint()
                                        onCChanged: requestPaint()
                                        onVisibleChanged: if (visible) requestPaint()
                                        Component.onCompleted: requestPaint()
                                        onPaint: {
                                            var ctx = getContext("2d"); ctx.reset()
                                            var cx = width/2, cy = height/2 + 8
                                            var rad = Math.min(width, height)/2 - 10
                                            var a0 = Math.PI*0.75, a1 = Math.PI*2.25
                                            ctx.lineWidth = 10; ctx.lineCap = "round"
                                            ctx.strokeStyle = root.cRaised
                                            ctx.beginPath(); ctx.arc(cx,cy,rad,a0,a1,false); ctx.stroke()
                                            if (r > 0.005) {
                                                ctx.strokeStyle = c
                                                ctx.beginPath()
                                                ctx.arc(cx,cy,rad,a0,a0+(a1-a0)*r,false)
                                                ctx.stroke()
                                            }
                                        }
                                    }
                                    Column { anchors.centerIn:parent; anchors.verticalCenterOffset:6; spacing:0
                                        Text { anchors.horizontalCenter:parent.horizontalCenter
                                               text:modelData.val; color:gaugeTile.gCol
                                               font.family:"DejaVu Sans Mono"; font.pixelSize:24; font.bold:true }
                                        Text { anchors.horizontalCenter:parent.horizontalCenter
                                               visible:modelData.unit!==""
                                               text:modelData.unit; color:root.cDim; font.pixelSize:10 }
                                    }
                                    Text { anchors.top:parent.top; anchors.topMargin:8
                                           anchors.horizontalCenter:parent.horizontalCenter
                                           text:modelData.t; color:root.cMuted
                                           font.pixelSize:12; font.bold:true; font.letterSpacing:2 }
                                }
                            }
                        }

                        // 2x2 tiles
                        Grid {
                            id: propTiles
                            anchors.top:gaugeRow3.bottom; anchors.topMargin:8
                            anchors.left:parent.left; anchors.right:parent.right
                            anchors.bottom:geoBanner.top; anchors.bottomMargin:8
                            columns:2; columnSpacing:8; rowSpacing:8
                            Repeater { model:[
                                {t:"SUNSPOTS", v:root.sol_ssn,   ac:root.cCyan,   h:"SSN"},
                                {t:"A-INDEX",  v:root.sol_ai,    ac:root.cViolet, h:"Daily geomag avg"},
                                {t:"X-RAY",    v:root.sol_xray,  ac:root.cRed,    h:"X-Ray flux"},
                                {t:"NOISE",    v:root.sol_noise, ac:root.cGreen,  h:"Signal/Noise"}
                            ]
                            delegate: Rectangle {
                                width:(propTiles.width-8)/2; height:(propTiles.height-8)/2
                                color:root.cCard; radius:10
                                border.color:Qt.darker(modelData.ac,2.2); border.width:2
                                Column { anchors.centerIn:parent; spacing:2; width:parent.width-16
                                    Text { text:modelData.t; color:modelData.ac; font.pixelSize:13; font.bold:true; font.letterSpacing:2
                                           width:parent.width; horizontalAlignment:Text.AlignHCenter }
                                    Text { text:modelData.v; color:root.cText; font.family:"DejaVu Sans Mono"
                                           font.pixelSize:30; font.bold:true
                                           elide:Text.ElideRight; width:parent.width
                                           horizontalAlignment:Text.AlignHCenter }
                                    Text { text:modelData.h; color:root.cDim; font.pixelSize:11
                                           width:parent.width; horizontalAlignment:Text.AlignHCenter }
                                }
                            }}
                        }

                        // GEOMAG banner
                        Rectangle {
                            id: geoBanner
                            anchors.left:parent.left; anchors.right:parent.right
                            anchors.bottom:parent.bottom
                            height:52; radius:10
                            color:Qt.darker(root.geoColor(root.sol_geo),3.4)
                            border.color:root.geoColor(root.sol_geo); border.width:2
                            Row { anchors.fill:parent; anchors.leftMargin:14; spacing:14
                                Text { text:"GEOMAG"; color:root.cMuted; font.pixelSize:12; font.bold:true
                                       font.letterSpacing:2; anchors.verticalCenter:parent.verticalCenter }
                                Text { text:root.sol_geo; color:root.geoColor(root.sol_geo)
                                       font.family:"DejaVu Sans Mono"; font.pixelSize:22; font.bold:true
                                       anchors.verticalCenter:parent.verticalCenter }
                            }
                        }
                    }

                    // ===== RIGHT: band conditions =====
                    Rectangle {
                        id: bandCondPanel
                        width:(parent.width-10)*0.54; height:parent.height
                        color:root.cCard; radius:10
                        border.color:Qt.darker(root.cAmber,1.8); border.width:1
                        Column { anchors.fill:parent; anchors.margins:10; spacing:6
                            Row { width:parent.width; height:18; spacing:6
                                Rectangle { width:4; height:18; radius:2; color:root.cAmber }
                                Text { text:"BAND CONDITIONS"; color:root.cAmber; font.pixelSize:13; font.bold:true; font.letterSpacing:3; anchors.verticalCenter:parent.verticalCenter }
                            }
                            // DAY / NIGHT column headers
                            Row { width:parent.width; height:16; spacing:0
                                Item { width:140; height:1 }
                                Text { width:(parent.width-140-8)/2-4; text:"DAY"
                                       color:root.cAmber; font.pixelSize:13; font.bold:true
                                       font.letterSpacing:2; horizontalAlignment:Text.AlignHCenter }
                                Item { width:8; height:1 }
                                Text { width:(parent.width-140-8)/2-4; text:"NIGHT"
                                       color:root.cCyan; font.pixelSize:13; font.bold:true
                                       font.letterSpacing:2; horizontalAlignment:Text.AlignHCenter }
                            }
                            Repeater { model:[
                                {name:"80m-40m",label:"80m / 40m"},
                                {name:"30m-20m",label:"30m / 20m"},
                                {name:"17m-15m",label:"17m / 15m"},
                                {name:"12m-10m",label:"12m / 10m"},
                                {name:"6m",     label:"6m"},
                                {name:"2m",     label:"2m"}
                            ]
                            delegate: Rectangle {
                                id: bandRow
                                width:parent.width
                                height:(parent.height-24-16-6-5*6)/6
                                radius:8; color:root.cRaised
                                property string dc: root.bandCond(modelData.name,"day")
                                property string nc: root.bandCond(modelData.name,"night")
                                Row { anchors.fill:parent; anchors.margins:7; spacing:0
                                    Text { width:140; anchors.verticalCenter:parent.verticalCenter
                                           text:modelData.label; color:root.cText; font.pixelSize:20; font.bold:true }
                                    Rectangle { width:(parent.width-140-8)/2-4; height:parent.height-8; radius:6
                                                anchors.verticalCenter:parent.verticalCenter
                                                color:Qt.darker(root.condColor(bandRow.dc),3.2)
                                                border.color:root.condColor(bandRow.dc); border.width:2
                                        Text { anchors.centerIn:parent
                                               text:root.condShort(bandRow.dc)
                                               color:root.condColor(bandRow.dc)
                                               font.family:"DejaVu Sans Mono"; font.pixelSize:18; font.bold:true }
                                    }
                                    Item { width:8; height:1 }
                                    Rectangle { width:(parent.width-140-8)/2-4; height:parent.height-8; radius:6
                                                anchors.verticalCenter:parent.verticalCenter
                                                color:Qt.darker(root.condColor(bandRow.nc),3.2)
                                                border.color:root.condColor(bandRow.nc); border.width:2
                                        Text { anchors.centerIn:parent
                                               text:root.condShort(bandRow.nc)
                                               color:root.condColor(bandRow.nc)
                                               font.family:"DejaVu Sans Mono"; font.pixelSize:18; font.bold:true }
                                    }
                                }
                            }}
                        }
                    }
                }
            }
        }

        // == CW/RTTY PAGE (fldigi XML-RPC) ================================
        Item {
            anchors.fill: parent; anchors.margins: 8
            visible: root.page === "cwrtty"

            QtObject {
                id: cwDecoder
                property string mode:        "CW"
                property bool   running:     false
                property string decodedText: ""
                property string statusText:  "fldigi: ---"
                property int    wpm:         20
                property int    toneHz:      700
                property bool   signalDetected: root.audioInLvl > 0.15
            }

            Connections {
                target: backend
                // FIX: limit dlugosci - inaczej tekst rosnie bez konca i spowalnia UI
                function onDecoderText(t) {
                    var s = cwDecoder.decodedText + t
                    if (s.length > 4000) s = s.slice(-3000)
                    cwDecoder.decodedText = s
                }
                function onDecoderStatus(s)  { cwDecoder.statusText = s }
                function onDecoderRunning(r) { cwDecoder.running = r }
            }

            Column {
                anchors.fill: parent; spacing: 8

                // -- Header row --------------------------------------------
                Row {
                    width: parent.width; height: 46; spacing: 10

                    Text { text:"CW / RTTY DECODER"; color:root.cText; font.pixelSize:20; font.bold:true; font.letterSpacing:2; anchors.verticalCenter:parent.verticalCenter }

                    Repeater {
                        model: ["CW","RTTY"]
                        delegate: Rectangle {
                            width:80; height:38; radius:8; anchors.verticalCenter:parent.verticalCenter
                            color:cwDecoder.mode===modelData?Qt.darker(root.cViolet,2.6):root.cRaised
                            border.color:cwDecoder.mode===modelData?root.cViolet:root.cBorder
                            border.width:cwDecoder.mode===modelData?2:1
                            Text { anchors.centerIn:parent; text:modelData
                                   color:cwDecoder.mode===modelData?root.cViolet:root.cText
                                   font.pixelSize:15; font.bold:true }
                            TapHandler { onTapped: {
                                cwDecoder.mode = modelData
                                if (cwDecoder.running)
                                    backend.startDecoder(modelData)
                            }}
                        }
                    }

                    // WPM (CW only) - keyer fldigi
                    Rectangle {
                        visible: cwDecoder.mode === "CW"
                        width:150; height:38; radius:8; anchors.verticalCenter:parent.verticalCenter
                        color:root.cCard; border.color:root.cBorder; border.width:1
                        Row { anchors.centerIn:parent; spacing:8
                            Text { text:"WPM:"; color:root.cMuted; font.pixelSize:12; font.bold:true; anchors.verticalCenter:parent.verticalCenter }
                            Rectangle { width:38; height:30; radius:6; color:root.cRaised; border.color:root.cBorder
                                Text { anchors.centerIn:parent; text:"-"; color:root.cText; font.pixelSize:18; font.bold:true }
                                TapHandler { onTapped: {
                                    cwDecoder.wpm = Math.max(5, cwDecoder.wpm-2)
                                    backend.setDecoderWpm(cwDecoder.wpm)
                                }}
                            }
                            Text { text:cwDecoder.wpm; color:root.cCyan; font.pixelSize:15; font.bold:true; font.family:"DejaVu Sans Mono"; anchors.verticalCenter:parent.verticalCenter }
                            Rectangle { width:38; height:30; radius:6; color:root.cRaised; border.color:root.cBorder
                                Text { anchors.centerIn:parent; text:"+"; color:root.cText; font.pixelSize:18; font.bold:true }
                                TapHandler { onTapped: {
                                    cwDecoder.wpm = Math.min(60, cwDecoder.wpm+2)
                                    backend.setDecoderWpm(cwDecoder.wpm)
                                }}
                            }
                        }
                    }

                    Rectangle { width:80; height:38; radius:8; anchors.verticalCenter:parent.verticalCenter
                        color:Qt.darker(root.cRed,3.2); border.color:root.cRed; border.width:2
                        Text { anchors.centerIn:parent; text:"CLEAR"; color:root.cRed; font.pixelSize:13; font.bold:true }
                        TapHandler { onTapped: {
                            cwDecoder.decodedText = ""
                            backend.clearDecoder()
                        }}
                    }
                    Rectangle { width:90; height:38; radius:8; anchors.verticalCenter:parent.verticalCenter
                        color:cwDecoder.running?Qt.darker(root.cRed,2.8):Qt.darker(root.cGreen,2.8)
                        border.color:cwDecoder.running?root.cRed:root.cGreen; border.width:2
                        Text { anchors.centerIn:parent; text:cwDecoder.running?"STOP":"START"
                               color:cwDecoder.running?root.cRed:root.cGreen; font.pixelSize:14; font.bold:true }
                        TapHandler { onTapped: {
                            if (cwDecoder.running) backend.stopDecoder()
                            else                   backend.startDecoder(cwDecoder.mode)
                        }}
                    }
                }

                // -- Audio level meters + sliders --------------------------
                Rectangle {
                    width:parent.width; height:110
                    color:root.cCard; radius:10; border.color:root.cBorder; border.width:1

                    Row {
                        anchors.fill:parent; anchors.margins:10; spacing:12

                        // Audio IN meter
                        Column { width:180; height:parent.height; spacing:4
                            Text { text:"AUDIO IN \u00b7 DEC"; color:root.cCyan; font.pixelSize:11; font.bold:true; font.letterSpacing:2 }
                            Row { width:parent.width; height:parent.height-20; spacing:8
                                Rectangle {
                                    width:24; height:parent.height; color:"#020804"; radius:4
                                    Rectangle {
                                        anchors.bottom:parent.bottom; width:parent.width
                                        height:parent.height * root.audioInLvl; radius:3
                                        gradient: Gradient {
                                            GradientStop{position:0.0; color:root.audioInLvl>0.8?root.cRed:root.cAmber}
                                            GradientStop{position:0.5; color:root.cAmber}
                                            GradientStop{position:1.0; color:root.cGreen}
                                        }
                                        Behavior on height { NumberAnimation{duration:60} }
                                    }
                                    Rectangle { anchors.top:parent.top; width:parent.width; height:6; radius:2
                                        color:root.audioInLvl>=0.95?root.cRed:"#141a1e"
                                        Behavior on color { ColorAnimation{duration:100} }
                                    }
                                }
                                Column { width:parent.width-24-8; height:parent.height; spacing:4
                                    Text { text:"GAIN "+root.audioInGain+"%"; color:root.cMuted; font.pixelSize:10; font.family:"DejaVu Sans Mono" }
                                    Rectangle {
                                        width:parent.width; height:parent.height-18; radius:6; color:root.cRaised
                                        Rectangle {
                                            width:parent.width; height:Math.round(root.audioInGain/100.0*parent.height)
                                            anchors.bottom:parent.bottom; radius:6; color:Qt.darker(root.cCyan,2.0)
                                        }
                                        DragHandler { target:null; onCentroidChanged: {
                                            if(!active) return
                                            var p = centroid.position
                                            var pct = Math.round((1.0 - p.y/parent.height)*100)
                                            pct = Math.max(0, Math.min(100, pct))
                                            root.audioInGain = pct
                                            backend.setAudioInGain(pct)
                                        }}
                                        TapHandler { onTapped: function(e) {
                                            var pct = Math.round((1.0 - e.position.y/parent.height)*100)
                                            pct = Math.max(0, Math.min(100, pct))
                                            root.audioInGain = pct
                                            backend.setAudioInGain(pct)
                                        }}
                                    }
                                }
                            }
                        }

                        Rectangle { width:1; height:parent.height; color:root.cBorder }

                        // Audio OUT meter
                        Column { width:180; height:parent.height; spacing:4
                            Text { text:"AUDIO OUT \u00b7 TX"; color:root.cAmber; font.pixelSize:11; font.bold:true; font.letterSpacing:2 }
                            Row { width:parent.width; height:parent.height-20; spacing:8
                                Rectangle {
                                    width:24; height:parent.height; color:"#020804"; radius:4
                                    Rectangle {
                                        anchors.bottom:parent.bottom; width:parent.width
                                        height:parent.height * root.audioOutLvl; radius:3
                                        gradient: Gradient {
                                            GradientStop{position:0.0; color:root.audioOutLvl>0.8?root.cRed:root.cAmber}
                                            GradientStop{position:0.5; color:root.cAmber}
                                            GradientStop{position:1.0; color:root.cGreen}
                                        }
                                        Behavior on height { NumberAnimation{duration:60} }
                                    }
                                    Rectangle { anchors.top:parent.top; width:parent.width; height:6; radius:2
                                        color:root.audioOutLvl>=0.95?root.cRed:"#141a1e"
                                        Behavior on color { ColorAnimation{duration:100} }
                                    }
                                }
                                Column { width:parent.width-24-8; height:parent.height; spacing:4
                                    Text { text:"GAIN "+root.audioOutGain+"%"; color:root.cMuted; font.pixelSize:10; font.family:"DejaVu Sans Mono" }
                                    Rectangle {
                                        width:parent.width; height:parent.height-18; radius:6; color:root.cRaised
                                        Rectangle {
                                            width:parent.width; height:Math.round(root.audioOutGain/100.0*parent.height)
                                            anchors.bottom:parent.bottom; radius:6; color:Qt.darker(root.cAmber,2.0)
                                        }
                                        DragHandler { target:null; onCentroidChanged: {
                                            if(!active) return
                                            var p = centroid.position
                                            var pct = Math.round((1.0 - p.y/parent.height)*100)
                                            pct = Math.max(0, Math.min(100, pct))
                                            root.audioOutGain = pct
                                            backend.setAudioOutGain(pct)
                                        }}
                                        TapHandler { onTapped: function(e) {
                                            var pct = Math.round((1.0 - e.position.y/parent.height)*100)
                                            pct = Math.max(0, Math.min(100, pct))
                                            root.audioOutGain = pct
                                            backend.setAudioOutGain(pct)
                                        }}
                                    }
                                }
                            }
                        }

                        Rectangle { width:1; height:parent.height; color:root.cBorder }

                        // Status column
                        Column { width:parent.width-180-180-2-12*4; height:parent.height; spacing:6
                            Text { text:"STATUS"; color:root.cMuted; font.pixelSize:11; font.bold:true; font.letterSpacing:2 }
                            Text { text:"MODE: "+cwDecoder.mode; color:root.cViolet; font.pixelSize:13; font.bold:true }
                            Text { text:cwDecoder.statusText; color:root.cDim; font.pixelSize:11 }
                            Text {
                                text: cwDecoder.running
                                      ? (cwDecoder.signalDetected ? "* DECODING" : "o LISTENING")
                                      : "- STOPPED"
                                color: cwDecoder.running
                                       ? (cwDecoder.signalDetected ? root.cGreen : root.cAmber)
                                       : root.cDim
                                font.pixelSize:14; font.bold:true
                            }
                            Text { visible:cwDecoder.mode==="CW"; text:"TONE: "+cwDecoder.toneHz+" Hz"; color:root.cCyan; font.pixelSize:11; font.family:"DejaVu Sans Mono" }
                        }
                    }
                }

                // -- Decoded text ------------------------------------------
                Rectangle {
                    width:parent.width; height:parent.height-46-8-110-8-70-8
                    color:root.cLcdBg; radius:10; border.color:"#1a5c35"; border.width:2
                    Column { anchors.fill:parent; anchors.margins:10; spacing:6
                        Text { text:"DECODED TEXT"; color:root.cLcdDim; font.pixelSize:10; font.bold:true; font.letterSpacing:4 }
                        Flickable {
                            width:parent.width; height:parent.height-20
                            contentWidth:decodedTxt.implicitWidth; contentHeight:decodedTxt.implicitHeight
                            clip:true
                            onContentHeightChanged: if(contentHeight>height) contentY=contentHeight-height
                            Text {
                                id:decodedTxt; width:parent.parent.width
                                text:cwDecoder.decodedText || "-- Waiting for signal --"
                                color:cwDecoder.decodedText?root.cLcdGreen:root.cLcdDim
                                font.family:"DejaVu Sans Mono"; font.pixelSize:20; font.bold:true
                                wrapMode:Text.Wrap
                            }
                        }
                    }
                }

                // -- Status / last chars bar -------------------------------
                Rectangle {
                    width:parent.width; height:70; radius:8
                    color:root.cCard; border.color:root.cBorder; border.width:1
                    Row { anchors.fill:parent; anchors.margins:8; spacing:8
                        Text { text:"RAW"; color:root.cDim; font.pixelSize:10; font.bold:true; font.letterSpacing:2; anchors.verticalCenter:parent.verticalCenter; width:30 }
                        Text {
                            text: cwDecoder.decodedText
                                  ? cwDecoder.decodedText.slice(-60)
                                  : cwDecoder.statusText
                            color:root.cGreen; font.family:"DejaVu Sans Mono"; font.pixelSize:13
                            anchors.verticalCenter:parent.verticalCenter
                            elide:Text.ElideLeft; width:parent.width-38-8
                        }
                    }
                }
            }
        }

        // == APRS PAGE ====================================================
        Item {
            anchors.fill: parent; anchors.margins: 8
            visible: root.page === "aprs"

            Column {
                anchors.fill: parent; spacing: 8

                // Header
                Row {
                    width: parent.width; height: 46; spacing: 10
                    Text { text:"APRS  " + appConfig.callsign + "  " + appConfig.locator + "  144.800 FM"
                           color:root.cText; font.pixelSize:18; font.bold:true; font.letterSpacing:1
                           anchors.verticalCenter:parent.verticalCenter }
                    Text { text: root.freqText === "144.800.000" && root.curMode === "FM"
                                 ? "\u2713 RADIO OK" : "\u26a0 RADIO: " + root.freqText + " " + root.curMode
                           color: root.freqText === "144.800.000" && root.curMode === "FM" ? root.cGreen : root.cAmber
                           font.pixelSize:13; font.bold:true; anchors.verticalCenter:parent.verticalCenter }
                    Rectangle { width:110; height:38; radius:8; anchors.verticalCenter:parent.verticalCenter
                        color:Qt.darker(root.cCyan,3.0); border.color:root.cCyan; border.width:2
                        Text { anchors.centerIn:parent; text:"RETUNE"; color:root.cCyan; font.pixelSize:13; font.bold:true }
                        TapHandler { onTapped: backend.startAprsPolling() }
                    }
                }

                // Upper section: incoming messages
                Rectangle {
                    width:parent.width; height:(parent.height-46-8-76-8)*0.999
                    color:root.cCard; radius:10; border.color:Qt.darker(root.cCyan,1.8); border.width:1
                    Column { anchors.fill:parent; anchors.margins:8; spacing:4
                        Row { width:parent.width; height:14; spacing:6
                            Rectangle { width:4; height:14; radius:2; color:root.cCyan }
                            Text { text:"RECEIVED STATIONS / MESSAGES"; color:root.cCyan
                                   font.pixelSize:11; font.bold:true; font.letterSpacing:3
                                   anchors.verticalCenter:parent.verticalCenter }
                        }
                        ListView {
                            id: aprsListView
                            width:parent.width; height:parent.height-22; spacing:2; clip:true
                            model: aprsModel
                            delegate: Rectangle {
                                width:aprsListView.width; height:40; radius:5
                                color:index%2===0?root.cRaised:root.cCard
                                // wiadomosci do/od wlasnego znaku wyroznione
                                border.color: model.mine ? root.cAmber : root.cBorder
                                border.width: model.mine ? 2 : 1
                                Row { anchors.fill:parent; anchors.leftMargin:10; anchors.rightMargin:8; spacing:10
                                    Text { width:118; anchors.verticalCenter:parent.verticalCenter
                                           text:model.callsign; color:root.cCyan
                                           font.family:"DejaVu Sans Mono"; font.pixelSize:16; font.bold:true }
                                    Text { width:parent.width-118-66-20; anchors.verticalCenter:parent.verticalCenter
                                           text:model.comment; color:root.cText; font.pixelSize:15
                                           elide:Text.ElideRight }
                                    Text { width:66; anchors.verticalCenter:parent.verticalCenter
                                           text:model.time; color:root.cDim
                                           font.pixelSize:11; font.family:"DejaVu Sans Mono"
                                           horizontalAlignment:Text.AlignRight }
                                }
                            }
                        }
                    }
                }

                // Lower section: send message
                Rectangle {
                    width:parent.width; height:76
                    color:root.cCard; radius:10
                    border.color:Qt.darker(root.cGreen,1.8); border.width:1
                    Column { anchors.fill:parent; anchors.margins:8; spacing:4
                        Row { width:parent.width; height:12; spacing:6
                            Rectangle { width:4; height:12; radius:2; color:root.cGreen }
                            Text { text:"SEND   \u00b7   CALL: tekst = wiadomosc   \u00b7   sam tekst = beacon pozycji"; color:root.cGreen; font.pixelSize:10; font.bold:true; font.letterSpacing:2; anchors.verticalCenter:parent.verticalCenter }
                        }
                        Row { width:parent.width; height:parent.height-18; spacing:8
                            Rectangle {
                                width:parent.width-110-8; height:parent.height; radius:8
                                color:root.cRaised; border.color:root.cBorder; border.width:1
                                Text { anchors.fill:parent; anchors.leftMargin:10
                                       text:aprsMsgInput.text || "np. SP2ABC: CZESC   lub   QRV 144.800"
                                       color:aprsMsgInput.text?root.cText:root.cDim
                                       font.pixelSize:18; verticalAlignment:Text.AlignVCenter }
                                TextInput { id:aprsMsgInput; visible:false }
                                TapHandler { onTapped: root.openVkb(aprsMsgInput, "alpha") }
                            }
                            Rectangle { width:110; height:parent.height; radius:8
                                color:Qt.darker(root.cGreen,2.8); border.color:root.cGreen; border.width:2
                                Text { anchors.centerIn:parent; text:"SEND"; color:root.cGreen; font.pixelSize:18; font.bold:true }
                                TapHandler { onTapped: {
                                    if(aprsMsgInput.text.length>0) {
                                        backend.sendAprsMessage(aprsMsgInput.text)
                                        aprsMsgInput.text=""
                                    }
                                }}
                            }
                        }
                    }
                }
            }
        }
    }

    // =======================================================================
    //  CONNECT DIALOG  (now includes audio device selector)
    // =======================================================================
    Item { id:modal; anchors.fill:parent; visible:false; z:100
        // FIX: tlo dialogu przechwytuje dotyk (wczesniej dotkniecie obok
        // dialogu klikalo przyciski pod spodem)
        Rectangle { anchors.fill:parent; color:"#cc000000"
            MouseArea { anchors.fill:parent; cursorShape: Qt.BlankCursor } }
        Rectangle {
            id:dlg; anchors.centerIn:parent
            width:Math.min(root.width-80,580); height:460
            radius:12; color:root.cBg; border.color:root.cCyan; border.width:2
            property string errorText: ""
            property bool   busy:      false
            property var    portList:  []
            property var    audioList: []
            function openDlg() {
                errorText=""; busy=false
                backend.getPorts(); backend.getAudioDevices()
                if (portInput.text === "")
                    portInput.text = portList.length ? portList[0] : "/dev/ttyUSB0"
                modal.visible=true
            }

            Column { anchors.fill:parent; anchors.margins:22; spacing:12

                Text { text:"CI-V CONNECTION"; color:root.cText; font.pixelSize:22; font.bold:true; font.letterSpacing:2 }

                // PORT - FIX: na ekranie dotykowym bez klawiatury TextField byl
                // nie do edycji; teraz pole otwiera wirtualna klawiature
                Row { width:parent.width; height:52; spacing:16
                    Text { width:110; height:parent.height; text:"PORT"; color:root.cMuted; font.pixelSize:15; font.bold:true; font.letterSpacing:2; verticalAlignment:Text.AlignVCenter }
                    Row { width:parent.width-126; height:52; spacing:8
                        Rectangle {
                            width:parent.width-96-8; height:52; radius:8
                            color:root.cRaised; border.color:root.cBorder
                            Text { anchors.fill:parent; anchors.leftMargin:10
                                   text:portInput.text || "/dev/..."
                                   color:root.cText; font.pixelSize:17; font.family:"DejaVu Sans Mono"
                                   verticalAlignment:Text.AlignVCenter; elide:Text.ElideLeft }
                            TextInput { id:portInput; visible:false }
                            TapHandler { onTapped: { root.openVkb(portInput, "alpha"); root.vkbLower = true } }
                        }
                        ComboBox {
                            id:portCombo; width:96; height:52
                            model:dlg.portList.length?dlg.portList:["/dev/ttyAS2","/dev/ttyUSB0","/dev/ttyUSB1"]
                            font.pixelSize:15
                            displayText: "LIST"
                            onActivated: portInput.text = currentText
                            background: Rectangle { color:root.cRaised; radius:8; border.color:root.cBorder }
                            contentItem: Text { leftPadding:10; text:portCombo.displayText; color:root.cCyan; font.pixelSize:15; font.bold:true; verticalAlignment:Text.AlignVCenter }
                            delegate: ItemDelegate {
                                width:260
                                contentItem: Text { text:modelData; color:root.cText; font.pixelSize:16; leftPadding:10; font.family:"DejaVu Sans Mono" }
                                background: Rectangle { color:hovered?root.cRaised:root.cCard }
                            }
                            popup: Popup {
                                y:portCombo.height+2; x:portCombo.width-260; width:260; padding:1
                                contentItem: ListView { clip:true; model:portCombo.delegateModel; implicitHeight:Math.min(contentHeight,240); implicitWidth:260 }
                                background: Rectangle { color:root.cCard; radius:8; border.color:root.cBorder }
                            }
                        }
                    }
                }

                // BAUD
                Row { width:parent.width; height:52; spacing:16
                    Text { width:110; height:parent.height; text:"BAUD"; color:root.cMuted; font.pixelSize:15; font.bold:true; font.letterSpacing:2; verticalAlignment:Text.AlignVCenter }
                    ComboBox {
                        id:baudCombo; width:parent.width-126; height:52
                        model:["9600","4800","19200"]; font.pixelSize:17
                        background: Rectangle { color:root.cRaised; radius:8; border.color:root.cBorder }
                        contentItem: Text { leftPadding:10; text:baudCombo.displayText; color:root.cText; font.pixelSize:17; verticalAlignment:Text.AlignVCenter }
                        delegate: ItemDelegate {
                            width:baudCombo.width
                            contentItem: Text { text:modelData; color:root.cText; font.pixelSize:16; leftPadding:10 }
                            background: Rectangle { color:hovered?root.cRaised:root.cCard }
                        }
                        popup: Popup {
                            y:baudCombo.height+2; width:baudCombo.width; padding:1
                            contentItem: ListView { clip:true; model:baudCombo.delegateModel; implicitHeight:contentHeight; implicitWidth:baudCombo.width }
                            background: Rectangle { color:root.cCard; radius:8; border.color:root.cBorder }
                        }
                    }
                }

                // CI-V ADDR
                Row { width:parent.width; height:52; spacing:16
                    Text { width:110; height:parent.height; text:"CI-V ADDR"; color:root.cMuted; font.pixelSize:13; font.bold:true; font.letterSpacing:2; verticalAlignment:Text.AlignVCenter; wrapMode:Text.WordWrap }
                    Rectangle {
                        width:140; height:52; radius:8; color:root.cRaised; border.color:root.cBorder
                        Text { anchors.centerIn:parent; text:(addrField.text || "70") + "h"
                               color:root.cText; font.family:"DejaVu Sans Mono"; font.pixelSize:20 }
                        TextInput { id:addrField; visible:false; text:"70" }
                        TapHandler { onTapped: { addrField.text = ""; root.openVkb(addrField, "alpha") } }
                    }
                }

                // AUDIO DEVICE
                Row { width:parent.width; height:52; spacing:16
                    Text { width:110; height:parent.height; text:"AUDIO DEV"; color:root.cMuted; font.pixelSize:13; font.bold:true; font.letterSpacing:2; verticalAlignment:Text.AlignVCenter; wrapMode:Text.WordWrap }
                    ComboBox {
                        id:audioCombo; width:parent.width-126; height:52
                        model:dlg.audioList.length?dlg.audioList:["default"]; font.pixelSize:14
                        background: Rectangle { color:root.cRaised; radius:8; border.color:root.cBorder }
                        contentItem: Text { leftPadding:8; text:audioCombo.displayText; color:root.cText; font.pixelSize:13; verticalAlignment:Text.AlignVCenter; elide:Text.ElideRight }
                        delegate: ItemDelegate {
                            width:audioCombo.width
                            contentItem: Text { text:modelData; color:root.cText; font.pixelSize:13; leftPadding:10; elide:Text.ElideRight }
                            background: Rectangle { color:hovered?root.cRaised:root.cCard }
                        }
                        popup: Popup {
                            y:audioCombo.height+2; width:audioCombo.width; padding:1
                            contentItem: ListView { clip:true; model:audioCombo.delegateModel; implicitHeight:Math.min(contentHeight,200); implicitWidth:audioCombo.width }
                            background: Rectangle { color:root.cCard; radius:8; border.color:root.cBorder }
                        }
                    }
                }

                Text { width:parent.width; text:dlg.errorText; color:root.cRed; font.pixelSize:14; visible:dlg.errorText!==""; elide:Text.ElideRight }

                Row { width:parent.width; spacing:12
                    Rectangle {
                        width:(parent.width-12)/2; height:58; radius:8
                        color:Qt.darker(root.cGreen,2.8); border.color:root.cGreen; border.width:2
                        opacity:dlg.busy?0.5:1.0
                        Text { anchors.centerIn:parent; text:dlg.busy?"CONNECTING...":"CONNECT"; color:root.cGreen; font.pixelSize:18; font.bold:true }
                        TapHandler { enabled:!dlg.busy; onTapped: {
                            var p = portInput.text.length ? portInput.text : portCombo.currentText
                            var audio = audioCombo.currentText
                            dlg.busy=true; dlg.errorText=""
                            backend.connectRadio(p, baudCombo.currentText, addrField.text || "70", audio)
                            modal.visible=false
                        }}
                    }
                    Rectangle {
                        width:(parent.width-12)/2; height:58; radius:8
                        color:Qt.darker(root.cRed,2.8); border.color:root.cRed; border.width:2
                        Text { anchors.centerIn:parent; text:"CANCEL"; color:root.cRed; font.pixelSize:18; font.bold:true }
                        TapHandler { onTapped: modal.visible=false }
                    }
                }
            }
        }
    }

    Shortcut { sequence:"Escape"; onActivated: root.visibility=Window.Windowed }
}
