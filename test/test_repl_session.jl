const RS = MPIEnsemble.ReplSession
const RS_LL = MPIEnsemble.LineLog
const RS_VT = MPIEnsemble.VTParse

rs_entries(repl) = [(e.kind, e.session, e.text) for e in RS_LL.window(repl.log, 1:length(repl.log))]

# Pump the session until `done(repl)` holds. Fails on a deadline, so that a session that never ends
# shows up as an error rather than a hang.
function rs_pump_until(done, repl; timeout::Real = 30)
    deadline = time() + timeout
    while !done(repl)
        time() < deadline || error("timed out after $timeout s; screen: $(last(join(RS_VT.screen_lines(repl.term), "\n"), 300))")
        RS.pump!(repl)
        sleep(0.002)
    end
    return repl
end

rs_ended(repl) = RS.has_ended(repl)
rs_on_screen(pat) = repl -> any(l -> occursin(pat, l), RS_VT.screen_lines(repl.term))

# A REPL whose child is `command`, started at 24 by 80.
function rs_start(command::Cmd; rows::Integer = 24, cols::Integer = 80)
    repl = RS.Repl(RS_LL.RankLog(0), command)
    RS.start!(repl, rows, cols)
    return repl
end

rs_shell(script::AbstractString) = Cmd(["sh", "-c", script])

# Close the REPL's session and wait until the child is gone, whatever state the session is in.
function rs_cleanup(repl)
    RS.shutdown!(repl)
    return nothing
end

@testset "exit status of a process that exited with a code" begin
    repl = rs_start(rs_shell("exit 7"))
    try
        rs_pump_until(rs_ended, repl)
        @test repl.exit == RS.ExitInfo(7, 0)
        @test RS.describe_exit(repl.exit) == "Julia exited with code 7"
    finally
        rs_cleanup(repl)
    end
end

@testset "exit status of a process killed by SIGKILL" begin
    repl = rs_start(rs_shell("kill -9 \$\$"))
    try
        rs_pump_until(rs_ended, repl)
        @test repl.exit == RS.ExitInfo(0, 9)
        @test RS.describe_exit(repl.exit) == "Julia was killed by signal 9 (SIGKILL)"
    finally
        rs_cleanup(repl)
    end
end

@testset "describe_exit names known signals and gives the number of others" begin
    @test RS.describe_exit(RS.ExitInfo(0, 15)) == "Julia was killed by signal 15 (SIGTERM)"
    @test RS.describe_exit(RS.ExitInfo(0, 60)) == "Julia was killed by signal 60"
    @test RS.describe_exit(RS.ExitInfo(0, 0)) == "Julia exited with code 0"
end

@testset "exit_info throws for a process that is still running" begin
    s = MPIEnsemble.Pty.spawn(Cmd(["sleep", "30"]))
    try
        @test_throws ErrorException RS.exit_info(s.process)
    finally
        close(s; timeout = 1)
    end
end

@testset "Ctrl+D at the Julia prompt ends the REPL with code 0" begin
    repl = rs_start(RS.julia_repl_command())
    try
        rs_pump_until(rs_on_screen("julia>"), repl; timeout = 120)
        @test RS.send!(repl, Vector{UInt8}("\x04"))
        rs_pump_until(rs_ended, repl; timeout = 60)
        @test repl.exit == RS.ExitInfo(0, 0)
        @test !RS.send!(repl, Vector{UInt8}("1+1\n"))
    finally
        rs_cleanup(repl)
    end
end

@testset "a crash with unread output keeps the tail in the log" begin
    repl = rs_start(rs_shell("seq 1 5000; kill -9 \$\$"))
    try
        rs_pump_until(rs_ended, repl)
        @test repl.exit == RS.ExitInfo(0, 9)
        lines = [e.text for e in RS_LL.window(repl.log, 1:length(repl.log)) if e.kind === :line]
        @test lines == string.(1:5000)
    finally
        rs_cleanup(repl)
    end
end

@testset "output queued when the child exits is fed before the end" begin
    # Few enough reads for the queue to hold all of the output, so the child can exit before it is read.
    repl = rs_start(rs_shell("seq 1 100; exit 0"))
    try
        deadline = time() + 30
        while !process_exited(repl.session.process)
            time() < deadline || error("the child did not exit")
            sleep(0.01)
        end
        @test !rs_ended(repl)
        rs_pump_until(rs_ended, repl)
        lines = [e.text for e in RS_LL.window(repl.log, 1:length(repl.log)) if e.kind === :line]
        @test lines == string.(1:100)
    finally
        rs_cleanup(repl)
    end
end

@testset "restart after a burst that fills the queue does not deadlock" begin
    # About 2 MB: the reader blocks on a full queue, and the child blocks on a full pseudo-terminal,
    # until the queue is pumped.
    repl = rs_start(rs_shell("seq 1 300000; exit 0"))
    try
        sleep(0.5)
        rs_pump_until(rs_ended, repl)
        @test repl.exit == RS.ExitInfo(0, 0)
        RS.restart!(repl)
        rs_pump_until(rs_ended, repl)
        @test repl.exit == RS.ExitInfo(0, 0)
        lines = [e.text for e in RS_LL.window(repl.log, 1:length(repl.log)) if e.kind === :line]
        @test lines == vcat(string.(1:300000), string.(1:300000))
        @test count(e -> e.kind === :restart, RS_LL.window(repl.log, 1:length(repl.log))) == 1
    finally
        rs_cleanup(repl)
    end
end

@testset "restart gives the old output, the restart entry, then the new output, in order" begin
    repl = rs_start(rs_shell("echo old-output; exit 0"))
    try
        rs_pump_until(rs_ended, repl)
        RS.restart!(repl)
        @test !rs_ended(repl)
        rs_pump_until(rs_ended, repl)
        @test rs_entries(repl) == [(:line, 1, "old-output"),
            (:restart, 2, "Julia exited with code 0"), (:line, 2, "old-output")]
        @test RS.describe_exit(repl.exit) == "Julia exited with code 0"
    finally
        rs_cleanup(repl)
    end
end

@testset "restart entry text describes a signal death" begin
    repl = rs_start(rs_shell("echo before; kill -9 \$\$"))
    try
        rs_pump_until(rs_ended, repl)
        RS.restart!(repl)
        rs_pump_until(rs_ended, repl)
        restart = RS_LL.window(repl.log, 2:2)[1]
        @test restart.kind === :restart
        @test restart.text == "Julia was killed by signal 9 (SIGKILL)"
    finally
        rs_cleanup(repl)
    end
end

@testset "restart is refused while the REPL is running" begin
    repl = rs_start(rs_shell("sleep 30"))
    try
        @test_throws ErrorException RS.restart!(repl)
    finally
        rs_cleanup(repl)
    end
end

@testset "ten restarts leave no processes and no descriptors" begin
    # Each session lives briefly, so that its pid is read while it runs.
    repl = rs_start(rs_shell("echo n; sleep 0.2"))
    pids = Int[]
    try
        rs_pump_until(rs_ended, repl)
        # One restart before counting, so that lazily allocated descriptors are not counted.
        RS.restart!(repl)
        rs_pump_until(rs_ended, repl)
        before = fd_count()
        for _ in 1:10
            RS.restart!(repl)
            push!(pids, getpid(repl.session.process))
            rs_pump_until(rs_ended, repl)
        end
        @test fd_count() == before
        @test all(!ispath("/proc/$pid") for pid in pids)
        @test count(e -> e.kind === :restart, RS_LL.window(repl.log, 1:length(repl.log))) == 11
    finally
        rs_cleanup(repl)
    end
end

@testset "typing into a finished session is ignored" begin
    repl = rs_start(rs_shell("exit 0"))
    try
        rs_pump_until(rs_ended, repl)
        @test !RS.send!(repl, Vector{UInt8}("ignored\n"))
        RS.pump!(repl)
        @test rs_entries(repl) == []
    finally
        rs_cleanup(repl)
    end
end

@testset "a restarted Julia REPL works after Ctrl+D" begin
    repl = rs_start(RS.julia_repl_command())
    try
        rs_pump_until(rs_on_screen("julia>"), repl; timeout = 120)
        RS.send!(repl, Vector{UInt8}("\x04"))
        rs_pump_until(rs_ended, repl; timeout = 60)
        RS.restart!(repl)
        rs_pump_until(rs_on_screen("julia>"), repl; timeout = 120)
        RS.send!(repl, Vector{UInt8}("1+1\n"))
        rs_pump_until(rs_on_screen(r"^2$"), repl; timeout = 60)
        @test any(e -> e.kind === :restart && e.session == 2, RS_LL.window(repl.log, 1:length(repl.log)))
    finally
        rs_cleanup(repl)
    end
end

@testset "shutdown of a running session ends the child and completes the log" begin
    repl = rs_start(rs_shell("sleep 60"))
    pid = getpid(repl.session.process)
    t0 = time()
    RS.shutdown!(repl)
    @test time() - t0 < 30
    @test !ispath("/proc/$pid")
    @test RS.has_ended(repl)
    @test length(RS_LL.session_reports(repl.log)) == 1
end

@testset "shutdown of an ended session does not end the log twice" begin
    repl = rs_start(rs_shell("exit 0"))
    rs_pump_until(rs_ended, repl)
    RS.shutdown!(repl)
    @test length(RS_LL.session_reports(repl.log)) == 1
end

@testset "restart separator shows how the previous session ended" begin
    PM = MPIEnsemble.PaneModel
    log = RS_LL.RankLog(0)
    t1 = RS_LL.begin_session!(log, 1, 3, 20)
    RS_LL.end_session!(log, t1, 2)
    t2 = RS_LL.begin_session!(log, 3, 3, 20; previous = "Julia exited with code 0")
    RS_LL.end_session!(log, t2, 4)
    restart = RS_LL.window(log, 1:1)[1]
    @test occursin("session&nbsp;2&nbsp;started;&nbsp;previous&nbsp;Julia&nbsp;exited&nbsp;with&nbsp;code&nbsp;0", PM.entry_html(restart))
    @test_throws ErrorException RS_LL.begin_session!(RS_LL.RankLog(0), 1, 3, 20; previous = "x")
end

# Gui.jl is loaded only when a window is opened, so its syntax is checked here.
@testset "Gui.jl parses" begin
    @test Meta.parseall(read(joinpath(pkgdir(MPIEnsemble), "src", "Gui.jl"), String)) isa Expr
end
