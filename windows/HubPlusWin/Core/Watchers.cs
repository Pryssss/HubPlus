using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace HubPlusWin.Core;

public static class SessionWatcher
{
    public static List<SessionInfo> ReadLive()
    {
        var result = new List<SessionInfo>();
        if (!Directory.Exists(ClaudePaths.SessionsDir)) return result;

        foreach (var file in Directory.GetFiles(ClaudePaths.SessionsDir, "*.json"))
        {
            try
            {
                var info = JsonSerializer.Deserialize<SessionInfo>(File.ReadAllText(file));
                if (info != null && !string.IsNullOrEmpty(info.SessionId) && info.IsAlive())
                    result.Add(info);
            }
            catch { /* skip malformed / locked */ }
        }
        return result.OrderByDescending(s => s.UpdatedAt ?? 0).ToList();
    }
}

/// Reads the tail of a session's JSONL transcript: last assistant message, model,
/// context tokens, and the effective cwd (where the agent is actually working).
public static class TranscriptReader
{
    public static void Fill(AgentSession row)
    {
        var path = ClaudePaths.TranscriptPath(row.Info.Cwd, row.Info.SessionId);
        if (!File.Exists(path)) return;

        string text;
        try { text = TailText(path, 256 * 1024); } catch { return; }

        foreach (var line in text.Split('\n'))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonDocument doc;
            try { doc = JsonDocument.Parse(line); } catch { continue; }
            using (doc)
            {
                var root = doc.RootElement;
                if (root.ValueKind != JsonValueKind.Object) continue;

                if (root.TryGetProperty("cwd", out var c) && c.ValueKind == JsonValueKind.String)
                {
                    var cw = c.GetString();
                    if (!string.IsNullOrEmpty(cw)) row.EffectiveCwd = cw;
                }
                if (root.TryGetProperty("timestamp", out var ts) && ts.ValueKind == JsonValueKind.String
                    && DateTime.TryParse(ts.GetString(), out var d))
                    row.UpdatedAt = d;

                if (!root.TryGetProperty("type", out var type) || type.GetString() != "assistant") continue;
                if (!root.TryGetProperty("message", out var msg) || msg.ValueKind != JsonValueKind.Object) continue;

                if (msg.TryGetProperty("model", out var model) && model.ValueKind == JsonValueKind.String)
                    row.Model = model.GetString();

                if (msg.TryGetProperty("usage", out var usage) && usage.ValueKind == JsonValueKind.Object)
                {
                    long sum = 0;
                    foreach (var key in new[] { "input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens" })
                        if (usage.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n))
                            sum += n;
                    row.ContextTokens = sum;
                }

                if (msg.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
                {
                    var parts = new List<string>();
                    foreach (var block in content.EnumerateArray())
                        if (block.ValueKind == JsonValueKind.Object
                            && block.TryGetProperty("type", out var bt) && bt.GetString() == "text"
                            && block.TryGetProperty("text", out var txt) && txt.ValueKind == JsonValueKind.String)
                            parts.Add(txt.GetString() ?? "");
                    var joined = string.Join(" ", parts).Trim();
                    if (joined.Length > 0) row.LastText = Sanitize(joined);
                }
            }
        }
    }

    static string TailText(string path, int maxBytes)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        if (fs.Length > maxBytes) fs.Seek(fs.Length - maxBytes, SeekOrigin.Begin);
        using var sr = new StreamReader(fs, Encoding.UTF8);
        return sr.ReadToEnd();
    }

    /// Strip control chars and cap length; untrusted transcript text renders inert.
    static string Sanitize(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var ch in s)
        {
            if (ch == '\n' || ch == '\t') sb.Append(' ');
            else if (ch < 0x20 || ch == 0x7f) { /* drop */ }
            else sb.Append(ch);
        }
        var o = sb.ToString();
        return o.Length > 240 ? o.Substring(0, 240) + "…" : o;
    }
}

public static class GitProbe
{
    public static void Fill(AgentSession row)
    {
        var cwd = row.EffectiveCwd ?? row.Info.Cwd;
        if (string.IsNullOrEmpty(cwd) || !Directory.Exists(cwd)) return;
        if (Run(cwd, "rev-parse --is-inside-work-tree") != "true") return;

        row.Branch = Run(cwd, "rev-parse --abbrev-ref HEAD");
        var top = Run(cwd, "rev-parse --show-toplevel");
        if (!string.IsNullOrEmpty(top)) row.RepoName = Path.GetFileName(top!.TrimEnd('\\', '/'));
        row.Dirty = !string.IsNullOrEmpty(Run(cwd, "status --porcelain"));
    }

    static string? Run(string cwd, string args)
    {
        try
        {
            var psi = new ProcessStartInfo("git", args)
            {
                WorkingDirectory = cwd,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = Process.Start(psi);
            if (p == null) return null;
            var output = p.StandardOutput.ReadToEnd();
            if (!p.WaitForExit(3000)) { try { p.Kill(); } catch { } return null; }
            return p.ExitCode == 0 ? output.Trim() : null;
        }
        catch { return null; }
    }
}

public static class StatsCache
{
    public static long? TokensToday()
    {
        try
        {
            if (!File.Exists(ClaudePaths.StatsCacheFile)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(ClaudePaths.StatsCacheFile));
            if (!doc.RootElement.TryGetProperty("dailyModelTokens", out var daily)
                || daily.ValueKind != JsonValueKind.Object) return null;

            var key = DateTime.Now.ToString("yyyy-MM-dd");
            if (!daily.TryGetProperty(key, out var today)) return null;

            if (today.ValueKind == JsonValueKind.Number && today.TryGetInt64(out var n)) return n;
            if (today.ValueKind == JsonValueKind.Object)
            {
                long sum = 0;   // daily totals (incl. cache tokens) can exceed Int32
                foreach (var p in today.EnumerateObject())
                    if (p.Value.ValueKind == JsonValueKind.Number && p.Value.TryGetInt64(out var v)) sum += v;
                return sum;
            }
        }
        catch { }
        return null;
    }
}
