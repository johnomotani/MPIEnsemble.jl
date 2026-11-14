# Translation of key events into the bytes that a terminal sends to its child process. A key press is
# described by a Qt::Key code, the event text and Qt::KeyboardModifier bits, as QML reports them in
# `KeyEvent`. Nothing here depends on Qt, so the translations are tested without a display.
module KeyMap

export key_bytes, paste_bytes, is_paste_chord

# Values of Qt::Key and Qt::KeyboardModifier. Letters use their upper-case code, as Qt reports them.
const KEY_SPECIAL = 0x01000000          # codes at or above this are named keys, not characters
const KEY_ESCAPE = 0x01000000
const KEY_TAB = 0x01000001
const KEY_BACKTAB = 0x01000002
const KEY_BACKSPACE = 0x01000003
const KEY_RETURN = 0x01000004
const KEY_ENTER = 0x01000005
const KEY_INSERT = 0x01000006
const KEY_DELETE = 0x01000007
const KEY_HOME = 0x01000010
const KEY_END = 0x01000011
const KEY_LEFT = 0x01000012
const KEY_UP = 0x01000013
const KEY_RIGHT = 0x01000014
const KEY_DOWN = 0x01000015
const KEY_PAGEUP = 0x01000016
const KEY_PAGEDOWN = 0x01000017
const KEY_SHIFT = 0x01000020
const KEY_CONTROL = 0x01000021
const KEY_META = 0x01000022
const KEY_ALT = 0x01000023
const KEY_CAPSLOCK = 0x01000024
const KEY_NUMLOCK = 0x01000025
const KEY_SCROLLLOCK = 0x01000026
const KEY_F1 = 0x01000030               # F2 to F12 are KEY_F1 + 1 to KEY_F1 + 11
const KEY_SUPER_L = 0x01000053
const KEY_SUPER_R = 0x01000054
const KEY_HYPER_L = 0x01000056
const KEY_HYPER_R = 0x01000057
const KEY_V = 0x56

const MOD_SHIFT = 0x02000000
const MOD_CTRL = 0x04000000
const MOD_ALT = 0x08000000
const MOD_META = 0x10000000

const MODIFIER_KEYS = (KEY_SHIFT, KEY_CONTROL, KEY_META, KEY_ALT, KEY_CAPSLOCK, KEY_NUMLOCK,
    KEY_SCROLLLOCK, KEY_SUPER_L, KEY_SUPER_R, KEY_HYPER_L, KEY_HYPER_R)

# Keys whose sequence ends in a letter. Unmodified, the arrows, Home and End use CSI, or SS3 when
# DECCKM is set; F1 to F4 use SS3. With modifiers, all of them use CSI 1 ; m letter.
const LETTER_KEYS = Dict{Int, Char}([KEY_UP => 'A', KEY_DOWN => 'B', KEY_RIGHT => 'C', KEY_LEFT => 'D',
    KEY_END => 'F', KEY_HOME => 'H', KEY_F1 => 'P', KEY_F1 + 1 => 'Q', KEY_F1 + 2 => 'R', KEY_F1 + 3 => 'S'])

# Keys whose sequence is CSI n ~, with CSI n ; m ~ when modified.
const TILDE_KEYS = Dict{Int, Int}([KEY_INSERT => 2, KEY_DELETE => 3, KEY_PAGEUP => 5, KEY_PAGEDOWN => 6,
    KEY_F1 + 4 => 15, KEY_F1 + 5 => 17, KEY_F1 + 6 => 18, KEY_F1 + 7 => 19, KEY_F1 + 8 => 20,
    KEY_F1 + 9 => 21, KEY_F1 + 10 => 23, KEY_F1 + 11 => 24])

const PASTE_START = "\e[200~"
const PASTE_END = "\e[201~"

as_bytes(s::AbstractString) = Vector{UInt8}(codeunits(s))

# The byte sent for Ctrl with the character key `k`, or `nothing` if Ctrl has no conventional
# control code for it.
function control_char(k::Int)
    if 0x41 <= k <= 0x5a                    # A to Z
        return Char(k - 0x40)
    elseif 0x61 <= k <= 0x7a                # a to z, for keys reported in lower case
        return Char(k - 0x60)
    elseif k == 0x20 || k == 0x40           # space and @ give NUL
        return Char(0x00)
    elseif 0x5b <= k <= 0x5f                # [ \ ] ^ _
        return Char(k - 0x40)
    elseif k == 0x2f                        # /
        return Char(0x1f)
    end
    return nothing
end

# The sequence for a named key that is not one of the tables above, or `nothing`. Ctrl+Tab has no
# translation here.
function named_key_bytes(k::Int, shift::Bool, ctrl::Bool)
    if k == KEY_RETURN || k == KEY_ENTER
        return "\r"
    elseif k == KEY_ESCAPE
        return "\e"
    elseif k == KEY_BACKSPACE
        return ctrl ? "\b" : "\x7f"
    elseif k == KEY_TAB
        ctrl && return nothing
        return shift ? "\e[Z" : "\t"
    elseif k == KEY_BACKTAB
        ctrl && return nothing
        return "\e[Z"
    end
    return nothing
end

"""
    key_bytes(key, text, modifiers; application_cursor = false) -> Union{Nothing, Vector{UInt8}}

The bytes to write to the child for one key press. `key` is the Qt::Key code, `text` the event text
and `modifiers` the Qt::KeyboardModifier bits. Keypad and group-switch bits are ignored.

Printable text is sent as UTF-8. Ctrl with a letter, `[`, `\\`, `]`, `^`, `_`, `@`, `/` or space
gives its control code. Alt puts `ESC` before the bytes of the key. With Shift, Ctrl or Alt, the
arrows, Home, End, F1 to F12, Insert, Delete, PageUp and PageDown use the xterm modifier form, for
example `ESC [ 1 ; 5 D` for Ctrl+Left. With `application_cursor` (DEC private mode 1), unmodified
arrows, Home and End use `ESC O` instead of `ESC [`.

Returns `nothing` for a pure modifier press, for any key with Meta, and for a key with no translation.
The caller ignores these and sends nothing.
"""
function key_bytes(key::Integer, text::AbstractString, modifiers::Integer; application_cursor::Bool = false)
    k = Int(key)
    m = Int(modifiers)
    (k in MODIFIER_KEYS || m & MOD_META != 0) && return nothing
    shift = m & MOD_SHIFT != 0
    ctrl = m & MOD_CTRL != 0
    alt = m & MOD_ALT != 0
    param = 1 + shift + 2 * alt + 4 * ctrl

    if haskey(LETTER_KEYS, k)
        c = LETTER_KEYS[k]
        s = if param > 1
            "\e[1;$param$c"
        elseif KEY_F1 <= k < KEY_F1 + 4 || application_cursor
            "\eO$c"
        else
            "\e[$c"
        end
        return as_bytes(s)
    elseif haskey(TILDE_KEYS, k)
        n = TILDE_KEYS[k]
        return as_bytes(param == 1 ? "\e[$n~" : "\e[$n;$param~")
    end

    base = named_key_bytes(k, shift, ctrl)
    if base !== nothing
        return as_bytes(alt ? "\e" * base : base)
    end
    # Named keys without a translation above are not characters, so they must not be sent as text.
    k >= KEY_SPECIAL && return nothing

    if ctrl
        c = control_char(k)
        c === nothing && return nothing
        base = string(c)
    else
        # Text containing control characters is not sent as printable text.
        (isempty(text) || any(c -> c < ' ' || c == '\x7f', text)) && return nothing
        base = text
    end
    return as_bytes(alt ? "\e" * base : base)
end

"""
    is_paste_chord(key, modifiers) -> Bool

Whether a key press is Ctrl+Shift+V, which pastes the clipboard instead of being sent to the child.
"""
is_paste_chord(key::Integer, modifiers::Integer) =
    Int(key) == KEY_V && Int(modifiers) & (MOD_CTRL | MOD_SHIFT) == (MOD_CTRL | MOD_SHIFT) &&
    Int(modifiers) & (MOD_ALT | MOD_META) == 0

"""
    paste_bytes(text; bracketed) -> Vector{UInt8}

The bytes to write for pasting `text`.

With `bracketed` (the child has enabled DEC private mode 2004), the text is wrapped in `ESC [200~`
and `ESC [201~`. Every `ESC [201~` in the text is removed, so the text cannot end the bracket early.
Other control characters are passed through unchanged.

Without `bracketed`, `\\r\\n` and `\\n` become `\\r`, which is what Return sends. C0 control characters
other than tab and `\\r`, and DEL, are dropped from the text, not replaced. This includes ESC.
"""
function paste_bytes(text::AbstractString; bracketed::Bool)
    if bracketed
        body = text
        while occursin(PASTE_END, body)
            body = replace(body, PASTE_END => "")
        end
        return as_bytes(PASTE_START * body * PASTE_END)
    end
    lines = replace(replace(text, "\r\n" => "\n"), '\n' => '\r')
    return as_bytes(filter(c -> c == '\t' || c == '\r' || (c >= ' ' && c != '\x7f'), lines))
end

end # module KeyMap
