@testset "main" begin
    # Argument errors are reported before any window opens.
    @test_throws "non-negative integer" MPIEnsemble.main(["x"])
    @test_throws "non-negative integer" MPIEnsemble.main(["-1"])
    @test_throws "non-negative integer" MPIEnsemble.main(["1.5"])
    @test_throws "at most one argument" MPIEnsemble.main(["2", "3"])
end
