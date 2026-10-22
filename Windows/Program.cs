using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using Microsoft.Win32;

namespace Couchpad;

/// <summary>Tray-only app: starts the server and shows status, pairing code and settings.</summary>
static class Program
{
    const int Port = 48123;
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    static NotifyIcon tray = null!;
    static ToolStripMenuItem statusItem = null!;
    static ToolStripMenuItem codeItem = null!;
    static ToolStripMenuItem addressItem = null!;
    static ToolStripMenuItem startupItem = null!;
    static ToolStripMenuItem forgetItem = null!;
    static Server server = null!;
    static PairingForm? pairingForm;

    [STAThread]
    static void Main()
    {
        using var single = new Mutex(true, "Couchpad.SingleInstance", out var first);
        if (!first) return;

        ApplicationConfiguration.Initialize();

        var menu = new ContextMenuStrip();
        statusItem = new ToolStripMenuItem("Starting…") { Enabled = false };
        codeItem = new ToolStripMenuItem("Pair an iPhone…", null, (_, _) => ShowCode());
        addressItem = new ToolStripMenuItem("Address") { Enabled = false };
        startupItem = new ToolStripMenuItem("Start with Windows", null, (_, _) => ToggleStartup()) { CheckOnClick = false };
        forgetItem = new ToolStripMenuItem("Forget paired iPhones…", null, (_, _) => ForgetPhones());
        menu.Items.Add(statusItem);
        menu.Items.Add(codeItem);
        menu.Items.Add(addressItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(startupItem);
        menu.Items.Add(forgetItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Quit Couchpad", null, (_, _) => Application.Exit()));
        menu.Opening += (_, _) => Refresh();

        tray = new NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "Couchpad",
            ContextMenuStrip = menu,
            Visible = true,
        };
        tray.DoubleClick += (_, _) => ShowCode();

        server = new Server(Port, () => SafeInvoke(Refresh));
        server.Start();
        Refresh();

        Application.ApplicationExit += (_, _) =>
        {
            Injector.ReleaseAll();
            server.Stop();
            tray.Visible = false;
        };
        Application.Run();
    }

    static Icon LoadIcon()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Couchpad.AppIcon.ico");
        return stream != null ? new Icon(stream) : SystemIcons.Application;
    }

    static void SafeInvoke(Action action)
    {
        if (tray.ContextMenuStrip is { IsHandleCreated: true } menu) menu.BeginInvoke(action);
        else action();
    }

    static void Refresh()
    {
        statusItem.Text = server.Status;
        addressItem.Text = $"Address: {LocalIPv4() ?? "?"}:{Port}";
        startupItem.Checked = IsStartupEnabled();
        forgetItem.Enabled = Pairing.PairedCount > 0;
        tray.Text = $"Couchpad — {server.Status}";
    }

    static void ShowCode()
    {
        pairingForm ??= new PairingForm(PairingPayload);
        pairingForm.ShowPairing();
    }

    static string PairingPayload() => PairingUrl.Make(Environment.MachineName, LocalIPv4(), Port, Pairing.Code);

    static void ForgetPhones()
    {
        var answer = MessageBox.Show("Forget all paired iPhones?\n\nEvery phone will need the pairing code again.",
            "Couchpad", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
        if (answer != DialogResult.OK) return;
        Pairing.ForgetAll();
        server.DisconnectAll();
        Refresh();
    }

    static bool IsStartupEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue("Couchpad") is string;
    }

    static void ToggleStartup()
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (IsStartupEnabled()) key.DeleteValue("Couchpad", false);
        else key.SetValue("Couchpad", $"\"{Environment.ProcessPath}\"");
        Refresh();
    }

    static string? LocalIPv4()
    {
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var addr in nic.GetIPProperties().UnicastAddresses)
            {
                if (addr.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(addr.Address))
                    return addr.Address.ToString();
            }
        }
        return null;
    }
}
