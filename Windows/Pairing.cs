using System.Text.Json;

namespace Couchpad;

public enum PairingEvent { CodeChanged, Expired, Paired }

/// <summary>
/// Phones pair once with a 6-digit code and are handed a random token for every later
/// connection. The code is only live for one minute after the user opens the pairing window,
/// each connection gets a single guess, three wrong guesses rotate the code and lock pairing
/// for a few seconds.
/// </summary>
static class Pairing
{
    public static readonly TimeSpan Window = TimeSpan.FromSeconds(60);
    public const int MaxWrongGuesses = 3;
    public static readonly TimeSpan Lockout = TimeSpan.FromSeconds(3);

    /// <summary>Raised on a thread-pool thread; marshal to the UI thread before touching controls.</summary>
    public static event Action<PairingEvent>? OnEvent;

    static readonly object Gate = new();
    static readonly string TokensPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Couchpad", "tokens.json");
    static HashSet<string> tokens = Load();
    static DateTime codeExpires = DateTime.MinValue;
    static DateTime lockedUntil = DateTime.MinValue;
    static int wrongGuesses;
    static System.Threading.Timer? expiryTimer;

    public static string Code { get; private set; } = MakeCode();

    public static bool IsCodeActive { get { lock (Gate) return DateTime.UtcNow < codeExpires; } }

    public static int SecondsRemaining
    {
        get { lock (Gate) return Math.Max(0, (int)Math.Ceiling((codeExpires - DateTime.UtcNow).TotalSeconds)); }
    }

    public static int PairedCount { get { lock (Gate) return tokens.Count; } }

    /// <summary>The user opened the pairing window: fresh code, one-minute window.</summary>
    public static void BeginPairing()
    {
        lock (Gate)
        {
            Code = MakeCode();
            codeExpires = DateTime.UtcNow + Window;
            wrongGuesses = 0;
            expiryTimer?.Dispose();
            expiryTimer = new System.Threading.Timer(_ =>
            {
                bool stillActive;
                lock (Gate) stillActive = DateTime.UtcNow < codeExpires;
                if (!stillActive) OnEvent?.Invoke(PairingEvent.Expired);
            }, null, Window, Timeout.InfiniteTimeSpan);
        }
        OnEvent?.Invoke(PairingEvent.CodeChanged);
    }

    /// <summary>The user closed the pairing window: the code stops working right away.</summary>
    public static void EndPairing()
    {
        lock (Gate)
        {
            codeExpires = DateTime.MinValue;
            expiryTimer?.Dispose();
            expiryTimer = null;
        }
    }

    /// <summary>The stored token (if any) for which <paramref name="matches"/> is true. The caller
    /// checks a transcript proof against each candidate; the token itself never travels.</summary>
    public static string? TokenWhere(Func<string, bool> matches)
    {
        lock (Gate) return tokens.FirstOrDefault(matches);
    }

    /// <summary>A pairing attempt: <paramref name="matches"/> checks the client's proof against the
    /// live code. Issues and stores a new token on success. Enforces the window, single guess,
    /// rotation and lockout.</summary>
    public static string? Pair(Func<string, bool> matches)
    {
        bool rotated = false;
        lock (Gate)
        {
            var now = DateTime.UtcNow;
            if (now >= codeExpires || now < lockedUntil) return null;
            if (matches(Code))
            {
                var token = Guid.NewGuid().ToString("D").ToUpperInvariant();
                tokens.Add(token);
                Save();
                codeExpires = DateTime.MinValue; // one pairing per window
                expiryTimer?.Dispose();
                expiryTimer = null;
                OnEvent?.Invoke(PairingEvent.Paired);
                return token;
            }
            if (++wrongGuesses >= MaxWrongGuesses)
            {
                Code = MakeCode();
                wrongGuesses = 0;
                lockedUntil = now + Lockout;
                rotated = true;
            }
        }
        if (rotated) OnEvent?.Invoke(PairingEvent.CodeChanged);
        return null;
    }

    public static void ForgetAll()
    {
        lock (Gate)
        {
            tokens.Clear();
            Save();
        }
    }

    static string MakeCode() => Random.Shared.Next(0, 1_000_000).ToString("D6");

    static HashSet<string> Load()
    {
        try
        {
            if (File.Exists(TokensPath))
                return JsonSerializer.Deserialize<HashSet<string>>(File.ReadAllText(TokensPath)) ?? new();
        }
        catch (Exception) { /* corrupt file: start over */ }
        return new();
    }

    static void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(TokensPath)!);
        File.WriteAllText(TokensPath, JsonSerializer.Serialize(tokens));
    }
}
