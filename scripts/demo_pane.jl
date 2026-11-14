# Open the single-REPL window and type a short demo into the REPL.
#
# Run from the package directory, on a machine with a display:
#     julia --project scripts/demo_pane.jl
#
# The input shows: the terminal size, a truecolour line, a line with three coloured runs,
# 20000 numbered lines (to test scrolling) and a final `1+1` at the prompt.
using MPIEnsemble

const DEMO_LINES = [
    "displaysize(stdout)",
    "println(\"\\e[38;2;255;128;0mtruecolour orange line\\e[0m\")",
    "printstyled(\"red \"; color = :red); printstyled(\"green \"; color = :green); printstyled(\"blue\\n\"; color = :blue)",
    "for i in 1:20000 println(\"line \", i) end",
    "1+1",
]

# Each line is sent as a bracketed paste, so that the REPL does not add closing brackets or quotes
# as the characters arrive, and then submitted with a carriage return.
const DEMO_INPUT = join(("\e[200~" * line * "\e[201~\r" for line in DEMO_LINES))

run_single_repl(startup_input = DEMO_INPUT)
