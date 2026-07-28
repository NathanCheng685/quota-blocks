using System.Drawing.Drawing2D;
using Microsoft.Win32;

namespace QuotaBlocks;

/// <summary>
/// The bar itself: two rows of provider icon, five blocks and the remaining
/// weekly percentage, pinned to the bottom-left corner on top of the taskbar.
/// </summary>
public sealed class OverlayForm : LayeredForm
{
    // Logical (96 dpi) metrics; everything is multiplied by the monitor scale.
    // A little slack around the content so the bar stays comfortably clickable
    // now that there is no panel to aim at.
    private const float PadX = 5f;
    private const float PadY = 4f;
    private const float RowHeight = 14f;
    private const float RowGap = 2f;
    private const float IconSize = 11f;
    private const float IconGap = 6f;
    private const float BlockWidth = 6f;
    private const float BlockHeight = 8f;
    private const float BlockGap = 3f;
    private const float ValueGap = 7f;
    private const float ScreenMargin = 9f;
    private const int BlockCount = 5;

    private readonly System.Windows.Forms.Timer refreshTimer = new();
    private readonly System.Windows.Forms.Timer topmostTimer = new();
    // Long enough to absorb a duplicate delivery of one click, short enough that
    // deliberately clicking twice in a row still opens and closes the panel.
    private static readonly TimeSpan ToggleDebounce = TimeSpan.FromMilliseconds(150);

    private DetailsForm? details;
    // Held in a field so the callback is not collected while the hook is live.
    private Native.WinEventProc? foregroundProc;
    private Native.WinEventProc? taskbarProc;
    private IntPtr foregroundHook;
    private IntPtr taskbarHook;
    private Rectangle lastTaskbar = Rectangle.Empty;
    private DateTime lastToggleAt = DateTime.MinValue;
    private DateTime detailsClosedAt = DateTime.MinValue;
    private CancellationTokenSource? inFlight;

    private QuotaState codexState = new QuotaState.Loading();
    private QuotaState claudeState = new QuotaState.Loading();

    public OverlayForm() : base(clickThroughFocus: true)
    {
        TopMost = true;
        Cursor = Cursors.Hand;

        refreshTimer.Interval = 120_000;
        refreshTimer.Tick += (_, _) => _ = RefreshAsync();

        // Backstop only — the shell hooks below handle the common cases
        // immediately. This catches what raises no event at all, and recovers if
        // explorer restarts and takes the taskbar hook with it.
        topmostTimer.Interval = 1_000;
        topmostTimer.Tick += (_, _) => ApplyVisibility();
    }

    public QuotaState CodexState => codexState;

    public QuotaState ClaudeState => claudeState;

    protected override void OnLoad(EventArgs e)
    {
        base.OnLoad(e);
        var screen = Screen.PrimaryScreen ?? Screen.AllScreens[0];
        Log.Write($"OnLoad dpi={DeviceDpi} bounds={screen.Bounds} working={screen.WorkingArea}");
        Reposition();
        Log.Write($"positioned at {Bounds}");
        Redraw();
        refreshTimer.Start();
        topmostTimer.Start();

        // The taskbar can move, resize or flip between light and dark without
        // any of it reaching the app through a window message it already sees.
        SystemEvents.DisplaySettingsChanged += OnEnvironmentChanged;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

        // Clicking the taskbar raises Shell_TrayWnd within the topmost band, and
        // the bar lives inside the taskbar's own rectangle, so it gets covered
        // completely. Waiting for the backstop timer left it hidden for seconds;
        // re-asserting the moment the foreground changes makes it imperceptible.
        foregroundProc = OnShellEvent;
        foregroundHook = Native.SetWinEventHook(
            Native.EVENT_SYSTEM_FOREGROUND,
            Native.EVENT_SYSTEM_FOREGROUND,
            IntPtr.Zero,
            foregroundProc,
            processId: 0,
            threadId: 0,
            Native.WINEVENT_OUTOFCONTEXT);

        // An auto-hiding taskbar slides away without any foreground change, so
        // watch the taskbar window's own movement too. Scoped to its thread so
        // this is not a firehose of every window move on the system.
        var tray = Native.TaskbarWindow();
        if (tray != IntPtr.Zero)
        {
            var trayThread = Native.GetWindowThreadProcessId(tray, out _);
            taskbarProc = OnShellEvent;
            taskbarHook = Native.SetWinEventHook(
                Native.EVENT_OBJECT_LOCATIONCHANGE,
                Native.EVENT_OBJECT_LOCATIONCHANGE,
                IntPtr.Zero,
                taskbarProc,
                processId: 0,
                trayThread,
                Native.WINEVENT_OUTOFCONTEXT);
        }

        // The hooks only report changes, so settle the initial state explicitly:
        // the app may well have started under a fullscreen window.
        ApplyVisibility();

        _ = RefreshAsync();
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        Reposition();
        Redraw();
    }

    private void OnShellEvent(
        IntPtr hook, uint eventType, IntPtr hwnd, int objectId, int childId, uint thread, uint time)
    {
        // WINEVENT_OUTOFCONTEXT delivers this on the installing thread's message
        // loop, so it is already the UI thread.
        if (IsDisposed || hwnd == Handle) return;
        ApplyVisibility();
    }

    /// <summary>
    /// The bar exists to look like part of the taskbar, so it is shown exactly
    /// when the taskbar itself is: hidden under fullscreen windows, and hidden
    /// when an auto-hiding taskbar has slid away. Both are read from the taskbar
    /// window's real position rather than inferred, because an auto-hidden
    /// taskbar never gives the working area back.
    /// </summary>
    private void ApplyVisibility()
    {
        var screen = Screen.PrimaryScreen ?? Screen.AllScreens[0];
        var taskbar = Native.TaskbarBounds();
        var onScreen = Rectangle.Intersect(taskbar, screen.Bounds);

        // A retracted auto-hide taskbar leaves only a sliver behind, which is
        // far too little to sit the bar in.
        var taskbarShowing = onScreen.Height >= Height && onScreen.Width > 0;
        var fullscreen = Native.CoversScreen(Native.GetForegroundWindow(), screen.Bounds);

        if (!taskbarShowing || fullscreen)
        {
            if (!Visible) return;
            Log.Write($"hiding: taskbarShowing={taskbarShowing} fullscreen={fullscreen}");
            details?.Close();
            Visible = false;
            return;
        }

        // The taskbar location hook fires often, and measuring the content
        // allocates, so only re-place the bar when the strip actually moved.
        if (onScreen != lastTaskbar)
        {
            lastTaskbar = onScreen;
            Reposition(onScreen);
        }

        if (!Visible)
        {
            Log.Write($"showing at {Bounds}");
            Visible = true;
            Redraw();
        }

        BringToFront();
    }

    private void OnEnvironmentChanged(object? sender, EventArgs e)
    {
        if (IsDisposed) return;
        BeginInvoke(() =>
        {
            Reposition();
            Redraw();
            details?.Redraw();
        });
    }

    private void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is UserPreferenceCategory.General or UserPreferenceCategory.Color)
        {
            OnEnvironmentChanged(sender, e);
        }
    }

    private float DpiScale => DeviceDpi / 96f;

    private static float S(float value, float scale) => value * scale;

    protected override Size MeasureContent()
    {
        var scale = DpiScale;
        using var font = Fonts.Numeric(ValueFontSize(scale));
        var valueWidth = Math.Max(
            Measure("100%", font),
            Math.Max(Measure(ValueText(codexState), font), Measure(ValueText(claudeState), font)));

        var width = S(PadX, scale) + S(IconSize, scale) + S(IconGap, scale)
            + BlockCount * S(BlockWidth, scale) + (BlockCount - 1) * S(BlockGap, scale)
            + S(ValueGap, scale) + valueWidth + S(PadX, scale);

        var height = S(PadY, scale) * 2 + S(RowHeight, scale) * 2 + S(RowGap, scale);

        return new Size((int)Math.Ceiling(width), (int)Math.Ceiling(height));
    }

    private static float ValueFontSize(float scale) => S(11f, scale);

    private static float Measure(string text, Font font)
    {
        using var bitmap = new Bitmap(1, 1);
        using var g = Graphics.FromImage(bitmap);
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        return g.MeasureString(text, font, PointF.Empty, StringFormat.GenericTypographic).Width;
    }

    protected override void Render(Graphics g, Size size)
    {
        var theme = Theme.Current;
        var scale = DpiScale;

        // No panel, no border: the rows sit directly on the taskbar. The fill is
        // still needed because a layered window passes clicks straight through
        // any pixel with zero alpha, which would make the bar unclickable.
        using (var hitTestFill = new SolidBrush(Color.FromArgb(3, 0, 0, 0)))
        {
            g.FillRectangle(hitTestFill, 0, 0, size.Width, size.Height);
        }

        DrawRow(g, theme, scale, QuotaProvider.Codex, codexState, S(PadY, scale));
        DrawRow(g, theme, scale, QuotaProvider.Claude, claudeState, S(PadY, scale) + S(RowHeight + RowGap, scale));
    }

    private void DrawRow(Graphics g, Theme theme, float scale, QuotaProvider provider, QuotaState state, float top)
    {
        var rowHeight = S(RowHeight, scale);
        var x = S(PadX, scale);

        var iconSize = S(IconSize, scale);
        DrawIcon(g, provider, new RectangleF(x, top + (rowHeight - iconSize) / 2f, iconSize, iconSize));
        x += iconSize + S(IconGap, scale);

        var filled = state is QuotaState.Available available ? available.Snapshot.Weekly.FilledBlockCount : 0;
        var blockWidth = S(BlockWidth, scale);
        var blockHeight = S(BlockHeight, scale);
        var blockTop = top + (rowHeight - blockHeight) / 2f;
        var color = Theme.Provider(provider);

        for (var i = 0; i < BlockCount; i++)
        {
            var rect = new RectangleF(x + i * (blockWidth + S(BlockGap, scale)), blockTop, blockWidth, blockHeight);
            g.FillRounded(rect, S(1.6f, scale), i < filled ? color : theme.EmptyBlock);
        }

        x += BlockCount * blockWidth + (BlockCount - 1) * S(BlockGap, scale) + S(ValueGap, scale);

        using var font = Fonts.Numeric(ValueFontSize(scale));
        using var brush = new SolidBrush(state is QuotaState.Available ? theme.Text : theme.SecondaryText);
        var text = ValueText(state);
        var textSize = g.MeasureString(text, font, PointF.Empty, StringFormat.GenericTypographic);
        g.DrawString(text, font, brush, x, top + (rowHeight - textSize.Height) / 2f, StringFormat.GenericTypographic);
    }

    private static void DrawIcon(Graphics g, QuotaProvider provider, RectangleF rect)
    {
        var path = SvgPath.Load(provider == QuotaProvider.Codex ? "chatgpt.svg" : "claude.svg");
        if (path is null)
        {
            g.FillRounded(rect, rect.Width / 4f, Theme.Provider(provider));
            return;
        }

        using var clone = (GraphicsPath)path.Clone();
        using var transform = new Matrix();
        transform.Translate(rect.X, rect.Y);
        transform.Scale(rect.Width, rect.Height);
        clone.Transform(transform);

        using var brush = new SolidBrush(Theme.Provider(provider));
        g.FillPath(brush, clone);
    }

    private static string ValueText(QuotaState state) => state switch
    {
        QuotaState.Available available => $"{available.Snapshot.Weekly.RemainingPercent}%",
        QuotaState.Unavailable => "—",
        _ => "···",
    };

    /// <summary>
    /// Centres the bar in the taskbar strip, at its left end. Passing the strip
    /// in keeps it aligned to where the taskbar really is; with no strip to sit
    /// in it falls back to the bottom-left of the screen.
    /// </summary>
    public void Reposition(Rectangle taskbar = default)
    {
        var screen = Screen.PrimaryScreen ?? Screen.AllScreens[0];
        var size = MeasureContent();
        var scale = DpiScale;

        if (taskbar.IsEmpty)
        {
            taskbar = Rectangle.Intersect(Native.TaskbarBounds(), screen.Bounds);
        }

        int top, left;
        if (taskbar.Height >= size.Height && taskbar.Width > 0)
        {
            top = taskbar.Top + (taskbar.Height - size.Height) / 2;
            left = taskbar.Left + (int)S(ScreenMargin, scale);
        }
        else
        {
            top = screen.Bounds.Bottom - size.Height - (int)S(6f, scale);
            left = screen.Bounds.Left + (int)S(ScreenMargin, scale);
        }

        Bounds = new Rectangle(left, top, size.Width, size.Height);
    }

    public async Task RefreshAsync()
    {
        var previous = inFlight;
        previous?.Cancel();
        var cts = new CancellationTokenSource();
        inFlight = cts;
        previous?.Dispose();

        var codexTask = ReadSafely(() => CodexQuotaService.FetchAsync(cts.Token));
        var claudeTask = ReadSafely(() => ClaudeQuotaService.FetchAsync(cts.Token));
        var results = await Task.WhenAll(codexTask, claudeTask);

        if (cts.IsCancellationRequested || IsDisposed) return;

        codexState = Next(results[0], codexState);
        claudeState = Next(results[1], claudeState);

        Reposition();
        Redraw();
        details?.Rebuild();
    }

    private static async Task<(QuotaSnapshot? Snapshot, Exception? Error)> ReadSafely(Func<Task<QuotaSnapshot>> operation)
    {
        try { return (await operation(), null); }
        catch (Exception e) { return (null, e); }
    }

    /// <summary>A transient failure keeps the previous reading rather than blanking the row.</summary>
    private static QuotaState Next((QuotaSnapshot? Snapshot, Exception? Error) result, QuotaState previous)
    {
        if (result.Snapshot is not null) return new QuotaState.Available(result.Snapshot);
        if (previous is QuotaState.Available && result.Error is QuotaException { IsTemporary: true }) return previous;
        return new QuotaState.Unavailable(result.Error?.Message ?? "unavailable");
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);

        // Opening the panel pumps messages, and this click can be delivered a
        // second time on the way out — which would immediately close what the
        // first delivery opened.
        var now = DateTime.UtcNow;
        if (now - lastToggleAt < ToggleDebounce) return;
        lastToggleAt = now;

        Log.Write($"bar mouse down at {e.Location} button={e.Button}");
        ToggleDetails();
    }

    private void ToggleDetails()
    {
        Log.Write($"toggle details, open={details is { IsDisposed: false, Visible: true }}");
        if (details is { IsDisposed: false, Visible: true })
        {
            details.Close();
            return;
        }

        // Clicking the bar deactivates an open panel, which closes it a moment
        // before this handler runs; without the guard the click would reopen it.
        if (DateTime.UtcNow - detailsClosedAt < TimeSpan.FromMilliseconds(250)) return;

        details = new DetailsForm(this);
        details.FormClosed += (_, _) =>
        {
            details = null;
            detailsClosedAt = DateTime.UtcNow;
        };
        details.ShowNear(Bounds);
    }

    public void ApplyLanguageChange()
    {
        Reposition();
        Redraw();
        details?.Rebuild();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            SystemEvents.DisplaySettingsChanged -= OnEnvironmentChanged;
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            foreach (var hook in new[] { foregroundHook, taskbarHook })
            {
                if (hook != IntPtr.Zero) Native.UnhookWinEvent(hook);
            }
            foregroundHook = taskbarHook = IntPtr.Zero;
            foregroundProc = taskbarProc = null;
            refreshTimer.Dispose();
            topmostTimer.Dispose();
            inFlight?.Cancel();
            inFlight?.Dispose();
        }
        base.Dispose(disposing);
    }
}
