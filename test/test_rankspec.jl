using MPIEnsemble.RankSpec: parse_rank_count

@testset "parse_rank_count" begin
    @test parse_rank_count(String[]) === nothing
    @test parse_rank_count(["4"]) == 4
    @test parse_rank_count(["1"]) == 1
    @test parse_rank_count(["+3"]) == 3
    # 0 is the serial Julia REPL, not a rank count of zero.
    @test parse_rank_count(["0"]) === 0
    @test_throws "non-negative integer (0 for a serial Julia REPL)" parse_rank_count(["-1"])
    @test_throws "non-negative integer (0 for a serial Julia REPL)" parse_rank_count(["-2"])
    @test_throws "non-negative integer (0 for a serial Julia REPL)" parse_rank_count(["abc"])
    @test_throws "non-negative integer (0 for a serial Julia REPL)" parse_rank_count(["1.5"])
    @test_throws "non-negative integer (0 for a serial Julia REPL)" parse_rank_count([""])
    @test_throws "at most one argument" parse_rank_count(["2", "3"])
    @test_throws "at most one argument" parse_rank_count(["0", "0"])
end
