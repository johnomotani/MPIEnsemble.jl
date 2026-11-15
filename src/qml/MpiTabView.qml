import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import jlqml

// The view of one MPI tab, which Main.qml repeats over the open MPI tabs (`mpiTabs`). It has one Pane per MPI
// rank, in a grid of `mpiProps.columns` columns whose cells are of equal size, over the tab's `rankModel`.
// `mpiProps` holds the tab's properties, and `tabId` is the tab's id in Julia calls. While the job is starting,
// and when it has failed, the view shows `mpiProps.message` instead of the grid. The view is shown only while
// its tab is selected (`selectedId` is the id of the selected tab), so that its rank panes are sized and
// refilled only then. One rank pane has the keyboard focus at a time: a click on a pane gives it the focus
// (Pane.qml does this), and that pane keeps the focus when the tab is hidden and shown again. The first pane
// has the focus when the tab is first shown.
//
// The view has a Kill MPI button, which is enabled while the job can be killed. It opens KillDialog, which asks
// for confirmation; Julia then kills the job, and the rank panes keep their output. Once the job has ended, a
// Restart MPI button starts it again in the same panes. While a rank is zoomed (`mpiProps.zoomed`), the grid has
// one column, so that the zoomed pane fills it, and the other rank panes are hidden (`zoomHidden`).
Item {
    id: mpiTab

    required property int tabId
    required property var rankModel
    required property var mpiProps
    required property int selectedId

    visible: tabId === selectedId

    // Index of the rank pane that has the focus last.
    property int focusIndex: 0

    function focusCurrent() {
        if (!mpiTab.visible)
            return
        var cell = mpiRepeater.itemAt(mpiTab.focusIndex)
        if (cell)
            cell.forceActiveFocus()
    }

    onVisibleChanged: focusCurrent()

    // Asks for confirmation before the job of this tab is killed. It is opened by the Kill MPI button.
    KillDialog {
        id: killDialog
        tabId: mpiTab.tabId
    }

    // Shown in place of the rank panes until the job has started. A failed launch keeps it.
    Text {
        x: 24
        width: mpiTab.width - 48
        y: (mpiTab.height - height) / 2
        visible: !mpiTab.mpiProps.panes
        text: mpiTab.mpiProps.message
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        color: mpiTab.mpiProps.messageFailed ? "#f7768e" : "#c0caf5"
        font.pixelSize: 16
    }

    // Above the grid: the state of the job, and the button for the next step, which is Kill MPI while the
    // job can be killed and Restart MPI once it has ended or was killed.
    Item {
        id: mpiBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 36
        visible: mpiTab.mpiProps.panes

        // The command the ranks run, shown on hover over the bar. The bar has a height even when its note is empty.
        HoverHandler {
            id: barHover
        }
        Controls.ToolTip.visible: barHover.hovered
        Controls.ToolTip.text: "Command: " + mpiTab.mpiProps.command
        Controls.ToolTip.delay: 500

        Text {
            id: barMessage
            anchors.left: parent.left
            anchors.right: parent.right
            // Leaves room for the buttons, which are at most 112 pixels wide and 12 pixels from the note.
            anchors.rightMargin: 124
            anchors.verticalCenter: parent.verticalCenter
            text: mpiTab.mpiProps.message
            elide: Text.ElideRight
            color: mpiTab.mpiProps.messageFailed || mpiTab.mpiProps.status === "killed" ? "#f7768e" : "#a9b1d6"
            font.pixelSize: 13
        }

        Controls.Button {
            id: killButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: mpiTab.mpiProps.killable
            text: "Kill MPI"
            implicitWidth: 96
            implicitHeight: 28
            onClicked: killDialog.open()

            contentItem: Text {
                text: killButton.text
                color: "#c0caf5"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                font.pixelSize: 13
            }
            background: Rectangle {
                radius: 3
                color: killButton.down ? "#5c2531" : "#7a2e3f"
                border.color: "#292e42"
            }
        }

        Controls.Button {
            id: restartButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: mpiTab.mpiProps.status === "killed" || mpiTab.mpiProps.status === "ended"
            text: "Restart MPI"
            implicitWidth: 112
            implicitHeight: 28
            onClicked: Julia.restartMpi(mpiTab.tabId)

            contentItem: Text {
                text: restartButton.text
                color: "#c0caf5"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                font.pixelSize: 13
            }
            background: Rectangle {
                radius: 3
                color: restartButton.down ? "#1f2335" : "#292e42"
                border.color: "#292e42"
            }
        }
    }

    GridLayout {
        anchors.top: mpiBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: mpiTab.mpiProps.panes
        columns: mpiTab.mpiProps.zoomed ? 1 : mpiTab.mpiProps.columns
        rowSpacing: 8
        columnSpacing: 8
        uniformCellWidths: true
        uniformCellHeights: true

        Repeater {
            id: mpiRepeater
            model: mpiTab.rankModel
            onCountChanged: mpiTab.focusCurrent()

            delegate: Pane {
                required property int index

                Layout.fillWidth: true
                Layout.fillHeight: true
                rankPane: true
                visible: mpiTab.visible && !props.zoomHidden
                onActiveFocusChanged: {
                    if (activeFocus)
                        mpiTab.focusIndex = index
                }
            }
        }
    }
}
