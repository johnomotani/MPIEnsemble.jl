import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import jlqml

// Top-level window: a menu bar, then a tab bar above a stack. The stack holds a Pane for each REPL pane
// (`replModel`), of which only the one in the selected tab is visible, and a MpiTabView for each open MPI
// tab (`mpiTabs`), of which only the selected one is visible. `tabModel` is built by Julia, with the roles
// tabId, tabTitle and ended. Only a visible pane takes input or is refilled. Julia.windowClosed() is called
// when the window is closed; the Julia event loop in Gui.jl then returns. Julia asks for the window to close
// by changing `closeRequest`, once its last tab has closed, or after the first tab's launch dialog is
// cancelled. While the window has no tab (`windowProps.askLaunch`), LaunchDialog opens at start-up, and the +
// button opens it at any other time.
//
// ApplicationWindow places the menu bar above the window contents, so the tab bar is anchored to the
// top of the contents.
//
// Each MPI tab has its own job, Kill MPI and Restart MPI buttons, and rank panes; see MpiTabView.qml.
Controls.ApplicationWindow {
    id: win
    width: 960
    height: 600
    visible: true
    title: "MPIEnsemble"
    color: "#1a1b26"

    readonly property int selectedId: windowProps.selected
    readonly property int selectedPane: windowProps.selectedPane
    readonly property int closeRequest: windowProps.closeRequest

    onClosing: Julia.windowClosed()
    onCloseRequestChanged: {
        if (closeRequest > 0)
            Qt.callLater(win.close)
    }

    // Asks what the next tab runs: a serial Julia REPL or MPI ranks. The dialog reports its answer to Julia.
    LaunchDialog {
        id: launchDialog
    }

    Component.onCompleted: {
        if (windowProps.askLaunch)
            launchDialog.open()
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
                    onClicked: launchDialog.open()
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

        // One MpiTabView per open MPI tab, each shown while its tab is selected.
        Repeater {
            model: mpiTabs

            delegate: MpiTabView {
                anchors.fill: parent
                anchors.margins: 8
                selectedId: win.selectedId
            }
        }
    }
}
