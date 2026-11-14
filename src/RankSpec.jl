"""
    RankSpec

Parsing of the number of MPI ranks requested on the command line. This module
has no GUI dependency so that it can be tested headless.
"""
module RankSpec

export parse_rank_count

"""
    parse_rank_count(args) -> Union{Nothing,Int}

Return the rank count given as the optional single positional argument in
`args`, or `nothing` if `args` is empty. Throw an `ArgumentError` if there is
more than one argument or the argument is not a positive integer.
"""
function parse_rank_count(args)
    isempty(args) && return nothing
    length(args) == 1 ||
        throw(ArgumentError("expected at most one argument (the rank count), got $(length(args))"))
    arg = only(args)
    n = tryparse(Int, arg)
    (n !== nothing && n >= 1) ||
        throw(ArgumentError("rank count must be a positive integer, got \"$arg\""))
    return n
end

end # module RankSpec
