import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Пути к установленным нативным файлам захвата.
class NativeCapturePaths {
  const NativeCapturePaths({required this.scriptPath, required this.dllPath});

  final String scriptPath;
  final String dllPath;
}

/// Нативный захват экрана для Windows.
///
/// Почему так: раньше выделение области делалось внутри Flutter-окна,
/// растянутого на весь экран (window_manager.setFullScreen), а PNG
/// декодировался/кадрировался на UI-изоляте. Отсюда фризы, «приближение»
/// снимка (окно и снимок на разных мониторах/DPI) и мигание.
///
/// Теперь снимок делает и показывает отдельный процесс PowerShell с
/// WinForms-оверлеем: 1 пиксель снимка = 1 физическому пикселю монитора,
/// корректный DPI и несколько мониторов. Flutter-окно просто прячется на
/// время съёмки, никакого fullscreen.
class NativeCapture {
  NativeCapture._();

  static NativeCapturePaths? _paths;

  /// Записывает скрипт в папку приложения (один раз) и чистит старые версии.
  static Future<NativeCapturePaths> ensureInstalled() async {
    final cached = _paths;
    if (cached != null) return cached;

    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      p.join(support.path, 'SmartScreenshotManager', 'native'),
    );
    await directory.create(recursive: true);

    final source = _asciiOnly(_overlaySource);
    final hash = _fnv1a(_scriptTemplate + source).toRadixString(16);
    final scriptName = 'ssm_capture_$hash.ps1';
    final dllName = 'ssm_overlay_$hash.dll';

    final scriptFile = File(p.join(directory.path, scriptName));
    if (!await scriptFile.exists()) {
      final text = _scriptTemplate.replaceFirst('__CSHARP__', source);
      await scriptFile.writeAsBytes(
        <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(text)],
        flush: true,
      );
    }

    try {
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        final isNative = (name.startsWith('ssm_capture_') && name.endsWith('.ps1')) ||
            (name.startsWith('ssm_overlay_') && name.endsWith('.dll'));
        if (isNative && name != scriptName && name != dllName) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}

    final paths = NativeCapturePaths(
      scriptPath: scriptFile.path,
      dllPath: p.join(directory.path, dllName),
    );
    _paths = paths;
    return paths;
  }

  /// В C#-коде кириллица пишется как есть, но в файл попадает как \uXXXX,
  /// чтобы кодировка PowerShell/csc никогда не ломала надписи.
  static String _asciiOnly(String value) {
    final buffer = StringBuffer();
    for (final unit in value.codeUnits) {
      if (unit < 128) {
        buffer.writeCharCode(unit);
      } else {
        buffer.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
      }
    }
    return buffer.toString();
  }

  static int _fnv1a(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  // ---------------------------------------------------------------------------
  // PowerShell-обёртка. Параметры приходят через переменные окружения
  // (SSM_MODE, SSM_OUT, SSM_COPY, SSM_RESULT, SSM_DLL), поэтому пути с
  // кириллицей/пробелами/кавычками ничего не ломают.
  // ---------------------------------------------------------------------------
  static const String _scriptTemplate = r'''
$ErrorActionPreference = 'Stop'
$ResultPath = $env:SSM_RESULT

function Write-Result([string]$Text) {
  if ([string]::IsNullOrEmpty($ResultPath)) { return }
  [System.IO.File]::WriteAllText($ResultPath, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

try {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing

  $dll = $env:SSM_DLL
  if ($dll -and (Test-Path -LiteralPath $dll)) {
    try { Add-Type -Path $dll } catch { }
  }

  if (-not ('Ssm.Capture' -as [type])) {
    $source = @'
__CSHARP__
'@
    $refs = @('System.Windows.Forms', 'System.Drawing')
    if ($dll) {
      # Компилируем один раз в DLL: следующие запуски стартуют мгновенно.
      try { Add-Type -TypeDefinition $source -ReferencedAssemblies $refs -OutputAssembly $dll -OutputType Library } catch { }
      if ((Test-Path -LiteralPath $dll) -and -not ('Ssm.Capture' -as [type])) {
        try { Add-Type -Path $dll } catch { }
      }
    }
    if (-not ('Ssm.Capture' -as [type])) {
      Add-Type -TypeDefinition $source -ReferencedAssemblies $refs
    }
  }

  $mode = $env:SSM_MODE
  if ($mode -eq 'warm') {
    $result = 'ok'
  } elseif ($mode -eq 'clip') {
    $result = [Ssm.Capture]::CopyFile($env:SSM_OUT)
  } else {
    $result = [Ssm.Capture]::Run($mode, $env:SSM_OUT, ($env:SSM_COPY -eq '1'))
  }
  Write-Result ([string]$result)
} catch {
  Write-Result ('error:' + $_.Exception.Message)
}
''';

  // ---------------------------------------------------------------------------
  // C# (компилируется csc из .NET Framework 4.x => только синтаксис C# 5).
  // ---------------------------------------------------------------------------
  static const String _overlaySource = r'''
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace Ssm
{
    public static class Native
    {
        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")]
        public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
        [DllImport("kernel32.dll")]
        public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

        // Per-monitor DPI v2: координаты и снимок в физических пикселях,
        // иначе на 125-200% масштабе снимок «уезжает» и выглядит увеличенным.
        public static void EnableDpiAwareness()
        {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch (Exception) { }
            try { SetProcessDPIAware(); } catch (Exception) { }
        }

        // Без этого оверлей, запущенный из фонового процесса, не получает фокус
        // и Esc/Enter не работают, пока не кликнешь.
        public static void ForceForeground(IntPtr hwnd)
        {
            try
            {
                IntPtr fg = GetForegroundWindow();
                uint pid = 0;
                uint fgThread = 0;
                if (fg != IntPtr.Zero) fgThread = GetWindowThreadProcessId(fg, out pid);
                uint cur = GetCurrentThreadId();
                bool attached = false;
                if (fgThread != 0 && fgThread != cur) attached = AttachThreadInput(cur, fgThread, true);
                SetForegroundWindow(hwnd);
                if (attached) AttachThreadInput(cur, fgThread, false);
            }
            catch (Exception) { }
        }
    }

    public static class Clip
    {
        public static bool SetImage(Image img)
        {
            for (int i = 0; i < 8; i++)
            {
                try { Clipboard.SetImage(img); return true; }
                catch (Exception) { Thread.Sleep(120); }
            }
            return false;
        }
    }

    public static class Capture
    {
        public static Bitmap Grab(Rectangle r)
        {
            Bitmap bmp = new Bitmap(r.Width, r.Height, PixelFormat.Format24bppRgb);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                try
                {
                    // CaptureBlt: захватывает и «слоистые» окна (меню, подсказки).
                    g.CopyFromScreen(r.X, r.Y, 0, 0, r.Size, CopyPixelOperation.SourceCopy | CopyPixelOperation.CaptureBlt);
                }
                catch (Exception)
                {
                    g.CopyFromScreen(r.X, r.Y, 0, 0, r.Size, CopyPixelOperation.SourceCopy);
                }
            }
            return bmp;
        }

        public static string CopyFile(string path)
        {
            try
            {
                using (Image img = Image.FromFile(path))
                using (Bitmap bmp = new Bitmap(img))
                {
                    return Clip.SetImage(bmp) ? "ok" : "error:clipboard is busy";
                }
            }
            catch (Exception ex)
            {
                return "error:" + ex.Message;
            }
        }

        // mode: region | text | screen | all
        public static string Run(string mode, string outPath, bool copy)
        {
            Native.EnableDpiAwareness();
            Application.EnableVisualStyles();

            Rectangle bounds;
            if (mode == "all") bounds = SystemInformation.VirtualScreen;
            else bounds = Screen.FromPoint(Cursor.Position).Bounds;

            using (Bitmap shot = Grab(bounds))
            {
                if (mode == "screen" || mode == "all")
                {
                    shot.Save(outPath, ImageFormat.Png);
                    if (copy) Clip.SetImage(shot);
                    return "ok";
                }

                bool textMode = (mode == "text");
                Bitmap result = null;
                bool forceCopy = false;
                using (OverlayForm form = new OverlayForm(shot, bounds, textMode))
                {
                    Application.Run(form);
                    result = form.ResultBitmap;
                    forceCopy = form.ForceCopy;
                }

                if (result == null) return "cancel";
                using (result)
                {
                    result.Save(outPath, ImageFormat.Png);
                    if (copy || forceCopy) Clip.SetImage(result);
                }
                return "ok";
            }
        }
    }

    public class OverlayForm : Form
    {
        enum Tool { Select, Pen, Line, Arrow, Rect, Marker, Mosaic, Text }
        enum DragMode { None, NewSel, Move, Resize, Draw }

        class Ann
        {
            public Tool Kind;
            public Color Color;
            public int Width;
            public List<Point> Points = new List<Point>();
            public Point A;
            public Point B;
            public string Text = "";
        }

        class Btn
        {
            public string Kind;
            public Tool T;
            public Color C;
            public string Label = "";
            public int W;
            public Rectangle R;
        }

        const string HintRegion = "Выделите область мышью  •  Esc — отмена";
        const string HintText = "Выделите область с текстом  •  Esc — отмена";
        const string HintEdit = "Enter — сохранить  •  Ctrl+C — в буфер  •  Ctrl+Z — назад  •  ПКМ — сбросить  •  Esc — отмена";

        static readonly int[] Widths = new int[] { 2, 4, 7, 11 };
        static readonly Color[] Palette = new Color[]
        {
            Color.FromArgb(235, 45, 45),
            Color.FromArgb(255, 205, 0),
            Color.FromArgb(40, 180, 90),
            Color.FromArgb(35, 120, 240),
            Color.FromArgb(255, 255, 255),
            Color.FromArgb(20, 20, 20)
        };

        readonly Bitmap _shot;
        Bitmap _dim;
        readonly Rectangle _screen;
        readonly bool _textMode;
        float _s = 1f;
        Font _font;

        bool _hasSel;
        Rectangle _sel = Rectangle.Empty;
        Point _anchor;
        Point _dragStart;
        Rectangle _selStart;
        int _handle = -1;
        DragMode _drag = DragMode.None;

        Tool _tool = Tool.Select;
        Color _color = Palette[0];
        int _widthIndex = 1;

        readonly List<Ann> _anns = new List<Ann>();
        Ann _cur;
        Ann _textEdit;
        readonly List<Btn> _btns = new List<Btn>();
        Rectangle _tbRect = Rectangle.Empty;
        int _hover = -1;

        public Bitmap ResultBitmap;
        public bool ForceCopy;

        public OverlayForm(Bitmap shot, Rectangle screen, bool textMode)
        {
            _shot = shot;
            _screen = screen;
            _textMode = textMode;

            AutoScaleMode = AutoScaleMode.None;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            KeyPreview = true;
            BackColor = Color.Black;
            Cursor = Cursors.Cross;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
            Bounds = screen;

            // Затемнённая копия снимка делается один раз: перерисовка при
            // движении мыши остаётся быстрой даже на 4K.
            _dim = new Bitmap(shot.Width, shot.Height, PixelFormat.Format24bppRgb);
            using (Graphics g = Graphics.FromImage(_dim))
            using (ImageAttributes ia = new ImageAttributes())
            {
                float k = 0.55f;
                ColorMatrix cm = new ColorMatrix(new float[][]
                {
                    new float[] { k, 0, 0, 0, 0 },
                    new float[] { 0, k, 0, 0, 0 },
                    new float[] { 0, 0, k, 0, 0 },
                    new float[] { 0, 0, 0, 1, 0 },
                    new float[] { 0, 0, 0, 0, 1 }
                });
                ia.SetColorMatrix(cm);
                g.DrawImage(shot, new Rectangle(0, 0, shot.Width, shot.Height), 0, 0, shot.Width, shot.Height, GraphicsUnit.Pixel, ia);
            }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x80; // WS_EX_TOOLWINDOW: без кнопки в панели задач и Alt+Tab
                return cp;
            }
        }

        protected override void WndProc(ref Message m)
        {
            // Игнорируем смену DPI: окно обязано остаться ровно на своём мониторе.
            if (m.Msg == 0x02E0) return;
            base.WndProc(ref m);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            try
            {
                uint dpi = Native.GetDpiForWindow(Handle);
                if (dpi >= 96) _s = dpi / 96f;
            }
            catch (Exception) { }
            if (_s < 1f) _s = 1f;
            if (_s > 4f) _s = 4f;
            _font = new Font("Segoe UI", 12f * _s, FontStyle.Regular, GraphicsUnit.Pixel);
            BuildButtons();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            Native.SetWindowPos(Handle, new IntPtr(-1), _screen.X, _screen.Y, _screen.Width, _screen.Height, 0x0040);
            Native.ForceForeground(Handle);
            Activate();
            Focus();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                if (_dim != null) { _dim.Dispose(); _dim = null; }
                if (_font != null) { _font.Dispose(); _font = null; }
            }
            base.Dispose(disposing);
        }

        // ------------------------------------------------------------ toolbar
        void BuildButtons()
        {
            _btns.Clear();
            using (Graphics g = CreateGraphics())
            {
                AddText(g, "tool", Tool.Select, "Выбор");
                AddText(g, "tool", Tool.Pen, "Перо");
                AddText(g, "tool", Tool.Line, "Линия");
                AddText(g, "tool", Tool.Arrow, "Стрелка");
                AddText(g, "tool", Tool.Rect, "Рамка");
                AddText(g, "tool", Tool.Marker, "Маркер");
                AddText(g, "tool", Tool.Mosaic, "Мозаика");
                AddText(g, "tool", Tool.Text, "Текст");
                AddSep();
                for (int i = 0; i < Palette.Length; i++) AddColor(Palette[i]);
                AddSep();
                AddText(g, "width", Tool.Select, "Толщ. 11");
                AddText(g, "undo", Tool.Select, "Назад");
                AddSep();
                AddText(g, "copy", Tool.Select, "В буфер");
                AddText(g, "save", Tool.Select, "Сохранить");
                AddText(g, "cancel", Tool.Select, "Отмена");
            }
        }

        void AddText(Graphics g, string kind, Tool t, string label)
        {
            Btn b = new Btn();
            b.Kind = kind;
            b.T = t;
            b.Label = label;
            b.W = (int)Math.Ceiling(g.MeasureString(label, _font).Width) + (int)(14 * _s);
            _btns.Add(b);
        }

        void AddColor(Color c)
        {
            Btn b = new Btn();
            b.Kind = "color";
            b.C = c;
            b.W = (int)(26 * _s);
            _btns.Add(b);
        }

        void AddSep()
        {
            Btn b = new Btn();
            b.Kind = "sep";
            b.W = (int)(10 * _s);
            _btns.Add(b);
        }

        void PlaceToolbar()
        {
            _tbRect = Rectangle.Empty;
            if (!_hasSel || _textMode || _drag == DragMode.NewSel) return;
            if (_sel.Width < 2 || _sel.Height < 2) return;

            int pad = (int)(6 * _s);
            int h = (int)(38 * _s);
            int gap = (int)(2 * _s);
            int total = pad * 2 - gap;
            for (int i = 0; i < _btns.Count; i++) total += _btns[i].W + gap;

            int margin = (int)(8 * _s);
            int x = _sel.Right - total;
            if (x + total > ClientSize.Width - margin) x = ClientSize.Width - margin - total;
            if (x < margin) x = margin;

            int y = _sel.Bottom + margin;
            if (y + h > ClientSize.Height - margin)
            {
                y = _sel.Top - h - margin;
                if (y < margin) y = Math.Min(_sel.Bottom, ClientSize.Height) - h - margin * 2;
                if (y < margin) y = margin;
            }

            _tbRect = new Rectangle(x, y, total, h);
            int cx = x + pad;
            int vpad = (int)(4 * _s);
            for (int i = 0; i < _btns.Count; i++)
            {
                Btn b = _btns[i];
                b.R = new Rectangle(cx, y + vpad, b.W, h - vpad * 2);
                cx += b.W + gap;
            }
        }

        Btn HitBtn(Point p)
        {
            if (_tbRect.IsEmpty || !_tbRect.Contains(p)) return null;
            for (int i = 0; i < _btns.Count; i++)
            {
                Btn b = _btns[i];
                if (b.Kind != "sep" && b.R.Contains(p)) return b;
            }
            return null;
        }

        void OnButton(Btn b)
        {
            switch (b.Kind)
            {
                case "tool":
                    SetTool(b.T);
                    break;
                case "color":
                    _color = b.C;
                    if (_textEdit != null) _textEdit.Color = _color;
                    Invalidate();
                    break;
                case "width":
                    _widthIndex = (_widthIndex + 1) % Widths.Length;
                    if (_textEdit != null) _textEdit.Width = PixelWidth();
                    Invalidate();
                    break;
                case "undo":
                    Undo();
                    break;
                case "copy":
                    Finish(true);
                    break;
                case "save":
                    Finish(false);
                    break;
                case "cancel":
                    Cancel();
                    break;
            }
        }

        void SetTool(Tool t)
        {
            CommitText();
            _tool = t;
            Invalidate();
        }

        int PixelWidth()
        {
            return Math.Max(1, (int)Math.Round(Widths[_widthIndex] * _s));
        }

        // ------------------------------------------------------------ geometry
        Point Clamp(Point p)
        {
            return new Point(
                Math.Max(0, Math.Min(ClientSize.Width, p.X)),
                Math.Max(0, Math.Min(ClientSize.Height, p.Y)));
        }

        static Rectangle MakeRect(Point a, Point b)
        {
            int x = Math.Min(a.X, b.X);
            int y = Math.Min(a.Y, b.Y);
            return new Rectangle(x, y, Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y));
        }

        Point[] HandlePoints()
        {
            int cx = _sel.X + _sel.Width / 2;
            int cy = _sel.Y + _sel.Height / 2;
            return new Point[]
            {
                new Point(_sel.Left, _sel.Top), new Point(cx, _sel.Top), new Point(_sel.Right, _sel.Top),
                new Point(_sel.Right, cy), new Point(_sel.Right, _sel.Bottom), new Point(cx, _sel.Bottom),
                new Point(_sel.Left, _sel.Bottom), new Point(_sel.Left, cy)
            };
        }

        int HitHandle(Point p)
        {
            if (!_hasSel) return -1;
            int r = (int)Math.Max(8, 7 * _s);
            Point[] hp = HandlePoints();
            for (int i = 0; i < hp.Length; i++)
            {
                if (Math.Abs(p.X - hp[i].X) <= r && Math.Abs(p.Y - hp[i].Y) <= r) return i;
            }
            return -1;
        }

        static Cursor HandleCursor(int h)
        {
            switch (h)
            {
                case 0:
                case 4: return Cursors.SizeNWSE;
                case 2:
                case 6: return Cursors.SizeNESW;
                case 1:
                case 5: return Cursors.SizeNS;
                default: return Cursors.SizeWE;
            }
        }

        void UpdateCursor(Point p)
        {
            Cursor c = Cursors.Cross;
            if (_hasSel && !_textMode)
            {
                PlaceToolbar();
                if (HitBtn(p) != null) c = Cursors.Hand;
                else if (!_tbRect.IsEmpty && _tbRect.Contains(p)) c = Cursors.Default;
                else if (_tool == Tool.Select)
                {
                    int h = HitHandle(p);
                    if (h >= 0) c = HandleCursor(h);
                    else if (_sel.Contains(p)) c = Cursors.SizeAll;
                }
                else if (_sel.Contains(p)) c = (_tool == Tool.Text) ? Cursors.IBeam : Cursors.Cross;
                else c = Cursors.Default;
            }
            if (Cursor != c) Cursor = c;
        }

        void OffsetAnns(int dx, int dy)
        {
            if (dx == 0 && dy == 0) return;
            for (int i = 0; i < _anns.Count; i++)
            {
                Ann a = _anns[i];
                a.A = new Point(a.A.X + dx, a.A.Y + dy);
                a.B = new Point(a.B.X + dx, a.B.Y + dy);
                for (int k = 0; k < a.Points.Count; k++)
                    a.Points[k] = new Point(a.Points[k].X + dx, a.Points[k].Y + dy);
            }
        }

        // ------------------------------------------------------------ mouse
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Right) { RightClick(); return; }
            if (e.Button != MouseButtons.Left) return;

            Point p = e.Location;
            PlaceToolbar();
            if (!_tbRect.IsEmpty && _tbRect.Contains(p))
            {
                Btn b = HitBtn(p);
                if (b != null) OnButton(b);
                return;
            }

            if (_hasSel && !_textMode && _tool != Tool.Select)
            {
                if (_sel.Contains(p)) BeginAnnotation(p);
                else CommitText();
                return;
            }

            if (_hasSel && !_textMode && _tool == Tool.Select)
            {
                int h = HitHandle(p);
                if (h >= 0)
                {
                    _drag = DragMode.Resize;
                    _handle = h;
                    _dragStart = p;
                    _selStart = _sel;
                    return;
                }
                if (_sel.Contains(p))
                {
                    _drag = DragMode.Move;
                    _dragStart = p;
                    _selStart = _sel;
                    return;
                }
            }

            // Новое выделение.
            _anns.Clear();
            _cur = null;
            _textEdit = null;
            _tool = Tool.Select;
            _anchor = Clamp(p);
            _sel = new Rectangle(_anchor.X, _anchor.Y, 0, 0);
            _hasSel = true;
            _drag = DragMode.NewSel;
            Invalidate();
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            Point p = e.Location;

            switch (_drag)
            {
                case DragMode.NewSel:
                    _sel = MakeRect(_anchor, Clamp(p));
                    Invalidate();
                    return;

                case DragMode.Move:
                    {
                        int nx = Math.Max(0, Math.Min(ClientSize.Width - _selStart.Width, _selStart.X + (p.X - _dragStart.X)));
                        int ny = Math.Max(0, Math.Min(ClientSize.Height - _selStart.Height, _selStart.Y + (p.Y - _dragStart.Y)));
                        OffsetAnns(nx - _sel.X, ny - _sel.Y);
                        _sel = new Rectangle(nx, ny, _selStart.Width, _selStart.Height);
                        Invalidate();
                        return;
                    }

                case DragMode.Resize:
                    {
                        Point q = Clamp(p);
                        int l = _selStart.Left, t = _selStart.Top, r = _selStart.Right, b = _selStart.Bottom;
                        if (_handle == 0 || _handle == 6 || _handle == 7) l = q.X;
                        if (_handle == 0 || _handle == 1 || _handle == 2) t = q.Y;
                        if (_handle == 2 || _handle == 3 || _handle == 4) r = q.X;
                        if (_handle == 4 || _handle == 5 || _handle == 6) b = q.Y;
                        _sel = Rectangle.FromLTRB(Math.Min(l, r), Math.Min(t, b), Math.Max(l, r), Math.Max(t, b));
                        Invalidate();
                        return;
                    }

                case DragMode.Draw:
                    UpdateDraw(Clamp(p));
                    Invalidate();
                    return;
            }

            PlaceToolbar();
            int hv = -1;
            if (_hasSel && !_textMode)
            {
                for (int i = 0; i < _btns.Count; i++)
                {
                    if (_btns[i].Kind != "sep" && !_tbRect.IsEmpty && _btns[i].R.Contains(p)) { hv = i; break; }
                }
            }
            if (hv != _hover) { _hover = hv; Invalidate(); }
            UpdateCursor(p);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (e.Button != MouseButtons.Left) return;

            DragMode d = _drag;
            _drag = DragMode.None;

            if (d == DragMode.NewSel)
            {
                if (_sel.Width < 6 || _sel.Height < 6)
                {
                    _hasSel = false;
                    _sel = Rectangle.Empty;
                }
                else if (_textMode)
                {
                    Finish(false);
                    return;
                }
            }
            else if (d == DragMode.Draw)
            {
                EndAnnotation();
            }
            Invalidate();
            UpdateCursor(e.Location);
        }

        protected override void OnMouseDoubleClick(MouseEventArgs e)
        {
            base.OnMouseDoubleClick(e);
            if (e.Button != MouseButtons.Left || _textMode || !_hasSel) return;
            PlaceToolbar();
            if (_tool == Tool.Select && _sel.Contains(e.Location) && HitBtn(e.Location) == null) Finish(false);
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            if (!_hasSel || _textMode) return;
            int dir = e.Delta > 0 ? 1 : -1;
            _widthIndex = Math.Max(0, Math.Min(Widths.Length - 1, _widthIndex + dir));
            if (_textEdit != null) _textEdit.Width = PixelWidth();
            Invalidate();
        }

        void RightClick()
        {
            if (_textEdit != null) { _textEdit = null; Invalidate(); return; }
            if (_hasSel)
            {
                _hasSel = false;
                _sel = Rectangle.Empty;
                _anns.Clear();
                _cur = null;
                _tool = Tool.Select;
                _drag = DragMode.None;
                Invalidate();
            }
            else
            {
                Cancel();
            }
        }

        // ------------------------------------------------------------ annotations
        Ann NewAnn(Tool t)
        {
            Ann a = new Ann();
            a.Kind = t;
            a.Color = _color;
            a.Width = PixelWidth();
            return a;
        }

        void BeginAnnotation(Point p)
        {
            CommitText();
            if (_tool == Tool.Text)
            {
                _textEdit = NewAnn(Tool.Text);
                _textEdit.A = p;
                Invalidate();
                return;
            }
            _cur = NewAnn(_tool);
            if (_tool == Tool.Pen) _cur.Points.Add(p);
            else { _cur.A = p; _cur.B = p; }
            _drag = DragMode.Draw;
        }

        void UpdateDraw(Point p)
        {
            if (_cur == null) return;
            if (_cur.Kind == Tool.Pen)
            {
                Point last = _cur.Points[_cur.Points.Count - 1];
                if (Math.Abs(p.X - last.X) + Math.Abs(p.Y - last.Y) >= 2) _cur.Points.Add(p);
                return;
            }

            if ((ModifierKeys & Keys.Shift) == Keys.Shift && (_cur.Kind == Tool.Line || _cur.Kind == Tool.Arrow))
            {
                int dx = p.X - _cur.A.X;
                int dy = p.Y - _cur.A.Y;
                double step = Math.PI / 4.0;
                double ang = Math.Round(Math.Atan2(dy, dx) / step) * step;
                double len = Math.Sqrt((double)dx * dx + (double)dy * dy);
                p = new Point(_cur.A.X + (int)Math.Round(len * Math.Cos(ang)), _cur.A.Y + (int)Math.Round(len * Math.Sin(ang)));
            }
            _cur.B = p;
        }

        void EndAnnotation()
        {
            if (_cur == null) return;
            bool keep = true;
            if (_cur.Kind != Tool.Pen)
                keep = Math.Abs(_cur.B.X - _cur.A.X) + Math.Abs(_cur.B.Y - _cur.A.Y) >= 4;
            if (keep) _anns.Add(_cur);
            _cur = null;
        }

        void CommitText()
        {
            if (_textEdit == null) return;
            if (_textEdit.Text.Length > 0) _anns.Add(_textEdit);
            _textEdit = null;
            Invalidate();
        }

        void Undo()
        {
            if (_textEdit != null) _textEdit = null;
            else if (_anns.Count > 0) _anns.RemoveAt(_anns.Count - 1);
            Invalidate();
        }

        // ------------------------------------------------------------ keyboard
        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e);

            if (e.KeyCode == Keys.Escape)
            {
                if (_textEdit != null) { _textEdit = null; Invalidate(); }
                else Cancel();
                e.Handled = true;
                return;
            }

            if (_textEdit != null)
            {
                if (e.KeyCode == Keys.Enter)
                {
                    CommitText();
                    e.SuppressKeyPress = true;
                    e.Handled = true;
                }
                return;
            }

            if (e.Control && e.KeyCode == Keys.Z) { Undo(); e.Handled = true; return; }
            if (e.Control && e.KeyCode == Keys.C) { Finish(true); e.Handled = true; return; }
            if (e.Control && e.KeyCode == Keys.S) { Finish(false); e.Handled = true; return; }
            if (e.KeyCode == Keys.Enter) { Finish(false); e.Handled = true; return; }

            if (_hasSel && !_textMode && !e.Control && !e.Alt)
            {
                switch (e.KeyCode)
                {
                    case Keys.V: SetTool(Tool.Select); e.Handled = true; break;
                    case Keys.P: SetTool(Tool.Pen); e.Handled = true; break;
                    case Keys.L: SetTool(Tool.Line); e.Handled = true; break;
                    case Keys.A: SetTool(Tool.Arrow); e.Handled = true; break;
                    case Keys.R: SetTool(Tool.Rect); e.Handled = true; break;
                    case Keys.H: SetTool(Tool.Marker); e.Handled = true; break;
                    case Keys.B: SetTool(Tool.Mosaic); e.Handled = true; break;
                    case Keys.T: SetTool(Tool.Text); e.Handled = true; break;
                }
            }
        }

        protected override void OnKeyPress(KeyPressEventArgs e)
        {
            base.OnKeyPress(e);
            if (_textEdit == null) return;
            char c = e.KeyChar;
            if (c == '\b')
            {
                if (_textEdit.Text.Length > 0) _textEdit.Text = _textEdit.Text.Substring(0, _textEdit.Text.Length - 1);
            }
            else if (!char.IsControl(c))
            {
                _textEdit.Text += c;
            }
            e.Handled = true;
            Invalidate();
        }

        // ------------------------------------------------------------ finish
        void Cancel()
        {
            ResultBitmap = null;
            Close();
        }

        void Finish(bool forceCopy)
        {
            if (!_hasSel) return;
            // Страховка: выделение никогда не выходит за пределы снимка.
            _sel = Rectangle.Intersect(_sel, new Rectangle(0, 0, _shot.Width, _shot.Height));
            if (_sel.Width < 2 || _sel.Height < 2) return;
            CommitText();
            ResultBitmap = Render();
            ForceCopy = forceCopy;
            Close();
        }

        Bitmap Render()
        {
            Bitmap bmp = new Bitmap(_sel.Width, _sel.Height, PixelFormat.Format24bppRgb);
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.DrawImage(_shot, new Rectangle(0, 0, _sel.Width, _sel.Height), _sel.X, _sel.Y, _sel.Width, _sel.Height, GraphicsUnit.Pixel);
                g.TranslateTransform(-_sel.X, -_sel.Y);
                for (int i = 0; i < _anns.Count; i++) DrawAnn(g, _anns[i], false);
            }
            return bmp;
        }

        // ------------------------------------------------------------ painting
        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics g = e.Graphics;
            g.InterpolationMode = InterpolationMode.NearestNeighbor;
            g.PixelOffsetMode = PixelOffsetMode.Half;

            // Всегда явный прямоугольник назначения: DrawImage(img, x, y) учитывает
            // DPI картинки и «увеличивает» снимок на экранах с масштабом.
            g.DrawImage(_dim, new Rectangle(0, 0, _dim.Width, _dim.Height), 0, 0, _dim.Width, _dim.Height, GraphicsUnit.Pixel);

            if (_hasSel && _sel.Width > 0 && _sel.Height > 0)
            {
                g.DrawImage(_shot, _sel, _sel.X, _sel.Y, _sel.Width, _sel.Height, GraphicsUnit.Pixel);

                GraphicsState st = g.Save();
                g.SetClip(_sel);
                for (int i = 0; i < _anns.Count; i++) DrawAnn(g, _anns[i], false);
                if (_cur != null) DrawAnn(g, _cur, false);
                if (_textEdit != null) DrawAnn(g, _textEdit, true);
                g.Restore(st);

                PaintSelectionChrome(g);
            }

            PaintHint(g);
            PlaceToolbar();
            PaintToolbar(g);
        }

        void PaintSelectionChrome(Graphics g)
        {
            GraphicsState st = g.Save();
            g.SmoothingMode = SmoothingMode.None;

            int bw = Math.Max(1, (int)Math.Round(1.5f * _s));
            using (Pen pen = new Pen(Color.FromArgb(0, 150, 255), bw))
            {
                g.DrawRectangle(pen, _sel.X - bw, _sel.Y - bw, _sel.Width + bw, _sel.Height + bw);
            }

            if (_tool == Tool.Select && !_textMode && _drag != DragMode.NewSel)
            {
                int hs = (int)Math.Max(7, 7 * _s);
                Point[] hp = HandlePoints();
                using (SolidBrush fill = new SolidBrush(Color.White))
                using (Pen edge = new Pen(Color.FromArgb(0, 120, 215), Math.Max(1, (int)_s)))
                {
                    for (int i = 0; i < hp.Length; i++)
                    {
                        Rectangle hr = new Rectangle(hp[i].X - hs / 2, hp[i].Y - hs / 2, hs, hs);
                        g.FillRectangle(fill, hr);
                        g.DrawRectangle(edge, hr);
                    }
                }
            }
            g.Restore(st);

            string txt = _sel.Width + " \u00D7 " + _sel.Height;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            SizeF ts = g.MeasureString(txt, _font);
            int lw = (int)ts.Width + (int)(10 * _s);
            int lh = (int)ts.Height + (int)(4 * _s);
            int lx = _sel.X;
            int ly = _sel.Y - lh - (int)(6 * _s);
            if (ly < 2) ly = _sel.Y + (int)(6 * _s);
            if (lx + lw > ClientSize.Width) lx = ClientSize.Width - lw - 2;
            using (SolidBrush bg = new SolidBrush(Color.FromArgb(215, 20, 20, 20)))
            {
                g.FillRectangle(bg, lx, ly, lw, lh);
            }
            g.DrawString(txt, _font, Brushes.White, lx + 5 * _s, ly + 2 * _s);
        }

        void PaintHint(Graphics g)
        {
            string t = null;
            if (!_hasSel) t = _textMode ? HintText : HintRegion;
            else if (!_textMode && _drag == DragMode.None) t = HintEdit;
            if (t == null) return;

            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            SizeF ts = g.MeasureString(t, _font);
            int w = (int)ts.Width + (int)(28 * _s);
            int h = (int)ts.Height + (int)(12 * _s);
            Rectangle r = new Rectangle((ClientSize.Width - w) / 2, (int)(16 * _s), w, h);
            if (_hasSel && _sel.IntersectsWith(Rectangle.Inflate(r, 0, (int)(30 * _s)))) return;

            g.SmoothingMode = SmoothingMode.AntiAlias;
            using (GraphicsPath gp = RoundRect(r, (int)(8 * _s)))
            using (SolidBrush bg = new SolidBrush(Color.FromArgb(215, 20, 22, 26)))
            {
                g.FillPath(bg, gp);
            }
            using (StringFormat sf = new StringFormat())
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;
                g.DrawString(t, _font, Brushes.White, r, sf);
            }
        }

        void PaintToolbar(Graphics g)
        {
            if (_tbRect.IsEmpty) return;

            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            using (GraphicsPath gp = RoundRect(_tbRect, (int)(8 * _s)))
            using (SolidBrush bg = new SolidBrush(Color.FromArgb(244, 34, 36, 40)))
            {
                g.FillPath(bg, gp);
            }

            using (StringFormat sf = new StringFormat())
            {
                sf.Alignment = StringAlignment.Center;
                sf.LineAlignment = StringAlignment.Center;

                for (int i = 0; i < _btns.Count; i++)
                {
                    Btn b = _btns[i];
                    bool hov = (i == _hover);

                    if (b.Kind == "sep")
                    {
                        using (Pen sp = new Pen(Color.FromArgb(90, 255, 255, 255), 1))
                        {
                            int sx = b.R.X + b.R.Width / 2;
                            g.DrawLine(sp, sx, b.R.Y + (int)(6 * _s), sx, b.R.Bottom - (int)(6 * _s));
                        }
                        continue;
                    }

                    if (b.Kind == "color")
                    {
                        int sz = (int)(16 * _s);
                        Rectangle sw = new Rectangle(b.R.X + (b.R.Width - sz) / 2, b.R.Y + (b.R.Height - sz) / 2, sz, sz);
                        using (SolidBrush cb = new SolidBrush(b.C)) g.FillEllipse(cb, sw);
                        bool selected = (b.C.ToArgb() == _color.ToArgb());
                        using (Pen cp = new Pen(selected ? Color.White : Color.FromArgb(hov ? 200 : 110, 255, 255, 255), selected ? 2f * _s : 1f))
                        {
                            Rectangle ring = Rectangle.Inflate(sw, (int)(3 * _s), (int)(3 * _s));
                            if (selected || hov) g.DrawEllipse(cp, ring);
                            else g.DrawEllipse(cp, sw);
                        }
                        continue;
                    }

                    if (b.Kind == "width") b.Label = "\u0422\u043E\u043B\u0449. " + Widths[_widthIndex];

                    bool active = (b.Kind == "tool" && b.T == _tool);
                    bool primary = (b.Kind == "save");
                    Color fillColor = Color.Transparent;
                    if (primary) fillColor = hov ? Color.FromArgb(30, 140, 235) : Color.FromArgb(0, 120, 215);
                    else if (active) fillColor = Color.FromArgb(0, 120, 215);
                    else if (hov) fillColor = (b.Kind == "cancel") ? Color.FromArgb(200, 70, 70) : Color.FromArgb(70, 255, 255, 255);

                    if (fillColor != Color.Transparent)
                    {
                        using (GraphicsPath bp = RoundRect(b.R, (int)(5 * _s)))
                        using (SolidBrush fb = new SolidBrush(fillColor))
                        {
                            g.FillPath(fb, bp);
                        }
                    }
                    g.DrawString(b.Label, _font, Brushes.White, b.R, sf);
                }
            }
        }

        static GraphicsPath RoundRect(Rectangle r, int rad)
        {
            int d = Math.Max(2, rad * 2);
            GraphicsPath p = new GraphicsPath();
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        // Рисует аннотацию в координатах снимка. Используется и для экрана,
        // и для итогового PNG, поэтому результат совпадает с тем, что видно.
        void DrawAnn(Graphics g, Ann a, bool caret)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            switch (a.Kind)
            {
                case Tool.Pen:
                    {
                        if (a.Points.Count == 1)
                        {
                            Point q = a.Points[0];
                            using (SolidBrush b = new SolidBrush(a.Color))
                                g.FillEllipse(b, q.X - a.Width / 2f, q.Y - a.Width / 2f, a.Width, a.Width);
                        }
                        else if (a.Points.Count > 1)
                        {
                            using (Pen p = new Pen(a.Color, a.Width))
                            {
                                p.StartCap = LineCap.Round;
                                p.EndCap = LineCap.Round;
                                p.LineJoin = LineJoin.Round;
                                g.DrawLines(p, a.Points.ToArray());
                            }
                        }
                        break;
                    }

                case Tool.Line:
                case Tool.Arrow:
                    {
                        if (a.A == a.B) break;
                        using (Pen p = new Pen(a.Color, a.Width))
                        {
                            p.StartCap = LineCap.Round;
                            p.LineJoin = LineJoin.Round;
                            AdjustableArrowCap cap = null;
                            if (a.Kind == Tool.Arrow)
                            {
                                cap = new AdjustableArrowCap(4f, 5f, true);
                                p.CustomEndCap = cap;
                            }
                            else
                            {
                                p.EndCap = LineCap.Round;
                            }
                            g.DrawLine(p, a.A, a.B);
                            if (cap != null) cap.Dispose();
                        }
                        break;
                    }

                case Tool.Rect:
                    {
                        using (Pen p = new Pen(a.Color, a.Width))
                        {
                            p.LineJoin = LineJoin.Miter;
                            g.DrawRectangle(p, MakeRect(a.A, a.B));
                        }
                        break;
                    }

                case Tool.Marker:
                    {
                        using (SolidBrush b = new SolidBrush(Color.FromArgb(95, a.Color)))
                            g.FillRectangle(b, MakeRect(a.A, a.B));
                        break;
                    }

                case Tool.Mosaic:
                    {
                        DrawMosaic(g, MakeRect(a.A, a.B));
                        break;
                    }

                case Tool.Text:
                    {
                        string t = a.Text;
                        if (caret) t += "|";
                        if (t.Length == 0) break;
                        float fs = 12f * _s + a.Width * 2.5f;
                        using (Font f = new Font("Segoe UI", fs, FontStyle.Bold, GraphicsUnit.Pixel))
                        using (SolidBrush b = new SolidBrush(a.Color))
                        {
                            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                            g.DrawString(t, f, b, a.A.X, a.A.Y);
                        }
                        break;
                    }
            }
        }

        void DrawMosaic(Graphics g, Rectangle r)
        {
            r.Intersect(new Rectangle(0, 0, _shot.Width, _shot.Height));
            if (r.Width < 2 || r.Height < 2) return;

            int block = Math.Max(6, (int)Math.Round(10 * _s));
            int sw = Math.Max(1, r.Width / block);
            int sh = Math.Max(1, r.Height / block);
            using (Bitmap small = new Bitmap(sw, sh, PixelFormat.Format24bppRgb))
            {
                using (Graphics sg = Graphics.FromImage(small))
                {
                    sg.InterpolationMode = InterpolationMode.HighQualityBilinear;
                    sg.PixelOffsetMode = PixelOffsetMode.Half;
                    sg.DrawImage(_shot, new Rectangle(0, 0, sw, sh), r.X, r.Y, r.Width, r.Height, GraphicsUnit.Pixel);
                }
                GraphicsState st = g.Save();
                g.SmoothingMode = SmoothingMode.None;
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.DrawImage(small, r, 0, 0, sw, sh, GraphicsUnit.Pixel);
                g.Restore(st);
            }
        }
    }
}
''';
}
