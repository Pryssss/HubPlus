using System.IO;
using System.Text;

namespace HubPlusWin.Core;

/// Locations and naming rules of the local Claude Code data dir on Windows
/// (%USERPROFILE%\.claude).
public static class ClaudePaths
{
    public static string Home =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");

    public static string SessionsDir => Path.Combine(Home, "sessions");
    public static string ProjectsDir => Path.Combine(Home, "projects");
    public static string StatsCacheFile => Path.Combine(Home, "stats-cache.json");
    public static string CredentialsFile => Path.Combine(Home, ".credentials.json");

    /// Claude Code names a project's transcript folder by replacing every
    /// non-alphanumeric char of the absolute cwd with '-'.
    public static string EncodedProjectDir(string cwd)
    {
        var sb = new StringBuilder(cwd.Length);
        foreach (var ch in cwd)
        {
            // ASCII-only [a-zA-Z0-9], matching Claude Code's /[^a-zA-Z0-9]/g rule
            // (char.IsLetterOrDigit would keep non-ASCII letters and diverge).
            bool keep = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9');
            sb.Append(keep ? ch : '-');
        }
        return sb.ToString();
    }

    public static string TranscriptPath(string cwd, string sessionId) =>
        Path.Combine(ProjectsDir, EncodedProjectDir(cwd), sessionId + ".jsonl");
}
