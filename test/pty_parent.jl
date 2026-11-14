# Run as a subprocess by test_pty.jl. It starts one Pty child, prints the child's pid on the first
# line of stdout, and then waits to be killed. With the argument `error`, it throws an uncaught
# error a moment after starting the child instead. With `thread`, the child is started from a task
# on another thread.
#
# Arguments: <child: julia|sleep> <spawn: main|thread> [error]
include(joinpath(@__DIR__, "..", "src", "Pty.jl"))

mode, where = ARGS[1], ARGS[2]
cmd = mode == "julia" ? Cmd(vcat(Base.julia_cmd().exec, ["-q", "--startup-file=no"])) : Cmd(["sleep", "300"])
session = where == "thread" ? fetch(Threads.@spawn(Pty.spawn(cmd))) : Pty.spawn(cmd)
println(getpid(session.process))
flush(stdout)
if length(ARGS) >= 3 && ARGS[3] == "error"
    sleep(1)
    error("pty_parent.jl: uncaught error after spawning the child")
end
sleep(600)
