@testset "GUI files" begin
    # Gui.jl is not loaded by the package, so no QML or Qt initialisation is needed.
    @test !isdefined(MPIEnsemble, :Gui)
    for qml_dir in (joinpath(pkgdir(MPIEnsemble), "src", "qml"),
                    joinpath(dirname(pathof(MPIEnsemble)), "qml"))
        @test isfile(joinpath(qml_dir, "Main.qml"))
        @test isfile(joinpath(qml_dir, "Pane.qml"))
    end
    @test isfile(joinpath(dirname(pathof(MPIEnsemble)), "Gui.jl"))
end
