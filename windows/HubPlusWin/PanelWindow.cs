using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using HubPlusWin.Core;

// UseWindowsForms + ImplicitUsings inject `global using System.Drawing/System.Windows.Forms;`,
// whose Brush/Brushes/Color/FontFamily/HorizontalAlignment/Orientation collide with WPF's.
// Using-aliases outrank global usings, pinning the WPF types for this file.
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using FontFamily = System.Windows.Media.FontFamily;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Orientation = System.Windows.Controls.Orientation;

namespace HubPlusWin;

/// Floating always-on-top panel (the Windows analog of the macOS notch island):
/// a dark rounded card listing live sessions + usage. Toggled from the tray.
public class PanelWindow : Window
{
    private readonly HubStore _store;
    private readonly StackPanel _content;

    private static readonly Brush Bg = new SolidColorBrush(Color.FromRgb(0x0E, 0x0E, 0x12));
    private static readonly Brush White = Brushes.White;
    private static readonly Brush Secondary = new SolidColorBrush(Color.FromRgb(0x9A, 0x9A, 0xA2));
    private static readonly Brush Orange = new SolidColorBrush(Color.FromRgb(0xFF, 0x9E, 0x2C));
    private static readonly Color Green = Color.FromRgb(0x35, 0xC7, 0x59);
    private static readonly Color Amber = Color.FromRgb(0xFA, 0xC7, 0x40);
    private static readonly Color Red = Color.FromRgb(0xFF, 0x4D, 0x4D);
    private static readonly Color Gray = Color.FromRgb(0x8A, 0x8A, 0x90);

    public PanelWindow(HubStore store)
    {
        _store = store;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Width = 560;
        SizeToContent = SizeToContent.Height;

        _content = new StackPanel { Margin = new Thickness(14) };
        Content = new Border
        {
            Background = Bg,
            CornerRadius = new CornerRadius(18),
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x18, 0xFF, 0xFF, 0xFF)),
            BorderThickness = new Thickness(1),
            Child = _content
        };

        MouseLeftButtonDown += (_, _) => { try { DragMove(); } catch { } };
        store.Changed += Rebuild;
        Rebuild();
        Hide();
    }

    public void ShowPanel()
    {
        var wa = SystemParameters.WorkArea;
        Left = wa.Left + (wa.Width - Width) / 2;
        Top = wa.Top + 8;
        Show();
        Activate();
    }

    private void Rebuild()
    {
        _content.Children.Clear();
        _content.Children.Add(Header());
        _content.Children.Add(Divider());
        _content.Children.Add(UsageView());
        _content.Children.Add(Divider());

        if (_store.Rows.Count == 0)
        {
            _content.Children.Add(new TextBlock
            {
                Text = "No live Claude Code sessions",
                Foreground = Secondary,
                FontSize = 12,
                HorizontalAlignment = HorizontalAlignment.Center,
                Margin = new Thickness(0, 14, 0, 14)
            });
            return;
        }

        for (int i = 0; i < _store.Rows.Count; i++)
        {
            _content.Children.Add(Card(_store.Rows[i]));
            if (i < _store.Rows.Count - 1) _content.Children.Add(Divider());
        }
    }

    private UIElement Header()
    {
        var dock = new DockPanel { Margin = new Thickness(0, 0, 0, 7) };

        var left = new StackPanel { Orientation = Orientation.Horizontal };
        left.Children.Add(new TextBlock { Text = "✳", Foreground = Orange, FontSize = 14, Margin = new Thickness(0, 0, 8, 0) });
        left.Children.Add(new TextBlock
        {
            Text = $"{_store.Rows.Count} agent{(_store.Rows.Count == 1 ? "" : "s")}",
            Foreground = White, FontSize = 14, FontWeight = FontWeights.SemiBold
        });
        DockPanel.SetDock(left, Dock.Left);
        dock.Children.Add(left);

        if (_store.TokensToday is long today)
        {
            dock.Children.Add(new TextBlock
            {
                Text = (today >= 1000 ? today / 1000 + "k" : today.ToString()) + " today",
                Foreground = Secondary, FontSize = 11, HorizontalAlignment = HorizontalAlignment.Right
            });
        }
        return dock;
    }

    private UIElement UsageView()
    {
        var panel = new StackPanel { Margin = new Thickness(0, 6, 0, 6) };
        switch (_store.Usage.State)
        {
            case UsageState.AuthError:
                panel.Children.Add(Note("re-auth in terminal (run `claude`)"));
                break;
            case UsageState.Unavailable:
                panel.Children.Add(Note("usage unavailable"));
                break;
            default:
                panel.Children.Add(UsageRow("Claude", "5h", _store.Usage.FiveHour));
                panel.Children.Add(UsageRow("", "7d", _store.Usage.SevenDay));
                break;
        }
        return panel;
    }

    private TextBlock Note(string text) =>
        new() { Text = text, Foreground = Orange, FontSize = 11 };

    private UIElement UsageRow(string head, string label, UsageWindow? w)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
        row.Children.Add(new TextBlock { Text = head, Foreground = White, FontSize = 12, Width = 56, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock { Text = label, Foreground = Secondary, FontSize = 11, Width = 22, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(Meter(w?.FractionLeft ?? 0, w == null ? Gray : BarColor(w.Utilization)));
        if (w != null)
        {
            row.Children.Add(Inline($"  {w.PercentLeft}% left", Secondary));
            if (w.ResetsAt is DateTime d && d > DateTime.Now)
                row.Children.Add(Inline($"  · resets {ResetLabel(d)}", Secondary));
        }
        else row.Children.Add(Inline("  —", Secondary));
        return row;
    }

    private TextBlock Inline(string text, Brush fg) =>
        new() { Text = text, Foreground = fg, FontSize = 11, VerticalAlignment = VerticalAlignment.Center };

    private UIElement Meter(double fraction, Color color)
    {
        var grid = new Grid { Width = 110, Height = 6, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(new Border { CornerRadius = new CornerRadius(3), Background = new SolidColorBrush(Color.FromArgb(0x20, 0xFF, 0xFF, 0xFF)) });
        grid.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(3),
            Background = new SolidColorBrush(color),
            Width = 110 * Math.Max(0, Math.Min(1, fraction)),
            HorizontalAlignment = HorizontalAlignment.Left
        });
        return grid;
    }

    private UIElement Card(AgentSession r)
    {
        var v = new StackPanel { Margin = new Thickness(0, 6, 0, 6) };

        var meta = new DockPanel();

        var leftCluster = new StackPanel { Orientation = Orientation.Horizontal };
        leftCluster.Children.Add(new Ellipse { Width = 7, Height = 7, Fill = new SolidColorBrush(StatusColor(r.Info.Kind)), VerticalAlignment = VerticalAlignment.Center });
        leftCluster.Children.Add(new TextBlock { Text = r.Title, Foreground = White, FontSize = 12, FontWeight = FontWeights.SemiBold, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        if (!string.IsNullOrEmpty(r.Branch))
            leftCluster.Children.Add(new TextBlock { Text = $"  ⎇ {r.Branch}{(r.Dirty ? " •" : "")}", Foreground = Secondary, FontSize = 11, FontFamily = new FontFamily("Consolas"), VerticalAlignment = VerticalAlignment.Center });
        DockPanel.SetDock(leftCluster, Dock.Left);
        meta.Children.Add(leftCluster);

        var rightCluster = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        rightCluster.Children.Add(Capsule(StatusLabel(r.Info.Kind), StatusColor(r.Info.Kind), true));
        if (r.ModelShort != "—") rightCluster.Children.Add(Capsule(r.ModelShort, Gray, false));
        if (r.ContextPercent is double pct) rightCluster.Children.Add(Capsule($"{(int)(pct * 100)}%", ContextColor(pct), false));
        rightCluster.Children.Add(new TextBlock { Text = "  " + r.AgeString, Foreground = Secondary, FontSize = 10, VerticalAlignment = VerticalAlignment.Center });
        meta.Children.Add(rightCluster);

        v.Children.Add(meta);

        if (!string.IsNullOrEmpty(r.LastText))
            v.Children.Add(new TextBlock
            {
                Text = r.LastText,
                Foreground = new SolidColorBrush(Color.FromArgb(0xB0, 0xFF, 0xFF, 0xFF)),
                FontSize = 11,
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.NoWrap,
                Margin = new Thickness(0, 4, 0, 0)
            });
        return v;
    }

    private UIElement Capsule(string text, Color color, bool prominent)
    {
        return new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Color.FromArgb((byte)(prominent ? 0x28 : 0x18), color.R, color.G, color.B)),
            Padding = new Thickness(7, 2, 7, 2),
            Margin = new Thickness(4, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = text, FontSize = 9, FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(prominent ? color : Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF))
            }
        };
    }

    private UIElement Divider() =>
        new Border { Height = 1, Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF)), Margin = new Thickness(0, 4, 0, 4) };

    private static Color StatusColor(StatusKind k) => k switch
    {
        StatusKind.Idle => Green,
        StatusKind.Busy => Amber,
        StatusKind.Waiting => Red,
        StatusKind.Error => Red,
        _ => Gray
    };

    private static string StatusLabel(StatusKind k) => k switch
    {
        StatusKind.Idle => "IDLE",
        StatusKind.Busy => "BUSY",
        StatusKind.Waiting => "WAITING",
        StatusKind.Error => "ERROR",
        _ => "—"
    };

    private static Color BarColor(double util) => util >= 90 ? Red : (util >= 70 ? Amber : Green);
    private static Color ContextColor(double pct) => pct >= 0.9 ? Red : (pct >= 0.75 ? Amber : Gray);
    private static string ResetLabel(DateTime d) =>
        (d.Date == DateTime.Today || (d - DateTime.Now).TotalHours < 12) ? d.ToString("h:mm tt") : d.ToString("MMM d");
}
