using MPIEnsemble.RankSpec: parse_launch_arguments, split_command, shell_join

@testset "parse_launch_arguments: the rank count" begin
    @test parse_launch_arguments(String[]) == (nothing, String[])
    @test parse_launch_arguments(["4"]) == (4, String[])
    @test parse_launch_arguments(["1"]) == (1, String[])
    @test parse_launch_arguments(["+3"]) == (3, String[])
    # 0 is the serial Julia REPL, not a rank count of zero.
    @test parse_launch_arguments(["0"]) == (0, String[])
    @test_throws "non-negative integer (0 for a serial Julia REPL)" parse_launch_arguments(["-1"])
    @test_throws "non-negative integer (0 for a serial Julia REPL)" parse_launch_arguments(["-2"])
    @test_throws "non-negative integer (0 for a serial Julia REPL)" parse_launch_arguments(["abc"])
    @test_throws "non-negative integer (0 for a serial Julia REPL)" parse_launch_arguments(["1.5"])
    @test_throws "non-negative integer (0 for a serial Julia REPL)" parse_launch_arguments([""])
    # A command given before the rank count is not a rank count.
    @test_throws "rank count must be a non-negative integer" parse_launch_arguments(["julia", "4"])
end

@testset "parse_launch_arguments: the command follows the rank count" begin
    @test parse_launch_arguments(["4", "julia"]) == (4, ["julia"])
    @test parse_launch_arguments(["4", "julia", "--project", "-t2"]) == (4, ["julia", "--project", "-t2"])
    # The arguments are not split: an argument with spaces stays one argument, and so does an empty one.
    @test parse_launch_arguments(["4", "/opt/julia bin/julia", "--project=a b", ""]) ==
        (4, ["/opt/julia bin/julia", "--project=a b", ""])
    @test parse_launch_arguments(["2", "/opt/julia/bin/julia", "--project", "-t2"]) ==
        (2, ["/opt/julia/bin/julia", "--project", "-t2"])
    # A command that is not Julia is taken as given.
    @test parse_launch_arguments(["3", "sh", "-c", "exit 0"]) == (3, ["sh", "-c", "exit 0"])
end

@testset "parse_launch_arguments: a command needs a rank count of 1 or more" begin
    @test_throws "a serial Julia REPL (rank count 0) takes no command" parse_launch_arguments(["0", "julia"])
    @test_throws "takes no command, but got the command \"julia -t2\"" parse_launch_arguments(["0", "julia", "-t2"])
    @test_throws "rank count must be a non-negative integer" parse_launch_arguments(["julia", "-t2"])
end

@testset "split_command: the dialog's command field" begin
    @test split_command("julia") == ["julia"]
    @test split_command("  /opt/julia/bin/julia   --project  -t2 ") == ["/opt/julia/bin/julia", "--project", "-t2"]
    @test split_command("julia \"--project=my dir\" -t2") == ["julia", "--project=my dir", "-t2"]
    @test split_command("julia '--project=my dir'") == ["julia", "--project=my dir"]
    @test split_command("julia --project=\"a b\"c") == ["julia", "--project=a bc"]
    # Blank text is the default command.
    @test split_command("") == String[]
    @test split_command(" \t ") == String[]
    # A quote that is not closed, or a trailing backslash, is an error that names the text.
    @test_throws ArgumentError split_command("julia \"-t2")
    @test_throws "cannot split the command \"julia '-t2\": unterminated single quote" split_command("julia '-t2")
    @test_throws "cannot split the command" split_command("julia --x=\\")
end

@testset "shell_join: text that split_command reads back" begin
    @test shell_join(String[]) == ""
    @test shell_join(["julia", "-t2"]) == "julia -t2"
    command = ["/opt/julia bin/julia", "--project=a b", "x\"y", "it's", ""]
    @test split_command(shell_join(command)) == command
end
