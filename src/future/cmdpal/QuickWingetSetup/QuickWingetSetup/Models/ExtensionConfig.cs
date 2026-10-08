using System.Text.Json.Serialization;

namespace QuickWingetSetup.Models;

public class ExtensionConfig
{
    [JsonPropertyName("source")]
    public string Source { get; set; } = "local";

    [JsonPropertyName("localPath")]
    public string LocalPath { get; set; } = @"C:\WindowsDeveloperConfig";

    [JsonPropertyName("githubRepo")]
    public string GithubRepo { get; set; } = "crutkas/WindowsDevSetupScripts";

    [JsonPropertyName("githubBranch")]
    public string GithubBranch { get; set; } = "master";

    /// <summary>
    /// Manifest filename, relative to <see cref="LocalPath"/> or repo root.
    /// </summary>
    [JsonPropertyName("manifestFile")]
    public string ManifestFile { get; set; } = "manifest.yml";

    [JsonPropertyName("cacheTTLDays")]
    public int CacheTTLDays { get; set; } = 7;
}
