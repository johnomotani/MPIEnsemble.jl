@testset "main" begin
    # Argument errors are reported before any window opens.
    @test_throws "positive integer" MPIEnsemble.main(["x"])
    @test_throws "at most one argument" MPIEnsemble.main(["2", "3"])
end
