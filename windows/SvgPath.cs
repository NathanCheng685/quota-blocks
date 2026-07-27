using System.Drawing.Drawing2D;
using System.Globalization;
using System.Reflection;
using System.Text;
using System.Xml.Linq;

namespace QuotaBlocks;

/// <summary>
/// Just enough SVG to reuse the provider marks from the macOS app: a single
/// filled path per file, using only move/line/curve commands. Parsed once and
/// cached as a GraphicsPath normalised into a 0..1 box so it can be scaled to
/// any DPI.
/// </summary>
public static class SvgPath
{
    private static readonly Dictionary<string, GraphicsPath> Cache = new();

    public static GraphicsPath? Load(string resourceName)
    {
        lock (Cache)
        {
            if (Cache.TryGetValue(resourceName, out var cached)) return cached;

            var path = Build(resourceName);
            if (path is not null) Cache[resourceName] = path;
            return path;
        }
    }

    private static GraphicsPath? Build(string resourceName)
    {
        var assembly = Assembly.GetExecutingAssembly();
        var full = assembly.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith(resourceName, StringComparison.OrdinalIgnoreCase));
        if (full is null) return null;

        using var stream = assembly.GetManifestResourceStream(full);
        if (stream is null) return null;

        var document = XDocument.Load(stream);
        XNamespace svg = "http://www.w3.org/2000/svg";
        var data = document.Descendants(svg + "path").FirstOrDefault()?.Attribute("d")?.Value;
        if (string.IsNullOrWhiteSpace(data)) return null;

        var viewBox = (document.Root?.Attribute("viewBox")?.Value ?? "0 0 100 100")
            .Split([' ', ','], StringSplitOptions.RemoveEmptyEntries)
            .Select(v => float.Parse(v, CultureInfo.InvariantCulture))
            .ToArray();

        var path = Parse(data);
        if (viewBox.Length == 4 && viewBox[2] > 0 && viewBox[3] > 0)
        {
            using var transform = new Matrix();
            transform.Scale(1f / viewBox[2], 1f / viewBox[3]);
            transform.Translate(-viewBox[0], -viewBox[1]);
            path.Transform(transform);
        }
        return path;
    }

    private static GraphicsPath Parse(string data)
    {
        var path = new GraphicsPath(FillMode.Winding);
        var reader = new Tokenizer(data);

        PointF current = default, start = default, lastControl = default;
        var previousCommand = '\0';

        while (reader.TryReadCommand(out var command))
        {
            var relative = char.IsLower(command);
            var op = char.ToUpperInvariant(command);

            do
            {
                switch (op)
                {
                    case 'M':
                    {
                        var point = reader.ReadPoint(relative, current);
                        path.StartFigure();
                        current = start = point;
                        // Extra coordinate pairs after a moveto are implicit linetos.
                        op = 'L';
                        break;
                    }
                    case 'L':
                    {
                        var point = reader.ReadPoint(relative, current);
                        path.AddLine(current, point);
                        current = point;
                        break;
                    }
                    case 'H':
                    {
                        var x = reader.ReadNumber() + (relative ? current.X : 0);
                        var point = new PointF(x, current.Y);
                        path.AddLine(current, point);
                        current = point;
                        break;
                    }
                    case 'V':
                    {
                        var y = reader.ReadNumber() + (relative ? current.Y : 0);
                        var point = new PointF(current.X, y);
                        path.AddLine(current, point);
                        current = point;
                        break;
                    }
                    case 'C':
                    {
                        var c1 = reader.ReadPoint(relative, current);
                        var c2 = reader.ReadPoint(relative, current);
                        var end = reader.ReadPoint(relative, current);
                        path.AddBezier(current, c1, c2, end);
                        lastControl = c2;
                        current = end;
                        break;
                    }
                    case 'S':
                    {
                        var reflected = previousCommand is 'C' or 'S'
                            ? new PointF(2 * current.X - lastControl.X, 2 * current.Y - lastControl.Y)
                            : current;
                        var c2 = reader.ReadPoint(relative, current);
                        var end = reader.ReadPoint(relative, current);
                        path.AddBezier(current, reflected, c2, end);
                        lastControl = c2;
                        current = end;
                        break;
                    }
                    case 'Q':
                    {
                        var control = reader.ReadPoint(relative, current);
                        var end = reader.ReadPoint(relative, current);
                        path.AddBezier(current, Lerp(current, control), Lerp(end, control), end);
                        lastControl = control;
                        current = end;
                        break;
                    }
                    case 'Z':
                        path.CloseFigure();
                        current = start;
                        break;
                    default:
                        // Unsupported command (arcs); skip its numbers rather than looping forever.
                        reader.SkipNumbers();
                        break;
                }

                previousCommand = op;
            }
            while (op != 'Z' && reader.HasNumberAhead);
        }

        return path;

        static PointF Lerp(PointF anchor, PointF control) =>
            new(anchor.X + 2f / 3f * (control.X - anchor.X), anchor.Y + 2f / 3f * (control.Y - anchor.Y));
    }

    private sealed class Tokenizer(string text)
    {
        private int index;

        public bool HasNumberAhead
        {
            get
            {
                var probe = index;
                while (probe < text.Length && IsSeparator(text[probe])) probe++;
                return probe < text.Length && (char.IsDigit(text[probe]) || text[probe] is '-' or '+' or '.');
            }
        }

        public bool TryReadCommand(out char command)
        {
            while (index < text.Length && IsSeparator(text[index])) index++;
            if (index < text.Length && char.IsLetter(text[index]))
            {
                command = text[index++];
                return true;
            }
            command = '\0';
            return false;
        }

        public float ReadNumber()
        {
            while (index < text.Length && IsSeparator(text[index])) index++;

            var builder = new StringBuilder();
            if (index < text.Length && text[index] is '-' or '+') builder.Append(text[index++]);
            while (index < text.Length && (char.IsDigit(text[index]) || text[index] == '.'))
            {
                builder.Append(text[index++]);
            }
            // Scientific notation, e.g. 1.5e-3.
            if (index < text.Length && (text[index] is 'e' or 'E'))
            {
                builder.Append(text[index++]);
                if (index < text.Length && text[index] is '-' or '+') builder.Append(text[index++]);
                while (index < text.Length && char.IsDigit(text[index])) builder.Append(text[index++]);
            }

            return float.TryParse(builder.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value)
                ? value
                : 0f;
        }

        public PointF ReadPoint(bool relative, PointF origin)
        {
            var x = ReadNumber();
            var y = ReadNumber();
            return relative ? new PointF(origin.X + x, origin.Y + y) : new PointF(x, y);
        }

        public void SkipNumbers()
        {
            while (HasNumberAhead) ReadNumber();
        }

        private static bool IsSeparator(char c) => c is ' ' or ',' or '\t' or '\r' or '\n';
    }
}
