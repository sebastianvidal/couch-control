using System.Net;
using System.Net.Sockets;
using System.Text;
using Makaretu.Dns;

namespace Couchpad;

/// <summary>
/// TCP listener advertised over Bonjour (mDNS). The first line from a phone must be
/// <c>hello &lt;code-or-token&gt;</c>; we answer <c>ok &lt;token&gt; windows</c> or <c>nope</c>.
/// After that each line is one input command (see Injector.Handle).
/// </summary>
sealed class Server
{
    readonly int port;
    readonly Action onChange;
    readonly TcpListener listener;
    readonly HashSet<TcpClient> clients = new();
    readonly HashSet<TcpClient> authenticated = new();
    readonly object gate = new();
    ServiceDiscovery? discovery;
    CancellationTokenSource cts = new();

    public string Status { get; private set; } = "Starting…";

    public Server(int port, Action onChange)
    {
        this.port = port;
        this.onChange = onChange;
        listener = new TcpListener(IPAddress.Any, port);
    }

    public void Start()
    {
        try
        {
            listener.Start();
        }
        catch (SocketException e)
        {
            Set($"Could not listen on port {port}: {e.Message}");
            return;
        }

        try
        {
            discovery = new ServiceDiscovery();
            discovery.Advertise(new ServiceProfile(Environment.MachineName, "_couchpad._tcp", (ushort)port));
        }
        catch (Exception e)
        {
            // The phone can still connect by IP address.
            Set($"Bonjour failed ({e.Message}); use the address below");
        }

        _ = AcceptLoop(cts.Token);
        Report();
    }

    public void Stop()
    {
        cts.Cancel();
        discovery?.Dispose();
        listener.Stop();
        DisconnectAll();
    }

    /// <summary>Drops every phone; they will have to pair again.</summary>
    public void DisconnectAll()
    {
        List<TcpClient> all;
        lock (gate) all = clients.ToList();
        foreach (var c in all) Drop(c);
    }

    async Task AcceptLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(token); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { continue; }

            client.NoDelay = true;
            lock (gate) clients.Add(client);
            _ = Serve(client, token);
        }
    }

    async Task Serve(TcpClient client, CancellationToken token)
    {
        try
        {
            using var stream = client.GetStream();
            using var reader = new StreamReader(stream, new UTF8Encoding(false));
            var isAuthenticated = false;
            while (!token.IsCancellationRequested)
            {
                var line = await reader.ReadLineAsync(token);
                if (line == null) break;

                if (isAuthenticated)
                {
                    Injector.Handle(line);
                    continue;
                }

                // Input that arrives before the handshake (queued on the phone while its socket
                // was reconnecting) is dropped, not refused: "nope" is only for a bad hello,
                // because the phone treats it as "this host forgot me" and discards its token.
                if (!line.StartsWith("hello ", StringComparison.Ordinal)) continue;
                var issued = Pairing.Authenticate(line[6..].Trim());
                if (issued != null)
                {
                    isAuthenticated = true;
                    lock (gate) authenticated.Add(client);
                    await Send(stream, $"ok {issued} windows");
                    Report();
                }
                else
                {
                    await Send(stream, "nope");
                }
            }
        }
        catch (Exception) { /* connection went away */ }
        finally { Drop(client); }
    }

    static Task Send(NetworkStream stream, string line) =>
        stream.WriteAsync(Encoding.UTF8.GetBytes(line + "\n")).AsTask();

    void Drop(TcpClient client)
    {
        bool wasAuthenticated;
        lock (gate)
        {
            if (!clients.Remove(client)) return;
            wasAuthenticated = authenticated.Remove(client);
        }
        try { client.Close(); } catch (Exception) { }
        // Never leave a key or mouse button stuck down when the phone goes away.
        if (wasAuthenticated) Injector.ReleaseAll();
        Report();
    }

    void Report()
    {
        int n;
        lock (gate) n = authenticated.Count;
        Set(n == 0 ? "Waiting for iPhone…" : n == 1 ? "1 iPhone connected" : $"{n} iPhones connected");
    }

    void Set(string status)
    {
        Status = status;
        onChange();
    }
}
