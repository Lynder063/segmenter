from PySide6.QtCore import Qt, QPoint, QRectF, Signal, Slot
from PySide6.QtWidgets import QWidget, QScrollArea, QSizePolicy
from PySide6.QtGui import QPainter, QColor, QPen, QBrush, QFont, QCursor, QMouseEvent
import math
from models import SegmentType, SegmentRange, SegmentDraft, TimelineDensityTrack

class TimelineWidget(QWidget):
    # Signals for notifications
    seek_requested = Signal(int)  # ms
    draft_range_created = Signal(SegmentType, int, int)  # type, start_ms, end_ms
    draft_start_dragged = Signal(SegmentType, int, int)  # type, index, new_ms
    draft_end_dragged = Signal(SegmentType, int, int)  # type, index, new_ms
    draft_moved = Signal(SegmentType, int, SegmentType, int, int)  # src_type, index, target_type, start_ms, end_ms
    drag_began = Signal()
    drag_ended = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.duration_ms = 60_000
        self.video_duration_ms = 0
        self.current_time_ms = 0
        self.zoom = 1.0
        self.minimum_zoom = 1.0
        
        self.server_segments = {t: [] for t in SegmentType}
        self.drafts = {t: [] for t in SegmentType}
        self.audio_track = TimelineDensityTrack.empty()
        
        self.row_height = 36
        self.density_row_height = 36
        self.handle_grab_width = 10
        self.left_margin = 0  # ScrollArea handles alignment, labels are in a separate fixed sidebar column

        # Drag state
        self.drag_mode = None  # None, "seek", "resize_start", "resize_end", "move", "create"
        self.drag_segment_type = None
        self.drag_draft_index = None
        self.drag_anchor_ms = 0
        self.drag_current_ms = 0
        self.drag_start_val_ms = 0
        self.drag_end_val_ms = 0
        
        # Mouse track
        self.setMouseTracking(True)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)

    def set_data(self, duration_ms, video_duration_ms, current_time_ms, zoom, minimum_zoom, server_segments, drafts, audio_track):
        self.duration_ms = max(duration_ms, 60_000)
        self.video_duration_ms = video_duration_ms
        self.current_time_ms = current_time_ms
        self.zoom = zoom
        self.minimum_zoom = minimum_zoom
        self.server_segments = server_segments
        self.drafts = drafts
        self.audio_track = audio_track
        
        # Recalculate size based on zoom
        self.update_geometry()
        self.update()

    def update_geometry(self):
        # Calculate width dynamically
        # base = duration_ms / 1000 * 8px
        base_width = (self.duration_ms / 1000.0) * 8.0
        calculated_width = int(min(max(240.0, base_width * self.zoom), 48000.0))
        
        viewport_width = 800
        if isinstance(self.parent(), QWidget) and isinstance(self.parent().parent(), QScrollArea):
            viewport_width = self.parent().parent().viewport().width()
        
        final_width = max(calculated_width, viewport_width)
        # Ensure width does not shrink unexpectedly after updates
        final_width = max(self.width(), final_width)
        
        num_density = 1 if self.audio_track.has_content else 0
        total_rows = num_density + len(SegmentType)
        final_height = total_rows * self.row_height
        
        self.resize(final_width, final_height)
        self.setMinimumSize(final_width, final_height)

    def position_to_ms(self, x: float) -> int:
        ratio = x / self.width()
        return int(ratio * self.duration_ms)

    def ms_to_position(self, ms: int) -> float:
        if self.duration_ms <= 0:
            return 0
        clamped = max(0, min(ms, self.duration_ms))
        ratio = clamped / self.duration_ms
        return ratio * self.width()

    def _get_row_y(self, row_index: int) -> int:
        return row_index * self.row_height

    def _get_segment_type_row(self, segment_type: SegmentType) -> int:
        num_density = 1 if self.audio_track.has_content else 0
        list_types = list(SegmentType)
        if segment_type in list_types:
            return num_density + list_types.index(segment_type)
        return 0

    def _get_segment_type_at_y(self, y: int) -> SegmentType:
        num_density = 1 if self.audio_track.has_content else 0
        offset_y = y - (num_density * self.row_height)
        row = max(0, min(offset_y // self.row_height, len(SegmentType) - 1))
        return list(SegmentType)[row]

    def hit_test_handle(self, pos: QPoint) -> tuple[Optional[SegmentType], Optional[int], Optional[str]]:
        """Returns (segment_type, draft_index, 'start'|'end') if hovering over a drag handle."""
        for seg_type in SegmentType:
            row_idx = self._get_segment_type_row(seg_type)
            row_y = self._get_row_y(row_idx)
            if row_y <= pos.y() <= row_y + self.row_height:
                for idx, draft in enumerate(self.drafts.get(seg_type, [])):
                    if draft.start_ms is not None:
                        hx = self.ms_to_position(draft.start_ms)
                        if abs(pos.x() - hx) <= self.handle_grab_width:
                            return seg_type, idx, "start"
                    if draft.end_ms is not None:
                        hx = self.ms_to_position(draft.end_ms)
                        if abs(pos.x() - hx) <= self.handle_grab_width:
                            return seg_type, idx, "end"
        return None, None, None

    def hit_test_draft_bar(self, pos: QPoint) -> tuple[Optional[SegmentType], Optional[int]]:
        """Returns (segment_type, draft_index) if clicking on a draft segment bar."""
        for seg_type in SegmentType:
            row_idx = self._get_segment_type_row(seg_type)
            row_y = self._get_row_y(row_idx)
            if row_y + 4 <= pos.y() <= row_y + self.row_height - 4:
                for idx, draft in enumerate(self.drafts.get(seg_type, [])):
                    if draft.start_ms is not None and draft.end_ms is not None:
                        x0 = self.ms_to_position(draft.start_ms)
                        x1 = self.ms_to_position(draft.end_ms)
                        if x0 <= pos.x() <= x1:
                            return seg_type, idx
        return None, None

    def mousePressEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton:
            pos = event.pos()
            
            # Check modifier keys
            is_shift = bool(event.modifiers() & Qt.ShiftModifier)
            is_alt = bool(event.modifiers() & Qt.AltModifier)
            
            # 1. Check drag handles
            seg_type, draft_idx, edge = self.hit_test_handle(pos)
            if seg_type is not None and draft_idx is not None and not is_shift and not is_alt:
                self.drag_mode = "resize_start" if edge == "start" else "resize_end"
                self.drag_segment_type = seg_type
                self.drag_draft_index = draft_idx
                self.drag_began.emit()
                return

            # 2. Check full segment move (Shift + Drag)
            if is_shift:
                seg_type, draft_idx = self.hit_test_draft_bar(pos)
                if seg_type is not None and draft_idx is not None:
                    draft = self.drafts[seg_type][draft_idx]
                    self.drag_mode = "move"
                    self.drag_segment_type = seg_type
                    self.drag_draft_index = draft_idx
                    self.drag_anchor_ms = self.position_to_ms(pos.x())
                    self.drag_start_val_ms = draft.start_ms
                    self.drag_end_val_ms = draft.end_ms
                    self.drag_began.emit()
                    return

            # 3. Check segment creation (Alt + Drag)
            if is_alt:
                self.drag_mode = "create"
                self.drag_segment_type = self._get_segment_type_at_y(pos.y())
                self.drag_anchor_ms = self.position_to_ms(pos.x())
                self.drag_current_ms = self.drag_anchor_ms
                return

            # 4. Standard seek drag
            self.drag_mode = "seek"
            ms = self.position_to_ms(pos.x())
            self.seek_requested.emit(ms)

    def mouseMoveEvent(self, event: QMouseEvent):
        pos = event.pos()
        
        # Handle hover cursors
        seg_type, _, _ = self.hit_test_handle(pos)
        if seg_type is not None:
            self.setCursor(QCursor(Qt.SizeHorCursor))
        else:
            self.setCursor(QCursor(Qt.ArrowCursor))

        if not self.drag_mode:
            return

        ms = self.position_to_ms(pos.x())
        
        if self.drag_mode == "seek":
            self.seek_requested.emit(ms)
        elif self.drag_mode == "resize_start":
            self.draft_start_dragged.emit(self.drag_segment_type, self.drag_draft_index, ms)
        elif self.drag_mode == "resize_end":
            self.draft_end_dragged.emit(self.drag_segment_type, self.drag_draft_index, ms)
        elif self.drag_mode == "move":
            delta_ms = ms - self.drag_anchor_ms
            new_start = max(0, self.drag_start_val_ms + delta_ms)
            new_end = self.drag_end_val_ms + delta_ms
            # Get target segment type based on current mouse Y
            target_type = self._get_segment_type_at_y(pos.y())
            
            # Show temporary visual update (actual model update on release)
            self.drag_current_ms = ms
            self.drag_segment_type_target = target_type
            self.seek_requested.emit(new_start)
            self.update()
        elif self.drag_mode == "create":
            self.drag_current_ms = ms
            self.update()

    def mouseReleaseEvent(self, event: QMouseEvent):
        if not self.drag_mode:
            return
            
        pos = event.pos()
        ms = self.position_to_ms(pos.x())
        
        if self.drag_mode == "move":
            delta_ms = ms - self.drag_anchor_ms
            new_start = max(0, self.drag_start_val_ms + delta_ms)
            new_end = self.drag_end_val_ms + delta_ms
            target_type = getattr(self, "drag_segment_type_target", self.drag_segment_type)
            
            self.draft_moved.emit(
                self.drag_segment_type,
                self.drag_draft_index,
                target_type,
                new_start,
                new_end
            )
            self.drag_ended.emit()
        elif self.drag_mode == "create":
            start = min(self.drag_anchor_ms, self.drag_current_ms)
            end = max(self.drag_anchor_ms, self.drag_current_ms)
            if end - start >= 100:  # Avoid micro-clicks
                self.draft_range_created.emit(self.drag_segment_type, start, end)
        elif self.drag_mode in ("resize_start", "resize_end"):
            self.drag_ended.emit()
            
        self.drag_mode = None
        self.update()

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        
        width = self.width()
        num_density = 1 if self.audio_track.has_content else 0
        total_rows = num_density + len(SegmentType)
        
        # Draw background grids & row headers
        for r in range(total_rows):
            y = self._get_row_y(r)
            # Draw row separator line
            painter.setPen(QPen(QColor(255, 255, 255, 40), 1))
            painter.drawLine(0, y, width, y)
            
            # Row background
            painter.setPen(Qt.NoPen)
            painter.setBrush(QColor(0, 0, 0, 10))
            painter.drawRect(0, y, width, self.row_height)

        # 1. Paint Density Track (Audio Waveform + Music Likelihood)
        if num_density > 0:
            track_y = 0
            # Draw buckets
            buckets = self.audio_track.buckets
            music_buckets = self.audio_track.music_likelihood_buckets or []
            
            if buckets:
                painter.setPen(Qt.NoPen)
                # Compute visual decimation to speed up painting
                target_cols = int(width)
                bucket_width = max(1.0, width / len(buckets))
                
                for idx, val in enumerate(buckets):
                    if val <= 0:
                        continue
                    
                    bar_height = val * (self.row_height - 6)
                    x = idx * bucket_width
                    y = self.row_height - bar_height - 3
                    
                    # Blend colors: systemMint to systemOrange based on music likelihood
                    likelihood = music_buckets[idx] if idx < len(music_buckets) else 0.0
                    color = self._audio_tint(likelihood)
                    
                    painter.setBrush(QBrush(color))
                    painter.drawRect(QRectF(x, y, max(1.0, bucket_width), bar_height))

        # 2. Paint Segment Types rows
        segment_top_y = num_density * self.row_height
        for idx, seg_type in enumerate(SegmentType):
            row_y = segment_top_y + (idx * self.row_height)
            color = QColor(seg_type.hex_color)
            
            # Draw server segments
            for range_obj in self.server_segments.get(seg_type, []):
                start = range_obj.start_ms or 0
                end = range_obj.end_ms or self.duration_ms
                x0 = self.ms_to_position(start)
                x1 = self.ms_to_position(end)
                bar_width = max(2.0, x1 - x0)
                
                # Server segment: 45% opacity fill, no outline
                color.setAlpha(115)
                painter.setPen(Qt.NoPen)
                painter.setBrush(QBrush(color))
                painter.drawRoundedRect(QRectF(x0, row_y + 4, bar_width, self.row_height - 8), 4, 4)

            # Draw local draft segments
            for draft_idx, draft in enumerate(self.drafts.get(seg_type, [])):
                if draft.start_ms is None and draft.end_ms is None:
                    continue
                    
                # Skip if we are moving this specific draft (drawn as drag outline below)
                if self.drag_mode == "move" and self.drag_segment_type == seg_type and self.drag_draft_index == draft_idx:
                    continue
                
                start = draft.start_ms if draft.start_ms is not None else 0
                end = draft.end_ms if draft.end_ms is not None else self.duration_ms
                
                x0 = self.ms_to_position(start)
                x1 = self.ms_to_position(end)
                bar_width = max(2.0, x1 - x0)
                
                # Draw solid background 85% opacity
                color.setAlpha(217)
                painter.setBrush(QBrush(color))
                
                # Dashed border if it's draft
                pen_color = QColor(color)
                pen_color.setAlpha(240)
                pen = QPen(pen_color, 1.5, Qt.DashLine)
                painter.setPen(pen)
                
                rect = QRectF(x0, row_y + 4, bar_width, self.row_height - 8)
                painter.drawRoundedRect(rect, 4, 4)

        # 3. Paint Move Drag Shadow
        if self.drag_mode == "move":
            delta_ms = self.position_to_ms(self.mapFromGlobal(QCursor.pos()).x()) - self.drag_anchor_ms
            drag_start = max(0, self.drag_start_val_ms + delta_ms)
            drag_end = self.drag_end_val_ms + delta_ms
            
            x0 = self.ms_to_position(drag_start)
            x1 = self.ms_to_position(drag_end)
            bar_width = max(2.0, x1 - x0)
            
            target_type = getattr(self, "drag_segment_type_target", self.drag_segment_type)
            target_row = self._get_segment_type_row(target_type)
            target_y = self._get_row_y(target_row)
            
            color = QColor(target_type.hex_color)
            color.setAlpha(120)
            painter.setBrush(QBrush(color))
            
            pen_color = QColor(color)
            pen_color.setAlpha(220)
            pen = QPen(pen_color, 1.5, Qt.DashLine)
            painter.setPen(pen)
            
            rect = QRectF(x0, target_y + 4, bar_width, self.row_height - 8)
            painter.drawRoundedRect(rect, 4, 4)

        # 4. Paint Alt-Create Selection Shadow
        if self.drag_mode == "create":
            x0 = self.ms_to_position(min(self.drag_anchor_ms, self.drag_current_ms))
            x1 = self.ms_to_position(max(self.drag_anchor_ms, self.drag_current_ms))
            bar_width = max(2.0, x1 - x0)
            
            row_idx = self._get_segment_type_row(self.drag_segment_type)
            row_y = self._get_row_y(row_idx)
            
            color = QColor(self.drag_segment_type.hex_color)
            color.setAlpha(90)
            painter.setBrush(QBrush(color))
            
            pen_color = QColor(color)
            pen_color.setAlpha(200)
            pen = QPen(pen_color, 1.5, Qt.DashLine)
            painter.setPen(pen)
            
            rect = QRectF(x0, row_y + 4, bar_width, self.row_height - 8)
            painter.drawRoundedRect(rect, 4, 4)

        # 5. Paint Playhead (Red vertical line)
        px = self.ms_to_position(self.current_time_ms)
        painter.setPen(QPen(QColor("#ff453a"), 2))
        painter.drawLine(px, 0, px, self.height())

    def _audio_tint(self, music_likelihood: float) -> QColor:
        # Interpolate between systemMint (#00c7be) and systemOrange (#ff9500)
        # using easing/squared mapping to avoid early orange flicker.
        clamped = min(max(music_likelihood, 0.0), 1.0)
        low_threshold = 0.15
        full_blend_at = 0.75
        
        normalized = min(max((clamped - low_threshold) / (full_blend_at - low_threshold), 0.0), 1.0)
        t = normalized * normalized
        
        # mint: r=0, g=199, b=190
        # orange: r=255, g=149, b=0
        r = int(0 + (255 - 0) * t)
        g = int(199 + (149 - 199) * t)
        b = int(190 + (0 - 190) * t)
        
        return QColor(r, g, b, 140)
