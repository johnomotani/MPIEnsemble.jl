using OffsetArrays

const TS = MPIEnsemble.TabSet

ts_titles(ts) = [TS.tab_title(t) for t in ts.tabs]
ts_states(ts) = [t.state for t in ts.tabs]

# The invariants of a tab set: the selected tab is open while any tab is open, and no id is both open
# and closed.
function ts_check(ts)
    ids = [t.id for t in ts.tabs]
    @test allunique(ids)
    @test isempty(intersect(Set(ids), ts.closed))
    if isempty(ts.tabs)
        @test TS.selected_id(ts) == 0
    else
        @test TS.selected_id(ts) in ids
    end
    return nothing
end

@testset "TabSet: a new set has no tabs" begin
    ts = TS.Tabs()
    @test isempty(ts)
    @test TS.selected_id(ts) == 0
    @test TS.window_should_close(ts)
end

@testset "TabSet: opening selects the new tab, and titles are numbered by creation" begin
    ts = TS.Tabs()
    a = TS.open!(ts, :repl, "a")
    @test TS.selected_id(ts) == a.id
    b = TS.open!(ts, :repl, "b")
    c = TS.open!(ts, :repl, "c")
    @test TS.selected_id(ts) == c.id
    @test length(ts) == 3
    @test ts_titles(ts) == ["Julia 1", "Julia 2", "Julia 3"]
    @test ts_states(ts) == ["a", "b", "c"]
    ts_check(ts)
end

@testset "TabSet: select changes the selection and rejects ids that are not open" begin
    ts = TS.Tabs()
    a = TS.open!(ts, :repl, "a")
    b = TS.open!(ts, :repl, "b")
    TS.select!(ts, a.id)
    @test_throws ErrorException TS.select!(ts, 99)
    @test TS.selected_id(ts) == a.id
    ts_check(ts)
end

@testset "TabSet: ids and numbers are never reused" begin
    ts = TS.Tabs()
    a = TS.open!(ts, :repl, "a")
    b = TS.open!(ts, :repl, "b")
    TS.close!(ts, b.id)
    d = TS.open!(ts, :repl, "d")
    @test d.id == 3
    @test TS.tab_title(d) == "Julia 3"
    TS.close!(ts, d.id)
    TS.close!(ts, a.id)
    e = TS.open!(ts, :repl, "e")
    @test e.id == 4
    @test TS.tab_title(e) == "Julia 4"
    @test TS.is_open(ts, a.id) == false
    @test TS.is_open(ts, e.id)
    ts_check(ts)
end

@testset "TabSet: closing the selected tab selects the one to its right, else the one to its left" begin
    ts = TS.Tabs()
    a = TS.open!(ts, :repl, "a")
    b = TS.open!(ts, :repl, "b")
    c = TS.open!(ts, :repl, "c")
    d = TS.open!(ts, :repl, "d")
    TS.select!(ts, b.id)
    @test TS.close!(ts, b.id) === b
    @test TS.selected_id(ts) == c.id
    TS.select!(ts, d.id)
    TS.close!(ts, d.id)
    @test TS.selected_id(ts) == c.id
    TS.close!(ts, a.id)
    @test TS.selected_id(ts) == c.id
    @test ts_states(ts) == ["c"]
    ts_check(ts)
end

@testset "TabSet: closing a tab that is not selected keeps the selection" begin
    ts = TS.Tabs()
    a = TS.open!(ts, :repl, "a")
    b = TS.open!(ts, :repl, "b")
    TS.select!(ts, b.id)
    TS.close!(ts, a.id)
    @test TS.selected_id(ts) == b.id
    ts_check(ts)
end

@testset "TabSet: closing the last tab reports that the window should close" begin
    ts = TS.Tabs()
    a = TS.open!(ts, :repl, "a")
    @test !TS.window_should_close(ts)
    TS.close!(ts, a.id)
    @test TS.window_should_close(ts)
    @test TS.selected_id(ts) == 0
    ts_check(ts)
end

@testset "TabSet: closed and unknown ids are told apart" begin
    ts = TS.Tabs()
    a = TS.open!(ts, :repl, "a")
    @test_throws ErrorException TS.check_closed(ts, a.id)
    @test_throws ErrorException TS.check_closed(ts, 42)
    TS.close!(ts, a.id)
    @test TS.check_closed(ts, a.id) === nothing
    @test_throws ErrorException TS.close!(ts, a.id)
    @test_throws "tab 42 is neither open nor closed" TS.check_closed(ts, 42)
end

@testset "TabSet: titles and markers" begin
    ts = TS.Tabs()
    TS.open!(ts, :repl, "a")
    b = TS.open!(ts, :repl, "b")
    @test TS.tab_label(b, false) == "Julia 2"
    @test TS.tab_label(b, true) == "Julia 2 (ended)"
    @test_throws ArgumentError TS.open!(ts, :mpi, "x")
end

# A fixed sequence of pseudo-random numbers in 0:1 (a linear congruential generator), so that the
# test does not depend on the Random standard library.
function ts_lcg(seed::UInt64)
    state = seed
    return () -> begin
        state = state * 6364136223846793005 + 1442695040888963407
        return (state >> 11) / 2.0^53
    end
end

@testset "TabSet: random opens, closes and selections keep the invariants" begin
    next = ts_lcg(UInt64(7))
    ts = TS.Tabs()
    opened = 0
    for _ in 1:400
        r = next()
        if r < 0.4 || isempty(ts)
            TS.open!(ts, :repl, opened)
            opened += 1
        elseif r < 0.7
            TS.close!(ts, ts.tabs[1 + floor(Int, next() * length(ts))].id)
        else
            TS.select!(ts, ts.tabs[1 + floor(Int, next() * length(ts))].id)
        end
        ts_check(ts)
    end
    @test length(ts.closed) + length(ts) == opened
end

@testset "TabSet: ten open and close cycles" begin
    ts = TS.Tabs()
    for cycle in 1:10
        tab = TS.open!(ts, :repl, cycle)
        @test TS.selected_id(ts) == tab.id
        @test TS.tab_title(tab) == "Julia $cycle"
        TS.close!(ts, tab.id)
        @test TS.window_should_close(ts)
        ts_check(ts)
    end
    @test ts.next_id == 11
end

@testset "drain_fairly!: one busy tab gets the whole budget" begin
    used = Dict(1 => 0, 2 => 0, 3 => 0)
    feed(i, limit) = (used[i] += limit; limit)
    TS.drain_fairly!(feed, [1, 2, 3], 300, 1)
    @test used == Dict(1 => 100, 2 => 100, 3 => 100)
end

@testset "drain_fairly!: idle tabs do not take share and the rest use the budget" begin
    used = [0, 0, 0]
    feed(i, limit) = i == 2 ? (used[i] += limit; limit) : 0
    TS.drain_fairly!(feed, [1, 2, 3], 500, 1)
    @test used == [0, 500, 0]
end

@testset "drain_fairly!: a tab with less work than its share passes the rest on" begin
    # Tab 1 has 3 units, tab 2 has 1000 and tab 3 has 1000. The budget is 300, so tabs 2 and 3 share
    # what tab 1 does not use, and the total is the budget.
    work = [3, 1000, 1000]
    used = [0, 0, 0]
    function feed(i, limit)
        n = min(limit, work[i])
        work[i] -= n
        used[i] += n
        return n
    end
    TS.drain_fairly!(feed, [1, 2, 3], 300, 1)
    @test sum(used) == 300
    @test used[1] == 3
    @test abs(used[2] - used[3]) <= 2
end

@testset "drain_fairly!: rounding remainder rotates between ticks" begin
    total = zeros(Int, 3)
    offset = 1
    for _ in 1:3
        offset = TS.drain_fairly!((i, limit) -> (total[i] += limit; limit), [1, 2, 3], 10, offset)
    end
    @test total == [10, 10, 10]
end

@testset "drain_fairly!: each call gets at most the share and at most what is left" begin
    limits = Tuple{Int, Int}[]
    TS.drain_fairly!((i, limit) -> (push!(limits, (i, limit)); 0), [1, 2, 3, 4], 10, 1)
    @test all(l -> l[2] == 3, limits)
    @test length(limits) == 4
end

@testset "drain_fairly!: no items, and a budget below one, are handled" begin
    @test TS.drain_fairly!((i, limit) -> error("no items"), Int[], 10, 1) == 1
    @test_throws ArgumentError TS.drain_fairly!((i, limit) -> 0, [1], 0, 1)
end

@testset "drain_fairly!: offset arrays visit the same items in the same order as vectors" begin
    # Each feed call uses half of its limit, so each run takes several rounds.
    function visits(items, budget, offset)
        calls = Tuple{Int, Int}[]
        next = TS.drain_fairly!((x, limit) -> (push!(calls, (x, limit)); limit ÷ 2), items, budget, offset)
        return calls, next
    end
    for offset in 1:3
        expected = visits([10, 20, 30], 40, offset)
        @test Set(first.(expected[1])) == Set([10, 20, 30])
        @test visits(OffsetArray([10, 20, 30], 0:2), 40, offset) == expected
        @test visits(OffsetArray([10, 20, 30], -1:1), 40, offset) == expected
    end
end
