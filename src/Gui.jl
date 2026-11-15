"""
    Gui

Qt window for MPIEnsemble, built from the QML files in `qml/`. Qt is
initialised when the first QML engine is created, so loading this module
needs a display only when a window is opened.

Only one QML engine can exist per process: `run_single_repl` can open a
window once per Julia session. The window has tabs (`TabSet`). A REPL tab
shows one pane, and an MPI tab shows one pane per MPI rank. Each pane has an
id of its own (`TabView.id`), and `WindowState.views` maps pane ids to panes.
QML calls take a pane id, or a tab id for the tab bar, as their first argument,
and are dispatched through `pane_call` and `tab_call`.
"""
module Gui

using QML
import ..ReplSession
import ..ReplPane
import ..TabSet
import ..MpiLauncher
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

# Lines appended to the logs per pass of the event loop, shared between all panes (see
# `TabSet.drain_fairly!`). Output beyond this waits for the next pass, so that the window stays
# responsive while a large output is being read.
const LINES_PER_TICK = 500

# Size of each MPI rank's terminal when its job starts, in characters. The first size reported by the
# rank's pane replaces it (see `ReplPane.size!`).
const RANK_ROWS = 24
const RANK_COLS = 80

"""
    TabView

The QML objects of one pane: the pane's rows as a model, and the properties that QML reads. `id` is the
pane's id, which QML uses in calls. `rank` is the MPI rank that the pane shows, or `nothing` for the pane of
a REPL tab. `ended_shown` is the ended state last reported in the tab bar (REPL tabs only). `failure` is the
error that stopped the pane's rank connection, or `nothing`. `killed` is true when the rank's job was killed
from the window while the rank had not ended (see `kill_mpi!`).
"""
mutable struct TabView
    const id::Int
    const session::ReplPane.State
    const model::Any
    const props::QML.JuliaPropertyMap
    const rank::Union{Nothing, Int}
    ended_shown::Bool
    failure::Any
    killed::Bool
end

"""
    MpiTab(nranks)

The state of an MPI tab. `views` holds one pane per rank, in rank order, once the job has started.
`status` is `:starting`, `:running`, `:ended`, `:killed` or `:failed`, and `failure` holds the message of a
failed start. `:ended` means every rank has ended on its own, or a restart failed after the previous job
ended; `:killed` means the job was killed. Both can be restarted (see `restart_mpi!`). `job` is the
launcher of the job, and `task` is the task that starts it. A job that has been killed or has ended
keeps its `job` until it is restarted or the tab is closed. `result` is what that task produced:
the job, or the error that stopped the launch, or `nothing` while the launch is in progress. The event loop
turns the result into panes and state (see `finish_launch!`), so the task itself never touches the window.
`offset` is where the fair drain of the rank panes starts next time (see `TabSet.drain_fairly!`).
`targets` is the set of ranks that receive input from the focused pane, and it holds every rank once the job
has started (see `attach_job!`). `zoomed` is the rank that alone receives input, or `nothing`. Both are
read by `route_targets`. `selected` is the rank that the user has selected with its Select button, or `nothing`
when no rank has been selected. `select_rank!` and `toggle_rank!` change `selected`, and `targets` with it: while
`selected` is a rank, `targets` is that rank alone. The two are kept apart because a job with one rank
has that rank as its only target without any selection.
"""
mutable struct MpiTab
    const nranks::Int
    const views::Vector{TabView}
    status::Symbol
    failure::Union{Nothing, String}
    job::Union{Nothing, MpiLauncher.Job}
    task::Union{Nothing, Task}
    result::Any
    offset::Int
    targets::Set{Int}
    selected::Union{Nothing, Int}
    zoomed::Union{Nothing, Int}
end

MpiTab(nranks::Int) =
    MpiTab(nranks, TabView[], :starting, nothing, nothing, nothing, nothing, 0, Set{Int}(), nothing, nothing)

# State of the window. `views` maps the pane ids of the open panes to their views, and `closed_panes`
# holds the ids of the panes that were closed. `tab_rows` is the tab bar's model. `repl_panes` and
# `rank_panes` are the models that QML repeats for the REPL panes and the rank panes. `props` holds the
# window's properties (see `new_window_props`), and `mpi_props` those of the MPI tab. `rank_count` is the
# number of MPI ranks, or `nothing` until the rank dialog gives one. `mpi_opened` is true once an MPI tab
# has been opened, which happens at most once per window. `closing` holds ids of tabs whose close was
# requested; they are closed by the event loop, not by the QML call. `failure` is the first error raised
# in a QML call, which the event loop rethrows. `offset` is where the fair drain of the tabs starts next
# time (see `TabSet.drain_fairly!`). `launch_options` are keyword arguments for `MpiLauncher.launch`.
mutable struct WindowState
    const tabs::TabSet.Tabs
    const views::Dict{Int, TabView}
    const closed_panes::Set{Int}
    const tab_rows::Any
    const repl_panes::Any
    const rank_panes::Any
    const props::QML.JuliaPropertyMap
    const mpi_props::QML.JuliaPropertyMap
    const tall_rows::Union{Nothing, Int}
    const startup_input::String
    const launch_options::NamedTuple
    rank_count::Union{Nothing, Int}
    mpi_opened::Bool
    startup_pending::Bool
    const closing::Vector{Int}
    failure::Any
    offset::Int
    next_pane_id::Int
end

function WindowState(startup_input::AbstractString, tall_rows::Union{Nothing, Int},
        rank_count::Union{Nothing, Int}; launch_options::NamedTuple = NamedTuple())
    props = QML.JuliaPropertyMap()
    props["selected"] = 0
    props["selectedKind"] = ""
    props["selectedPane"] = 0
    props["closeRequest"] = 0
    props["askRanks"] = rank_count === nothing
    mpi_props = QML.JuliaPropertyMap()
    mpi_props["status"] = ""
    mpi_props["message"] = ""
    mpi_props["columns"] = 1
    mpi_props["tabId"] = 0
    mpi_props["killable"] = false
    mpi_props["panes"] = false
    mpi_props["messageFailed"] = false
    rows = QML.JuliaItemModel(TabSet.Tab[], false)
    QML.addrole!(rows, "tabId", t -> t.id)
    QML.addrole!(rows, "tabTitle", t -> TabSet.tab_label(t, tab_ended(t)))
    QML.addrole!(rows, "ended", tab_ended)
    return WindowState(TabSet.Tabs(), Dict{Int, TabView}(), Set{Int}(), rows, pane_model(), pane_model(),
        props, mpi_props, tall_rows, String(startup_input), launch_options, rank_count, false, true, Int[],
        nothing, 0, 1)
end

# The model of panes that QML repeats. Each item is a `TabView`, and its roles are the required properties
# of Pane.qml.
function pane_model()
    model = QML.JuliaItemModel(TabView[], false)
    QML.addrole!(model, "paneId", v -> v.id)
    QML.addrole!(model, "rowModel", v -> QML.QVariant(v.model))
    QML.addrole!(model, "props", v -> QML.QVariant(v.props.propertymap))
    return model
end

# Whether the REPL of a REPL tab has ended. An MPI tab has no REPL of its own, so it has not ended.
tab_ended(tab::TabSet.Tab) = tab.kind === :repl && has_ended(tab.state.session.repl)

# The panes of a tab: the one pane of a REPL tab, or the rank panes of an MPI tab.
tab_views(tab::TabSet.Tab) = tab.kind === :mpi ? tab.state.views : (tab.state,)

# Number of columns of the rank grid: the smallest integer whose square is at least `nranks`.
rank_columns(nranks::Integer) = isqrt(nranks - 1) + 1

# A new pane's view, with the next pane id. `start` is called with the `changed` callback, which the pane
# calls when its rows are refilled while it is visible, and returns the pane's `ReplPane.State`. `rank` is
# the MPI rank that the pane shows, or `nothing`. The view is registered in `win.views`.
function new_view(win::WindowState, start::Function; rank::Union{Nothing, Int} = nothing)
    id = win.next_pane_id
    win.next_pane_id += 1
    props = QML.JuliaPropertyMap()
    props["follow"] = true
    props["target"] = 0
    props["refill"] = 0
    props["thumbTop"] = 0.0
    props["thumbSize"] = 1.0
    props["ended"] = false
    props["exitText"] = ""
    props["rankLabel"] = rank === nothing ? "" : string(rank)
    props["selected"] = false
    props["dimmed"] = false
    owner = Ref{Any}(nothing)
    session = start(() -> publish_rows!(owner[]))
    model = QML.JuliaItemModel(session.pane.rows, false)
    QML.addrole!(model, "html", identity)
    QML.get_julia_data(model).values[] === session.pane.rows || error("the item model does not wrap the pane rows")
    view = TabView(id, session, model, props, rank, false, nothing, false)
    owner[] = view
    win.views[id] = view
    return view
end

# Remove a closed pane from `win.views` and from the model that QML repeats for it.
function remove_view!(win::WindowState, view::TabView, panes)
    delete!(win.views, view.id)
    push!(win.closed_panes, view.id)
    i = findfirst(v -> v === view, Base.values(panes)[])
    i === nothing && error("pane $(view.id) is not in its model")
    delete!(panes, i)
    return nothing
end

# The pane's matrix keeps its size and identity, so each refill is one `dataChanged`.
function publish_rows!(view::TabView)
    QML.emit_data_changed(view.model, 1, 1, size(view.session.pane.rows, 1), 1)
    return nothing
end

# Set the properties read by QML for the pane. Nothing is set for a hidden pane: its properties are set
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
    ended = view.failure !== nothing || view.killed || has_ended(st.repl)
    ended == p["ended"] || (p["ended"] = ended)
    exit_text = ended ? end_text(view) : ""
    exit_text == p["exitText"] || (p["exitText"] = exit_text)
    if st.refilled
        p["refill"] = p["refill"] + 1
        st.refilled = false
    end
    return nothing
end

# The text of the prompt at the bottom of an ended pane. A rank cannot be restarted on its own, so its
# text says that its whole job must restart. A rank whose connection failed says so instead, and a rank
# whose job was killed says that.
function end_text(view::TabView)
    view.rank === nothing && return describe_exit(view.session.repl.exit)
    view.failure === nothing || return "Rank $(view.rank) failed: $(sprint(showerror, view.failure))"
    view.killed && return "Rank $(view.rank) ended: the MPI job was killed. " *
        "Restarting needs the whole MPI job to restart."
    return "Rank $(view.rank) ended: $(describe_exit(view.session.repl.exit)). " *
        "Restarting needs the whole MPI job to restart."
end

"""
    run_single_repl(; startup_input = "", tall_rows = nothing, rank_count = nothing)

Open the window with one tab, which runs a Julia REPL, and run the Qt event loop on the calling thread
until the window is closed. Must be called from the main thread, not from an `@async` task. Throws an
error if a window is already open in this process.

`rank_count` is the number of MPI ranks, or `nothing`. With a count, the window opens an MPI tab after the
REPL tab and launches that many ranks (see `open_mpi_tab!`). Without a count, the window first shows a
modal dialog that asks for one. Its OK button is enabled only for a whole number of 1 or more, and records
the count, and the MPI tab is opened. Cancel, or Escape, closes the window, and this function then returns
without a count. An invalid `rank_count` throws `ArgumentError`.

Each REPL tab is an independent REPL with its own pane, output, scrollback, selection, scrollbar and restart
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

The MPI tab has a Kill MPI button while its job can be killed. After confirmation in a dialog, the job is
killed at once, and each rank that had not ended shows that its job was killed. The rank panes stay in the
tab with their output, and refuse input. When every rank has ended on its own, or the job was killed, the
tab offers a Restart MPI button, which starts a new job with the same number of ranks in the same panes.
Each pane keeps its output, and the new session's output follows it.

An error from a tab's reader or writer task, or from a QML call, is rethrown by this function once the
window has closed. The error of a rank's connection is shown in that rank's pane and printed to standard
error instead, and the other panes keep working.
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
        QML.loadqml(QML_MAIN; tabModel = win.tab_rows, replModel = win.repl_panes, rankModel = win.rank_panes,
            windowProps = win.props, mpiProps = win.mpi_props)
        ranks === nothing || open_mpi_tab!(win)
        run_loop!(win)
    finally
        WINDOW_OPEN[] = false
        shutdown!(win)
    end
    return nothing
end

# Each QML function is registered once. Functions that take a pane id run `pane_call`, and those that
# take a tab id run `tab_call`.
function register_functions!(win::WindowState)
    QML.qmlfunction("windowClosed", () -> (WINDOW_OPEN[] = false; nothing))
    QML.qmlfunction("setRankCount", n -> guarded(() -> (set_rank_count!(win, Int(n)); open_mpi_tab!(win)), win, nothing))
    QML.qmlfunction("cancelRankDialog", () -> guarded(() -> cancel_rank_dialog!(win), win, nothing))
    QML.qmlfunction("newTab", () -> guarded(() -> new_tab!(win), win, nothing))
    QML.qmlfunction("selectTab", id -> tab_call(tab_id -> select_tab!(win, tab_id), win, id, nothing))
    QML.qmlfunction("closeTab", id -> tab_call(tab_id -> request_close!(win, tab_id), win, id, nothing))
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
        pane_call(view -> key_input!(win, view, key, String(text), modifiers), win, id, false))
    QML.qmlfunction("isPasteChord", (key, modifiers) -> is_paste_chord(Int(key), Int(modifiers)))
    QML.qmlfunction("pasteText", (id, text) ->
        pane_call(view -> paste_input!(win, view, String(text)), win, id, false))
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
    QML.qmlfunction("killMpi", id -> tab_call(tab_id -> kill_mpi!(win, tab_id), win, id, nothing))
    QML.qmlfunction("restartMpi", id -> tab_call(tab_id -> restart_mpi!(win, tab_id), win, id, nothing))
    QML.qmlfunction("toggleRank", id -> pane_call(view -> toggle_rank_pane!(win, view), win, id, nothing))
    return nothing
end

# Run `f` for the open tab `id`, which is given its id. Returns `default` for a tab that has been closed:
# a QML event queued before the close can still arrive. An id that was never a tab of this window is
# an error.
function tab_call(f, win::WindowState, id, default)
    return guarded(() -> begin
        if !TabSet.is_open(win.tabs, Int(id))
            TabSet.check_closed(win.tabs, Int(id))
            return default
        end
        return f(Int(id))
    end, win, default)
end

# Run `f` for the pane `id`, which is given its view. Returns `default` for a pane that has been closed,
# as `tab_call` does. A hidden pane is neither refilled nor sized, so an event for it is an error, unless
# `hidden_ok` is set: the scroll and size events that QML can send just after the pane has been hidden
# return `default` instead.
function pane_call(f, win::WindowState, id, default; hidden_ok::Bool = false)
    return guarded(() -> begin
        view = get(win.views, Int(id), nothing)
        if view === nothing
            Int(id) in win.closed_panes || error("pane $id is neither open nor closed in this window")
            return default
        end
        if !view.session.visible
            hidden_ok && return default
            error("event for pane $id, whose pane is hidden")
        end
        return f(view)
    end, win, default)
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

# One pass of the event loop: close the tabs that were asked to close, take the results of MPI launches,
# then feed the output of every tab, sharing `LINES_PER_TICK` lines between them.
function service!(win::WindowState)
    while !isempty(win.closing)
        id = popfirst!(win.closing)
        TabSet.is_open(win.tabs, id) && close_tab!(win, id)
    end
    for tab in win.tabs.tabs
        tab.kind === :mpi && finish_launch!(win, tab.state)
    end
    win.offset = TabSet.drain_fairly!((tab, limit) -> feed_tab!(win, tab, limit), win.tabs.tabs,
        LINES_PER_TICK, win.offset)
    # Ranks end while their output is fed, so whether the job has ended is checked afterwards.
    for tab in win.tabs.tabs
        tab.kind === :mpi && update_job_state!(win, tab.state)
    end
    return nothing
end

# Feed the output of one tab, and return the number of lines fed. A REPL tab's pane is fed, and its
# ended state is reported in the tab bar. An MPI tab shares `limit` between its rank panes.
function feed_tab!(win::WindowState, tab::TabSet.Tab, limit::Int)
    tab.kind === :mpi && return feed_mpi!(tab.state, limit)
    view = tab.state
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

# Feed the rank panes of an MPI tab, sharing `limit` between them in turn (see `TabSet.drain_fairly!`),
# so that one rank with much output cannot hold back the others.
function feed_mpi!(mpi::MpiTab, limit::Int)
    used = 0
    mpi.offset = TabSet.drain_fairly!(mpi.views, limit, mpi.offset) do view, share
        lines = feed_rank!(view, share)
        used += lines
        return lines
    end
    return used
end

# Feed one rank's pane. An error from the rank's connection, such as its wrapper closing the socket
# without an EXIT frame, is kept as the pane's failure: it is shown in the pane and printed, and the pane
# is not fed again. The other panes are not affected.
function feed_rank!(view::TabView, limit::Int)
    view.failure === nothing || return 0
    lines = try
        ReplPane.feed!(view.session, limit)
    catch e
        view.failure = e
        println(stderr, end_text(view))
        sync_props!(view)
        return 0
    end
    sync_props!(view)
    return lines
end

# Add a REPL tab at the end and select it. The startup input goes to the first tab only.
function new_tab!(win::WindowState)
    startup = win.startup_pending ? win.startup_input : ""
    win.startup_pending = false
    view = new_view(win, changed -> ReplPane.State(ReplSession.julia_repl_command(), startup, win.tall_rows; changed))
    tab = TabSet.open!(win.tabs, :repl, view)
    show_selection!(win)
    push!(win.tab_rows, tab)
    push!(win.repl_panes, view)
    return nothing
end

function select_tab!(win::WindowState, id::Int)
    TabSet.select!(win.tabs, id)
    show_selection!(win)
    return nothing
end

# The selected tab, or `nothing` when no tab is open.
function selected_tab(win::WindowState)
    id = TabSet.selected_id(win.tabs)
    id == 0 && return nothing
    return win.tabs.tabs[TabSet.index_of(win.tabs, id)]
end

# Make the panes of the selected tab visible and those of every other tab hidden, and tell QML which tab
# is selected. A pane's visibility is set before the properties that QML binds to it change, so that a
# pane which QML creates or shows finds itself visible.
function show_selection!(win::WindowState)
    current = TabSet.selected_id(win.tabs)
    for tab in win.tabs.tabs
        shown = tab.id == current
        for view in tab_views(tab)
            ReplPane.set_visible!(view.session, shown)
            sync_props!(view)
        end
    end
    tab = selected_tab(win)
    win.props["selected"] = current
    win.props["selectedKind"] = tab === nothing ? "" : string(tab.kind)
    win.props["selectedPane"] = tab !== nothing && tab.kind === :repl ? tab.state.id : 0
    return nothing
end

"""
    open_mpi_tab!(win) -> Tab

Open the MPI tab after the tabs that are open, select it, and start the ranks. The window's rank count
gives the number of ranks. The tab shows that the ranks are starting, and the launch runs in a task, so
that the window stays responsive while the job starts. When the job has started, the tab shows one pane
per rank, in rank order; if it cannot start, the tab shows the error and the error is printed to standard
error. A window has at most one MPI tab. Throws if the window has no rank count or already has an MPI tab.
"""
function open_mpi_tab!(win::WindowState)
    n = win.rank_count
    n === nothing && error("the window has no rank count, so there are no MPI ranks to launch")
    win.mpi_opened && error("the window already has an MPI tab, which is not opened again")
    win.mpi_opened = true
    mpi = MpiTab(n)
    tab = TabSet.open!(win.tabs, :mpi, mpi)
    win.mpi_props["tabId"] = tab.id
    win.mpi_props["columns"] = rank_columns(n)
    set_mpi_status!(win, mpi, :starting, "Starting $n MPI ranks…")
    show_selection!(win)
    push!(win.tab_rows, tab)
    mpi.task = @async start_ranks!(mpi, win.launch_options)
    return tab
end

# Set the status of an MPI tab and the properties that QML reads for it. `message` is the text shown in
# the tab: the note above the rank panes once they exist, or the text in place of them otherwise. It is
# the failure message when the tab has failed. `is_error` marks a note that reports an error.
function set_mpi_status!(win::WindowState, mpi::MpiTab, status::Symbol, message::AbstractString;
        is_error::Bool = false)
    mpi.status = status
    mpi.failure = status === :failed ? String(message) : nothing
    win.mpi_props["status"] = String(status)
    win.mpi_props["message"] = String(message)
    win.mpi_props["messageFailed"] = is_error || status === :failed
    update_killable!(win, mpi)
    return nothing
end

# A rank can be killed while it has not ended: the job has started, and some rank has neither delivered its
# exit status nor been killed. A rank whose connection failed may still be running, so it counts as running.
rank_running(view::TabView) = !view.killed && !has_ended(view.session.repl)
mpi_killable(mpi::MpiTab) = mpi.status === :running && any(rank_running, mpi.views)

# Set the property that enables the Kill MPI button, when it changes.
function update_killable!(win::WindowState, mpi::MpiTab)
    killable = mpi_killable(mpi)
    killable == win.mpi_props["killable"] || (win.mpi_props["killable"] = killable)
    return nothing
end

# The job has ended when it is running and no rank is running: each rank has ended on its own, or was killed.
# Then the tab says so, and the job can be restarted.
function update_job_state!(win::WindowState, mpi::MpiTab)
    if mpi.status === :running && !any(rank_running, mpi.views)
        set_mpi_status!(win, mpi, :ended, "The MPI job has ended.")
    end
    update_killable!(win, mpi)
    return nothing
end

# Launch the job of an MPI tab, in a task. The task only records the outcome in `mpi.result`: the window is
# changed by the event loop (see `finish_launch!`). An interrupt is the tab being closed while the job
# starts (see `close_mpi!`), and the launcher stops what it has started.
function start_ranks!(mpi::MpiTab, launch_options::NamedTuple)
    try
        mpi.result = MpiLauncher.launch(mpi.nranks, RANK_ROWS, RANK_COLS; launch_options...)
    catch e
        e isa InterruptException && return nothing
        mpi.result = e
    end
    return nothing
end

# Act on the outcome of an MPI launch, from the event loop, once it is known. A started job gets its panes,
# or, when it is a restart, the panes that it already has. An error is shown in the tab and printed to
# standard error, and the window keeps running. A failed restart leaves the panes with their output, and
# the job can be restarted again.
function finish_launch!(win::WindowState, mpi::MpiTab)
    mpi.status === :starting || return nothing
    result = mpi.result
    result === nothing && return nothing
    if result isa MpiLauncher.Job
        attach_job!(win, mpi, result)
    elseif isempty(mpi.views)
        message = "Could not start $(mpi.nranks) MPI ranks: $(sprint(showerror, result))"
        set_mpi_status!(win, mpi, :failed, message)
        println(stderr, message)
    else
        message = "Could not restart $(mpi.nranks) MPI ranks: $(sprint(showerror, result)). " *
            "Restart MPI to try again."
        set_mpi_status!(win, mpi, :ended, message; is_error = true)
        println(stderr, message)
    end
    return nothing
end

# Make the panes of a started job. The panes are made visible before they are added to the model that QML
# repeats, so that each pane is visible when QML creates it. Pane `i` shows the connection of rank `i - 1`,
# which the rank labels rely on: the rank comes from each connection's HELLO frame.
#
# A restart keeps the panes, their logs, and the targets and selection, and gives each pane the connection of the new
# job's rank with the same number. Each pane's output from the old job stays, and the new session follows it.
function attach_job!(win::WindowState, mpi::MpiTab, job::MpiLauncher.Job)
    for (i, conn) in enumerate(job.ranks)
        conn.rank == i - 1 || error("connection $i of the job is for rank $(conn.rank), not rank $(i - 1)")
    end
    mpi.job = job
    fresh = isempty(mpi.views)
    if fresh
        mpi.targets = Set(0:(length(job.ranks) - 1))
        for conn in job.ranks
            push!(mpi.views, new_view(win, changed -> ReplPane.State(conn, RANK_ROWS, RANK_COLS; changed);
                rank = conn.rank))
        end
        win.mpi_props["panes"] = true
    else
        length(mpi.views) == length(job.ranks) || error("the restarted job has $(length(job.ranks)) ranks, " *
            "but the tab has $(length(mpi.views)) panes")
        for (view, conn) in zip(mpi.views, job.ranks)
            view.rank == conn.rank || error("the pane of rank $(view.rank) was given the connection of rank $(conn.rank)")
            view.killed = false
            view.failure = nothing
            ReplPane.restart!(view.session, conn; rows = RANK_ROWS, cols = RANK_COLS)
            sync_props!(view)
        end
    end
    sync_selection_props!(mpi)
    set_mpi_status!(win, mpi, :running, "")
    show_selection!(win)
    if fresh
        for view in mpi.views
            push!(win.rank_panes, view)
        end
    end
    return nothing
end

"""
    kill_mpi!(win, id)

Kill the job of the MPI tab `id`, as Kill MPI does after it is confirmed. The launcher and the ranks are
stopped at once (see `MpiLauncher.kill!`). Each rank that had not ended is marked as killed, and its pane
says that its job was killed. The panes keep their output and refuse input, and the tab shows the job as
killed, so that it can be restarted (see `restart_mpi!`). Killing a job that is already killed does nothing.
A job that has not started, has ended, or whose launch failed, has nothing to kill, and throws. Throws if
`id` is not an MPI tab.
"""
function kill_mpi!(win::WindowState, id::Int)
    tab = win.tabs.tabs[TabSet.index_of(win.tabs, id)]
    tab.kind === :mpi || error("tab $id is not an MPI tab, so it has no MPI job to kill")
    mpi = tab.state
    mpi.status === :killed && return nothing
    mpi.status === :running || error("the MPI job of tab $id cannot be killed while it is $(mpi.status)")
    MpiLauncher.kill!(mpi.job)
    for view in mpi.views
        rank_running(view) || continue
        view.killed = true
        sync_props!(view)
    end
    set_mpi_status!(win, mpi, :killed, "The MPI job was killed.")
    return nothing
end

"""
    restart_mpi!(win, id)

Restart the job of the MPI tab `id` with the same number of ranks, once the job has ended: either every
rank ended on its own, or the job was killed (see `kill_mpi!`). The old job is shut down first, and its
socket directory removed, so that the old and the new job never run together. The rank panes are kept, and
each keeps its output: the new session's output follows it, after a line that says how the old session
ended. The new job is launched in a task, as the first one is (see `finish_launch!`). A tab that is starting,
running or failed throws, and so does a tab that is not an MPI tab.
"""
function restart_mpi!(win::WindowState, id::Int)
    tab = win.tabs.tabs[TabSet.index_of(win.tabs, id)]
    tab.kind === :mpi || error("tab $id is not an MPI tab, so it has no MPI job to restart")
    mpi = tab.state
    mpi.status in (:killed, :ended) ||
        error("the MPI job of tab $id cannot be restarted while it is $(mpi.status)")
    # Output that is queued for the panes is fed before the old job's sockets close, since a rank whose
    # connection failed reports the failure only when its output is fed.
    for view in mpi.views
        feed_rank!(view, typemax(Int))
    end
    if mpi.job !== nothing
        MpiLauncher.shutdown!(mpi.job)
        mpi.job = nothing
    end
    set_mpi_status!(win, mpi, :starting, "Restarting $(mpi.nranks) MPI ranks…")
    mpi.result = nothing
    mpi.task = @async start_ranks!(mpi, win.launch_options)
    return nothing
end

# The rank count given to the window, or `nothing` while none has been given.
rank_count(win::WindowState) = win.rank_count

# Record the count given in the rank dialog. The window must not have a count already. Opening the MPI tab
# is a separate step (see `open_mpi_tab!`).
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

# Close the tab `id`: hide its panes, remove it from the tab bar, select its neighbour if it was selected,
# and end what it runs. Closing the last tab asks QML to close the window. A REPL is ended last, because
# `ReplPane.shutdown!` can throw after the session is closed; the tab is then already removed, so
# `shutdown!(win)` does not end it again.
function close_tab!(win::WindowState, id::Int)
    i = TabSet.index_of(win.tabs, id)
    tab = win.tabs.tabs[i]
    for view in tab_views(tab)
        ReplPane.set_visible!(view.session, false)
    end
    TabSet.close!(win.tabs, id)
    delete!(win.tab_rows, i)
    show_selection!(win)
    if TabSet.window_should_close(win.tabs)
        win.props["closeRequest"] = win.props["closeRequest"] + 1
    end
    if tab.kind === :mpi
        close_mpi!(win, tab.state)
    else
        view = tab.state
        remove_view!(win, view, win.repl_panes)
        ReplPane.shutdown!(view.session)
    end
    return nothing
end

# End an MPI tab. A launch still in progress is interrupted, and the launcher stops what it has started.
# Each rank's session is shut down, and then the job is shut down, so that the ranks stop even when a
# rank's session fails. The first failure is rethrown afterwards. A failure that was already shown in its
# rank's pane is not repeated.
function close_mpi!(win::WindowState, mpi::MpiTab)
    failures = Any[]
    task = mpi.task
    if task !== nothing && !istaskdone(task)
        schedule(task, InterruptException(); error = true)
        try
            wait(task)
        catch e
            (e isa TaskFailedException && e.task.result isa InterruptException) || push!(failures, e)
        end
    end
    # A job that finished launching but was not attached yet is shut down with the others.
    if mpi.job === nothing && mpi.result isa MpiLauncher.Job
        mpi.job = mpi.result
    end
    for view in mpi.views
        ReplPane.set_visible!(view.session, false)
    end
    for view in mpi.views
        remove_view!(win, view, win.rank_panes)
        try
            ReplPane.shutdown!(view.session)
        catch e
            view.failure === e || push!(failures, e)
        end
    end
    empty!(mpi.views)
    if mpi.job !== nothing
        try
            MpiLauncher.shutdown!(mpi.job)
        catch e
            push!(failures, e)
        end
        mpi.job = nothing
    end
    isempty(failures) || throw(first(failures))
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

# The MPI tab that holds `view` as one of its rank panes, or `nothing` for a REPL tab's pane.
function mpi_tab_of(win::WindowState, view::TabView)
    for tab in win.tabs.tabs
        tab.kind === :mpi && any(v -> v === view, tab.state.views) && return tab.state
    end
    return nothing
end

# The rank panes that receive input from the focused rank pane of an MPI tab, in rank order: the zoomed
# rank alone when one is zoomed, else the panes of the ranks in `targets`. Each target must have a pane,
# so an error is raised for a target without one.
function route_targets(mpi::MpiTab)
    if mpi.zoomed !== nothing
        views = [v for v in mpi.views if v.rank == mpi.zoomed]
        length(views) == 1 || error("zoomed rank $(mpi.zoomed) has no pane in this MPI tab")
        return views
    end
    views = [v for v in mpi.views if v.rank in mpi.targets]
    length(views) == length(mpi.targets) || error("a target rank of this MPI tab has no pane")
    return views
end

# Select `rank`, which makes it the only target, so that input goes only to its pane. Throws if `rank` is not a
# rank of the job.
function select_rank!(mpi::MpiTab, rank::Integer)
    0 <= rank < mpi.nranks || error("rank $rank is not one of the $(mpi.nranks) ranks of this MPI tab")
    mpi.selected = Int(rank)
    mpi.targets = Set([Int(rank)])
    return nothing
end

# Clear the selection if `rank` is selected, else select it. Clearing makes every rank a target again, so input
# goes to all ranks. Selecting one rank while another is selected moves the selection to that rank.
function toggle_rank!(mpi::MpiTab, rank::Integer)
    if mpi.selected == Int(rank)
        mpi.selected = nothing
        mpi.targets = Set(0:(mpi.nranks - 1))
    else
        select_rank!(mpi, rank)
    end
    return nothing
end

# Toggle the selection from the Select button of the rank pane `view`. Throws if `view` is not a rank pane
# of an MPI tab.
function toggle_rank_pane!(win::WindowState, view::TabView)
    mpi = mpi_tab_of(win, view)
    mpi === nothing && error("pane $(view.id) is not a rank pane of an MPI tab, so it has no rank to select")
    toggle_rank!(mpi, view.rank)
    sync_selection_props!(mpi)
    return nothing
end

# Set the properties that QML reads for the selection. `selected` is true for the pane of the rank in
# `mpi.selected`, which shows its Select button as selected. `dimmed` is true for a pane that does not receive
# input from the focused pane (see `route_targets`).
function sync_selection_props!(mpi::MpiTab)
    receivers = Set(v.rank for v in route_targets(mpi))
    for view in mpi.views
        selected = view.rank == mpi.selected
        selected == view.props["selected"] || (view.props["selected"] = selected)
        dimmed = !(view.rank in receivers)
        dimmed == view.props["dimmed"] || (view.props["dimmed"] = dimmed)
    end
    return nothing
end

# Deliver input from the focused pane `view`, by calling `send(target)` for each pane that receives it.
# In a REPL tab that is `view` alone. In an MPI tab it is every pane from `route_targets`, and the result is
# whether `send` succeeded for `view`, which is false when `view` does not receive input.
function route_input!(send, win::WindowState, view::TabView)
    mpi = mpi_tab_of(win, view)
    mpi === nothing && return send(view)
    sent = false
    for target in route_targets(mpi)
        ok = send(target)
        target === view && (sent = ok)
    end
    return sent
end

# Called from QML for each key press in a pane. Returns whether the focused pane's key was sent.
key_input!(win::WindowState, view::TabView, key, text, modifiers) =
    route_input!(target -> key_pressed!(target, key, text, modifiers), win, view)

# Called from QML for each paste in a pane. Returns whether the focused pane's text was sent.
paste_input!(win::WindowState, view::TabView, text) = route_input!(target -> paste_text!(target, text), win, view)

# Called from QML for each key press. Returns whether the key was sent, so that QML accepts only
# the events that were handled. Input is ignored once the child has exited. Each pane encodes the key with
# its own terminal state, since application-cursor mode is set per rank.
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
# Returns false, and does nothing else, when the child has ended, its connection has failed, or its job was
# killed.
function send_bytes!(view::TabView, bytes::Vector{UInt8})
    (view.failure === nothing && !view.killed) || return false
    ReplPane.send_input!(view.session, bytes) || return false
    sync_props!(view)
    return true
end

function scrolled!(view::TabView, first, count, at_end)
    shift = user_scrolled!(view.session.pane, Int(first), Int(count), Bool(at_end))
    sync_props!(view)
    return shift
end

# Close every tab's session and complete its log (see `ReplPane.shutdown!`), and shut down every MPI job
# (see `close_mpi!`). Every tab is shut down even if one fails; the first failure is then rethrown.
function shutdown!(win::WindowState)
    failures = Any[]
    for tab in win.tabs.tabs
        try
            if tab.kind === :mpi
                close_mpi!(win, tab.state)
            else
                ReplPane.shutdown!(tab.state.session)
            end
        catch e
            push!(failures, e)
        end
    end
    isempty(failures) || throw(first(failures))
    return nothing
end

end # module Gui
