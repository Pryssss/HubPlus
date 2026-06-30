using System.IO;
using System.Windows;
using HubPlusWin.Core;
using Drawing = System.Drawing;
using WinForms = System.Windows.Forms;

namespace HubPlusWin;

public partial class App : System.Windows.Application
{
    private readonly HubStore _store = new();
    private WinForms.NotifyIcon? _tray;
    private PanelWindow? _panel;

    private void OnStartup(object sender, StartupEventArgs e)
    {
        _store.Start();
        _panel = new PanelWindow(_store);
        SetupTray();
        _store.Changed += UpdateTray;
        UpdateTray();
    }

    private void SetupTray()
    {
        _tray = new WinForms.NotifyIcon
        {
            Icon = LoadIcon(),
            Visible = true,
            Text = "Hub+"
        };
        _tray.MouseClick += (_, ev) =>
        {
            if (ev.Button == WinForms.MouseButtons.Left) TogglePanel();
        };

        var menu = new WinForms.ContextMenuStrip();
        menu.Items.Add("Open Hub+", null, (_, _) => ShowPanel());
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("Quit Hub+", null, (_, _) => Quit());
        _tray.ContextMenuStrip = menu;
    }

    private static Drawing.Icon LoadIcon()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Assets", "icon.ico");
            if (File.Exists(path)) return new Drawing.Icon(path);
        }
        catch { }
        return Drawing.SystemIcons.Application;
    }

    private void TogglePanel()
    {
        if (_panel == null) return;
        if (_panel.IsVisible) _panel.Hide();
        else ShowPanel();
    }

    private void ShowPanel() => _panel?.ShowPanel();

    private void UpdateTray()
    {
        if (_tray == null) return;
        var (text, _) = _store.CompactBadge();
        _tray.Text = string.IsNullOrEmpty(text) ? "Hub+" : $"Hub+ — {text}";
    }

    private void Quit()
    {
        if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
        Shutdown();
    }

    private void OnExit(object sender, ExitEventArgs e)
    {
        if (_tray != null) { _tray.Visible = false; _tray.Dispose(); }
    }
}
