using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using Microsoft.Win32;

namespace CouchControl;

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

    [STAThread]
    static void Main()
    {
        using var single = new Mutex(true, "CouchControl.SingleInstance", out var first);
        if (!first) return;

        ApplicationConfiguration.Initialize();

        var menu = new ContextMenuStrip();
        statusItem = new ToolStripMenuItem("Starting…") { Enabled = false };
        codeItem = new ToolStripMenuItem("Pairing code", null, (_, _) => ShowCode());
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
        menu.Items.Add(new ToolStripMenuItem("Quit Couch Control", null, (_, _) => Application.Exit()));
        menu.Opening += (_, _) => Refresh();

        tray = new NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "Couch Control",
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
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("CouchControl.AppIcon.ico");
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
        codeItem.Text = $"Pairing code: {Pairing.Code}";
        addressItem.Text = $"Address: {LocalIPv4() ?? "?"}:{Port}";
        startupItem.Checked = IsStartupEnabled();
        forgetItem.Enabled = Pairing.PairedCount > 0;
        tray.Text = $"Couch Control — {server.Status}";
    }

    static void ShowCode()
    {
        MessageBox.Show(
            $"{Pairing.Code}\n\nEnter this code in Couch Control on your iPhone. It changes after each pairing.",
            "Couch Control pairing code", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    static void ForgetPhones()
    {
        var answer = MessageBox.Show("Forget all paired iPhones?\n\nEvery phone will need the pairing code again.",
            "Couch Control", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
        if (answer != DialogResult.OK) return;
        Pairing.ForgetAll();
        server.DisconnectAll();
        Refresh();
    }

    static bool IsStartupEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue("CouchControl") is string;
    }

    static void ToggleStartup()
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (IsStartupEnabled()) key.DeleteValue("CouchControl", false);
        else key.SetValue("CouchControl", $"\"{Environment.ProcessPath}\"");
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
