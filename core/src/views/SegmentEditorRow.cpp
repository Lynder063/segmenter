#include "views/SegmentEditorRow.h"

#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QToolButton>

#include "Theme.h"

namespace segmenter {

SegmentEditorRow::SegmentEditorRow(SegmentType segmentType, QWidget *parent)
    : QFrame(parent)
    , m_segmentType(segmentType)
{
    setObjectName(QStringLiteral("SegmentEditorRow"));
    setFrameShape(QFrame::StyledPanel);
    buildUi();
}

void SegmentEditorRow::buildUi()
{
    auto *layout = new QHBoxLayout(this);
    layout->setContentsMargins(8, 6, 8, 6);
    layout->setSpacing(6);

    m_colorDot = new QLabel(this);
    m_colorDot->setFixedSize(12, 12);
    m_colorDot->setStyleSheet(QStringLiteral("background-color: %1; border-radius: 6px;")
                                  .arg(segmentTypeHexColor(m_segmentType)));
    layout->addWidget(m_colorDot);

    m_nameLabel = new QLabel(segmentTypeDisplayName(m_segmentType), this);
    m_nameLabel->setStyleSheet(QStringLiteral("font-weight: bold;"));
    m_nameLabel->setMinimumWidth(58);
    layout->addWidget(m_nameLabel);

    const auto makeField = [this](const QString &placeholder) {
        auto *field = new QLineEdit(this);
        field->setPlaceholderText(placeholder);
        field->setMinimumWidth(62);
        field->setAlignment(Qt::AlignCenter);
        return field;
    };

    m_startField = makeField(QStringLiteral("--"));
    layout->addWidget(m_startField, 1);

    m_setStartButton = new QToolButton(this);
    m_setStartButton->setText(QStringLiteral("⌄"));
    m_setStartButton->setToolTip(tr("Set start from playhead"));
    layout->addWidget(m_setStartButton);

    m_endField = makeField(QStringLiteral("--"));
    layout->addWidget(m_endField, 1);

    m_setEndButton = new QToolButton(this);
    m_setEndButton->setText(QStringLiteral("⌄"));
    m_setEndButton->setToolTip(tr("Set end from playhead"));
    layout->addWidget(m_setEndButton);

    m_clearButton = new QToolButton(this);
    m_clearButton->setText(QStringLiteral("🗑"));
    m_clearButton->setToolTip(tr("Clear draft"));
    m_clearButton->setStyleSheet(QStringLiteral("color: %1;")
                                     .arg(theme::color::statusError.name()));
    layout->addWidget(m_clearButton);

    m_uploadButton = new QToolButton(this);
    m_uploadButton->setText(QStringLiteral("⌃"));
    m_uploadButton->setToolTip(tr("Upload this segment"));
    m_uploadButton->setStyleSheet(QStringLiteral("color: %1;")
                                     .arg(segmentTypeHexColor(m_segmentType)));
    layout->addWidget(m_uploadButton);

    connect(m_startField, &QLineEdit::editingFinished, this, &SegmentEditorRow::commitFromFields);
    connect(m_endField, &QLineEdit::editingFinished, this, &SegmentEditorRow::commitFromFields);

    connect(m_setStartButton, &QToolButton::clicked, this, [this] {
        emit setStartFromPlayheadRequested(m_segmentType);
    });
    connect(m_setEndButton, &QToolButton::clicked, this, [this] {
        emit setEndFromPlayheadRequested(m_segmentType);
    });
    connect(m_clearButton, &QToolButton::clicked, this, [this] {
        emit clearRequested(m_segmentType);
    });
    connect(m_uploadButton, &QToolButton::clicked, this, [this] {
        emit uploadRequested(m_segmentType);
    });
}

void SegmentEditorRow::setDraft(const SegmentDraft &draft)
{
    m_draft = draft;

    m_updatingFields = true;
    m_startField->setText(draft.startMs.has_value() ? formatTimecode(*draft.startMs) : QString());
    m_endField->setText(draft.endMs.has_value() ? formatTimecode(*draft.endMs) : QString());
    m_updatingFields = false;
}

void SegmentEditorRow::commitFromFields()
{
    if (m_updatingFields) {
        return;
    }

    SegmentDraft edited;
    edited.startMs = parseTimecode(m_startField->text());
    edited.endMs = parseTimecode(m_endField->text());

    if (edited == m_draft) {
        return;
    }

    // Re-render from the parsed values so a typed "1:05" becomes "01:05.000"
    // and unparseable text visibly reverts instead of sitting there looking set.
    m_draft = edited;
    setDraft(edited);

    emit draftEdited(m_segmentType, edited);
}

} // namespace segmenter
