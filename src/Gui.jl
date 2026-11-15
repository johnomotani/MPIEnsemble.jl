"""
    Gui

Qt window for MPIEnsemble, built from the QML files in `qml/`. Qt is
initialised when the first QML engine is created, so loading this module
needs a display only when a window is opened.

Only one QML engine can exist per process: `run_single_repl` can open a
window once per Julia session. Within the window, each tab has its own pane
(`ReplPane`), its own item model and its own property map. QML calls take the
tab id as their first argument, and are dispatched through `WindowState.views`.
"""
module Gui

using QML
import ..ReplSession
import ..ReplPane
import ..TabSet
using ..ReplSession: describe_exit, has_ended, is_started
using ..MPIEnsemble: check_tall_rows, check_rank_count
using ..VTParse: application_cursor, bracketed_paste
using ..KeyMap: key_bytes, paste_bytes, is_paste_chord
using ..PaneModel: follow_row, select_start!, select_extend!, select_extend_start!, select_end!,
    select_word!, select_line!, clear_selection!, selected_text, scroll_to_fraction!, page!,
    scroll_action, scroll_action!, scrollbar_state, user_scrolled!

export run_single_repl

const QML_MAIN = joinpath(@__DIR__, "qml", "Main.qml")

const WINDOW_OPEN = Ref(false)

# Value of QClipboard::Selection, the mode of the PRIMARY selection.
const QT_CLIPBOARD_SELECTION = 1

# Lines appended to the logs per pass of the event loop, shared between all tabs (see
# `TabSet.drain_fairly!`). Output beyond this waits for the next pass, so that the window stays
# responsive while a large output is being read.
const LINES_PER_TICK = 500

# The QML objects of one tab: the pane's rows as a model, and the properties that QML reads. `ended_shown`
# is the ended state last reported in the tab bar.
mutable struct TabView
    const session::ReplPane.State
    const model::Any
    const props::QML.JuliaPropertyMap
    ended_shown::Bool
end

# State of the window. `views` maps the ids of the open tabs to their views; `tab_rows` is the tab bar's
# model, with the same order as `tabs`. `props` holds `selected` (the id of the selected tab),
# `closeRequest`, which QML reads to close the window once the last tab has closed, and `askRanks`,
# which is true while the rank dialog is to be shown.
mutable struct WindowState
    const tabs::TabSet.Tabs
    const views::Dict{Int, TabView}
    const tab_rows::Any
    const props::QML.JuliaPropertyMap
    const tall_rows::Union{Nothing, Int}
    const startup_input::String
    # Number of MPI ranks, or `nothing` until the rank dialog gives one.
    rank_count::Union{Nothing, Int}
    startup_pending::Bool
    # Ids of tabs whose close was requested. They are closed by the event loop, not by the QML call.
    const closing::Vector{Int}
    # The first error raised in a QML call. The event loop rethrows it.
    failure::Any
    # Position in `tabs` where the next pass of the event loop starts (see `TabSet.drain_fairly!`).
    offset::Int
end

function WindowState(startup_input::AbstractString, tall_rows::Union{Nothing, Int},
        rank_count::Union{Nothing, Int})
    props = QML.JuliaPropertyMap()
    props["selected"] = 0
    props["closeRequest"] = 0
    props["askRanks"] = rank_count === nothing
    rows = QML.JuliaItemModel(TabSet.Tab[], false)
    QML.addrole!(rows, "tabId", t -> t.id)
    QML.addrole!(rows, "tabTitle", t -> TabSet.tab_label(t, has_ended(view_of(t).session.repl)))
    QML.addrole!(rows, "ended", t -> has_ended(view_of(t).session.repl))
    QML.addrole!(rows, "rowModel", t -> QML.QVariant(view_of(t).model))
    QML.addrole!(rows, "props", t -> QML.QVariant(view_of(t).props.propertymap))
    return WindowState(TabSet.Tabs(), Dict{Int, TabView}(), rows, props, tall_rows, String(startup_input),
        rank_count, true, Int[], nothing, 0)
end

view_of(tab::TabSet.Tab)::TabView = tab.state

# A new tab's view: a pane of one row until it is sized, and a session that starts with `startup`.
function new_view(win::WindowState, startup::String)
    props = QML.JuliaPropertyMap()
    props["follow"] = true
    props["target"] = 0
    props["refill"] = 0
    props["thumbTop"] = 0.0
    props["thumbSize"] = 1.0
    props["ended"] = false
    props["exitText"] = ""
    owner = Ref{Any}(nothing)
    session = ReplPane.State(ReplSession.julia_repl_command(), startup, win.tall_rows;
        changed = () -> publish_rows!(owner[]))
    model = QML.JuliaItemModel(session.pane.rows, false)
    QML.addrole!(model, "html", identity)
    QML.get_julia_data(model).values[] === session.pane.rows || error("the item model does not wrap the pane rows")
    view = TabView(session, model, props, false)
    owner[] = view
    return view
end

# The pane's matrix keeps its size and identity, so each refill is one `dataChanged`.
function publish_rows!(view::TabView)
    QML.emit_data_changed(view.model, 1, 1, size(view.session.pane.rows, 1), 1)
    return nothing
end

# Set the properties read by QML for the tab. Nothing is set for a hidden tab: its properties are set
# when it is shown. `refill` is set last: QML moves the view when it changes, and must then see the
# current `follow`, `target` and scrollbar thumb.
function sync_props!(view::TabView)
    st = view.session
    st.visible || return nothing
    pane = st.pane
    p = view.props
    follow = pane.follow
    follow == p["follow"] || (p["follow"] = follow)
    target = follow_row(pane)
    target == p["target"] || (p["target"] = target)
    thumb_top, thumb_size = scrollbar_state(pane)
    thumb_top == p["thumbTop"] || (p["thumbTop"] = thumb_top)
    thumb_size == p["thumbSize"] || (p["thumbSize"] = thumb_size)
    ended = has_ended(st.repl)
    ended == p["ended"] || (p["ended"] = ended)
    exit_text = ended ? describe_exit(st.repl.exit) : ""
    exit_text == p["exitText"] || (p["exitText"] = exit_text)
    if st.refilled
        p["refill"] = p["refill"] + 1
        st.refilled = false
    end
    return nothing
end

"""
    run_single_repl(; startup_input = "", tall_rows = nothing, rank_count = nothing)

Open the window with one tab, which runs a Julia REPL, and run the Qt event loop on the calling thread
until the window is closed. Must be called from the main thread, not from an `@async` task. Throws an
error if a window is already open in this process.

`rank_count` is the number of MPI ranks, or `nothing`. A count is recorded in the window state and read
with `rank_count`; no MPI ranks are launched. Without a count, the window first shows a modal dialog
that asks for one. Its OK button is enabled only for a whole number of 1 or more, and records the count.
Cancel, or Escape, closes the window, and this function then returns without a count. An invalid
`rank_count` throws `ArgumentError`.

Each tab is an independent REPL with its own pane, output, scrollback, selection, scrollbar and restart
prompt. The tab bar at the top of the window lists the tabs as "Julia 1", "Julia 2", and so on, in the
order they were opened; the number is never reused in the window. The "+" button opens a new REPL tab and
selects it. The close button of a tab, or a middle-click on it, closes the tab and ends its REPL. The
tab to its right is then selected, or the tab to its left if there is none. Closing the last tab closes
the window. A tab whose REPL has ended is labelled "(ended)" and its title is dimmed. Only the selected
tab is shown and takes keyboard input, but the other tabs keep running, and their output is read while
they are hidden. Each tab keeps its scroll position while hidden. Closing the window ends every tab's REPL.

The window starts `julia -q --startup-file=no` in a pseudo-terminal, sized to the pane. When the
first `julia> ` prompt appears, `startup_input` is written to the pseudo-terminal, as if typed. Use
`"\\r"` at the end of each line to submit it. Only the first tab's REPL receives `startup_input`.

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
bottom of the output. Once the child has exited, a prompt at the bottom of the pane says how it ended and
offers to restart it, with the Restart button or Return. Restarting starts a new REPL in the same pane,
after a separator in the output. The output stays visible and selectable while the prompt is shown, and
input is ignored.

Each log line is one row of the pane: a line wider than the pane is cut off at its right edge.

An error from a tab's reader or writer task, or from a QML call, is rethrown by this function once the
window has closed.
"""
function run_single_repl(; startup_input::AbstractString = "", tall_rows = nothing, rank_count = nothing)
    tall = check_tall_rows(tall_rows)
    ranks = check_rank_count(rank_count)
    WINDOW_OPEN[] && error("the MPIEnsemble window is already open in this process")
    win = WindowState(startup_input, tall, ranks)
    register_functions!(win)
    WINDOW_OPEN[] = true
    try
        new_tab!(win)
        QML.loadqml(QML_MAIN; tabModel = win.tab_rows, windowProps = win.props)
        run_loop!(win)
    finally
        WINDOW_OPEN[] = false
        shutdown!(win)
    end
    return nothing
end

# Each QML function is registered once. Functions that take a tab id run `tab_call` or `pane_call`.
function register_functions!(win::WindowState)
    QML.qmlfunction("windowClosed", () -> (WINDOW_OPEN[] = false; nothing))
    QML.qmlfunction("setRankCount", n -> guarded(() -> set_rank_count!(win, Int(n)), win, nothing))
    QML.qmlfunction("cancelRankDialog", () -> guarded(() -> cancel_rank_dialog!(win), win, nothing))
    QML.qmlfunction("newTab", () -> guarded(() -> new_tab!(win), win, nothing))
    QML.qmlfunction("selectTab", id -> tab_call(view -> select_tab!(win, Int(id)), win, id, nothing))
    QML.qmlfunction("closeTab", id -> tab_call(view -> request_close!(win, Int(id)), win, id, nothing))
    QML.qmlfunction("paneSized", (id, w, h, cw, ch) ->
        pane_call(view -> pane_sized!(view, w, h, cw, ch), win, id, nothing; hidden_ok = true))
    QML.qmlfunction("userScrolled", (id, first, count, at_end) ->
        pane_call(view -> scrolled!(view, first, count, at_end), win, id, 0; hidden_ok = true))
    QML.qmlfunction("scrollToFraction", (id, f) ->
        pane_call(view -> view_op!(view, p -> scroll_to_fraction!(p, Float64(f))), win, id, 0))
    QML.qmlfunction("pageView", (id, dir) -> pane_call(view -> view_op!(view, p -> page!(p, Int(dir))), win, id, 0))
    QML.qmlfunction("scrollKey", (id, key, modifiers) -> pane_call(view -> scroll_key!(view, key, modifiers), win, id, -1))
    # Text from QML arrives as a QString, whose code units are UTF-16. It is converted to a String
    # here, so that the bytes sent are UTF-8.
    QML.qmlfunction("keyPressed", (id, key, text, modifiers) ->
        pane_call(view -> key_pressed!(view, key, String(text), modifiers), win, id, false))
    QML.qmlfunction("isPasteChord", (key, modifiers) -> is_paste_chord(Int(key), Int(modifiers)))
    QML.qmlfunction("pasteText", (id, text) -> pane_call(view -> paste_text!(view, String(text)), win, id, false))
    QML.qmlfunction("selectionStart", (id, slot, col) ->
        pane_call(view -> selection_op!(view, p -> select_start!(p, Int(slot), Int(col))), win, id, nothing))
    QML.qmlfunction("selectionExtendStart", (id, slot, col) ->
        pane_call(view -> selection_op!(view, p -> select_extend_start!(p, Int(slot), Int(col))), win, id, nothing))
    QML.qmlfunction("selectionExtend", (id, slot, col) ->
        pane_call(view -> selection_op!(view, p -> select_extend!(p, Int(slot), Int(col))), win, id, nothing))
    QML.qmlfunction("selectionEnd", id -> pane_call(view -> selection_end!(view), win, id, nothing))
    QML.qmlfunction("selectWord", (id, slot, col) ->
        pane_call(view -> selection_end_op!(view, p -> select_word!(p, Int(slot), Int(col))), win, id, nothing))
    QML.qmlfunction("selectLine", (id, slot) ->
        pane_call(view -> selection_end_op!(view, p -> select_line!(p, Int(slot))), win, id, nothing))
    QML.qmlfunction("clearSelection", id -> pane_call(view -> selection_op!(view, clear_selection!), win, id, nothing))
    QML.qmlfunction("restartSession", id -> pane_call(restart_session!, win, id, nothing))
    return nothing
end

# Run `f` for the tab `id`, which is given its view. Returns `default` for a tab that has been closed:
# a QML event queued before the close can still arrive. An id that was never a tab of this window is
# an error.
function tab_call(f, win::WindowState, id, default)
    return guarded(() -> begin
        view = get(win.views, Int(id), nothing)
        if view === nothing
            TabSet.check_closed(win.tabs, Int(id))
            return default
        end
        return f(view)
    end, win, default)
end

# As `tab_call`, but for a pane that is shown. A hidden pane is neither refilled nor sized, so an event
# for it is an error, unless `hidden_ok` is set: the scroll and size events that QML can send just after
# the pane has been hidden return `default` instead.
function pane_call(f, win::WindowState, id, default; hidden_ok::Bool = false)
    return tab_call(win, id, default) do view
        if !view.session.visible
            hidden_ok && return default
            error("event for tab $id, whose pane is hidden")
        end
        return f(view)
    end
end

# Run `f`, and keep the first error for the event loop. The QML call then returns `default`.
function guarded(f, win::WindowState, default)
    try
        return f()
    catch e
        win.failure === nothing && (win.failure = CapturedException(e, catch_backtrace()))
        return default
    end
end

function run_loop!(win::WindowState)
    while WINDOW_OPEN[]
        QML.process_events()
        check_failure!(win)
        service!(win)
        check_failure!(win)
        sleep(0.005)
    end
    return nothing
end

check_failure!(win::WindowState) = win.failure === nothing || throw(win.failure)

# One pass of the event loop: close the tabs that were asked to close, then feed the output of every
# tab, sharing `LINES_PER_TICK` lines between them.
function service!(win::WindowState)
    while !isempty(win.closing)
        id = popfirst!(win.closing)
        TabSet.is_open(win.tabs, id) && close_tab!(win, id)
    end
    win.offset = TabSet.drain_fairly!((tab, limit) -> feed_tab!(win, tab, limit), win.tabs.tabs,
        LINES_PER_TICK, win.offset)
    return nothing
end

# Feed the output of one tab to its log, and report a change of its ended state in the tab bar.
# The pane is refreshed only while the tab is visible (see `ReplPane.feed!`).
function feed_tab!(win::WindowState, tab::TabSet.Tab, limit::Int)
    view = view_of(tab)
    lines = ReplPane.feed!(view.session, limit)
    sync_props!(view)
    ended = has_ended(view.session.repl)
    if ended != view.ended_shown
        view.ended_shown = ended
        i = TabSet.index_of(win.tabs, tab.id)
        QML.emit_data_changed(win.tab_rows, i, 1, i, 1)
    end
    return lines
end

# Add a REPL tab at the end and select it. The startup input goes to the first tab only.
function new_tab!(win::WindowState)
    startup = win.startup_pending ? win.startup_input : ""
    view = new_view(win, startup)
    win.startup_pending = false
    previous = TabSet.selected_id(win.tabs)
    tab = TabSet.open!(win.tabs, :repl, view)
    win.views[tab.id] = view
    push!(win.tab_rows, tab)
    show_selection!(win, previous)
    return nothing
end

function select_tab!(win::WindowState, id::Int)
    previous = TabSet.selected_id(win.tabs)
    TabSet.select!(win.tabs, id)
    show_selection!(win, previous)
    return nothing
end

# Make the selected tab visible and every other tab hidden, after the selection has changed from
# `previous`, and tell QML which tab is selected.
function show_selection!(win::WindowState, previous::Int)
    current = TabSet.selected_id(win.tabs)
    current == previous && return nothing
    old = get(win.views, previous, nothing)
    old === nothing || ReplPane.set_visible!(old.session, false)
    if current != 0
        ReplPane.set_visible!(win.views[current].session, true)
    end
    win.props["selected"] = current
    return nothing
end

# The number of MPI ranks given to the window, or `nothing` while none has been given.
rank_count(win::WindowState) = win.rank_count

# Record the count given in the rank dialog. The window must not have a count already.
function set_rank_count!(win::WindowState, n::Integer)
    win.rank_count === nothing || error("the window already has a rank count of $(win.rank_count)")
    win.rank_count = check_rank_count(n)
    win.props["askRanks"] = false
    return nothing
end

# The rank dialog was cancelled: no count is recorded and the window is closed.
function cancel_rank_dialog!(win::WindowState)
    win.rank_count === nothing || error("the window already has a rank count of $(win.rank_count)")
    win.props["askRanks"] = false
    win.props["closeRequest"] = win.props["closeRequest"] + 1
    return nothing
end

# Ask the event loop to close the tab `id`. The loop closes it on its next pass.
function request_close!(win::WindowState, id::Int)
    push!(win.closing, id)
    return nothing
end

# Close the tab `id`: remove it from the tab bar, select its neighbour if it was selected, and end its
# REPL. Closing the last tab asks QML to close the window. The REPL is ended last, because
# `ReplPane.shutdown!` can throw after the session is closed; the tab is then already removed, so
# `shutdown!(win)` does not end it again.
function close_tab!(win::WindowState, id::Int)
    view = win.views[id]
    delete!(win.views, id)
    i = TabSet.index_of(win.tabs, id)
    TabSet.close!(win.tabs, id)
    delete!(win.tab_rows, i)
    show_selection!(win, id)
    if TabSet.window_should_close(win.tabs)
        win.props["closeRequest"] = win.props["closeRequest"] + 1
    end
    ReplPane.shutdown!(view.session)
    return nothing
end

# Called from QML with the pane size and the measured cell size, in pixels.
function pane_sized!(view::TabView, w, h, cw, ch)
    pane_rows = max(1, floor(Int, h / ch))
    cols = max(1, floor(Int, w / cw))
    ReplPane.size!(view.session, pane_rows, cols)
    sync_props!(view)
    return nothing
end

# Start a new REPL in the pane after the previous one has ended. The output of the previous session
# stays in the pane, and the new session's output follows it.
function restart_session!(view::TabView)
    st = view.session
    has_ended(st.repl) || error("the REPL is still running, so it cannot be restarted")
    ReplPane.restart!(st)
    sync_props!(view)
    return nothing
end

# Scrolling by the scrollbar and by the jump keys. Returns the matrix row at the top of the view after
# the change, or 0 when the pane now follows the bottom (QML then places the view by the follow rule).
function view_op!(view::TabView, f)
    row = f(view.session.pane)
    sync_props!(view)
    return row
end

# Called from QML for each key press before it is translated. Returns the row as `view_op!` does, or
# -1 when the key is not a jump key, in which case QML passes it on.
function scroll_key!(view::TabView, key, modifiers)
    action = scroll_action(Int(key), Int(modifiers))
    action === nothing && return -1
    return view_op!(view, p -> scroll_action!(p, action))
end

# Called from QML for each key press. Returns whether the key was sent, so that QML accepts only
# the events that were handled. Input is ignored once the child has exited.
function key_pressed!(view::TabView, key, text, modifiers)
    st = view.session
    is_started(st.repl) || error("keyboard input before the session has started")
    bytes = key_bytes(Int(key), text, Int(modifiers); application_cursor = application_cursor(st.repl.term))
    bytes === nothing && return false
    return send_bytes!(view, bytes)
end

# Apply a change to the selection, then update the properties that QML reads.
function selection_op!(view::TabView, f)
    f(view.session.pane)
    sync_props!(view)
    return nothing
end

# A change that ends a selection gesture: the selected text becomes the PRIMARY selection, if any.
function selection_end_op!(view::TabView, f)
    selection_op!(view, f)
    set_primary_selection!(selected_text(view.session.pane))
    return nothing
end

selection_end!(view::TabView) = selection_end_op!(view, select_end!)

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
function paste_text!(view::TabView, text)
    is_started(view.session.repl) || error("paste before the session has started")
    isempty(text) && return false
    return send_bytes!(view, paste_bytes(text; bracketed = bracketed_paste(view.session.repl.term)))
end

# Queue bytes for the child. The pane then follows the bottom, since the child's echo follows input.
# Returns false, and does nothing else, when the child has ended.
function send_bytes!(view::TabView, bytes::Vector{UInt8})
    ReplPane.send_input!(view.session, bytes) || return false
    sync_props!(view)
    return true
end

function scrolled!(view::TabView, first, count, at_end)
    shift = user_scrolled!(view.session.pane, Int(first), Int(count), Bool(at_end))
    sync_props!(view)
    return shift
end

# Close every tab's session and complete its log (see `ReplPane.shutdown!`). Every tab is shut down
# even if one fails; the first failure is then rethrown.
function shutdown!(win::WindowState)
    failures = Any[]
    for tab in win.tabs.tabs
        try
            ReplPane.shutdown!(view_of(tab).session)
        catch e
            push!(failures, e)
        end
    end
    isempty(failures) || throw(first(failures))
    return nothing
end

end # module Gui
