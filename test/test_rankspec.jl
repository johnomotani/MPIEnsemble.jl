using MPIEnsemble.RankSpec: parse_rank_count

@testset "parse_rank_count" begin
    @test parse_rank_count(String[]) === nothing
    @test parse_rank_count(["4"]) == 4
    @test_throws "positive integer" parse_rank_count(["0"])
    @test_throws "positive integer" parse_rank_count(["-2"])
    @test_throws "positive integer" parse_rank_count(["many"])
    @test_throws "at most one argument" parse_rank_count(["2", "3"])
end
