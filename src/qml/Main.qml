import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import jlqml

// Top-level window: a menu bar, then a tab bar above a stack. The stack holds a Pane for each REPL pane
// (`replModel`), of which only the one in the selected tab is visible, and the MPI tab's grid of rank
// panes (over `rankModel`), which is shown while the MPI tab is selected. `tabModel` is
// built by Julia, with the roles tabId, tabTitle and ended. Only a visible pane takes input or is
// refilled. Julia.windowClosed() is called when the window is closed; the Julia event loop in Gui.jl
// then returns. Julia asks for the window to close by changing `closeRequest`, once its last tab has
// closed, or after the rank dialog is cancelled. When Julia has no rank count (`windowProps.askRanks`),
// RankDialog opens at start-up.
//
// ApplicationWindow places the menu bar above the window contents, so the tab bar is anchored to the
// top of the contents.
//
// The MPI tab has a Kill MPI button, which is enabled while the job can be killed. It opens KillDialog,
// which asks for confirmation; Julia then kills the job, and the rank panes keep their output. Once the
// job has ended, a Restart MPI button starts it again in the same panes.
Controls.ApplicationWindow {
    id: win
    width: 960
    height: 600
    visible: true
    title: "MPIEnsemble"
    color: "#1a1b26"

    readonly property int selectedId: windowProps.selected
    readonly property int selectedPane: windowProps.selectedPane
    readonly property string selectedKind: windowProps.selectedKind
    readonly property int closeRequest: windowProps.closeRequest

    onClosing: Julia.windowClosed()
    onCloseRequestChanged: {
        if (closeRequest > 0)
            Qt.callLater(win.close)
    }

    // Asks for the rank count when Julia has none. The dialog reports its answer to Julia.
    RankDialog {
        id: rankDialog
    }

    // Asks for confirmation before the MPI job is killed. It is opened by the Kill MPI button.
    KillDialog {
        id: killDialog
        tabId: mpiProps.tabId
    }

    Component.onCompleted: {
        if (windowProps.askRanks)
            rankDialog.open()
    }

    // Placeholder menus. Each holds one disabled item until its feature is implemented.
    component PlaceholderMenu: Controls.Menu {
        required property string menuTitle
        title: menuTitle

        background: Rectangle {
            implicitWidth: 180
            color: "#1f2335"
            border.color: "#292e42"
        }

        Controls.MenuItem {
            id: placeholderItem
            text: "Not available yet"
            enabled: false

            contentItem: Text {
                leftPadding: 12
                rightPadding: 12
                verticalAlignment: Text.AlignVCenter
                text: placeholderItem.text
                color: "#565f89"
                font.pixelSize: 13
            }
            background: Rectangle {
                implicitHeight: 28
                color: "transparent"
            }
        }
    }

    menuBar: Controls.MenuBar {
        background: Rectangle {
            implicitHeight: 28
            color: "#16161e"
        }

        delegate: Controls.MenuBarItem {
            id: menuBarItem

            contentItem: Text {
                leftPadding: 10
                rightPadding: 10
                verticalAlignment: Text.AlignVCenter
                text: menuBarItem.text
                color: "#c0caf5"
                font.pixelSize: 13
            }
            background: Rectangle {
                implicitHeight: 28
                color: menuBarItem.highlighted ? "#292e42" : "transparent"
            }
        }

        PlaceholderMenu { menuTitle: "Settings" }
        PlaceholderMenu { menuTitle: "Mode" }
        PlaceholderMenu { menuTitle: "Rearrange" }
    }

    Rectangle {
        id: tabBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 32
        color: "#16161e"

        Row {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            spacing: 2

            Repeater {
                model: tabModel

                delegate: Rectangle {
                    id: tab
                    required property int tabId
                    required property string tabTitle
                    required property bool ended

                    width: 170
                    height: tabBar.height
                    color: tab.tabId === win.selectedId ? "#292e42" : "#1f2335"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.right: closeButton.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        text: tab.tabTitle
                        elide: Text.ElideRight
                        color: tab.ended ? "#565f89" : "#c0caf5"
                        font.pixelSize: 13
                    }

                    // Left click selects the tab; middle click closes it. The close button is above
                    // this area, so its clicks do not reach it.
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        onClicked: function (mouse) {
                            if (mouse.button === Qt.MiddleButton)
                                Julia.closeTab(tab.tabId)
                            else
                                Julia.selectTab(tab.tabId)
                        }
                    }

                    Rectangle {
                        id: closeButton
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        width: 20
                        height: 20
                        radius: 3
                        color: closeMouse.containsMouse ? "#3b4261" : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: "×"
                            color: "#c0caf5"
                            font.pixelSize: 15
                        }

                        MouseArea {
                            id: closeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton
                            onClicked: Julia.closeTab(tab.tabId)
                        }
                    }
                }
            }

            Rectangle {
                id: newTabButton
                width: 32
                height: tabBar.height
                color: newMouse.containsMouse ? "#292e42" : "transparent"

                Text {
                    anchors.centerIn: parent
                    text: "+"
                    color: "#c0caf5"
                    font.pixelSize: 18
                }

                MouseArea {
                    id: newMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton
                    onClicked: Julia.newTab()
                }
            }
        }
    }

    Item {
        id: stack
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: tabBar.bottom
        anchors.bottom: parent.bottom

        // The roles of the pane model are the required properties of Pane.
        Repeater {
            model: replModel

            delegate: Pane {
                anchors.fill: parent
                anchors.margins: 8
                visible: paneId === win.selectedPane
            }
        }

        // The MPI tab: one Pane per MPI rank, in a grid of `mpiProps.columns` columns whose cells are of
        // equal size. While the job is starting, and when it has failed, the tab shows `mpiProps.message`
        // instead of the grid. Each rank pane is visible only while the tab is selected, so that it is sized
        // and refilled only then. One rank pane has the keyboard focus at a time: a click on a pane gives it
        // the focus (Pane.qml does this), and that pane keeps the focus when the tab is hidden and shown
        // again. The first pane has the focus when the tab is first shown.
        Item {
            id: mpiTab
            anchors.fill: parent
            anchors.margins: 8
            visible: win.selectedKind === "mpi"

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

            // Shown in place of the rank panes until the job has started. A failed launch keeps it.
            Text {
                x: 24
                width: mpiTab.width - 48
                y: (mpiTab.height - height) / 2
                visible: !mpiProps.panes
                text: mpiProps.message
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: mpiProps.messageFailed ? "#f7768e" : "#c0caf5"
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
                visible: mpiProps.panes

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    // Leaves room for the buttons, which are at most 112 pixels wide and 12 pixels from the note.
                    anchors.rightMargin: 124
                    anchors.verticalCenter: parent.verticalCenter
                    text: mpiProps.message
                    elide: Text.ElideRight
                    color: mpiProps.messageFailed || mpiProps.status === "killed" ? "#f7768e" : "#a9b1d6"
                    font.pixelSize: 13
                }

                Controls.Button {
                    id: killButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: mpiProps.killable
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
                    visible: mpiProps.status === "killed" || mpiProps.status === "ended"
                    text: "Restart MPI"
                    implicitWidth: 112
                    implicitHeight: 28
                    onClicked: Julia.restartMpi(mpiProps.tabId)

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
                visible: mpiProps.panes
                columns: mpiProps.columns
                rowSpacing: 8
                columnSpacing: 8
                uniformCellWidths: true
                uniformCellHeights: true

                Repeater {
                    id: mpiRepeater
                    model: rankModel
                    onCountChanged: mpiTab.focusCurrent()

                    delegate: Pane {
                        required property int index

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        rankPane: true
                        visible: mpiTab.visible
                        onActiveFocusChanged: {
                            if (activeFocus)
                                mpiTab.focusIndex = index
                        }
                    }
                }
            }
        }
    }
}
