import QtQuick
import QtQuick.Controls as Controls
import jlqml

// Modal dialog that chooses the kind of the next tab: a serial Julia REPL, or an MPI job with a whole number
// of ranks, 1 or more. Main.qml opens it at start-up while the window has no tab (`windowProps.askLaunch`),
// and the + button opens it otherwise. OK, or Return, passes the choice to Julia (Julia.launchSerial or
// Julia.launchMpi). Cancel, or Escape, calls Julia.cancelLaunch.
Controls.Dialog {
    id: dialog

    readonly property bool canConfirm: serialRadio.checked || (mpiRadio.checked && field.acceptableInput)

    // Set once the dialog has been answered, so that a second Return or OK does not answer it again.
    property bool answered: false

    parent: Controls.Overlay.overlay
    anchors.centerIn: parent
    width: 360
    padding: 16
    modal: true
    focus: true
    closePolicy: Controls.Popup.CloseOnEscape
    title: "Open a tab"

    // The choice starts at MPI with the last rank count when a count was given, and at Serial Julia REPL
    // otherwise.
    onAboutToShow: {
        dialog.answered = false
        const last = windowProps.lastRanks
        mpiRadio.checked = last > 0
        serialRadio.checked = !mpiRadio.checked
        field.text = last > 0 ? String(last) : ""
    }
    onAccepted: {
        if (serialRadio.checked)
            Julia.launchSerial()
        else
            Julia.launchMpi(parseInt(field.text, 10))
    }
    onRejected: Julia.cancelLaunch()

    function confirm() {
        if (dialog.answered || !dialog.canConfirm)
            return
        dialog.answered = true
        dialog.accept()
    }

    function cancel() {
        if (dialog.answered)
            return
        dialog.answered = true
        dialog.reject()
    }

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

    // A radio button in the dark palette. Its indicator is a ring, with a dot when it is checked. The text
    // starts after the indicator, which the left padding leaves room for.
    component ChoiceButton: Controls.RadioButton {
        id: choice

        height: 30
        leftPadding: 24

        indicator: Rectangle {
            x: 0
            y: (choice.height - height) / 2
            implicitWidth: 16
            implicitHeight: 16
            radius: 8
            color: "#16161e"
            border.color: choice.checked ? "#7aa2f7" : "#565f89"

            Rectangle {
                anchors.centerIn: parent
                width: 8
                height: 8
                radius: 4
                color: choice.enabled ? "#7aa2f7" : "#565f89"
                visible: choice.checked
            }
        }
        contentItem: Text {
            text: choice.text
            color: choice.enabled ? "#c0caf5" : "#565f89"
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: 13
        }
    }

    contentItem: Column {
        width: dialog.availableWidth
        spacing: 10

        // Return and Enter confirm, whichever control has the focus. `confirm` ignores a repeated answer.
        Shortcut {
            sequences: ["Return", "Enter"]
            enabled: dialog.visible
            onActivated: dialog.confirm()
        }

        Controls.ButtonGroup {
            id: choiceGroup
        }

        ChoiceButton {
            id: serialRadio
            width: parent.width
            text: "Serial Julia REPL"
            Controls.ButtonGroup.group: choiceGroup
        }

        Row {
            spacing: 8

            ChoiceButton {
                id: mpiRadio
                text: "MPI with"
                Controls.ButtonGroup.group: choiceGroup
            }

            Controls.TextField {
                id: field
                width: 72
                height: 30
                enabled: mpiRadio.checked
                placeholderText: "4"
                placeholderTextColor: "#565f89"
                color: "#c0caf5"
                selectionColor: "#3d59a1"
                selectedTextColor: "#c0caf5"
                font.pixelSize: 14
                selectByMouse: true
                validator: IntValidator {
                    bottom: 1
                    top: 2147483647
                }
                background: Rectangle {
                    color: field.enabled ? "#16161e" : "#1f2335"
                    radius: 3
                    border.color: field.activeFocus ? "#7aa2f7" : "#292e42"
                }
            }

            Text {
                height: 30
                text: "ranks"
                color: "#c0caf5"
                verticalAlignment: Text.AlignVCenter
                font.pixelSize: 13
            }
        }

        // Explains the rank count.
        Text {
            width: parent.width
            text: "Whole number of MPI ranks, 1 or more"
            color: "#a9b1d6"
            font.pixelSize: 13
            wrapMode: Text.WordWrap
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
                onClicked: dialog.cancel()
            }
            DialogButton {
                text: "OK"
                accent: true
                enabled: dialog.canConfirm
                onClicked: dialog.confirm()
            }
        }
    }
}
