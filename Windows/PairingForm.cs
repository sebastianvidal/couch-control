using QRCoder;

namespace CouchControl;

/// <summary>Small window with the pairing QR code and the digits under it.</summary>
sealed class PairingForm : Form
{
    readonly PictureBox picture = new() { SizeMode = PictureBoxSizeMode.Zoom, Dock = DockStyle.Top, Height = 260 };
    readonly Label codeLabel = new() { Dock = DockStyle.Top, Height = 50, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Consolas", 26, FontStyle.Bold) };
    readonly Label hint = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = SystemColors.GrayText, Padding = new Padding(12, 0, 12, 8) };

    public PairingForm()
    {
        Text = "Pair with Couchpad";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        ClientSize = new Size(300, 400);
        hint.Text = "Scan with Couchpad on your iPhone (or with the Camera app), or type the code. It changes after each pairing.";
        Controls.Add(hint);
        Controls.Add(codeLabel);
        Controls.Add(picture);
        FormClosing += (_, e) => { e.Cancel = true; Hide(); }; // keep it around, just hide
    }

    public void Update(string payload, string code)
    {
        codeLabel.Text = code;
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M);
        var png = new PngByteQRCode(data).GetGraphic(8);
        picture.Image?.Dispose();
        picture.Image = Image.FromStream(new MemoryStream(png));
    }
}

static class PairingUrl
{
    /// <summary>couchctl://pair?name=&lt;host&gt;&amp;addr=&lt;ip&gt;&amp;port=48123&amp;code=&lt;6 digits&gt;</summary>
    public static string Make(string name, string? address, int port, string code) =>
        $"couchctl://pair?name={Uri.EscapeDataString(name)}&addr={Uri.EscapeDataString(address ?? "")}&port={port}&code={code}";
}
