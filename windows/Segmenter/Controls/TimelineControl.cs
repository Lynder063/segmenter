using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Segmenter.Models;

namespace Segmenter.Controls
{
    public class TimelineControl : FrameworkElement
    {
        public static readonly DependencyProperty DurationMsProperty =
            DependencyProperty.Register(nameof(DurationMs), typeof(long), typeof(TimelineControl),
                new FrameworkPropertyMetadata(60000L, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

        public static readonly DependencyProperty VideoDurationMsProperty =
            DependencyProperty.Register(nameof(VideoDurationMs), typeof(long), typeof(TimelineControl),
                new FrameworkPropertyMetadata(0L, FrameworkPropertyMetadataOptions.AffectsRender));

        public static readonly DependencyProperty CurrentTimeMsProperty =
            DependencyProperty.Register(nameof(CurrentTimeMs), typeof(long), typeof(TimelineControl),
                new FrameworkPropertyMetadata(0L, FrameworkPropertyMetadataOptions.AffectsRender));

        public static readonly DependencyProperty ZoomProperty =
            DependencyProperty.Register(nameof(Zoom), typeof(double), typeof(TimelineControl),
                new FrameworkPropertyMetadata(1.0, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

        public static readonly DependencyProperty ServerSegmentsProperty =
            DependencyProperty.Register(nameof(ServerSegments), typeof(Dictionary<SegmentType, List<SegmentRange>>), typeof(TimelineControl),
                new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

        public static readonly DependencyProperty DraftsProperty =
            DependencyProperty.Register(nameof(Drafts), typeof(Dictionary<SegmentType, List<SegmentDraft>>), typeof(TimelineControl),
                new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

        public static readonly DependencyProperty AudioTrackProperty =
            DependencyProperty.Register(nameof(AudioTrack), typeof(TimelineDensityTrack), typeof(TimelineControl),
                new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

        public long DurationMs
        {
            get => (long)GetValue(DurationMsProperty);
            set => SetValue(DurationMsProperty, value);
        }

        public long VideoDurationMs
        {
            get => (long)GetValue(VideoDurationMsProperty);
            set => SetValue(VideoDurationMsProperty, value);
        }

        public long CurrentTimeMs
        {
            get => (long)GetValue(CurrentTimeMsProperty);
            set => SetValue(CurrentTimeMsProperty, value);
        }

        public double Zoom
        {
            get => (double)GetValue(ZoomProperty);
            set => SetValue(ZoomProperty, value);
        }

        public Dictionary<SegmentType, List<SegmentRange>> ServerSegments
        {
            get => (Dictionary<SegmentType, List<SegmentRange>>)GetValue(ServerSegmentsProperty);
            set => SetValue(ServerSegmentsProperty, value);
        }

        public Dictionary<SegmentType, List<SegmentDraft>> Drafts
        {
            get => (Dictionary<SegmentType, List<SegmentDraft>>)GetValue(DraftsProperty);
            set => SetValue(DraftsProperty, value);
        }

        public TimelineDensityTrack AudioTrack
        {
            get => (TimelineDensityTrack)GetValue(AudioTrackProperty);
            set => SetValue(AudioTrackProperty, value);
        }

        // Action Events matching Python Signals
        public event Action<long>? SeekRequested;
        public event Action<SegmentType, long, long>? DraftRangeCreated;
        public event Action<SegmentType, int, long>? DraftStartDragged;
        public event Action<SegmentType, int, long>? DraftEndDragged;
        public event Action<SegmentType, int, SegmentType, long, long>? DraftMoved;
        public event Action? DragBegan;
        public event Action? DragEnded;

        private const double RowHeight = 36.0;
        private const double HandleGrabWidth = 10.0;

        // Drag State
        private string? _dragMode = null; // "seek", "resize_start", "resize_end", "move", "create"
        private SegmentType? _dragSegmentType = null;
        private SegmentType? _dragSegmentTypeTarget = null;
        private int? _dragDraftIndex = null;
        private long _dragAnchorMs = 0;
        private long _dragCurrentMs = 0;
        private long _dragStartValMs = 0;
        private long _dragEndValMs = 0;

        // Render Cache
        private DrawingGroup? _cachedBackgroundDrawing = null;
        private double _lastRenderWidth = -1;
        private long _lastRenderDurationMs = -1;
        private TimelineDensityTrack? _lastRenderAudioTrack = null;

        public TimelineControl()
        {
            ClipToBounds = true;
            Focusable = true;
        }

        private int GetRowCount()
        {
            int numDensity = (AudioTrack != null && AudioTrack.HasContent) ? 1 : 0;
            return numDensity + Enum.GetValues(typeof(SegmentType)).Length;
        }

        private int GetRowIndex(SegmentType type)
        {
            int numDensity = (AudioTrack != null && AudioTrack.HasContent) ? 1 : 0;
            return numDensity + (int)type;
        }

        private SegmentType GetSegmentTypeAtY(double y)
        {
            int numDensity = (AudioTrack != null && AudioTrack.HasContent) ? 1 : 0;
            double offsetY = y - (numDensity * RowHeight);
            int rowIdx = (int)Math.Max(0, Math.Min(offsetY / RowHeight, Enum.GetValues(typeof(SegmentType)).Length - 1));
            return (SegmentType)rowIdx;
        }

        private double MsToPos(long ms)
        {
            if (DurationMs <= 0) return 0;
            double clamped = Math.Max(0, Math.Min(ms, DurationMs));
            return (clamped / (double)DurationMs) * ActualWidth;
        }

        private long PosToMs(double x)
        {
            if (ActualWidth <= 0) return 0;
            double ratio = x / ActualWidth;
            return (long)(ratio * DurationMs);
        }

        private (SegmentType SegType, int DraftIdx, string Edge)? HitTestHandle(Point pos)
        {
            if (Drafts == null) return null;

            foreach (SegmentType segType in Enum.GetValues(typeof(SegmentType)))
            {
                int rowIdx = GetRowIndex(segType);
                double rowY = rowIdx * RowHeight;
                if (pos.Y >= rowY && pos.Y <= rowY + RowHeight)
                {
                    if (Drafts.TryGetValue(segType, out var list))
                    {
                        for (int idx = 0; idx < list.Count; idx++)
                        {
                            var draft = list[idx];
                            if (draft.StartMs != null)
                            {
                                double hx = MsToPos(draft.StartMs.Value);
                                if (Math.Abs(pos.X - hx) <= HandleGrabWidth)
                                {
                                    return (segType, idx, "start");
                                }
                            }
                            if (draft.EndMs != null)
                            {
                                double hx = MsToPos(draft.EndMs.Value);
                                if (Math.Abs(pos.X - hx) <= HandleGrabWidth)
                                {
                                    return (segType, idx, "end");
                                }
                            }
                        }
                    }
                }
            }
            return null;
        }

        private (SegmentType SegType, int DraftIdx)? HitTestDraftBar(Point pos)
        {
            if (Drafts == null) return null;

            foreach (SegmentType segType in Enum.GetValues(typeof(SegmentType)))
            {
                int rowIdx = GetRowIndex(segType);
                double rowY = rowIdx * RowHeight;
                if (pos.Y >= rowY + 4 && pos.Y <= rowY + RowHeight - 4)
                {
                    if (Drafts.TryGetValue(segType, out var list))
                    {
                        for (int idx = 0; idx < list.Count; idx++)
                        {
                            var draft = list[idx];
                            if (draft.StartMs != null && draft.EndMs != null)
                            {
                                double x0 = MsToPos(draft.StartMs.Value);
                                double x1 = MsToPos(draft.EndMs.Value);
                                if (pos.X >= x0 && pos.X <= x1)
                                {
                                    return (segType, idx);
                                }
                            }
                        }
                    }
                }
            }
            return null;
        }

        protected override Size MeasureOverride(Size constraint)
        {
            double baseWidth = (DurationMs / 1000.0) * 8.0;
            double calculatedWidth = Math.Max(240.0, Math.Min(baseWidth * Zoom, 48000.0));
            
            // Allow parent viewport to expand beyond calculatedWidth if needed
            double width = double.IsInfinity(constraint.Width) ? calculatedWidth : Math.Max(calculatedWidth, constraint.Width);
            double height = GetRowCount() * RowHeight;

            return new Size(width, height);
        }

        protected override Size ArrangeOverride(Size arrangeBounds)
        {
            return arrangeBounds;
        }

        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
        {
            base.OnMouseLeftButtonDown(e);
            Point pos = e.GetPosition(this);
            CaptureMouse();

            bool isShift = Keyboard.IsKeyDown(Key.LeftShift) || Keyboard.IsKeyDown(Key.RightShift);
            bool isAlt = Keyboard.IsKeyDown(Key.LeftAlt) || Keyboard.IsKeyDown(Key.RightAlt);

            // 1. Drag Handles (Resize)
            var handleHit = HitTestHandle(pos);
            if (handleHit != null && !isShift && !isAlt)
            {
                _dragMode = handleHit.Value.Edge == "start" ? "resize_start" : "resize_end";
                _dragSegmentType = handleHit.Value.SegType;
                _dragDraftIndex = handleHit.Value.DraftIdx;
                DragBegan?.Invoke();
                e.Handled = true;
                return;
            }

            // 2. Full Segment Move (Shift + Drag)
            if (isShift)
            {
                var barHit = HitTestDraftBar(pos);
                if (barHit != null)
                {
                    _dragMode = "move";
                    _dragSegmentType = barHit.Value.SegType;
                    _dragSegmentTypeTarget = barHit.Value.SegType;
                    _dragDraftIndex = barHit.Value.DraftIdx;
                    _dragAnchorMs = PosToMs(pos.X);
                    var draft = Drafts![_dragSegmentType.Value][_dragDraftIndex.Value];
                    _dragStartValMs = draft.StartMs ?? 0;
                    _dragEndValMs = draft.EndMs ?? 0;
                    DragBegan?.Invoke();
                    e.Handled = true;
                    return;
                }
            }

            // 3. Segment Creation (Alt + Drag)
            if (isAlt)
            {
                _dragMode = "create";
                _dragSegmentType = GetSegmentTypeAtY(pos.Y);
                _dragAnchorMs = PosToMs(pos.X);
                _dragCurrentMs = _dragAnchorMs;
                e.Handled = true;
                return;
            }

            // 4. Standard Seek
            _dragMode = "seek";
            long ms = PosToMs(pos.X);
            SeekRequested?.Invoke(ms);
            e.Handled = true;
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            Point pos = e.GetPosition(this);

            if (_dragMode == null)
            {
                // Hover cursor effects
                var handleHit = HitTestHandle(pos);
                Cursor = handleHit != null ? Cursors.SizeWE : Cursors.Arrow;
                return;
            }

            long ms = PosToMs(pos.X);

            if (_dragMode == "seek")
            {
                SeekRequested?.Invoke(ms);
            }
            else if (_dragMode == "resize_start")
            {
                DraftStartDragged?.Invoke(_dragSegmentType!.Value, _dragDraftIndex!.Value, ms);
            }
            else if (_dragMode == "resize_end")
            {
                DraftEndDragged?.Invoke(_dragSegmentType!.Value, _dragDraftIndex!.Value, ms);
            }
            else if (_dragMode == "move")
            {
                long deltaMs = ms - _dragAnchorMs;
                long newStart = Math.Max(0, _dragStartValMs + deltaMs);
                _dragCurrentMs = ms;
                _dragSegmentTypeTarget = GetSegmentTypeAtY(pos.Y);
                SeekRequested?.Invoke(newStart);
                InvalidateVisual();
            }
            else if (_dragMode == "create")
            {
                _dragCurrentMs = ms;
                InvalidateVisual();
            }
        }

        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
        {
            base.OnMouseLeftButtonUp(e);
            if (_dragMode == null) return;

            Point pos = e.GetPosition(this);
            long ms = PosToMs(pos.X);
            ReleaseMouseCapture();

            if (_dragMode == "move")
            {
                long deltaMs = ms - _dragAnchorMs;
                long newStart = Math.Max(0, _dragStartValMs + deltaMs);
                long newEnd = _dragEndValMs + deltaMs;
                var targetType = _dragSegmentTypeTarget ?? _dragSegmentType!.Value;

                DraftMoved?.Invoke(
                    _dragSegmentType!.Value,
                    _dragDraftIndex!.Value,
                    targetType,
                    newStart,
                    newEnd
                );
                DragEnded?.Invoke();
            }
            else if (_dragMode == "create")
            {
                long start = Math.Min(_dragAnchorMs, _dragCurrentMs);
                long end = Math.Max(_dragAnchorMs, _dragCurrentMs);
                if (end - start >= 100) // Avoid micro clicks
                {
                    DraftRangeCreated?.Invoke(_dragSegmentType!.Value, start, end);
                }
            }
            else if (_dragMode == "resize_start" || _dragMode == "resize_end")
            {
                DragEnded?.Invoke();
            }

            _dragMode = null;
            InvalidateVisual();
        }

        protected override void OnRender(DrawingContext drawingContext)
        {
            base.OnRender(drawingContext);
            double width = ActualWidth;
            if (width <= 0) return;

            int numDensity = (AudioTrack != null && AudioTrack.HasContent) ? 1 : 0;
            int totalRows = GetRowCount();

            // Cache validation for static background and audio track
            if (_cachedBackgroundDrawing == null || 
                _lastRenderWidth != width || 
                _lastRenderDurationMs != DurationMs || 
                _lastRenderAudioTrack != AudioTrack)
            {
                _cachedBackgroundDrawing = new DrawingGroup();
                using (DrawingContext dc = _cachedBackgroundDrawing.Open())
                {
                    var linePen = new Pen(new SolidColorBrush(Color.FromArgb(40, 255, 255, 255)), 1.0);
                    var rowBrush = new SolidColorBrush(Color.FromArgb(10, 0, 0, 0));

                    for (int r = 0; r < totalRows; r++)
                    {
                        double y = r * RowHeight;
                        dc.DrawLine(linePen, new Point(0, y), new Point(width, y));
                        dc.DrawRectangle(rowBrush, null, new Rect(0, y, width, RowHeight));
                    }

                    if (numDensity > 0 && AudioTrack != null && AudioTrack.Buckets != null && AudioTrack.Buckets.Count > 0)
                    {
                        var buckets = AudioTrack.Buckets;
                        var musicBuckets = AudioTrack.MusicLikelihoodBuckets ?? new List<float>();
                        double bucketWidth = width / buckets.Count;

                        for (int idx = 0; idx < buckets.Count; idx++)
                        {
                            float val = buckets[idx];
                            if (val <= 0) continue;

                            double barHeight = val * (RowHeight - 6);
                            double x = idx * bucketWidth;
                            double y = RowHeight - barHeight - 3;

                            float likelihood = idx < musicBuckets.Count ? musicBuckets[idx] : 0.0f;
                            var brush = new SolidColorBrush(GetAudioColor(likelihood));
                            brush.Freeze();

                            dc.DrawRectangle(brush, null, new Rect(x, y, Math.Max(1.0, bucketWidth), barHeight));
                        }
                    }
                }

                _lastRenderWidth = width;
                _lastRenderDurationMs = DurationMs;
                _lastRenderAudioTrack = AudioTrack;
            }

            // 1. Paint Cached Background
            drawingContext.DrawDrawing(_cachedBackgroundDrawing);

            // 2. Paint Segment Type Rows
            int segmentTopRow = numDensity;
            for (int i = 0; i < Enum.GetValues(typeof(SegmentType)).Length; i++)
            {
                var segType = (SegmentType)i;
                double rowY = (segmentTopRow + i) * RowHeight;
                var baseColor = (Color)ColorConverter.ConvertFromString(segType.GetHexColor());

                // Server Segments (45% opacity fill, no outline)
                if (ServerSegments != null && ServerSegments.TryGetValue(segType, out var serverRanges))
                {
                    var fillBrush = new SolidColorBrush(Color.FromArgb(115, baseColor.R, baseColor.G, baseColor.B));
                    foreach (var r in serverRanges)
                    {
                        long start = r.StartMs ?? 0;
                        long end = r.EndMs ?? DurationMs;
                        double x0 = MsToPos(start);
                        double x1 = MsToPos(end);
                        double barWidth = Math.Max(2.0, x1 - x0);

                        drawingContext.DrawRoundedRectangle(fillBrush, null, new Rect(x0, rowY + 4, barWidth, RowHeight - 8), 4.0, 4.0);
                    }
                }

                // Local Draft Segments (85% opacity fill, dashed outline)
                if (Drafts != null && Drafts.TryGetValue(segType, out var draftList))
                {
                    var fillBrush = new SolidColorBrush(Color.FromArgb(217, baseColor.R, baseColor.G, baseColor.B));
                    var borderPen = new Pen(new SolidColorBrush(Color.FromArgb(240, baseColor.R, baseColor.G, baseColor.B)), 1.5)
                    {
                        DashStyle = DashStyles.Dash
                    };

                    for (int idx = 0; idx < draftList.Count; idx++)
                    {
                        var draft = draftList[idx];
                        if (draft.StartMs == null && draft.EndMs == null) continue;

                        // Skip drawing if this specific draft is currently being dragged/moved (drawn as shadow below)
                        if (_dragMode == "move" && _dragSegmentType == segType && _dragDraftIndex == idx)
                        {
                            continue;
                        }

                        long start = draft.StartMs ?? 0;
                        long end = draft.EndMs ?? DurationMs;
                        double x0 = MsToPos(start);
                        double x1 = MsToPos(end);
                        double barWidth = Math.Max(2.0, x1 - x0);

                        drawingContext.DrawRoundedRectangle(fillBrush, borderPen, new Rect(x0, rowY + 4, barWidth, RowHeight - 8), 4.0, 4.0);
                    }
                }
            }

            // 3. Paint Move Drag Shadow
            if (_dragMode == "move" && _dragSegmentType != null && _dragDraftIndex != null)
            {
                long deltaMs = PosToMs(Mouse.GetPosition(this).X) - _dragAnchorMs;
                long dragStart = Math.Max(0, _dragStartValMs + deltaMs);
                long dragEnd = _dragEndValMs + deltaMs;

                double x0 = MsToPos(dragStart);
                double x1 = MsToPos(dragEnd);
                double barWidth = Math.Max(2.0, x1 - x0);

                var targetType = _dragSegmentTypeTarget ?? _dragSegmentType.Value;
                int targetRow = GetRowIndex(targetType);
                double targetY = targetRow * RowHeight;

                var baseColor = (Color)ColorConverter.ConvertFromString(targetType.GetHexColor());
                var fillBrush = new SolidColorBrush(Color.FromArgb(120, baseColor.R, baseColor.G, baseColor.B));
                var borderPen = new Pen(new SolidColorBrush(Color.FromArgb(220, baseColor.R, baseColor.G, baseColor.B)), 1.5)
                {
                    DashStyle = DashStyles.Dash
                };

                drawingContext.DrawRoundedRectangle(fillBrush, borderPen, new Rect(x0, targetY + 4, barWidth, RowHeight - 8), 4.0, 4.0);
            }

            // 4. Paint Alt-Create Selection Shadow
            if (_dragMode == "create" && _dragSegmentType != null)
            {
                long start = Math.Min(_dragAnchorMs, _dragCurrentMs);
                long end = Math.Max(_dragAnchorMs, _dragCurrentMs);

                double x0 = MsToPos(start);
                double x1 = MsToPos(end);
                double barWidth = Math.Max(2.0, x1 - x0);

                int rowIdx = GetRowIndex(_dragSegmentType.Value);
                double rowY = rowIdx * RowHeight;

                var baseColor = (Color)ColorConverter.ConvertFromString(_dragSegmentType.Value.GetHexColor());
                var fillBrush = new SolidColorBrush(Color.FromArgb(90, baseColor.R, baseColor.G, baseColor.B));
                var borderPen = new Pen(new SolidColorBrush(Color.FromArgb(200, baseColor.R, baseColor.G, baseColor.B)), 1.5)
                {
                    DashStyle = DashStyles.Dash
                };

                drawingContext.DrawRoundedRectangle(fillBrush, borderPen, new Rect(x0, rowY + 4, barWidth, RowHeight - 8), 4.0, 4.0);
            }

            // 5. Paint Playhead (Red vertical line)
            double playheadX = MsToPos(CurrentTimeMs);
            var playheadPen = new Pen(new SolidColorBrush(Color.FromRgb(255, 69, 58)), 2.0);
            drawingContext.DrawLine(playheadPen, new Point(playheadX, 0), new Point(playheadX, ActualHeight));
        }

        private Color GetAudioColor(float musicLikelihood)
        {
            float clamped = Math.Clamp(musicLikelihood, 0.0f, 1.0f);
            float lowThreshold = 0.15f;
            float fullBlendAt = 0.75f;
            
            float normalized = Math.Clamp((clamped - lowThreshold) / (fullBlendAt - lowThreshold), 0.0f, 1.0f);
            float t = normalized * normalized;

            // Interpolate between Mint (0, 199, 190) and Orange (255, 149, 0)
            byte r = (byte)(0 + (255 - 0) * t);
            byte g = (byte)(199 + (149 - 199) * t);
            byte b = (byte)(190 + (0 - 190) * t);

            return Color.FromArgb(140, r, g, b);
        }
    }
}
