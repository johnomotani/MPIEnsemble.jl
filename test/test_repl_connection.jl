# Tests for a REPL over a rank's launcher connection (`Repl(log, connection; rows, cols)`). The ranks are
# started by the fake launcher (test/mpi/fake_mpiexec.sh). Most tests use the real wrapper, so each rank
# runs a julia REPL; the failure and exit-frame tests use the fake wrapper (test/mpi/fake_wrapper.py) and
# need no julia. These need sh and setsid, and no display; the wrapper runs with the Python from Python_jll.

const RC_RS = MPIEnsemble.ReplSession
const RC_LL = MPIEnsemble.LineLog
const RC_VT = MPIEnsemble.VTParse
const RC_MPI = MPIEnsemble.MpiLauncher

const RC_FAKE_LAUNCHER = Cmd(["sh", joinpath(@__DIR__, "mpi", "fake_mpiexec.sh")])
const RC_FAKE_WRAPPER = joinpath(@__DIR__, "mpi", "fake_wrapper.py")
const RC_REAL_WRAPPER = joinpath(@__DIR__, "..", "src", "wrapper", "wrapper.py")
# Seconds allowed for ranks with a julia REPL to start and answer.
const RC_TIMEOUT = 180
const RC_ROWS = 24
const RC_COLS = 80

# The ranks need XDG_RUNTIME_DIR for their socket. The tests use the session's directory, or the
# temporary directory where there is none.
rc_with_runtime(f) = withenv(f, "XDG_RUNTIME_DIR" => get(ENV, "XDG_RUNTIME_DIR", tempdir()))

# Launch `nranks` ranks under the fake launcher, and a REPL over each rank's connection, started at
# RC_ROWS by RC_COLS. The caller shuts the REPLs and the job down.
function rc_start_job(nranks::Integer; wrapper = RC_REAL_WRAPPER)
    job = RC_MPI.launch(nranks, RC_ROWS, RC_COLS; launcher = RC_FAKE_LAUNCHER, timeout = RC_TIMEOUT,
        wrapper)
    repls = [RC_RS.Repl(RC_LL.RankLog(conn.rank), conn; rows = RC_ROWS, cols = RC_COLS) for conn in job.ranks]
    for repl in repls
        RC_RS.start!(repl, RC_ROWS, RC_COLS)
    end
    return job, repls
end

# Pump every REPL until `pred()` holds. A REPL that fails throws its error, as the window does.
# Fails after `timeout` seconds, with the screen of each REPL, so that a hang shows up as an error.
function rc_wait_until(pred, repls...; timeout::Real = RC_TIMEOUT)
    deadline = time() + timeout
    while !pred()
        if time() >= deadline
            screens = join(("rank $(repl.log.rank) screen:\n" * join(RC_VT.screen_lines(repl.term), "\n")
                for repl in repls), "\n")
            error("timed out after $timeout s\n$screens")
        end
        foreach(RC_RS.pump!, repls)
        sleep(0.002)
    end
    return nothing
end

rc_log_text(repl) = join((e.text for e in RC_LL.window(repl.log, 1:length(repl.log))), "\n")
rc_log_has_line(repl, line::AbstractString) = any(e -> strip(e.text) == line, RC_LL.window(repl.log, 1:length(repl.log)))
rc_on_screen(repl, text::AbstractString) = any(l -> occursin(text, l), RC_VT.screen_lines(repl.term))

# Type `code` into `repl` as a line.
rc_type(repl, code::AbstractString) = RC_RS.send!(repl, Vector{UInt8}(codeunits(code * "\r")))

# Type `code`, then enough newlines to scroll its output off the screen. A line reaches the log when it
# leaves the screen, so the output of `code` is in the log once this has been read.
rc_type_scrolled(repl, code::AbstractString) = rc_type(repl, code * "; foreach(_ -> println(), 1:$(2 * RC_ROWS))")

# Stop the REPLs, then the job, whatever state they are in. A REPL whose rank has failed throws its error
# again from `shutdown!`, which is expected only in the failure test.
function rc_close(job, repls...; expect_error::Bool = false)
    try
        foreach(RC_RS.shutdown!, repls)
    catch e
        expect_error && e isa ErrorException || rethrow()
    finally
        RC_MPI.shutdown!(job; exit_timeout = 10)
    end
    return nothing
end

@testset "a REPL over two ranks' launcher connections" begin
    rc_with_runtime() do
        job, repls = rc_start_job(2)
        r0, r1 = repls
        try
            @testset "both julia prompts appear" begin
                rc_wait_until(() -> rc_on_screen(r0, "julia>") && rc_on_screen(r1, "julia>"), r0, r1)
                @test RC_RS.is_started(r0) && !RC_RS.has_ended(r0)
            end

            @testset "the launch size reaches the rank's terminal, with no extra RESIZE" begin
                rc_type_scrolled(r0, "println(displaysize(stdout))")
                rc_wait_until(() -> rc_log_has_line(r0, "($RC_ROWS, $RC_COLS)"), r0, r1)
            end

            @testset "output of println appears in the log of each rank" begin
                rc_type_scrolled(r0, "println(\"rank says hi\")")
                rc_type_scrolled(r1, "println(\"rank says hi\")")
                rc_wait_until(() -> rc_log_has_line(r0, "rank says hi") && rc_log_has_line(r1, "rank says hi"), r0, r1)
            end

            @testset "input typed in one rank does not reach the other" begin
                rc_type_scrolled(r0, "println(\"marker \", \"rank zero only\")")
                rc_wait_until(() -> rc_log_has_line(r0, "marker rank zero only"), r0, r1)
                @test !occursin("rank zero only", rc_log_text(r1))
            end

            @testset "multi-byte output arrives intact, whatever the frame boundaries" begin
                rc_type_scrolled(r1, "println(repeat(\"\\u00e9\", 5000))")
                rc_wait_until(() -> count('\u00e9', rc_log_text(r1)) == 5000, r0, r1)
                @test !occursin('\ufffd', rc_log_text(r1))
            end

            @testset "a resize sends a RESIZE frame and the rank's terminal takes the new size" begin
                RC_RS.set_size!(r0, 30, 100)
                rc_type_scrolled(r0, "println(displaysize(stdout))")
                rc_wait_until(() -> rc_log_has_line(r0, "(30, 100)"), r0, r1)
                @test r0.rows == 30 && r0.cols == 100
            end

            @testset "interrupt stops a sleep and the prompt returns" begin
                rc_type(r0, "sleep(30)")
                rc_wait_until(() -> rc_log_has_line(r0, "sleep(30)") || rc_on_screen(r0, "sleep(30)"), r0, r1)
                # Sleep briefly, so that julia is in sleep(30) rather than still reading the line.
                started = time()
                rc_wait_until(() -> time() - started > 2, r0, r1)
                interrupted = time()
                @test RC_RS.interrupt!(r0)
                rc_type_scrolled(r0, "println(\"after interrupt\")")
                rc_wait_until(() -> rc_log_has_line(r0, "after interrupt"), r0, r1; timeout = 25)
                @test time() - interrupted < 25
                @test occursin("InterruptException", rc_log_text(r0))
            end

            @testset "exit() ends a rank's REPL with exit status 0, and the other rank still answers" begin
                rc_type(r1, "exit()")
                rc_wait_until(() -> RC_RS.has_ended(r1), r0, r1)
                @test r1.exit == RC_RS.ExitInfo(0, 0)
                @test RC_RS.describe_exit(r1.exit) == "Julia exited with code 0"
                @test !RC_RS.send!(r1, Vector{UInt8}(codeunits("1\r")))
                @test !RC_RS.interrupt!(r1)

                @test !RC_RS.has_ended(r0)
                rc_type_scrolled(r0, "println(\"still answering\")")
                rc_wait_until(() -> rc_log_has_line(r0, "still answering"), r0, r1)
            end

            @testset "restart! throws, for a rank that has ended and one that is running" begin
                @test_throws "cannot be restarted" RC_RS.restart!(r1)
                @test_throws "cannot be restarted" RC_RS.restart!(r0)
            end
        finally
            rc_close(job, repls...)
        end
        @test process_exited(job.process)
        @test !isdir(job.directory)
    end
end

@testset "a rank's connection that closes without EXIT is an error in the REPL" begin
    rc_with_runtime() do
        withenv("FAKE_WRAPPER_MODE" => "no_exit") do
            job, (repl,) = rc_start_job(1; wrapper = RC_FAKE_WRAPPER)
            failure = nothing
            try
                try
                    rc_wait_until(() -> RC_RS.has_ended(repl), repl)
                catch e
                    failure = e
                end
                @test failure isa ErrorException
                @test failure isa ErrorException && occursin("without an EXIT frame", failure.msg)
                @test !RC_RS.has_ended(repl)
            finally
                rc_close(job, repl; expect_error = true)
            end
        end
    end
end

@testset "an EXIT frame gives the exit status of the REPL" begin
    rc_with_runtime() do
        withenv("FAKE_WRAPPER_MODE" => "exit_frame") do
            job, (repl,) = rc_start_job(1; wrapper = RC_FAKE_WRAPPER)
            try
                rc_wait_until(() -> RC_RS.has_ended(repl), repl)
                @test repl.exit == RC_RS.ExitInfo(7, 0)
                @test RC_RS.describe_exit(repl.exit) == "Julia exited with code 7"
                @test occursin("bye", rc_log_text(repl))
                @test_throws "cannot be restarted" RC_RS.restart!(repl)
            finally
                rc_close(job, repl)
            end
        end
    end
end
