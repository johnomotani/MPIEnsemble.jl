"""
    RankSpec

Parsing of the MPI launch specification: the number of ranks and the command that each rank runs. This module
has no GUI dependency so that it can be tested headless.
"""
module RankSpec

export parse_launch_arguments, split_command, shell_join

"""
    parse_launch_arguments(args) -> (count, command)

Parse the command-line arguments of MPIEnsemble. The first argument, if any, is the rank count: a non-negative
integer, where `0` means a serial Julia REPL and a positive integer is the number of MPI ranks. Every argument
after it is the command that each rank runs, with the executable first. Without arguments, `count` is `nothing`.
Without a command, `command` is an empty vector, which means the default command.

The command is taken as it is given: its arguments are not split, so an argument containing spaces stays one
argument. Throws `ArgumentError` if the first argument is not a non-negative integer, or if a command is given
with a count of `0` (a serial Julia REPL takes no command) or without a count.
"""
function parse_launch_arguments(args)
    isempty(args) && return (nothing, String[])
    arg = String(first(args))
    n = tryparse(Int, arg)
    (n !== nothing && n >= 0) ||
        throw(ArgumentError("rank count must be a non-negative integer (0 for a serial Julia REPL), got \"$arg\""))
    command = String[String(a) for a in args[2:end]]
    n == 0 && !isempty(command) &&
        throw(ArgumentError("a serial Julia REPL (rank count 0) takes no command, but got the command " *
            "\"$(shell_join(command))\"; give a rank count of 1 or more to run a command under MPI"))
    return (n, command)
end

"""
    split_command(text) -> Vector{String}

Split the text of the command field of the launch dialog into arguments, with `Base.shell_split`: arguments are
separated by whitespace, and an argument that contains whitespace is enclosed in single or double quotes. Blank
text gives an empty vector, which means the default command. Throws `ArgumentError` if a quote is not closed or
the text ends with a backslash.
"""
function split_command(text::AbstractString)
    try
        return String.(Base.shell_split(text))
    catch e
        e isa ErrorException || rethrow()
        throw(ArgumentError("cannot split the command \"$text\": $(e.msg)"))
    end
end

"""
    shell_join(command) -> String

The command as text that `split_command` reads back as the same arguments. Arguments that need quoting are quoted.
An empty `command` gives an empty string.
"""
shell_join(command::AbstractVector{<:AbstractString}) = join(Base.shell_escape.(command), " ")

end # module RankSpec
