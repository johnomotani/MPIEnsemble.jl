@testset "main" begin
    # Argument errors are reported before any window opens.
    @test_throws "non-negative integer" MPIEnsemble.main(["x"])
    @test_throws "non-negative integer" MPIEnsemble.main(["-1"])
    @test_throws "non-negative integer" MPIEnsemble.main(["1.5"])
    @test_throws "takes no command" MPIEnsemble.main(["0", "julia", "-t2"])
    @test_throws "rank count must be a non-negative integer" MPIEnsemble.main(["julia", "-t2"])
end

@testset "run_single_repl: a command needs a positive rank count, and no window opens" begin
    @test_throws "a command needs an MPI start-up with a rank count of 1 or more, got rank count nothing" begin
        MPIEnsemble.run_single_repl(command = ["julia"])
    end
    @test_throws "a command needs an MPI start-up with a rank count of 1 or more, got rank count 0" begin
        MPIEnsemble.run_single_repl(rank_count = 0, command = ["julia"])
    end
    @test_throws "the command must be a vector of strings" MPIEnsemble.run_single_repl(rank_count = 2, command = "julia")
end
