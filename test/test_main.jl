@testset "main" begin
    out = mktemp() do path, io
        redirect_stdout(io) do
            @test MPIEnsemble.main(["3"]) == 0
        end
        flush(io)
        read(path, String)
    end
    @test occursin("3 rank", out)
    @test_throws "positive integer" MPIEnsemble.main(["x"])
end
