using System.Text.Json;

namespace CouchControl;

/// <summary>
/// Phones must pair once with the 6-digit code shown in the tray menu. A successful pairing
/// hands the phone a random token it presents on every later connection.
/// </summary>
static class Pairing
{
    static readonly object Gate = new();
    static readonly string TokensPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Couchpad", "tokens.json");
    static HashSet<string> tokens = Load();

    public static string Code { get; private set; } = MakeCode();

    public static int PairedCount { get { lock (Gate) return tokens.Count; } }

    /// <summary>Returns a token when <paramref name="credential"/> is the current code or an existing token.</summary>
    public static string? Authenticate(string credential)
    {
        lock (Gate)
        {
            if (tokens.Contains(credential)) return credential;
            if (credential != Code) return null;
            var token = Guid.NewGuid().ToString("D").ToUpperInvariant();
            tokens.Add(token);
            Save();
            Code = MakeCode();
            return token;
        }
    }

    public static void ForgetAll()
    {
        lock (Gate)
        {
            tokens.Clear();
            Save();
            Code = MakeCode();
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
