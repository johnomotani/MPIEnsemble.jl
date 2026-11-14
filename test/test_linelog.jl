const LL = MPIEnsemble.LineLog
const VTP = MPIEnsemble.VTParse

bytes_of(s::AbstractString) = Vector{UInt8}(codeunits(s))

entry_texts(log) = [(e.kind, e.session, e.text) for e in LL.window(log, 1:length(log))]

@testset "entries carry rank, session, time and byte spans" begin
    log = LL.RankLog(3)
    # One row, so that the line leaves the screen with the chunk that ends it.
    term = LL.begin_session!(log, 1, 1, 80)
    LL.feed_output!(log, term, bytes_of("\e[31mé\e[0m└ x\r\n"), 42)
    LL.end_session!(log, term, 43)
    e = LL.window(log, 1:1)[1]
    @test e.rank == 3
    @test e.session == 1
    @test e.t_ns == 42
    @test e.kind === :line
    @test e.text == "é└ x"
    @test [e.text[r] for (r, _) in e.spans] == ["é", "└ x"]
end

@testset "lines on screen are not entries until the session ends" begin
    log = LL.RankLog(0)
    term = LL.begin_session!(log, 1, 24, 80)
    LL.feed_output!(log, term, bytes_of("julia> 1+1"), 2)
    @test length(log) == 0
    @test LL.live_row(log).text == "julia> 1+1"
    LL.feed_output!(log, term, bytes_of("\r\n2\r\njulia> "), 3)
    @test length(log) == 0
    @test LL.live_row(log).text == "julia>"
    LL.end_session!(log, term, 4)
    @test entry_texts(log) == [(:line, 1, "julia> 1+1"), (:line, 1, "2"), (:line, 1, "julia>")]
    @test LL.live_row(log) === nothing
end

@testset "lines are appended as they scroll off the screen" begin
    log = LL.RankLog(0)
    term = LL.begin_session!(log, 1, 2, 80)
    LL.feed_output!(log, term, bytes_of("a\r\nb\r\n"), 2)
    @test entry_texts(log) == [(:line, 1, "a")]
    @test LL.live_row(log) === nothing
    LL.feed_output!(log, term, bytes_of("c"), 3)
    @test entry_texts(log) == [(:line, 1, "a")]
    @test LL.live_row(log).text == "c"
    LL.end_session!(log, term, 4)
    @test entry_texts(log) == [(:line, 1, "a"), (:line, 1, "b"), (:line, 1, "c")]
end

@testset "restart flushes a row with text and appends a restart entry" begin
    log = LL.RankLog(0)
    t1 = LL.begin_session!(log, 1, 24, 80)
    LL.feed_output!(log, t1, bytes_of("1+1\r\n2\r\njulia> "), 2)
    LL.end_session!(log, t1, 5)
    t2 = LL.begin_session!(log, 6, 24, 80)
    LL.feed_output!(log, t2, bytes_of("x\r\n"), 7)
    LL.end_session!(log, t2, 8)
    @test entry_texts(log) == [(:line, 1, "1+1"), (:line, 1, "2"), (:line, 1, "julia>"),
        (:restart, 2, ""), (:line, 2, "x")]
    restart = LL.window(log, 4:4)[1]
    @test restart.t_ns == 6
    @test isempty(restart.spans)
end

@testset "restart after a blank row does not flush" begin
    log = LL.RankLog(0)
    t1 = LL.begin_session!(log, 1, 24, 80)
    LL.feed_output!(log, t1, bytes_of("a\r\n"), 2)
    LL.end_session!(log, t1, 3)
    t2 = LL.begin_session!(log, 4, 24, 80)
    LL.end_session!(log, t2, 5)
    @test entry_texts(log) == [(:line, 1, "a"), (:restart, 2, "")]
end

@testset "session reports hold counts for each ended session" begin
    log = LL.RankLog(0)
    t1 = LL.begin_session!(log, 1, 24, 80)
    LL.feed_output!(log, t1, bytes_of("\e[7n"), 2)
    LL.end_session!(log, t1, 3)
    t2 = LL.begin_session!(log, 4, 24, 80)
    LL.feed_output!(log, t2, bytes_of("line\r\e[2K\e[1Gedit"), 5)
    LL.end_session!(log, t2, 6)
    reports = LL.session_reports(log)
    @test [r.session for r in reports] == [1, 2]
    @test reports[1].ignored == Dict("CSI n" => 1)
    @test reports[2].rewrites == 0
    @test reports[2].discarded == 0
end

@testset "session misuse fails with a message" begin
    log = LL.RankLog(0)
    t1 = LL.begin_session!(log, 1, 24, 80)
    @test_throws "still open" LL.begin_session!(log, 2, 24, 80)
    @test_throws "still open" LL.close_log!(log)
    @test_throws "not the open session" LL.feed_output!(log, VTP.Terminal(2, 2), bytes_of("x"), 3)
    @test_throws "not the open session" LL.end_session!(log, VTP.Terminal(2, 2), 3)
    LL.end_session!(log, t1, 4)
    LL.close_log!(log)
    @test_throws "is closed" LL.begin_session!(log, 5, 24, 80)
end

@testset "window range is checked" begin
    log = LL.RankLog(0)
    t1 = LL.begin_session!(log, 1, 24, 80)
    LL.feed_output!(log, t1, bytes_of("a\r\nb\r\n"), 2)
    LL.end_session!(log, t1, 3)
    @test LL.window(log, 3:2) == LL.LogEntry[]
    @test_throws "outside the log" LL.window(log, 1:3)
    @test_throws "outside the log" LL.window(log, 0:1)
end

@testset "await_length waits for appends and for close" begin
    log = LL.RankLog(0)
    t1 = LL.begin_session!(log, 1, 24, 80)
    waiter = @async LL.await_length(log, 0)
    sleep(0.05)
    @test !istaskdone(waiter)
    LL.feed_output!(log, t1, bytes_of("a\r\n"), 2)
    sleep(0.05)
    @test !istaskdone(waiter)
    LL.end_session!(log, t1, 3)
    @test fetch(waiter) == 1
    closer = @async LL.await_length(log, 1)
    LL.close_log!(log)
    @test fetch(closer) == 1
end

@testset "log view follows the bottom until scrolled away" begin
    log = LL.RankLog(0)
    # One row, so that each line is appended as soon as it is written.
    t1 = LL.begin_session!(log, 1, 1, 80)
    LL.feed_output!(log, t1, bytes_of(join(["l$i\r\n" for i in 1:10])), 2)
    view = LL.LogView(log, 3)
    @test view.follow
    @test [e.text for e in LL.visible(view)] == ["l8", "l9", "l10"]

    LL.feed_output!(log, t1, bytes_of("l11\r\n"), 3)
    LL.on_append!(view)
    @test [e.text for e in LL.visible(view)] == ["l9", "l10", "l11"]

    LL.scroll_to!(view, 1)
    @test !view.follow
    @test [e.text for e in LL.visible(view)] == ["l1", "l2", "l3"]

    LL.feed_output!(log, t1, bytes_of("l12\r\n"), 4)
    LL.on_append!(view)
    @test view.top == 1
    @test [e.text for e in LL.visible(view)] == ["l1", "l2", "l3"]

    LL.scroll_to!(view, 100)
    @test view.top == 10
    @test view.follow
    LL.follow_bottom!(view)
    @test view.top == 10
    @test_throws "must be at least 1" LL.LogView(log, 0)
end

@testset "reader on another thread sees a consistent log" begin
    fixture_chunks = load_chunks("f_long_output")
    # The log after the session ends, including the lines on screen when it ends.
    expected = [rstrip(L.text) for L in replay_fixture("f_long_output").lines]
    target = length(expected)
    log = LL.RankLog(1)
    writer = Threads.@spawn begin
        term = LL.begin_session!(log, 0, 24, 80)
        for (t_ns, bytes) in fixture_chunks
            LL.feed_output!(log, term, bytes, t_ns)
        end
        LL.end_session!(log, term, 0)
        LL.close_log!(log)
        length(log)
    end
    reader = Threads.@spawn begin
        view = LL.LogView(log, 5)
        seen = 0
        lengths = Int[]
        while seen < target
            seen = LL.await_length(log, seen)
            LL.on_append!(view)
            push!(lengths, seen)
        end
        (lengths, [rstrip(e.text) for e in LL.visible(view)])
    end
    total = fetch(writer)
    lengths, last_visible = fetch(reader)
    @test total == target
    @test issorted(lengths)
    @test last(lengths) == total
    @test [rstrip(e.text) for e in LL.window(log, 1:total)] == expected
    @test last_visible == expected[(end - 4):end]
end

@testset "session reports hold the queries answered" begin
    log = LL.RankLog(0)
    term = LL.begin_session!(log, 1, 24, 80)
    LL.feed_output!(log, term, bytes_of("ab\e[6n\e[5n"), 2)
    # Replies are left for the caller to write; feeding does not take them.
    @test VTP.take_replies!(term) == bytes_of("\e[1;3R\e[0n")
    LL.end_session!(log, term, 3)
    @test LL.session_reports(log)[1].answered == Dict("CSI 6 n" => 1, "CSI 5 n" => 1)
    @test isempty(LL.session_reports(log)[1].ignored)
end
