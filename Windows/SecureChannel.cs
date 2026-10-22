using System.Security.Cryptography;
using System.Text;

namespace Couchpad;

/// <summary>
/// Couchpad wire protocol v2, matching Shared/SecureChannel.swift byte for byte:
/// P-256 ECDH, HKDF-SHA256 session key, AES-256-GCM frames (4-byte big-endian length, then
/// ciphertext ‖ 16-byte tag; nonce = direction byte ‖ 3 zero bytes ‖ 64-bit big-endian
/// counter; AAD = direction byte), and HMAC-SHA256 proofs over the handshake transcript.
/// </summary>
static class SecureChannel
{
    static readonly byte[] SessionInfo = Encoding.UTF8.GetBytes("couchpad v2 session");
    public static readonly byte[] ClientTag = Encoding.UTF8.GetBytes("client");
    public static readonly byte[] HostTag = Encoding.UTF8.GetBytes("host");
    public const int MaxFrame = 64 * 1024;

    /// <summary>Raw 64-byte X‖Y public key, the format CryptoKit's rawRepresentation uses.</summary>
    public static byte[] RawPublicKey(ECDiffieHellman key)
    {
        var p = key.ExportParameters(false);
        return p.Q.X!.Concat(p.Q.Y!).ToArray();
    }

    public static byte[] SessionKey(ECDiffieHellman privateKey, byte[] peerRawPublicKey, byte[] nonce)
    {
        if (peerRawPublicKey.Length != 64) throw new CryptographicException("bad public key");
        using var peer = ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = peerRawPublicKey[..32], Y = peerRawPublicKey[32..] },
        });
        var shared = privateKey.DeriveRawSecretAgreement(peer.PublicKey);
        return HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, nonce, SessionInfo);
    }

    public static byte[] Transcript(byte[] clientKey, byte[] hostKey, byte[] nonce) =>
        clientKey.Concat(hostKey).Concat(nonce).ToArray();

    public static byte[] Proof(string secret, byte[] transcript, byte[] side) =>
        HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), transcript.Concat(side).ToArray());

    public static bool ProofMatches(byte[] proof, string secret, byte[] transcript, byte[] side) =>
        CryptographicOperations.FixedTimeEquals(Proof(secret, transcript, side), proof);
}

/// <summary>Encrypts or decrypts frames for one direction of one session.</summary>
sealed class FrameCipher : IDisposable
{
    readonly AesGcm aes;
    readonly byte direction;
    ulong counter;

    /// <param name="direction">0 for client→host, 1 for host→client.</param>
    public FrameCipher(byte[] key, byte direction)
    {
        aes = new AesGcm(key, 16);
        this.direction = direction;
    }

    byte[] Nonce(ulong n)
    {
        var nonce = new byte[12];
        nonce[0] = direction;
        for (var i = 0; i < 8; i++) nonce[4 + i] = (byte)(n >> (8 * (7 - i)));
        return nonce;
    }

    /// <summary>A full frame: 4-byte length prefix, then ciphertext ‖ tag.</summary>
    public byte[] Seal(string line)
    {
        var plain = Encoding.UTF8.GetBytes(line);
        var cipher = new byte[plain.Length];
        var tag = new byte[16];
        aes.Encrypt(Nonce(counter++), plain, cipher, tag, new[] { direction });
        var frame = new byte[4 + cipher.Length + 16];
        var len = cipher.Length + 16;
        frame[0] = (byte)(len >> 24); frame[1] = (byte)(len >> 16); frame[2] = (byte)(len >> 8); frame[3] = (byte)len;
        cipher.CopyTo(frame, 4);
        tag.CopyTo(frame, 4 + cipher.Length);
        return frame;
    }

    /// <summary>Decrypts one frame body (without the length prefix). Throws on tampering or reordering.</summary>
    public string Open(ReadOnlySpan<byte> body)
    {
        if (body.Length < 16) throw new CryptographicException("short frame");
        var plain = new byte[body.Length - 16];
        aes.Decrypt(Nonce(counter), body[..^16], body[^16..], plain, new[] { direction });
        counter++;
        return Encoding.UTF8.GetString(plain);
    }

    public void Dispose() => aes.Dispose();
}

/// <summary>Accumulates bytes and yields handshake lines, then complete frame bodies.</summary>
sealed class FrameBuffer
{
    readonly List<byte> data = new();

    public void Append(ReadOnlySpan<byte> bytes) => data.AddRange(bytes.ToArray());

    public string? NextLine()
    {
        var i = data.IndexOf((byte)'\n');
        if (i < 0) return null;
        var line = Encoding.UTF8.GetString(data.GetRange(0, i).ToArray());
        data.RemoveRange(0, i + 1);
        return line;
    }

    public byte[]? NextFrame()
    {
        if (data.Count < 4) return null;
        var len = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
        if (len < 0 || len > SecureChannel.MaxFrame) throw new CryptographicException("frame too large");
        if (data.Count < 4 + len) return null;
        var body = data.GetRange(4, len).ToArray();
        data.RemoveRange(0, 4 + len);
        return body;
    }
}
