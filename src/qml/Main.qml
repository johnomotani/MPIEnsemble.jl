import QtQuick
import QtQuick.Controls as Controls
import jlqml

// Top-level window: a menu bar, then a tab bar above a stack holding one Pane per tab. `tabModel` is
// built by Julia, with the roles tabId, tabTitle, ended, rowModel and props. Only the pane of the
// selected tab is visible, and only a visible pane takes input or is refilled. Julia.windowClosed() is
// called when the window is closed; the Julia event loop in Gui.jl then returns. Julia asks for the
// window to close by changing `closeRequest`, once its last tab has closed.
//
// ApplicationWindow places the menu bar above the window contents, so the tab bar is anchored to the
// top of the contents.
Controls.ApplicationWindow {
    id: win
    width: 960
    height: 600
    visible: true
    title: "MPIEnsemble"
    color: "#1a1b26"

    readonly property int selectedId: windowProps.selected
    readonly property int closeRequest: windowProps.closeRequest

    onClosing: Julia.windowClosed()
    onCloseRequestChanged: {
        if (closeRequest > 0)
            Qt.callLater(win.close)
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

        Repeater {
            model: tabModel

            // The roles of the tab model are the required properties of Pane.
            delegate: Pane {
                anchors.fill: parent
                anchors.margins: 8
                visible: tabId === win.selectedId
            }
        }
    }
}
