using System.Text.Json.Serialization;

namespace QuickWingetSetup.Models;

public class ExtensionConfig
{
    [JsonPropertyName("source")]
    public string Source { get; set; } = "github";

    /// <summary>Repository root of a local clone; only used when <see cref="Source"/> is "local".</summary>
    [JsonPropertyName("localPath")]
    public string LocalPath { get; set; } = string.Empty;

    [JsonPropertyName("githubRepo")]
    public string GithubRepo { get; set; } = "microsoft/WindowsDeveloperConfig";

    [JsonPropertyName("githubBranch")]
    public string GithubBranch { get; set; } = "main";

    /// <summary>
    /// Manifest path relative to <see cref="LocalPath"/> or the repo root. Flow paths inside the
    /// manifest resolve against that same root, so the signed top-level copies are what get launched.
    /// </summary>
    [JsonPropertyName("manifestFile")]
    public string ManifestFile { get; set; } = "src/manifest.yml";

    [JsonPropertyName("cacheTTLDays")]
    public int CacheTTLDays { get; set; } = 7;
}
