namespace QuotaBlocks;

public enum QuotaProvider
{
    Codex,
    Claude,
}

/// <summary>One rate-limit window. Percentages are stored as *used*, shown as *remaining*.</summary>
public sealed record QuotaWindow(int UsedPercent, DateTime? ResetsAt)
{
    public int RemainingPercent => Math.Clamp(100 - UsedPercent, 0, 100);

    /// <summary>How many of the five blocks are lit, 20% each, always at least one while any quota is left.</summary>
    public int FilledBlockCount =>
        RemainingPercent <= 0 ? 0 : Math.Min(5, (int)Math.Ceiling(RemainingPercent / 20.0));
}

/// <summary>
/// Which local source produced a reading. Kept as data rather than a formatted
/// string so the panel can localise it and explain what the source cannot tell.
/// </summary>
public enum QuotaSource
{
    /// <summary>The Claude Code CLI's OAuth session; includes reset times.</summary>
    ClaudeCodeCli,

    /// <summary>The Claude desktop app's usage log; percentages only.</summary>
    ClaudeDesktopLog,
}

public sealed record QuotaSnapshot(
    QuotaProvider Provider,
    QuotaWindow Weekly,
    QuotaWindow? Session = null,
    QuotaWindow? Extra = null,
    string? ExtraLabel = null,
    QuotaSource? Source = null,
    DateTime? SourceSampledAt = null);

public abstract record QuotaState
{
    public sealed record Loading : QuotaState;

    public sealed record Available(QuotaSnapshot Snapshot) : QuotaState;

    public sealed record Unavailable(string Message) : QuotaState;

    public QuotaSnapshot? SnapshotOrNull => this is Available a ? a.Snapshot : null;
}

/// <summary>
/// Failures we can describe to the user. Transient ones keep the last good reading
/// on screen instead of blanking the row.
/// </summary>
public sealed class QuotaException : Exception
{
    public QuotaException(string message, bool isTemporary) : base(message)
    {
        IsTemporary = isTemporary;
    }

    public bool IsTemporary { get; }

    public static QuotaException NotSignedIn(string provider) =>
        new($"{provider} 未登录", isTemporary: false);

    public static QuotaException Missing(string message) => new(message, isTemporary: false);

    public static QuotaException Temporary(string message) => new(message, isTemporary: true);
}
