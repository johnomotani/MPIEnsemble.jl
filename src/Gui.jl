"""
    Gui

Qt window for MPIEnsemble, built from the QML files in `qml/`. Qt is
initialised when the first QML engine is created, so loading this module
needs a display only when a window is opened.

Only one QML engine can exist per process: `run_single_repl` can open a
window once per Julia session.
"""
module Gui

using QML
import ..ReplSession
using ..ReplSession: Repl, describe_exit, has_ended, is_started
using ..MPIEnsemble: check_tall_rows
using ..VTParse: screen_lines, application_cursor, bracketed_paste
using ..KeyMap: key_bytes, paste_bytes, is_paste_chord
using ..LineLog: RankLog
using ..PaneModel: Pane, attach!, set_screen_rows!, set_view_rows!, refresh!, resume_following!,
    user_scrolled!, follow_row, select_start!, select_extend!, select_extend_start!, select_end!,
    select_word!, select_line!, clear_selection!, selected_text, scroll_to_fraction!, page!,
    scroll_action, scroll_action!, scrollbar_state

export run_single_repl

const QML_MAIN = joinpath(@__DIR__, "qml", "Main.qml")

const WINDOW_OPEN = Ref(false)

# Value of QClipboard::Selection, the mode of the PRIMARY selection.
const QT_CLIPBOARD_SELECTION = 1

# Lines appended to the log per pass of the event loop. Output beyond this waits for the next pass,
# so that the window stays responsive while a large output is being read.
const LINES_PER_TICK = 500

# `screen_lines` removes trailing spaces, so the prompt is matched without its final space.
const PROMPT = "julia>"

# The REPL pane and its session. Fields are touched only from the thread running the Qt event loop.
# The session's tasks share state with it through `ReplSession.Repl`.
mutable struct ReplState
    const log::RankLog
    const pane::Pane
    const model::Any
    const props::QML.JuliaPropertyMap
    const startup_input::String
    const tall_rows::Union{Nothing, Int}
    const repl::Repl
    refilled::Bool
    shown::Bool                 # false once the window is closing: no more updates to QML
    prompt_seen::Bool
end

function ReplState(startup_input::AbstractString, tall_rows::Union{Nothing, Int})
    log = RankLog(0)
    props = QML.JuliaPropertyMap()
    props["follow"] = true
    props["target"] = 0
    props["refill"] = 0
    props["thumbTop"] = 0.0
    props["thumbSize"] = 1.0
    props["ended"] = false
    props["exitText"] = ""
    owner = Ref{Any}(nothing)
    pane = Pane(log, 1; notify = (p, kind, first, last) -> publish!(owner[], kind, first, last))
    model = QML.JuliaItemModel(pane.rows, false)
    QML.addrole!(model, "html", identity)
    QML.get_julia_data(model).values[] === pane.rows || error("the item model does not wrap the pane rows")
    repl = Repl(log, ReplSession.julia_repl_command())
    state = ReplState(log, pane, model, props, String(startup_input), tall_rows, repl, false, true, false)
    owner[] = state
    return state
end

# The pane's matrix keeps its size and identity, so each refill is one `dataChanged`.
function publish!(st::ReplState, kind::Symbol, first::Int, last::Int)
    kind === :change || error("unexpected pane notification $kind")
    st.shown || return nothing
    QML.emit_data_changed(st.model, first, 1, last, 1)
    st.refilled = true
    return nothing
end

# Set the properties read by QML. `refill` is set last: QML moves the view when it changes, and
# must then see the current `follow`, `target` and scrollbar thumb.
function sync_props!(st::ReplState)
    st.shown || return nothing
    follow = st.pane.follow
    follow == st.props["follow"] || (st.props["follow"] = follow)
    target = follow_row(st.pane)
    target == st.props["target"] || (st.props["target"] = target)
    thumb_top, thumb_size = scrollbar_state(st.pane)
    thumb_top == st.props["thumbTop"] || (st.props["thumbTop"] = thumb_top)
    thumb_size == st.props["thumbSize"] || (st.props["thumbSize"] = thumb_size)
    ended = has_ended(st.repl)
    ended == st.props["ended"] || (st.props["ended"] = ended)
    exit_text = ended ? describe_exit(st.repl.exit) : ""
    exit_text == st.props["exitText"] || (st.props["exitText"] = exit_text)
    if st.refilled
        st.props["refill"] = st.props["refill"] + 1
        st.refilled = false
    end
    return nothing
end

"""
    run_single_repl(; startup_input = "", tall_rows = nothing)

Open the single-REPL window and run the Qt event loop on the calling thread until the window is
closed. Must be called from the main thread, not from an `@async` task. Throws an error if a window
is already open in this process.

The window starts `julia -q --startup-file=no` in a pseudo-terminal, sized to the pane. When the
first `julia> ` prompt appears, `startup_input` is written to the pseudo-terminal, as if typed. Use
`"\\r"` at the end of each line to submit it.

With `tall_rows = nothing` (the default), the pseudo-terminal has as many rows as the pane. An
integer `tall_rows` gives the pseudo-terminal and the screen model `max(tall_rows, rows that fit the
pane)` rows, so that a multi-line input taller than the pane stays on the child's screen and can be
edited from its first line. The pane then shows a viewport onto that screen and the log. Resizing the
window changes only the columns, unless the pane grows taller than `tall_rows`. Side effect: the
child's `displaysize` reports the tall row count, not the pane height, so programs that use the
terminal height, such as the REPL's output truncation, see the tall count. Throws `ArgumentError` if
`tall_rows` is neither `nothing` nor a positive integer.

A vertical scrollbar at the right of the pane shows where the view is in the whole output, which may
be far longer than the pane's matrix of rows: the thumb's position and size are fractions of the whole
sequence, and dragging the thumb sets the view by fraction. A click on the track above or below the
thumb moves the view by one page. Shift+PageUp and Shift+PageDown move the view by one page, and
Ctrl+Home and Ctrl+End move to the top of the output and to the bottom (resuming following). These
keys are not sent to the child.

Left-button drags, double-clicks and triple-clicks in the pane select text. The selection is highlighted
and its text becomes the PRIMARY selection. With a selection, a Shift-click or Shift-drag moves its
active end and keeps the other end fixed. Selecting sends nothing to the session. Key presses in the
pane clear the highlight, except the jump keys, but not the PRIMARY selection; pressing Shift alone
does not clear it. See `PaneModel` for the selection model.

Key presses in the pane are sent to the session as bytes (see `KeyMap`). Ctrl+Shift+V pastes the
clipboard, using bracketed paste when the child has enabled it. Typing returns the pane to the
bottom of the output. Once the child has exited, a prompt at the bottom of the pane says how it ended and offers to restart
it, with the Restart button or Return. Restarting starts a new REPL in the same pane, after a separator
in the output. The output stays visible and selectable while the prompt is shown, and input is ignored.

Each log line is one row of the pane: a line wider than the pane is cut off at its right edge.

Closing the window ends the REPL and the pseudo-terminal session. An error from the session's reader
is rethrown by this function.
"""
function run_single_repl(; startup_input::AbstractString = "", tall_rows = nothing)
    tall = check_tall_rows(tall_rows)
    WINDOW_OPEN[] && error("the MPIEnsemble window is already open in this process")
    st = ReplState(startup_input, tall)
    QML.qmlfunction("windowClosed", () -> (WINDOW_OPEN[] = false; nothing))
    QML.qmlfunction("paneSized", (w, h, cw, ch) -> pane_sized!(st, w, h, cw, ch))
    QML.qmlfunction("userScrolled", (first, count, at_end) -> scrolled!(st, first, count, at_end))
    QML.qmlfunction("scrollToFraction", f -> view_op!(st, p -> scroll_to_fraction!(p, Float64(f))))
    QML.qmlfunction("pageView", dir -> view_op!(st, p -> page!(p, Int(dir))))
    QML.qmlfunction("scrollKey", (key, modifiers) -> scroll_key!(st, key, modifiers))
    # Text from QML arrives as a QString, whose code units are UTF-16. It is converted to a String
    # here, so that the bytes sent are UTF-8.
    QML.qmlfunction("keyPressed", (key, text, modifiers) -> key_pressed!(st, key, String(text), modifiers))
    QML.qmlfunction("isPasteChord", (key, modifiers) -> is_paste_chord(Int(key), Int(modifiers)))
    QML.qmlfunction("pasteText", text -> paste_text!(st, String(text)))
    QML.qmlfunction("selectionStart", (slot, col) -> selection_op!(st, p -> select_start!(p, Int(slot), Int(col))))
    QML.qmlfunction("selectionExtendStart", (slot, col) -> selection_op!(st, p -> select_extend_start!(p, Int(slot), Int(col))))
    QML.qmlfunction("selectionExtend", (slot, col) -> selection_op!(st, p -> select_extend!(p, Int(slot), Int(col))))
    QML.qmlfunction("selectionEnd", () -> selection_end!(st))
    QML.qmlfunction("selectWord", (slot, col) -> selection_end_op!(st, p -> select_word!(p, Int(slot), Int(col))))
    QML.qmlfunction("selectLine", slot -> selection_end_op!(st, p -> select_line!(p, Int(slot))))
    QML.qmlfunction("clearSelection", () -> selection_op!(st, clear_selection!))
    QML.qmlfunction("restartSession", () -> restart_session!(st))
    WINDOW_OPEN[] = true
    try
        QML.loadqml(QML_MAIN; rowModel = st.model, props = st.props)
        while WINDOW_OPEN[]
            QML.process_events()
            drain!(st)
            sleep(0.005)
        end
    finally
        WINDOW_OPEN[] = false
        shutdown!(st)
    end
    return nothing
end

# Rows of the pseudo-terminal and the screen model for a pane of `pane_rows` rows.
session_rows(st::ReplState, pane_rows::Int) = st.tall_rows === nothing ? pane_rows : max(st.tall_rows, pane_rows)

# Called from QML with the pane size and the measured cell size, in pixels.
function pane_sized!(st::ReplState, w, h, cw, ch)
    pane_rows = max(1, floor(Int, h / ch))
    rows = session_rows(st, pane_rows)
    cols = max(1, floor(Int, w / cw))
    set_view_rows!(st.pane, pane_rows)
    if is_started(st.repl)
        if (st.repl.rows, st.repl.cols) != (rows, cols)
            ReplSession.set_size!(st.repl, rows, cols)
            set_screen_rows!(st.pane, rows)
        end
    else
        set_screen_rows!(st.pane, rows)
        ReplSession.start!(st.repl, rows, cols)
        attach!(st.pane, st.repl.term)
    end
    sync_props!(st)
    return nothing
end

# Start a new REPL in the pane after the previous one has ended. The output of the previous session
# stays in the pane, and the new session's output follows it.
function restart_session!(st::ReplState)
    has_ended(st.repl) || error("the REPL is still running, so it cannot be restarted")
    ReplSession.restart!(st.repl)
    # startup_input is typed into the first session only.
    st.prompt_seen = true
    attach!(st.pane, st.repl.term)
    resume_following!(st.pane)
    sync_props!(st)
    return nothing
end

# Scrolling by the scrollbar and by the jump keys. Returns the matrix row at the top of the view after
# the change, or 0 when the pane now follows the bottom (QML then places the view by the follow rule).
function view_op!(st::ReplState, f)
    st.shown || return 0
    row = f(st.pane)
    sync_props!(st)
    return row
end

# Called from QML for each key press before it is translated. Returns the row as `view_op!` does, or
# -1 when the key is not a jump key, in which case QML passes it on.
function scroll_key!(st::ReplState, key, modifiers)
    action = scroll_action(Int(key), Int(modifiers))
    action === nothing && return -1
    return view_op!(st, p -> scroll_action!(p, action))
end

# Called from QML for each key press. Returns whether the key was sent, so that QML accepts only
# the events that were handled. Input is ignored once the child has exited.
function key_pressed!(st::ReplState, key, text, modifiers)
    is_started(st.repl) || error("keyboard input before the session has started")
    bytes = key_bytes(Int(key), text, Int(modifiers); application_cursor = application_cursor(st.repl.term))
    bytes === nothing && return false
    return send_input!(st, bytes)
end

# Apply a change to the selection, then update the properties that QML reads.
function selection_op!(st::ReplState, f)
    st.shown || return nothing
    f(st.pane)
    sync_props!(st)
    return nothing
end

# A change that ends a selection gesture: the selected text becomes the PRIMARY selection, if any.
function selection_end_op!(st::ReplState, f)
    selection_op!(st, f)
    st.shown && set_primary_selection!(selected_text(st.pane))
    return nothing
end

selection_end!(st::ReplState) = selection_end_op!(st, select_end!)

# Layout of Qt 6's QLatin1String, passed by value: the size, then the data pointer.
struct QLatin1StringView
    size::Int
    data::Ptr{UInt8}
end

# Make `text` the PRIMARY selection, to paste elsewhere with the middle button. Selecting text in a
# QML TextEdit from code did not publish PRIMARY under Xvfb, so the text is given to Qt's clipboard
# directly. Empty text is not published, so a click that clears the highlight leaves PRIMARY as it was.
#
# The QString is stored as Qt 6's QArrayDataPointer<char16_t>: three words (shared-data pointer,
# data pointer, size). After the clipboard has taken its copy, QString::operator=(QLatin1String) with
# an empty string drops the QString's reference to the shared data, so this code never touches Qt's
# reference counts. The layouts used here were checked against the Qt 6 headers only, hence
# `qt_check_version`.
function set_primary_selection!(text::Union{Nothing, String})
    (text === nothing || isempty(text)) && return nothing
    qt_check_version()
    clipboard = ccall(qt_symbol(:_ZN15QGuiApplication9clipboardEv), Ptr{Cvoid}, ())
    clipboard == C_NULL && error("no clipboard: the QML application is not running")
    units = transcode(UInt16, text)
    qstring = Ref{NTuple{3, UInt}}((0, 0, 0))
    empty = Ref{UInt8}(0)
    GC.@preserve units qstring empty begin
        p = Base.unsafe_convert(Ptr{Cvoid}, qstring)
        ccall(qt_symbol(:_ZN7QStringC1EPK5QCharx), Cvoid, (Ptr{Cvoid}, Ptr{UInt16}, Int),
            p, pointer(units), length(units))
        ccall(qt_symbol(:_ZN10QClipboard7setTextERK7QStringNS_4ModeE), Cvoid,
            (Ptr{Cvoid}, Ptr{Cvoid}, Cint), clipboard, p, QT_CLIPBOARD_SELECTION)
        ccall(qt_symbol(:_ZN7QStringaSE13QLatin1String), Cvoid, (Ptr{Cvoid}, QLatin1StringView),
            p, QLatin1StringView(0, Base.unsafe_convert(Ptr{UInt8}, empty)))
    end
    return nothing
end

# Qt's `qVersion` (C linkage) returns the version string of the loaded QtCore.
function qt_check_version()
    version = unsafe_string(ccall(qt_symbol(:qVersion), Cstring, ()))
    startswith(version, "6.") || error(
        "the QString layout was verified for Qt 6 only, but the loaded Qt is version $version")
    return nothing
end

# Qt symbol `name` from the libraries already loaded into the process. Linux only.
function qt_symbol(name::Symbol)
    ptr = ccall(:dlsym, Ptr{Cvoid}, (Ptr{Cvoid}, Cstring), C_NULL, name)
    ptr == C_NULL && error("Qt symbol $name is not loaded")
    return ptr
end

# Called from QML with the clipboard text for Ctrl+Shift+V. Returns whether anything was sent.
function paste_text!(st::ReplState, text)
    is_started(st.repl) || error("paste before the session has started")
    isempty(text) && return false
    return send_input!(st, paste_bytes(text; bracketed = bracketed_paste(st.repl.term)))
end

# Queue bytes for the child. The pane then follows the bottom, since the child's echo follows input.
# Returns false, and does nothing else, when the child has ended.
function send_input!(st::ReplState, bytes::Vector{UInt8})
    ReplSession.send!(st.repl, bytes) || return false
    resume_following!(st.pane)
    sync_props!(st)
    return true
end

function check_prompt!(st::ReplState)
    any(l -> occursin(PROMPT, l), screen_lines(st.repl.term)) || return nothing
    st.prompt_seen = true
    isempty(st.startup_input) || ReplSession.send!(st.repl, Vector{UInt8}(codeunits(st.startup_input)))
    return nothing
end

# Run on each pass of the event loop: feed pending output, then refresh the pane once. A session
# that has ended is released by `ReplSession.poll_exit!`, after which the prompt is shown.
function drain!(st::ReplState)
    ReplSession.check_errors(st.repl)
    if ReplSession.feed_chunks!(st.repl, LINES_PER_TICK)
        st.prompt_seen || check_prompt!(st)
        refresh!(st.pane)
        sync_props!(st)
    end
    if ReplSession.poll_exit!(st.repl)
        refresh!(st.pane)
        sync_props!(st)
    end
    return nothing
end

function scrolled!(st::ReplState, first, count, at_end)
    shift = user_scrolled!(st.pane, Int(first), Int(count), Bool(at_end))
    sync_props!(st)
    return shift
end

# Close the session and complete the log (see `ReplSession.shutdown!`). Output is not drawn after this.
function shutdown!(st::ReplState)
    st.shown = false
    ReplSession.shutdown!(st.repl)
    return nothing
end

end # module Gui
