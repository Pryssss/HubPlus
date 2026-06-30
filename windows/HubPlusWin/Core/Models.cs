using System.Text.Json.Serialization;

namespace HubPlusWin.Core;

public enum StatusKind { Idle, Busy, Waiting, Error, Unknown }

/// One entry of ~/.claude/sessions/<pid>.json
public class SessionInfo
{
    [JsonPropertyName("pid")] public int Pid { get; set; }
    [JsonPropertyName("sessionId")] public string SessionId { get; set; } = "";
    [JsonPropertyName("cwd")] public string Cwd { get; set; } = "";
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }
    [JsonPropertyName("updatedAt")] public double? UpdatedAt { get; set; }
    [JsonPropertyName("statusUpdatedAt")] public double? StatusUpdatedAt { get; set; }

    public bool IsAlive()
    {
        try
        {
            using var p = System.Diagnostics.Process.GetProcessById(Pid);
            if (p.HasExited) return false;
            try
            {
                // Guard against PID reuse: a Claude Code session runs as node/claude.
                var name = p.ProcessName.ToLowerInvariant();
                if (name.Length > 0 && !name.Contains("node") && !name.Contains("claude")) return false;
            }
            catch { /* name not readable — assume it's still our session */ }
            return true;
        }
        catch { return false; }
    }

    public StatusKind Kind => (Status ?? "").ToLowerInvariant() switch
    {
        "idle" => StatusKind.Idle,
        "busy" or "running" or "active" => StatusKind.Busy,
        "waiting" or "waiting-approval" or "blocked" or "needs-input" => StatusKind.Waiting,
        "error" or "failed" => StatusKind.Error,
        _ => StatusKind.Unknown
    };
}

/// Merged per-session view model (registry + transcript + git).
public class AgentSession
{
    public SessionInfo Info { get; set; } = new();
    public string? LastText { get; set; }
    public string? Model { get; set; }
    public long? ContextTokens { get; set; }
    public string? EffectiveCwd { get; set; }
    public string? Branch { get; set; }
    public string? RepoName { get; set; }
    public bool Dirty { get; set; }
    public DateTime? UpdatedAt { get; set; }

    public string Title
    {
        get
        {
            if (!string.IsNullOrEmpty(RepoName)) return RepoName!;
            var cwd = (EffectiveCwd ?? Info.Cwd).TrimEnd('\\', '/');
            var name = System.IO.Path.GetFileName(cwd);
            return string.IsNullOrEmpty(name) ? cwd : name;
        }
    }

    public long ContextWindow
    {
        get
        {
            var m = (Model ?? "").ToLowerInvariant();
            if (m.Contains("[1m]") || m.Contains("-1m")) return 1_000_000;
            // Heuristic: a session can't exceed a 200k window without being on the 1M tier.
            return (ContextTokens ?? 0) > 200_000 ? 1_000_000 : 200_000;
        }
    }

    public double? ContextPercent =>
        ContextTokens is long t && ContextWindow > 0
            ? Math.Min(1.0, (double)t / ContextWindow)
            : null;

    public string ModelShort => ModelCatalog.Short(Model);

    public string AgeString
    {
        get
        {
            var ms = Info.UpdatedAt ?? Info.StatusUpdatedAt;
            if (ms is not double m) return "";
            var date = DateTimeOffset.FromUnixTimeMilliseconds((long)m).LocalDateTime;
            var span = DateTime.Now - date;
            if (span.TotalSeconds < 5) return "now";
            if (span.TotalMinutes < 1) return $"{(int)span.TotalSeconds}s ago";
            if (span.TotalHours < 1) return $"{(int)span.TotalMinutes}m ago";
            if (span.TotalDays < 1) return $"{(int)span.TotalHours}h ago";
            return $"{(int)span.TotalDays}d ago";
        }
    }
}

public static class ModelCatalog
{
    public static string Short(string? m)
    {
        if (m == null) return "—";
        var x = m.ToLowerInvariant();
        if (x.Contains("opus-4-8")) return "Opus 4.8";
        if (x.Contains("opus")) return "Opus";
        if (x.Contains("sonnet-4-6")) return "Sonnet 4.6";
        if (x.Contains("sonnet")) return "Sonnet";
        if (x.Contains("haiku")) return "Haiku";
        return m;
    }
}

public enum UsageState { Loading, Ok, AuthError, Unavailable }

public class UsageWindow
{
    public double Utilization { get; set; }   // percent used, 0..100
    public DateTime? ResetsAt { get; set; }

    public int PercentLeft => Math.Max(0, Math.Min(100, (int)Math.Round(100 - Utilization)));
    public double FractionLeft => Math.Max(0, Math.Min(1, (100 - Utilization) / 100.0));
}

public class UsageSnapshot
{
    public UsageWindow? FiveHour { get; set; }
    public UsageWindow? SevenDay { get; set; }
    public UsageState State { get; set; } = UsageState.Loading;
}
