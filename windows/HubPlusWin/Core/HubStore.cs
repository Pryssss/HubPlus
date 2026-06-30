using System.Windows.Threading;

namespace HubPlusWin.Core;

/// Aggregates monitor data and raises Changed on the UI thread. Sessions/git/
/// transcripts refresh on a short timer; usage polls every 60s (the endpoint
/// rate-limits) and keeps the last-good value on a transient failure.
public class HubStore
{
    public List<AgentSession> Rows { get; private set; } = new();
    public UsageSnapshot Usage { get; private set; } = new();
    public long? TokensToday { get; private set; }

    public event Action? Changed;

    private DispatcherTimer? _timer;
    private DispatcherTimer? _usageTimer;
    private int _usageFails;

    public void Start()
    {
        Refresh();
        RefreshUsage();

        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();

        _usageTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) };
        _usageTimer.Tick += (_, _) => RefreshUsage();
        _usageTimer.Start();
    }

    public void Refresh()
    {
        Task.Run(() =>
        {
            var rows = new List<AgentSession>();
            foreach (var s in SessionWatcher.ReadLive())
            {
                var row = new AgentSession { Info = s };
                TranscriptReader.Fill(row);
                GitProbe.Fill(row);
                rows.Add(row);
            }
            var today = StatsCache.TokensToday();
            Dispatch(() =>
            {
                Rows = rows;
                TokensToday = today;
                Changed?.Invoke();
            });
        });
    }

    public void RefreshUsage()
    {
        Task.Run(async () =>
        {
            var (result, snapshot) = await UsageClient.Fetch();
            Dispatch(() =>
            {
                switch (result)
                {
                    case UsageResult.Ok:
                        _usageFails = 0;
                        Usage = snapshot!;
                        break;
                    case UsageResult.AuthError:
                        _usageFails = 0;
                        Usage = new UsageSnapshot { State = UsageState.AuthError };
                        break;
                    case UsageResult.Transient:
                        if (Usage.State != UsageState.Ok && ++_usageFails >= 2)
                            Usage = new UsageSnapshot { State = UsageState.Unavailable };
                        break;
                }
                Changed?.Invoke();
            });
        });
    }

    /// Menu-bar style badge: attention first, then near-limit, else agent count.
    public (string text, bool alert) CompactBadge()
    {
        if (Rows.Exists(r => r.Info.Kind == StatusKind.Waiting)) return ("waiting", true);
        if (Usage.State == UsageState.Ok)
        {
            var windows = new List<(string label, int left)>();
            if (Usage.FiveHour != null) windows.Add(("5h", Usage.FiveHour.PercentLeft));
            if (Usage.SevenDay != null) windows.Add(("7d", Usage.SevenDay.PercentLeft));
            if (windows.Count > 0)
            {
                var tight = windows.OrderBy(w => w.left).First();
                if (tight.left <= 15) return ($"{tight.label} {tight.left}%", true);
            }
        }
        return Rows.Count == 0 ? ("", false) : ($"{Rows.Count}", false);
    }

    private static void Dispatch(Action action)
    {
        var app = System.Windows.Application.Current;
        if (app == null) return;
        if (app.Dispatcher.CheckAccess()) action();
        else app.Dispatcher.BeginInvoke(action);
    }
}
