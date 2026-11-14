const VTE = MPIEnsemble.VTParse

# Feeds the parser the output received on `ch` until `done(term)` holds, failing after `timeout`
# seconds with the current screen in the message.
function feed_until!(term, ch, done, what::AbstractString; timeout::Real = 60)
    deadline = time() + timeout
    while true
        while isready(ch)
            VTE.feed!(term, take!(ch))
        end
        done(term) && return nothing
        time() > deadline && error("timed out waiting for $what; screen: $(VTE.screen_lines(term))")
        sleep(0.02)
    end
end

@testset "REPL: an edit to an earlier line of multi-line input shows on screen" begin
    cmd = MPIEnsemble.ReplSession.julia_repl_command()
    s = MPIEnsemble.Pty.spawn(cmd; rows = 24, cols = 80)
    ch = Channel{Vector{UInt8}}(Inf)
    reader = @async begin
        try
            while true
                b = readavailable(s)
                isempty(b) && break
                put!(ch, b)
            end
        catch err
            # Reading a pseudo-terminal after its child exits fails with EIO.
            err isa Base.IOError || rethrow()
        finally
            close(ch)
        end
    end
    term = VTE.Terminal(24, 80)
    try
        feed_until!(term, ch, t -> any(l -> occursin("julia>", l), VTE.screen_lines(t)), "the prompt")
        write(s, "function f(x)\n")
        feed_until!(term, ch, t -> VTE.cursor_pos(t)[1] == 2, "the second line of input")
        write(s, "x+1\n")
        feed_until!(term, ch, t -> VTE.cursor_pos(t)[1] == 3, "the third line of input")
        write(s, "end")
        feed_until!(term, ch, t -> strip(VTE.screen_lines(t)[3]) == "end", "end on the third line")
        feed_until!(term, ch, t -> MPIEnsemble.Pty.is_raw(s), "the REPL to read keystrokes")
        write(s, "\e[A\e[A")
        feed_until!(term, ch, t -> VTE.cursor_pos(t)[1] == 1, "the cursor on the first line")
        write(s, "\e[D\e[D99")
        feed_until!(term, ch, t -> occursin("f99unction", VTE.screen_lines(t)[1]), "the edit on the first line")
        @test occursin("f99unction", VTE.screen_lines(term)[1])
        @test VTE.counters(term).rewrites == 0
        @test isempty(VTE.take_lines!(term))
    finally
        close(s)
        wait(reader)
    end
end
