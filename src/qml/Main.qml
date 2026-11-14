import QtQuick
import jlqml

// Top-level window. It holds one pane that fills the window. Julia.windowClosed()
// is called when the window is closed; the Julia event loop in Gui.jl then returns.
Window {
    id: win
    width: 960
    height: 600
    visible: true
    title: "MPIEnsemble"
    color: "#1a1b26"

    onClosing: Julia.windowClosed()

    Pane {
        anchors.fill: parent
        anchors.margins: 8
    }
}
