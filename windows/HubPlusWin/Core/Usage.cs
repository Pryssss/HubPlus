using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace HubPlusWin.Core;

public enum UsageResult { Ok, AuthError, Transient }

/// Reads the Claude Code OAuth token. On Windows it may live in the cross-platform
/// file ~/.claude/.credentials.json or in Windows Credential Manager. Read-only:
/// the token is used for a single request to api.anthropic.com and never stored.
public static class CredentialReader
{
    public static string? ClaudeToken()
    {
        // 1) Cross-platform credentials file.
        try
        {
            if (File.Exists(ClaudePaths.CredentialsFile))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(ClaudePaths.CredentialsFile));
                var t = FindToken(doc.RootElement);
                if (!string.IsNullOrEmpty(t)) return t;
            }
        }
        catch { }

        // 2) Windows Credential Manager (best effort; target name may vary).
        foreach (var target in new[] { "Claude Code-credentials", "Claude Code", "claude-code" })
        {
            try
            {
                var blob = WinCred.Read(target);
                if (blob == null) continue;
                var t = ExtractToken(blob);
                if (!string.IsNullOrEmpty(t)) return t;
            }
            catch { }
        }
        return null;
    }

    static string? FindToken(JsonElement el)
    {
        if (el.ValueKind != JsonValueKind.Object) return null;
        foreach (var name in new[] { "accessToken", "access_token" })
            if (el.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String)
                return v.GetString();
        foreach (var p in el.EnumerateObject())
        {
            var r = FindToken(p.Value);
            if (r != null) return r;
        }
        return null;
    }

    static string? ExtractToken(string blob)
    {
        var trimmed = blob.Trim();
        if (trimmed.StartsWith("{"))
        {
            try { using var doc = JsonDocument.Parse(trimmed); return FindToken(doc.RootElement); }
            catch { return null; }
        }
        return trimmed.Length > 20 ? trimmed : null;
    }
}

static class WinCred
{
    [StructLayout(LayoutKind.Sequential)]
    struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CredReadW")]
    static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr cred);

    public static string? Read(string target)
    {
        if (!CredRead(target, 1 /* CRED_TYPE_GENERIC */, 0, out var ptr)) return null;
        try
        {
            var cred = Marshal.PtrToStructure<CREDENTIAL>(ptr);
            if (cred.CredentialBlobSize == 0 || cred.CredentialBlob == IntPtr.Zero) return null;
            var bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, cred.CredentialBlobSize);
            var utf8 = Encoding.UTF8.GetString(bytes);
            if (utf8.Contains('{') || utf8.Contains("accessToken")) return utf8;
            return Encoding.Unicode.GetString(bytes);   // some stores use UTF-16
        }
        finally { CredFree(ptr); }
    }
}

/// Fetches subscription usage (5h/7d) from the same endpoint the CLI uses for /usage.
public static class UsageClient
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    public static async Task<(UsageResult result, UsageSnapshot? snapshot)> Fetch()
    {
        var token = CredentialReader.ClaudeToken();
        if (string.IsNullOrEmpty(token)) return (UsageResult.AuthError, null);

        var req = new HttpRequestMessage(HttpMethod.Get, "https://api.anthropic.com/api/oauth/usage");
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);
        req.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");
        req.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
        req.Headers.TryAddWithoutValidation("User-Agent", "HubPlus");

        try
        {
            using var resp = await Http.SendAsync(req);
            var code = (int)resp.StatusCode;
            if (code == 401 || code == 403) return (UsageResult.AuthError, null);
            if (!resp.IsSuccessStatusCode) return (UsageResult.Transient, null);

            var body = await resp.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(body);
            var five = Window(doc.RootElement, "five_hour");
            var seven = Window(doc.RootElement, "seven_day");
            if (five == null && seven == null) return (UsageResult.Transient, null);
            return (UsageResult.Ok, new UsageSnapshot { FiveHour = five, SevenDay = seven, State = UsageState.Ok });
        }
        catch { return (UsageResult.Transient, null); }
    }

    static UsageWindow? Window(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var w) || w.ValueKind != JsonValueKind.Object) return null;
        if (!w.TryGetProperty("utilization", out var u) || u.ValueKind != JsonValueKind.Number
            || !u.TryGetDouble(out var util)) return null;

        DateTime? reset = null;
        if (w.TryGetProperty("resets_at", out var r) && r.ValueKind == JsonValueKind.String
            && DateTime.TryParse(r.GetString(), out var d))
            reset = d;
        return new UsageWindow { Utilization = util, ResetsAt = reset };
    }
}
