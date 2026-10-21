using System.Runtime.InteropServices;

namespace CouchControl;

/// <summary>
/// Turns protocol lines into SendInput calls. The phone speaks macOS virtual keycodes
/// (the protocol is shared with the Mac app); <see cref="Keymap"/> translates them.
/// Line format (space separated):
///   m dx dy        move pointer by delta (sent as relative motion, which is what games read)
///   s dx dy        scroll by pixels
///   b l|r 1|0      mouse button down/up
///   c l|r          click
///   k code 1|0     key down/up (macOS virtual keycode)
///   t text         type text (rest of line)
///   r              release everything held
/// </summary>
static class Injector
{
    static readonly object Gate = new();
    static readonly HashSet<ushort> HeldKeys = new();
    static bool leftDown, rightDown;

    public static void Handle(string line)
    {
        var p = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (p.Length == 0) return;
        lock (Gate)
        {
            switch (p[0])
            {
                case "m" when p.Length >= 3 && int.TryParse(p[1], out var dx) && int.TryParse(p[2], out var dy):
                    Mouse(Native.MOUSEEVENTF_MOVE, dx, dy, 0);
                    break;
                case "s" when p.Length >= 3 && int.TryParse(p[1], out var sx) && int.TryParse(p[2], out var sy):
                    // Pixels → wheel units: 120 per notch, about 40 px per notch on the Mac side.
                    if (sy != 0) Mouse(Native.MOUSEEVENTF_WHEEL, 0, 0, sy * 3);
                    if (sx != 0) Mouse(Native.MOUSEEVENTF_HWHEEL, 0, 0, -sx * 3);
                    break;
                case "b" when p.Length >= 3:
                    Button(p[1] == "r", p[2] == "1");
                    break;
                case "c" when p.Length >= 2:
                    Button(p[1] == "r", true);
                    Button(p[1] == "r", false);
                    break;
                case "k" when p.Length >= 3 && ushort.TryParse(p[1], out var code):
                    Key(code, p[2] == "1");
                    break;
                case "t" when line.Length > 2:
                    Type(line[2..]);
                    break;
                case "g" when p.Length >= 2:
                    Gesture(p[1]);
                    break;
                case "r":
                    ReleaseAllLocked();
                    break;
            }
        }
    }

    /// <summary>
    /// Three-finger swipes from the phone, as the shortcuts for the closest Windows actions:
    /// up = Task View, down = show desktop, left/right = previous/next virtual desktop.
    /// </summary>
    static void Gesture(string direction)
    {
        const ushort LWIN = 0x5B, LCTRL = 0xA2, TAB = 0x09, D = 0x44, LEFT = 0x25, RIGHT = 0x27;
        switch (direction)
        {
            case "up": Chord(LWIN, TAB); break;
            case "down": Chord(LWIN, D); break;
            case "left": Chord(LCTRL, LWIN, LEFT); break;
            case "right": Chord(LCTRL, LWIN, RIGHT); break;
        }
    }

    static void Chord(params ushort[] keys)
    {
        foreach (var k in keys) SendKey(k, true);
        for (var i = keys.Length - 1; i >= 0; i--) SendKey(keys[i], false);
    }

    public static void ReleaseAll()
    {
        lock (Gate) ReleaseAllLocked();
    }

    static void ReleaseAllLocked()
    {
        foreach (var code in HeldKeys.ToList()) Key(code, false);
        if (leftDown) Button(false, false);
        if (rightDown) Button(true, false);
    }

    // MARK: Mouse

    static void Mouse(uint flags, int dx, int dy, int data)
    {
        var input = new Native.INPUT
        {
            type = Native.INPUT_MOUSE,
            u = new Native.InputUnion
            {
                mi = new Native.MOUSEINPUT { dx = dx, dy = dy, mouseData = data, dwFlags = flags },
            },
        };
        Native.SendInput(1, new[] { input }, Marshal.SizeOf<Native.INPUT>());
    }

    static void Button(bool right, bool down)
    {
        uint flag = (right, down) switch
        {
            (true, true) => Native.MOUSEEVENTF_RIGHTDOWN,
            (true, false) => Native.MOUSEEVENTF_RIGHTUP,
            (false, true) => Native.MOUSEEVENTF_LEFTDOWN,
            (false, false) => Native.MOUSEEVENTF_LEFTUP,
        };
        Mouse(flag, 0, 0, 0);
        if (right) rightDown = down; else leftDown = down;
    }

    // MARK: Keyboard

    /// <summary>Press or release a key given its macOS virtual keycode.</summary>
    static void Key(ushort macCode, bool down)
    {
        if (!Keymap.TryGetVirtualKey(macCode, out var vk)) return;
        SendKey(vk, down);
        if (down) HeldKeys.Add(macCode); else HeldKeys.Remove(macCode);
    }

    /// <summary>
    /// Sends both the virtual key and its scan code: regular apps read the former, games
    /// (DirectInput / raw input) the latter.
    /// </summary>
    static void SendKey(ushort vk, bool down)
    {
        var scan = (ushort)Native.MapVirtualKey(vk, Native.MAPVK_VK_TO_VSC);
        uint flags = down ? 0 : Native.KEYEVENTF_KEYUP;
        if (Keymap.IsExtended(vk)) flags |= Native.KEYEVENTF_EXTENDEDKEY;
        var input = new Native.INPUT
        {
            type = Native.INPUT_KEYBOARD,
            u = new Native.InputUnion
            {
                ki = new Native.KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags },
            },
        };
        Native.SendInput(1, new[] { input }, Marshal.SizeOf<Native.INPUT>());
    }

    /// <summary>
    /// Characters that exist on the current keyboard layout are typed as real key presses
    /// (with Shift where needed) so games see the right key; anything else goes as Unicode.
    /// </summary>
    static void Type(string text)
    {
        foreach (var ch in text)
        {
            if (ch == '\n') { SendKey(Native.VK_RETURN, true); SendKey(Native.VK_RETURN, false); continue; }
            if (ch == '\t') { SendKey(Native.VK_TAB, true); SendKey(Native.VK_TAB, false); continue; }

            var scan = Native.VkKeyScan(ch);
            if (scan == -1 || char.IsSurrogate(ch))
            {
                TypeUnicode(ch);
                continue;
            }
            var vk = (ushort)(scan & 0xFF);
            var shift = (scan & 0x100) != 0;
            var ctrl = (scan & 0x200) != 0;
            var alt = (scan & 0x400) != 0;
            if (ctrl || alt)
            {
                // AltGr characters: safer to type as Unicode than to fake the chord.
                TypeUnicode(ch);
                continue;
            }
            if (shift) SendKey(Native.VK_LSHIFT, true);
            SendKey(vk, true);
            SendKey(vk, false);
            if (shift) SendKey(Native.VK_LSHIFT, false);
        }
    }

    static void TypeUnicode(char ch)
    {
        var inputs = new[]
        {
            new Native.INPUT
            {
                type = Native.INPUT_KEYBOARD,
                u = new Native.InputUnion { ki = new Native.KEYBDINPUT { wScan = ch, dwFlags = Native.KEYEVENTF_UNICODE } },
            },
            new Native.INPUT
            {
                type = Native.INPUT_KEYBOARD,
                u = new Native.InputUnion { ki = new Native.KEYBDINPUT { wScan = ch, dwFlags = Native.KEYEVENTF_UNICODE | Native.KEYEVENTF_KEYUP } },
            },
        };
        Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.INPUT>());
    }
}

/// <summary>macOS virtual keycode → Windows virtual key.</summary>
static class Keymap
{
    static readonly Dictionary<ushort, ushort> Map = new()
    {
        // Letters
        [0] = 'A', [1] = 'S', [2] = 'D', [3] = 'F', [4] = 'H', [5] = 'G', [6] = 'Z', [7] = 'X', [8] = 'C', [9] = 'V',
        [11] = 'B', [12] = 'Q', [13] = 'W', [14] = 'E', [15] = 'R', [16] = 'Y', [17] = 'T', [31] = 'O', [32] = 'U',
        [34] = 'I', [35] = 'P', [37] = 'L', [38] = 'J', [40] = 'K', [45] = 'N', [46] = 'M',
        // Digits
        [18] = '1', [19] = '2', [20] = '3', [21] = '4', [23] = '5', [22] = '6', [26] = '7', [28] = '8', [25] = '9', [29] = '0',
        // Punctuation (US layout positions)
        [24] = 0xBB /* = */, [27] = 0xBD /* - */, [30] = 0xDD /* ] */, [33] = 0xDB /* [ */, [39] = 0xDE /* ' */,
        [41] = 0xBA /* ; */, [42] = 0xDC /* \ */, [43] = 0xBC /* , */, [44] = 0xBF /* / */, [47] = 0xBE /* . */,
        [50] = 0xC0 /* ` */,
        // Control keys
        [36] = Native.VK_RETURN, [48] = Native.VK_TAB, [49] = 0x20 /* space */, [51] = 0x08 /* backspace */,
        [53] = 0x1B /* esc */, [57] = 0x14 /* caps lock */,
        // Modifiers: ⌘ → Win, ⌥ → Alt, ⌃ → Ctrl
        [55] = 0x5B /* LWIN */, [54] = 0x5C /* RWIN */, [56] = Native.VK_LSHIFT, [60] = 0xA1 /* RSHIFT */,
        [58] = 0xA4 /* LMENU */, [61] = 0xA5 /* RMENU */, [59] = 0xA2 /* LCONTROL */, [62] = 0xA3 /* RCONTROL */,
        // Function keys
        [122] = 0x70, [120] = 0x71, [99] = 0x72, [118] = 0x73, [96] = 0x74, [97] = 0x75,
        [98] = 0x76, [100] = 0x77, [101] = 0x78, [109] = 0x79, [103] = 0x7A, [111] = 0x7B,
        // Arrows
        [123] = 0x25, [124] = 0x27, [125] = 0x28, [126] = 0x26,
        // 63 (fn) has no Windows equivalent and is ignored.
    };

    static readonly HashSet<ushort> Extended = new()
    {
        0x25, 0x26, 0x27, 0x28, // arrows
        0x5B, 0x5C,             // Win keys
        0xA3, 0xA5,             // right Ctrl, right Alt
        0x2D, 0x2E, 0x24, 0x23, 0x21, 0x22, // insert, delete, home, end, page up/down
    };

    public static bool TryGetVirtualKey(ushort macCode, out ushort vk) => Map.TryGetValue(macCode, out vk);
    public static bool IsExtended(ushort vk) => Extended.Contains(vk);
}

static class Native
{
    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;

    public const uint MOUSEEVENTF_MOVE = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
    public const uint MOUSEEVENTF_HWHEEL = 0x1000;

    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;

    public const uint MAPVK_VK_TO_VSC = 0;

    public const ushort VK_TAB = 0x09;
    public const ushort VK_RETURN = 0x0D;
    public const ushort VK_LSHIFT = 0xA0;

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public int mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public InputUnion u;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern short VkKeyScan(char ch);
}
