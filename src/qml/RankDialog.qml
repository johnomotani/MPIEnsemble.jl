import QtQuick
import QtQuick.Controls as Controls
import jlqml

// Modal dialog asking for the number of MPI ranks. OK is enabled only for a whole number of 1 or more,
// and then passes that number to Julia (Julia.setRankCount). Cancel, or Escape, passes nothing and
// Julia closes the window (Julia.cancelRankDialog). Main.qml opens it when Julia has no count yet.
Controls.Dialog {
    id: dialog

    readonly property bool valid: field.acceptableInput

    parent: Controls.Overlay.overlay
    anchors.centerIn: parent
    width: 320
    padding: 16
    modal: true
    closePolicy: Controls.Popup.CloseOnEscape
    title: "Number of MPI ranks"

    onAccepted: Julia.setRankCount(parseInt(field.text, 10))
    onRejected: Julia.cancelRankDialog()

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

    // A button in the dark palette. `accent` marks the confirming button.
    component DialogButton: Controls.Button {
        id: button
        property bool accent: false

        implicitWidth: 84
        implicitHeight: 30

        contentItem: Text {
            text: button.text
            color: button.enabled ? "#c0caf5" : "#565f89"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: 13
        }
        background: Rectangle {
            radius: 3
            color: !button.enabled ? "#1f2335" : button.accent ? "#3d59a1" : "#292e42"
            border.color: "#292e42"
            opacity: button.down ? 0.8 : 1
        }
    }

    contentItem: Column {
        width: dialog.availableWidth
        spacing: 10

        Text {
            width: parent.width
            text: "Whole number of MPI ranks, 1 or more"
            color: "#a9b1d6"
            font.pixelSize: 13
            wrapMode: Text.WordWrap
        }

        Controls.TextField {
            id: field
            width: parent.width
            height: 30
            placeholderText: "for example 4"
            placeholderTextColor: "#565f89"
            color: "#c0caf5"
            selectionColor: "#3d59a1"
            selectedTextColor: "#c0caf5"
            font.pixelSize: 14
            selectByMouse: true
            focus: true
            validator: IntValidator {
                bottom: 1
                top: 2147483647
            }
            background: Rectangle {
                color: "#16161e"
                radius: 3
                border.color: field.activeFocus ? "#7aa2f7" : "#292e42"
            }
            onAccepted: {
                if (dialog.valid)
                    dialog.accept()
            }
        }
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
                text: "OK"
                accent: true
                enabled: dialog.valid
                onClicked: dialog.accept()
            }
        }
    }
}
