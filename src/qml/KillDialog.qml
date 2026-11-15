import QtQuick
import QtQuick.Controls as Controls
import jlqml

// Modal dialog that asks for confirmation before the MPI job of an MPI tab is killed. Kill passes the tab's
// id to Julia (Julia.killMpi). Cancel, or Escape, passes nothing, so the job keeps running. Main.qml opens it
// from the Kill MPI button.
Controls.Dialog {
    id: dialog

    // The id of the MPI tab whose job is killed.
    required property int tabId

    parent: Controls.Overlay.overlay
    anchors.centerIn: parent
    width: 360
    padding: 16
    modal: true
    closePolicy: Controls.Popup.CloseOnEscape
    title: "Kill MPI"

    onAccepted: Julia.killMpi(dialog.tabId)

    background: Rectangle {
        color: "#1f2335"
        border.color: "#292e42"
        radius: 4
    }

    header: Text {
        text: dialog.title
        color: "#c0caf5"
        font.pixelSize: 14
        font.bold: true
        leftPadding: 16
        rightPadding: 16
        topPadding: 12
        bottomPadding: 4
    }

    // A button in the dark palette. `danger` marks the button that kills the job.
    component DialogButton: Controls.Button {
        id: button
        property bool danger: false

        implicitWidth: 84
        implicitHeight: 30

        contentItem: Text {
            text: button.text
            color: "#c0caf5"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: 13
        }
        background: Rectangle {
            radius: 3
            color: button.danger ? (button.down ? "#5c2531" : "#7a2e3f") : (button.down ? "#1f2335" : "#292e42")
            border.color: "#292e42"
        }
    }

    contentItem: Text {
        width: dialog.availableWidth
        text: "Stop every rank of this MPI job now. The output of each rank stays in its pane."
        color: "#a9b1d6"
        font.pixelSize: 13
        wrapMode: Text.WordWrap
    }

    footer: Item {
        implicitHeight: 50

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            DialogButton {
                text: "Cancel"
                onClicked: dialog.reject()
            }
            DialogButton {
                text: "Kill"
                danger: true
                onClicked: dialog.accept()
            }
        }
    }
}
