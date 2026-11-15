import QtQuick
import jlqml

// Terminal pane: a ListView over the pane's row model, one HTML row per item. Each pane is a REPL pane
// or the pane of one MPI rank (both in Main.qml), and sets `paneId`, `rowModel` and `props` from the model
// that repeats it. Calls to Julia name the pane with `paneId` first, except `isPasteChord`,
// which only looks at the key. The owner sets `visible` for the pane, and a pane that is hidden is not
// sized or refilled. The row height and the column width are measured with TextMetrics and reported to
// Julia, which sizes the terminal in cells. Julia decides the window position. This file reports user
// scrolling, applies the offset that Julia returns after a refill. When Julia says the pane is following,
// the view moves to the row Julia names (the cursor row, when it is above the end of the output) or to
// the end.
//
// A REPL pane takes the keyboard when it is shown. A rank pane (`rankPane`) takes it only when its owner
// gives it the focus, and its border is dim while it does not have the focus. A rank pane cannot be
// restarted, so its end prompt has no Restart button and Return does nothing there.
//
// The pane holds keyboard focus. Each key press is passed to Julia, which writes the bytes for the
// child process; the event is accepted only when Julia reports that it sent something. Ctrl+Shift+V
// reads the clipboard through `pasteBuffer`, a hidden TextEdit, and passes the text to Julia.
//
// Left-button drags select text, and Shift with a left-button press or drag moves the end of an existing
// selection. Julia keeps the selection, so this file sends the matrix row and the column under the
// pointer. A drag past the top or bottom edge scrolls the view a row at a time.
// Julia makes the selected text the PRIMARY selection.
//
// The scrollbar at the right draws the thumb from `props.thumbTop` and `props.thumbSize`, which are
// fractions of the whole output. Julia maps a drag or a track click to a view position. Jump keys
// are sent to Julia first, and never reach the child.
Rectangle {
    id: pane
    color: "#24283b"
    border.color: rankPane && !activeFocus ? "#3b4261" : "#7aa2f7"
    border.width: 2
    radius: 4

    required property int paneId
    required property var rowModel
    required property var props
    // True for the pane of an MPI rank. Such a pane is not given the focus when it is shown, its border is
    // dim without the focus, and it has no Restart button.
    property bool rankPane: false

    readonly property real cellW: metrics.advanceWidth / 10
    readonly property real cellH: Math.ceil(metrics.height)
    readonly property int refillCount: props.refill

    TextMetrics {
        id: metrics
        font.family: "monospace"
        font.pixelSize: 13
        text: "MMMMMMMMMM"
    }

    // Sizes the tab's terminal. A hidden pane reports nothing: it is sized when it is shown.
    function reportSize() {
        if (visible && view.width > 0 && view.height > 0)
            Julia.paneSized(paneId, view.width, view.height, cellW, cellH)
    }

    function snapToEnd() {
        view.syncing = true
        view.positionViewAtEnd()
        view.syncing = false
    }

    // `row` is a 1-based matrix row. The view moves only as far as needed to show it.
    function showRow(row) {
        view.syncing = true
        view.positionViewAtIndex(row - 1, ListView.Contain)
        view.syncing = false
    }

    // Puts the top of the view at a 1-based matrix row, as returned by Julia. A row of 0 means that
    // the pane is following, and the follow rule places the view on the next refill.
    function applyRow(row) {
        if (row <= 0)
            return
        view.syncing = true
        view.contentY = (row - 1) * cellH
        view.syncing = false
    }

    // Matrix row (1-based) at a y coordinate in the view, and the 1-based column at an x coordinate.
    // Both may fall outside the view during a drag; Julia clamps them.
    function slotAt(y) {
        return Math.floor((y + view.contentY) / cellH) + 1
    }

    function colAt(x) {
        return Math.floor(x / cellW) + 1
    }

    onRefillCountChanged: {
        if (!props.follow)
            return
        if (props.target > 0)
            showRow(props.target)
        else
            snapToEnd()
    }

    // A shown pane is sized, and a REPL pane takes the keyboard. A pane that is hidden is sized when it
    // is shown again.
    function show() {
        reportSize()
        if (!rankPane)
            forceActiveFocus()
    }

    Component.onCompleted: {
        if (visible)
            show()
    }

    onVisibleChanged: {
        if (visible)
            show()
    }

    // Modifier keys alone leave the selection alone, so that Shift can be held before a Shift-click.
    function isModifierKey(key) {
        return key === Qt.Key_Shift || key === Qt.Key_Control || key === Qt.Key_Alt || key === Qt.Key_Meta
            || key === Qt.Key_AltGr || key === Qt.Key_CapsLock
    }

    Keys.onPressed: function (event) {
        // After a REPL has ended, Return restarts it. Other keys are not sent. A rank cannot be restarted.
        if (!rankPane && props.ended && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            Julia.restartSession(pane.paneId)
            event.accepted = true
            return
        }
        // Jump keys scroll the view and are not sent to the child. They keep the selection.
        var row = Julia.scrollKey(pane.paneId, event.key, event.modifiers)
        if (row >= 0) {
            pane.applyRow(row)
            event.accepted = true
            return
        }
        if (!pane.isModifierKey(event.key))
            Julia.clearSelection(pane.paneId)
        if (Julia.isPasteChord(event.key, event.modifiers)) {
            pasteBuffer.text = ""
            pasteBuffer.paste()
            event.accepted = Julia.pasteText(pane.paneId, pasteBuffer.text)
        } else {
            event.accepted = Julia.keyPressed(pane.paneId, event.key, event.text, event.modifiers)
        }
    }

    TextEdit {
        id: pasteBuffer
        visible: false
        textFormat: TextEdit.PlainText
    }

    ListView {
        id: view
        anchors.fill: parent
        anchors.margins: 6
        anchors.rightMargin: 22
        clip: true
        model: rowModel
        boundsBehavior: Flickable.StopAtBounds
        property bool syncing: false

        onWidthChanged: pane.reportSize()
        onHeightChanged: pane.reportSize()

        onContentYChanged: {
            if (syncing || height <= 0)
                return
            var first = Math.max(1, Math.floor(contentY / pane.cellH) + 1)
            var count = Math.ceil(height / pane.cellH)
            // Within one row of the end counts as the end: a wheel scroll can stop just short of it.
            var atEnd = contentY >= contentHeight - height - pane.cellH
            var shift = Julia.userScrolled(pane.paneId, first, count, atEnd)
            if (shift != 0) {
                // The matrix moved by `shift` rows; keep the same rows in view.
                syncing = true
                contentY -= shift * pane.cellH
                syncing = false
            }
        }

        delegate: Text {
            required property string html
            width: view.width
            height: pane.cellH
            text: html
            textFormat: Text.RichText
            wrapMode: Text.NoWrap
            font.family: "monospace"
            font.pixelSize: 13
            color: "#c0caf5"
            verticalAlignment: Text.AlignVCenter
        }
    }

    // Scrollbar. The thumb's size and position are fractions of the whole output, which Julia supplies
    // (see `PaneModel.scrollbar_state`). The thumb is at least `minThumb` pixels, so that it can be
    // grabbed at any output length. A drag keeps the pointer's offset in the thumb, and Julia maps the
    // thumb's fraction to the view. A press on the track moves the view by one page.
    Rectangle {
        id: bar
        readonly property real minThumb: 24
        readonly property real thumbHeight: Math.min(height, Math.max(minThumb, props.thumbSize * height))
        readonly property real room: height - thumbHeight

        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.topMargin: 6
        anchors.bottomMargin: 6
        anchors.rightMargin: 6
        width: 12
        radius: 3
        color: "#1f2335"

        Rectangle {
            id: thumb
            width: parent.width
            height: bar.thumbHeight
            y: props.thumbTop * bar.room
            radius: 3
            color: "#7aa2f7"
        }

        MouseArea {
            id: barMouse
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            property bool dragging: false
            property real grabOffset: 0

            onPressed: function (mouse) {
                pane.forceActiveFocus()
                var t = thumb.y
                if (mouse.y >= t && mouse.y <= t + thumb.height) {
                    dragging = true
                    grabOffset = mouse.y - t
                } else {
                    dragging = false
                    pane.applyRow(Julia.pageView(pane.paneId, mouse.y < t ? -1 : 1))
                }
            }

            onPositionChanged: function (mouse) {
                if (!dragging || bar.room <= 0)
                    return
                var f = Math.max(0, Math.min(1, (mouse.y - grabOffset) / bar.room))
                pane.applyRow(Julia.scrollToFraction(pane.paneId, f))
            }

            onReleased: dragging = false
        }
    }

    // Mouse selection. A press starts a selection, and a second or third press within half a second
    // and near the first selects a word or a line. A press with Shift moves the active end of the
    // selection instead, and is not counted as a click. A drag extends the selection when it started
    // with a plain press (clicks === 1) or with Shift (`dragSelects`).
    MouseArea {
        id: selector
        anchors.fill: view
        acceptedButtons: Qt.LeftButton
        property int clicks: 0
        property real lastTime: 0
        property real lastX: -1000
        property real lastY: -1000
        property real dragX: 0
        property real dragY: 0
        property bool dragSelects: false

        onPressed: function (mouse) {
            pane.forceActiveFocus()
            var slot = pane.slotAt(mouse.y)
            var col = pane.colAt(mouse.x)
            dragX = mouse.x
            dragY = mouse.y
            if (mouse.modifiers & Qt.ShiftModifier) {
                clicks = 0
                lastTime = 0
                dragSelects = true
                Julia.selectionExtendStart(pane.paneId, slot, col)
                return
            }
            var now = Date.now()
            var near = Math.abs(mouse.x - lastX) <= pane.cellW && Math.abs(mouse.y - lastY) <= pane.cellH
            clicks = (near && now - lastTime < 500) ? clicks % 3 + 1 : 1
            lastTime = now
            lastX = mouse.x
            lastY = mouse.y
            dragSelects = clicks === 1
            if (clicks === 1)
                Julia.selectionStart(pane.paneId, slot, col)
            else if (clicks === 2)
                Julia.selectWord(pane.paneId, slot, col)
            else
                Julia.selectLine(pane.paneId, slot)
        }

        onPositionChanged: function (mouse) {
            dragX = mouse.x
            dragY = mouse.y
            if (pressed && dragSelects)
                Julia.selectionExtend(pane.paneId, pane.slotAt(mouse.y), pane.colAt(mouse.x))
        }

        onReleased: function (mouse) {
            Julia.selectionEnd(pane.paneId)
        }

        // While a drag is above or below the view, scroll one row per tick and extend the selection
        // to the row at the edge that is now visible.
        Timer {
            id: edgeScroll
            interval: 40
            repeat: true
            running: selector.pressed && selector.dragSelects && (selector.dragY < 0 || selector.dragY > view.height)
            onTriggered: {
                var dir = selector.dragY < 0 ? -1 : 1
                var maxY = Math.max(0, view.contentHeight - view.height)
                view.contentY = Math.max(0, Math.min(view.contentY + dir * pane.cellH, maxY))
                var first = Math.floor(view.contentY / pane.cellH) + 1
                var last = Math.floor((view.contentY + view.height - 1) / pane.cellH) + 1
                Julia.selectionExtend(pane.paneId, dir < 0 ? first : last, pane.colAt(selector.dragX))
            }
        }
    }
    // Shown after the REPL has ended, or after a rank's connection has failed. It lies over the bottom of the
    // output, which stays scrollable and selectable beneath it. Return also restarts (see Keys.onPressed).
    Rectangle {
        id: endPrompt
        visible: props.ended
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 8
        height: 36
        radius: 4
        color: "#292e42"
        border.color: "#e0af68"
        border.width: 1

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: rankPane ? parent.right : restartButton.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: props.exitText
            elide: Text.ElideRight
            color: "#c0caf5"
            font.pixelSize: 13
        }

        Rectangle {
            id: restartButton
            visible: !pane.rankPane
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 84
            height: 26
            radius: 3
            color: restartMouse.containsMouse ? "#7aa2f7" : "#3b4261"

            Text {
                anchors.centerIn: parent
                text: "Restart"
                color: restartMouse.containsMouse ? "#1a1b26" : "#c0caf5"
                font.pixelSize: 13
            }

            MouseArea {
                id: restartMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                onPressed: pane.forceActiveFocus()
                onClicked: Julia.restartSession(pane.paneId)
            }
        }
    }
}
