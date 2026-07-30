#pragma once

#include <QFrame>

#include "models/Models.h"

class QLabel;
class QLineEdit;
class QToolButton;

namespace segmenter {

/// One row of the Segment Drafts panel: a colour dot, the segment name, the
/// start and end timecode fields with their "set from playhead" buttons, and
/// clear/upload actions.
class SegmentEditorRow : public QFrame {
    Q_OBJECT

public:
    explicit SegmentEditorRow(SegmentType segmentType, QWidget *parent = nullptr);

    SegmentType segmentType() const { return m_segmentType; }

    /// Pushes values into the fields without emitting draftEdited — used when
    /// the timeline or an RCD scan is the source of the change.
    void setDraft(const SegmentDraft &draft);
    SegmentDraft draft() const { return m_draft; }

signals:
    /// The user typed a new timecode into one of the fields.
    void draftEdited(SegmentType type, const SegmentDraft &draft);
    void setStartFromPlayheadRequested(SegmentType type);
    void setEndFromPlayheadRequested(SegmentType type);
    void clearRequested(SegmentType type);
    void uploadRequested(SegmentType type);

private:
    void buildUi();
    void commitFromFields();

    SegmentType m_segmentType;
    SegmentDraft m_draft;

    QLabel *m_colorDot = nullptr;
    QLabel *m_nameLabel = nullptr;
    QLineEdit *m_startField = nullptr;
    QLineEdit *m_endField = nullptr;
    QToolButton *m_setStartButton = nullptr;
    QToolButton *m_setEndButton = nullptr;
    QToolButton *m_clearButton = nullptr;
    QToolButton *m_uploadButton = nullptr;

    // Guards setDraft against re-emitting draftEdited through the field's own
    // editingFinished signal.
    bool m_updatingFields = false;
};

} // namespace segmenter
