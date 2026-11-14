const KM = MPIEnsemble.KeyMap

# The bytes for a key press, as a String, or `nothing`.
keys_out(key, text, mods; kw...) = (b = KM.key_bytes(key, text, mods; kw...); b === nothing ? nothing : String(b))

@testset "printable text" begin
    @test keys_out(0x41, "a", 0) == "a"
    @test keys_out(0x41, "A", KM.MOD_SHIFT) == "A"
    @test keys_out(0x31, "1", 0) == "1"
    @test keys_out(0x20, " ", 0) == " "
    @test keys_out(0xc9, "é", 0) == "é"
    @test Vector{UInt8}(keys_out(0xc9, "é", 0)) == UInt8[0xc3, 0xa9]
    @test keys_out(0, "ü", 0) == "ü"
    @test keys_out(0x34, "€", KM.MOD_ALT) == "\e€"
    @test keys_out(0x41, "", 0) === nothing
    @test keys_out(0x41, "a", KM.MOD_META) === nothing
end

@testset "named keys" begin
    @test keys_out(KM.KEY_RETURN, "\r", 0) == "\r"
    @test keys_out(KM.KEY_ENTER, "\r", KM.MOD_ALT) == "\e\r"
    @test keys_out(KM.KEY_ENTER, "\r", KM.MOD_SHIFT | KM.MOD_CTRL) == "\r"
    @test keys_out(KM.KEY_TAB, "\t", 0) == "\t"
    @test keys_out(KM.KEY_TAB, "\t", KM.MOD_SHIFT) == "\e[Z"
    @test keys_out(KM.KEY_BACKTAB, "", KM.MOD_SHIFT) == "\e[Z"
    @test keys_out(KM.KEY_TAB, "\t", KM.MOD_CTRL) === nothing
    @test keys_out(KM.KEY_BACKSPACE, "\b", 0) == "\x7f"
    @test keys_out(KM.KEY_BACKSPACE, "\b", KM.MOD_CTRL) == "\b"
    @test keys_out(KM.KEY_BACKSPACE, "\b", KM.MOD_ALT) == "\e\x7f"
    @test keys_out(KM.KEY_ESCAPE, "\e", 0) == "\e"
    @test keys_out(KM.KEY_ESCAPE, "\e", KM.MOD_ALT) == "\e\e"
end

@testset "arrows, Home and End" begin
    @test keys_out(KM.KEY_UP, "", 0) == "\e[A"
    @test keys_out(KM.KEY_DOWN, "", 0) == "\e[B"
    @test keys_out(KM.KEY_RIGHT, "", 0) == "\e[C"
    @test keys_out(KM.KEY_LEFT, "", 0) == "\e[D"
    @test keys_out(KM.KEY_HOME, "", 0) == "\e[H"
    @test keys_out(KM.KEY_END, "", 0) == "\e[F"
    @test keys_out(KM.KEY_UP, "", 0; application_cursor = true) == "\eOA"
    @test keys_out(KM.KEY_LEFT, "", 0; application_cursor = true) == "\eOD"
    @test keys_out(KM.KEY_HOME, "", 0; application_cursor = true) == "\eOH"
    @test keys_out(KM.KEY_END, "", 0; application_cursor = true) == "\eOF"
    # Modified keys use the CSI form whatever the cursor mode.
    @test keys_out(KM.KEY_LEFT, "", KM.MOD_SHIFT; application_cursor = true) == "\e[1;2D"
    @test keys_out(KM.KEY_UP, "", KM.MOD_SHIFT) == "\e[1;2A"
    @test keys_out(KM.KEY_RIGHT, "", KM.MOD_ALT) == "\e[1;3C"
    @test keys_out(KM.KEY_LEFT, "", KM.MOD_CTRL) == "\e[1;5D"
    @test keys_out(KM.KEY_LEFT, "", KM.MOD_CTRL | KM.MOD_SHIFT) == "\e[1;6D"
    @test keys_out(KM.KEY_RIGHT, "", KM.MOD_CTRL | KM.MOD_ALT | KM.MOD_SHIFT) == "\e[1;8C"
    @test keys_out(KM.KEY_HOME, "", KM.MOD_CTRL) == "\e[1;5H"
    @test keys_out(KM.KEY_END, "", KM.MOD_SHIFT) == "\e[1;2F"
end

@testset "editing and paging keys" begin
    @test keys_out(KM.KEY_INSERT, "", 0) == "\e[2~"
    @test keys_out(KM.KEY_DELETE, "\x7f", 0) == "\e[3~"
    @test keys_out(KM.KEY_PAGEUP, "", 0) == "\e[5~"
    @test keys_out(KM.KEY_PAGEDOWN, "", 0) == "\e[6~"
    @test keys_out(KM.KEY_DELETE, "", KM.MOD_CTRL) == "\e[3;5~"
    @test keys_out(KM.KEY_PAGEUP, "", KM.MOD_SHIFT) == "\e[5;2~"
end

@testset "function keys" begin
    f(n) = KM.KEY_F1 + n - 1
    @test keys_out(f(1), "", 0) == "\eOP"
    @test keys_out(f(2), "", 0) == "\eOQ"
    @test keys_out(f(3), "", 0) == "\eOR"
    @test keys_out(f(4), "", 0) == "\eOS"
    @test keys_out(f(5), "", 0) == "\e[15~"
    @test keys_out(f(6), "", 0) == "\e[17~"
    @test keys_out(f(7), "", 0) == "\e[18~"
    @test keys_out(f(8), "", 0) == "\e[19~"
    @test keys_out(f(9), "", 0) == "\e[20~"
    @test keys_out(f(10), "", 0) == "\e[21~"
    @test keys_out(f(11), "", 0) == "\e[23~"
    @test keys_out(f(12), "", 0) == "\e[24~"
    @test keys_out(f(1), "", KM.MOD_SHIFT) == "\e[1;2P"
    @test keys_out(f(5), "", KM.MOD_CTRL) == "\e[15;5~"
    # Function keys ignore application cursor mode.
    @test keys_out(f(1), "", 0; application_cursor = true) == "\eOP"
end

@testset "Ctrl with letters and punctuation" begin
    @test keys_out(0x41, "\x01", KM.MOD_CTRL) == "\x01"
    @test keys_out(0x41, "\x01", KM.MOD_CTRL | KM.MOD_SHIFT) == "\x01"
    @test keys_out(0x43, "\x03", KM.MOD_CTRL) == "\x03"
    @test keys_out(0x44, "\x04", KM.MOD_CTRL) == "\x04"
    @test keys_out(0x45, "\x05", KM.MOD_CTRL) == "\x05"
    @test keys_out(0x4b, "\x0b", KM.MOD_CTRL) == "\x0b"
    @test keys_out(0x55, "\x15", KM.MOD_CTRL) == "\x15"
    @test keys_out(0x57, "\x17", KM.MOD_CTRL) == "\x17"
    @test keys_out(0x5a, "\x1a", KM.MOD_CTRL) == "\x1a"
    @test keys_out(0x61, "\x01", KM.MOD_CTRL) == "\x01"
    @test keys_out(0x5b, "\e", KM.MOD_CTRL) == "\e"
    @test keys_out(0x5c, "\x1c", KM.MOD_CTRL) == "\x1c"
    @test keys_out(0x5d, "\x1d", KM.MOD_CTRL) == "\x1d"
    @test keys_out(0x5e, "\x1e", KM.MOD_CTRL) == "\x1e"
    @test keys_out(0x5f, "\x1f", KM.MOD_CTRL) == "\x1f"
    @test keys_out(0x40, "\0", KM.MOD_CTRL) == "\0"
    @test keys_out(0x2f, "\x1f", KM.MOD_CTRL) == "\x1f"
    @test keys_out(0x20, "\0", KM.MOD_CTRL) == "\0"
    @test keys_out(0x41, "\x01", KM.MOD_CTRL | KM.MOD_ALT) == "\e\x01"
end

@testset "Alt prefixes ESC" begin
    @test keys_out(0x78, "x", KM.MOD_ALT) == "\ex"
    @test keys_out(0x58, "X", KM.MOD_ALT | KM.MOD_SHIFT) == "\eX"
    @test keys_out(0x42, "\x02", KM.MOD_ALT | KM.MOD_CTRL) == "\e\x02"
end

@testset "keypad and modifier bits" begin
    @test keys_out(KM.KEY_ENTER, "\r", KM.MOD_SHIFT | 0x20000000) == "\r"
    @test keys_out(0x31, "1", 0x20000000) == "1"
end

@testset "keys with no translation return nothing" begin
    for k in (KM.KEY_SHIFT, KM.KEY_CONTROL, KM.KEY_ALT, KM.KEY_META, KM.KEY_SUPER_L, KM.KEY_CAPSLOCK)
        @test keys_out(k, "", KM.MOD_SHIFT | KM.MOD_CTRL) === nothing
    end
    @test keys_out(0x01000008, "", 0) === nothing      # Pause
    @test keys_out(0x01000009, "", 0) === nothing      # Print
    @test keys_out(0x31, "1", KM.MOD_CTRL) === nothing
    @test keys_out(0x39, "", KM.MOD_CTRL) === nothing
    @test keys_out(0x41, "\x01", KM.MOD_META) === nothing
    @test keys_out(KM.KEY_LEFT, "", KM.MOD_META) === nothing
    @test keys_out(KM.KEY_TAB, "\t", KM.MOD_CTRL) === nothing
    @test keys_out(KM.KEY_F1 + 30, "", 0) === nothing  # F31
    @test keys_out(0x41, "\x01", 0) === nothing         # control character text without Ctrl
end

@testset "Ctrl+Shift+V is the paste chord" begin
    @test KM.is_paste_chord(0x56, KM.MOD_CTRL | KM.MOD_SHIFT)
    @test !KM.is_paste_chord(0x56, KM.MOD_CTRL)
    @test !KM.is_paste_chord(0x56, KM.MOD_SHIFT)
    @test !KM.is_paste_chord(0x56, KM.MOD_CTRL | KM.MOD_SHIFT | KM.MOD_ALT)
    @test !KM.is_paste_chord(0x43, KM.MOD_CTRL | KM.MOD_SHIFT)
end

@testset "paste" begin
    @testset "bracketed" begin
        paste(s) = String(KM.paste_bytes(s; bracketed = true))
        @test paste("a\nb") == "\e[200~a\nb\e[201~"
        @test paste("") == "\e[200~\e[201~"
        @test paste("x\e[201~y") == "\e[200~xy\e[201~"
        @test paste("\e\e[201~[201~") == "\e[200~\e[201~"
        @test paste("a\x03b\e[Ac") == "\e[200~a\x03b\e[Ac\e[201~"
        @test paste("é\r\n") == "\e[200~é\r\n\e[201~"
    end
    @testset "not bracketed" begin
        paste(s) = String(KM.paste_bytes(s; bracketed = false))
        @test paste("a\nb") == "a\rb"
        @test paste("a\r\nb\rc\n") == "a\rb\rc\r"
        @test paste("a\x03\e[Ab\x7f\te") == "a[Ab\te"
        @test paste("é\x01") == "é"
        @test Vector{UInt8}(paste("\e")) == UInt8[]
    end
end
