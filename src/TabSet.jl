# The tabs of a window: an ordered list of tabs, one of which is selected while any tab is open. This
# file does not use QML, so the tab rules can be tested without a display.
#
# Each tab has an id that is never reused in the window, and a number that gives its title. Closed ids
# are kept, so that a call for a closed tab, which can arrive from a queued event, is told apart from
# a call for an id that was never open (see `check_closed`).
module TabSet

export Tab, Tabs, open!, close!, select!, selected_id, is_open, index_of, check_closed,
    window_should_close, tab_label, drain_fairly!

# Title prefix for each kind of tab that `open!` accepts.
const KIND_NAMES = Dict(:repl => "Julia")

"""
    Tab(id, kind, number, state)

A tab of a window. `id` identifies it for the window's lifetime, `number` numbers it in the title, and
`state` is the object that holds what the tab shows, which this file does not inspect.
"""
struct Tab
    id::Int
    kind::Symbol
    number::Int
    state::Any
end

"""
    Tabs()

The tabs of a window, in display order. Create one per window, with `open!` to add a tab.
"""
mutable struct Tabs
    tabs::Vector{Tab}
    selected::Int           # id of the selected tab, or 0 when no tab is open
    next_id::Int
    next_number::Int
    closed::Set{Int}
end

Tabs() = Tabs(Tab[], 0, 1, 1, Set{Int}())

Base.length(ts::Tabs) = length(ts.tabs)
Base.isempty(ts::Tabs) = isempty(ts.tabs)

"""
    tab_title(tab) -> String

The title of `tab`, such as `Julia 2`.
"""
function tab_title(tab::Tab)
    prefix = get(KIND_NAMES, tab.kind, nothing)
    prefix === nothing && throw(ArgumentError("no title for tabs of kind $(tab.kind)"))
    return "$prefix $(tab.number)"
end

"""
    tab_label(tab, ended::Bool) -> String

The title of `tab` with a marker when its session has ended, such as `Julia 2 (ended)`.
"""
tab_label(tab::Tab, ended::Bool) = ended ? tab_title(tab) * " (ended)" : tab_title(tab)

"""
    open!(ts, kind, state) -> Tab

Add a tab of `kind` at the end of `ts`, holding `state`, and select it. The new tab takes the next id
and the next number, neither of which is used by another tab in this window.
"""
function open!(ts::Tabs, kind::Symbol, state)
    haskey(KIND_NAMES, kind) || throw(ArgumentError("unknown tab kind $kind"))
    tab = Tab(ts.next_id, kind, ts.next_number, state)
    ts.next_id += 1
    ts.next_number += 1
    push!(ts.tabs, tab)
    ts.selected = tab.id
    return tab
end

"""
    close!(ts, id) -> Tab

Remove the open tab `id` and return it. If it was the selected tab, the tab to its right is selected,
or the tab to its left when there is none to the right. Closing the last tab leaves no tab selected,
and `window_should_close` then holds. Throws if `id` is not open.
"""
function close!(ts::Tabs, id::Integer)
    i = index_of(ts, id)
    tab = ts.tabs[i]
    deleteat!(ts.tabs, i)
    push!(ts.closed, tab.id)
    if ts.selected == tab.id
        ts.selected = isempty(ts.tabs) ? 0 : ts.tabs[min(i, length(ts.tabs))].id
    end
    return tab
end

"""
    select!(ts, id)

Select the open tab `id`. Throws if `id` is not open.
"""
function select!(ts::Tabs, id::Integer)
    index_of(ts, id)
    ts.selected = Int(id)
    return ts
end

"""
    selected_id(ts) -> Int

The id of the selected tab, or 0 when no tab is open.
"""
selected_id(ts::Tabs) = ts.selected

"""
    is_open(ts, id) -> Bool

Whether `id` is an open tab.
"""
is_open(ts::Tabs, id::Integer) = findfirst(t -> t.id == id, ts.tabs) !== nothing

"""
    index_of(ts, id) -> Int

The position of the open tab `id` in `ts`. Throws if `id` is not open.
"""
function index_of(ts::Tabs, id::Integer)
    i = findfirst(t -> t.id == id, ts.tabs)
    i === nothing && throw(ErrorException("tab $id is not open"))
    return i
end

"""
    check_closed(ts, id)

Return nothing when `id` is a tab that was open and has been closed. Throws if `id` was never a tab
of `ts`, or is an open tab.
"""
function check_closed(ts::Tabs, id::Integer)
    id in ts.closed || throw(ErrorException("tab $id is neither open nor closed in this window"))
    return nothing
end

"""
    window_should_close(ts) -> Bool

Whether no tab is open, which is when the window that holds `ts` should close.
"""
window_should_close(ts::Tabs) = isempty(ts.tabs)

"""
    drain_fairly!(feed, items, budget, offset) -> Int

Share `budget` units of work between `items`, calling `feed(item, limit)` for each item in turn. The
item is allowed at most `limit` units, and `feed` returns the units it used. Items are visited from
position `offset`, in rounds: each round allows every item an equal share of what is left, rounded
up, and rounds continue while budget remains and some item used some of it. The return value is the
position to start from next time, so that the items that get the rounding remainder rotate. Positions
count from 1 in the order of `eachindex(items)`, so `items` may have any axes.
"""
function drain_fairly!(feed, items::AbstractVector, budget::Integer, offset::Integer)
    budget >= 1 || throw(ArgumentError("the budget must be at least 1, got $budget"))
    n = length(items)
    n == 0 && return 1
    indices = collect(eachindex(items))
    remaining = Int(budget)
    progress = true
    while remaining > 0 && progress
        progress = false
        share = cld(remaining, n)
        for k in 0:n-1
            remaining > 0 || break
            used = feed(items[indices[mod1(offset + k, n)]], min(share, remaining))
            if used > 0
                progress = true
                remaining = max(0, remaining - used)
            end
        end
    end
    return mod1(offset + 1, n)
end

end # module TabSet
