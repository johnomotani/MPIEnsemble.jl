# Open the single-REPL window and print 1000000 numbered lines in the REPL, to test scrolling and memory
# with a long output. The REPL prints how long the loop took.
#
# Run from the package directory, on a machine with a display:
#     julia --project scripts/demo_million.jl
#
# While the output is printed, the process reports its resident memory (VmRSS) every five seconds.
using MPIEnsemble

const DEMO_LINES = [
    "t0 = time()",
    "for i in 1:1000000 println(\"output line \", i) end",
    "println(\"printed 1000000 lines in \", round(time() - t0; digits = 2), \" s\")",
]

# Each line is sent as a bracketed paste, so that the REPL does not add closing brackets or quotes
# as the characters arrive, and then submitted with a carriage return.
const DEMO_INPUT = join(("\e[200~" * line * "\e[201~\r" for line in DEMO_LINES))

function report_rss(every::Real)
    while true
        sleep(every)
        lines = split(read("/proc/self/status", String), '\n')
        for line in filter(startswith("VmRSS"), lines)
            println("VmRSS of this process: ", strip(split(line, ':')[2]))
        end
        flush(stdout)
    end
end

@async report_rss(5)
run_single_repl(startup_input = DEMO_INPUT)
