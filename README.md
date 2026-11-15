# MPIEnsemble.jl

A window of per-rank terminal panes for interactive MPI work in Julia. Linux
only; requires Julia 1.13 or later.

This package is under development. The window shows Julia REPLs in tabs, and, with a rank count, an MPI tab
with one REPL per MPI rank.

## Usage

```
julia --project -m MPIEnsemble [RANKS]
```

The optional argument `RANKS` is the number of MPI ranks, a positive integer. Without it, the window shows a
dialog that asks for the number; OK records it, and Cancel closes the window, which then ends the program
without error.

With a number, the window opens an MPI tab after the first REPL tab and starts that many ranks under the
`mpiexec` given by MPIPreferences.jl (see MPI builds below). The tab says "Starting N MPI ranks…" until the
job has started, and this does not block the window, so the REPL tabs work meanwhile. Then the tab shows one
REPL pane per rank, in rank order, in a grid with ceil(sqrt(N)) columns and cells of equal size. Each pane shows
its rank number in its top-right corner. Each rank's REPL runs in its own Julia process. The keys, paste and mouse
selection work in a rank pane as they do in a REPL pane, and the pane resizes with the window. Clicking a pane gives it the keyboard focus: its border is
bright, and the other panes have dim borders. Keys and paste go only to the focused rank.

If the ranks do not start, for example because the launcher is not found or the ranks do not connect within
60 seconds, the MPI tab shows the error and the error is also printed to standard error. The REPL tabs keep
working. When a rank's Julia exits, its pane shows the exit code, and says that restarting needs the whole MPI
job to restart; a rank pane has no Restart button. If a rank's connection closes without its exit report,
the error is shown in that rank's pane, and the other ranks keep working.

Closing the MPI tab ends the job, and the MPI tab is not opened again: start the window again to launch the
ranks again. Closing the window also ends the job. Either way, the wrapper processes and the launcher stop.

The launcher that starts the ranks, `MpiLauncher.jl`, can also be used on its own.

The following are not implemented yet: input broadcast to all ranks, and restarting or killing a single rank.

The window needs a display (on Linux, for example, an X server or Wayland session).

The window has a tab bar across its top, with one tab for each REPL, titled "Julia 1", "Julia 2" and so on
in the order they were opened. The MPI tab, when there is one, is titled "MPI" and comes after the first REPL
tab. Clicking a tab shows its REPL, and the "+" button at the end of the bar opens
another REPL tab and shows it. Each tab has its own REPL, output, scrollback, selection and restart prompt.
A tab's close button, or a middle-click on the tab, closes it and ends its REPL; the tab to its right is then
shown, or the tab to its left if there is none. Closing the last tab closes the window, and so does closing
the window itself, which ends every REPL. Tabs keep running while they are hidden. Tabs have no keyboard
shortcuts yet, so keys such as Ctrl+Shift+T still go to the REPL as before.

Keyboard input goes to the REPL: text, Return,
Tab, arrows, Home, End, Backspace, Delete, PageUp, PageDown, function keys, and Ctrl and Alt
combinations. Ctrl+Shift+V pastes the clipboard. Pasted text uses bracketed paste when the REPL has
enabled it. Ctrl+D at an empty prompt ends the REPL. A prompt at the bottom of the pane then says how it
ended, such as "Julia exited with code 0" or "Julia was killed by signal 9 (SIGKILL)", and offers a
Restart button; pressing Return also restarts. Restarting starts a new REPL in the same pane, after a
separator line, and the earlier output stays above it. The output stays selectable and scrollable while
the prompt is shown, and other keys are ignored until the REPL restarts. Scrolling up with the mouse
wheel stops the view following new output; typing returns it to the bottom.

Programs in the window can ask the terminal for its cursor position, its screen size or its device
attributes, and the window answers, so a program that waits for the reply does not stall. Those replies
are not typed input: they do not scroll the pane or clear a selection.

Dragging with the left mouse button selects text in the pane, and double-clicking or triple-clicking
selects a word or a line. The selection is highlighted and its text becomes the system primary selection,
so that middle-click pastes it elsewhere; a click clears the highlight, and a key press clears it too,
except the jump keys below, which scroll and keep the selection.
With a selection, Shift-clicking or Shift-dragging moves its active end, keeping the other end where it
was, so the selection can be extended in either direction. Selecting does not send anything to the REPL.

The pane keeps all the output of the session, with no line limit, so its memory use grows with the
amount of output. The scrollbar and page jumps treat the view as at most 140 rows, so a pane taller than that moves by 139
rows per page and has a smaller thumb than its height suggests. A scrollbar at the right of the pane shows where the view is in all of it. The thumb
is sized and placed by fraction of the whole output, so dragging it reaches any line, whatever the
length. A click on the track above or below the thumb moves the view by one page. Shift+PageUp and
Shift+PageDown also move the view by one page, which is one row less than the number visible. Ctrl+Home
goes to the top of the output, and Ctrl+End goes to the bottom and resumes following new output. These
four keys are handled by the window and are not sent to the REPL. Typing any other key returns the view
to the bottom, as before.

By default the window's pseudo-terminal has as many rows as the pane shows. A multi-line input taller
than the pane then scrolls off the top of the REPL's screen, and the lines that scroll off appear in the
pane twice when the input is edited. Setting the environment variable `MPIENSEMBLE_TALL_PTY_ROWS` to a
positive integer, for example

```
MPIENSEMBLE_TALL_PTY_ROWS=200 julia --project -m MPIEnsemble
```

gives the pseudo-terminal that many rows, or the pane's rows when there are more. The pane then shows a
viewport onto the REPL's screen and the output above it, so an input of up to that many lines can be
edited from its first line. The pane follows the cursor row when the cursor is above the end of the
output. Window resizes change only the columns, unless the pane is taller than the setting. The side
effect is that the REPL's `displaysize` reports the tall row count instead of the pane height, so
output is not truncated to the pane height, and programs that use the terminal height see the tall
count. An invalid value, such as `0` or `abc`, is an error when the window is opened.

## MPI builds

The package installs the MPI builds MPICH_jll, OpenMPI_jll, MPItrampoline_jll and MPIABI_jll, which are
the MPI binaries that the launcher can use on Linux. MPIPreferences.jl chooses which one is used, and the
default is MPICH_jll. Each of these packages provides its MPI only when it is the one MPIPreferences.jl
selects. To use another, run `MPIPreferences.use_jll_binary("OpenMPI_jll")` (or the name of another build)
and restart Julia. To use an MPI installed on the system, run `MPIPreferences.use_system_binary()` and restart
Julia; its launcher is `mpiexec` on the PATH unless another command is given with the `mpiexec` keyword.

## Wrapper

`src/wrapper/wrapper.py` is the per-rank process that runs one Julia REPL in a pseudo-terminal and
relays it over a Unix socket to the window. It runs with the Python interpreter provided by the
Python_jll package, which is Python 3.11 or later, so no system Python is needed. Installing this package
downloads that interpreter, which is about 54 MB. The wrapper uses only the Python standard library and runs
on Linux only. Its docstring gives the environment variables, the frame format and the shutdown and failure
behaviour. The window starts one wrapper per rank under `mpiexec`, through `MpiLauncher.jl`. Its tests are in
`test/wrapper` (Python unit tests) and `test/test_wrapper.jl` (which runs them, and a round trip from Julia).
Both use the same Python_jll interpreter, so `python3` on the PATH is not used.

## Tests

```
julia --project -e 'using Pkg; Pkg.test()'
```
