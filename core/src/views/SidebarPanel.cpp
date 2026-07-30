#include "views/SidebarPanel.h"

#include <QComboBox>
#include <QGridLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QIntValidator>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QVBoxLayout>

#include "Theme.h"
#include "views/SegmentEditorRow.h"

namespace segmenter {

SidebarPanel::SidebarPanel(QWidget *parent)
    : QWidget(parent)
{
    buildUi();
}

void SidebarPanel::buildUi()
{
    auto *root = new QVBoxLayout(this);
    root->setContentsMargins(8, 8, 8, 8);
    root->setSpacing(8);

    // --- Video ------------------------------------------------------------
    auto *videoGroup = new QGroupBox(tr("Video"), this);
    auto *videoLayout = new QVBoxLayout(videoGroup);
    videoLayout->setSpacing(6);

    m_videoNameLabel = new QLabel(tr("No file loaded"), videoGroup);
    m_videoNameLabel->setObjectName(QStringLiteral("videoTitle"));
    m_videoNameLabel->setWordWrap(true);
    videoLayout->addWidget(m_videoNameLabel);

    auto *openButton = new QPushButton(tr("Open Local Video"), videoGroup);
    videoLayout->addWidget(openButton);

    m_lookupHintLabel = new QLabel(videoGroup);
    m_lookupHintLabel->setObjectName(QStringLiteral("hintText"));
    m_lookupHintLabel->setWordWrap(true);
    videoLayout->addWidget(m_lookupHintLabel);

    root->addWidget(videoGroup);

    // --- API Keys ---------------------------------------------------------
    auto *keysGroup = new QGroupBox(tr("API Keys"), this);
    auto *keysLayout = new QVBoxLayout(keysGroup);
    keysLayout->setSpacing(6);

    const auto makeKeyField = [&](const QString &placeholder) {
        auto *field = new QLineEdit(keysGroup);
        field->setPlaceholderText(placeholder);
        // Keys are secrets; showing them in the clear invites shoulder-surfing
        // and screenshots of the window leaking them.
        field->setEchoMode(QLineEdit::Password);
        keysLayout->addWidget(field);
        return field;
    };

    m_theIntroDbKeyField = makeKeyField(tr("TheIntroDB API Key"));
    m_introDbKeyField = makeKeyField(tr("IntroDB API Key"));
    m_tmdbKeyField = makeKeyField(tr("TMDB API Key"));

    auto *saveKeysButton = new QPushButton(tr("Save Keys to Credential Manager"), keysGroup);
    keysLayout->addWidget(saveKeysButton);

    root->addWidget(keysGroup);

    // --- Media Identification --------------------------------------------
    auto *mediaGroup = new QGroupBox(tr("Media Identification"), this);
    auto *mediaLayout = new QVBoxLayout(mediaGroup);
    mediaLayout->setSpacing(6);

    auto *searchRow = new QHBoxLayout();
    searchRow->setSpacing(6);
    m_searchField = new QLineEdit(mediaGroup);
    m_searchField->setPlaceholderText(tr("Search TMDB..."));
    searchRow->addWidget(m_searchField, 1);

    auto *searchButton = new QPushButton(QStringLiteral("🔍"), mediaGroup);
    searchButton->setFixedWidth(34);
    searchRow->addWidget(searchButton);
    mediaLayout->addLayout(searchRow);

    m_resultsCombo = new QComboBox(mediaGroup);
    m_resultsCombo->setPlaceholderText(tr("No lookup results"));
    mediaLayout->addWidget(m_resultsCombo);

    m_tmdbIdField = new QLineEdit(mediaGroup);
    m_tmdbIdField->setPlaceholderText(tr("TMDB ID"));
    m_tmdbIdField->setValidator(new QIntValidator(0, 99999999, m_tmdbIdField));
    mediaLayout->addWidget(m_tmdbIdField);

    m_imdbIdField = new QLineEdit(mediaGroup);
    m_imdbIdField->setPlaceholderText(tr("IMDB ID (optional)"));
    mediaLayout->addWidget(m_imdbIdField);

    m_mediaTypeCombo = new QComboBox(mediaGroup);
    m_mediaTypeCombo->addItem(mediaTypeDisplayName(MediaType::Movie),
                              static_cast<int>(MediaType::Movie));
    m_mediaTypeCombo->addItem(mediaTypeDisplayName(MediaType::Tv),
                              static_cast<int>(MediaType::Tv));
    mediaLayout->addWidget(m_mediaTypeCombo);

    auto *seasonRow = new QHBoxLayout();
    seasonRow->setSpacing(6);
    m_seasonField = new QLineEdit(mediaGroup);
    m_seasonField->setPlaceholderText(tr("Season"));
    m_seasonField->setValidator(new QIntValidator(0, 999, m_seasonField));
    seasonRow->addWidget(m_seasonField);

    m_episodeField = new QLineEdit(mediaGroup);
    m_episodeField->setPlaceholderText(tr("Episode"));
    m_episodeField->setValidator(new QIntValidator(0, 9999, m_episodeField));
    seasonRow->addWidget(m_episodeField);
    mediaLayout->addLayout(seasonRow);

    auto *actionRow = new QHBoxLayout();
    actionRow->setSpacing(6);
    auto *loadSegmentsButton = new QPushButton(tr("Load Segments"), mediaGroup);
    actionRow->addWidget(loadSegmentsButton);

    auto *uploadAllButton = new QPushButton(tr("Upload All Drafts"), mediaGroup);
    uploadAllButton->setObjectName(QStringLiteral("uploadAllBtn"));
    actionRow->addWidget(uploadAllButton);
    mediaLayout->addLayout(actionRow);

    auto *scanButton = new QPushButton(tr("Scan Season (Fingerprint)"), mediaGroup);
    mediaLayout->addWidget(scanButton);

    root->addWidget(mediaGroup);

    // --- Segment Drafts ---------------------------------------------------
    auto *draftsGroup = new QGroupBox(tr("Segment Drafts"), this);
    auto *draftsLayout = new QVBoxLayout(draftsGroup);
    draftsLayout->setSpacing(6);

    for (const SegmentType type : allSegmentTypes()) {
        auto *row = new SegmentEditorRow(type, draftsGroup);
        draftsLayout->addWidget(row);
        m_draftRows.insert(static_cast<int>(type), row);

        connect(row, &SegmentEditorRow::draftEdited, this, &SidebarPanel::draftEdited);
        connect(row, &SegmentEditorRow::setStartFromPlayheadRequested,
                this, &SidebarPanel::setStartFromPlayheadRequested);
        connect(row, &SegmentEditorRow::setEndFromPlayheadRequested,
                this, &SidebarPanel::setEndFromPlayheadRequested);
        connect(row, &SegmentEditorRow::clearRequested, this, &SidebarPanel::clearDraftRequested);
        connect(row, &SegmentEditorRow::uploadRequested, this, &SidebarPanel::uploadSegmentRequested);
    }

    root->addWidget(draftsGroup);
    root->addStretch(1);

    // --- Wiring -----------------------------------------------------------
    connect(openButton, &QPushButton::clicked, this, &SidebarPanel::openVideoRequested);
    connect(saveKeysButton, &QPushButton::clicked, this, &SidebarPanel::saveKeysRequested);
    connect(loadSegmentsButton, &QPushButton::clicked, this, &SidebarPanel::loadSegmentsRequested);
    connect(uploadAllButton, &QPushButton::clicked, this, &SidebarPanel::uploadAllRequested);
    connect(scanButton, &QPushButton::clicked, this, &SidebarPanel::scanSeasonRequested);

    const auto emitSearch = [this] {
        const QString query = m_searchField->text().trimmed();
        if (!query.isEmpty()) {
            emit searchTmdbRequested(query);
        }
    };
    connect(searchButton, &QPushButton::clicked, this, emitSearch);
    connect(m_searchField, &QLineEdit::returnPressed, this, emitSearch);

    connect(m_resultsCombo, &QComboBox::currentIndexChanged, this, [this](int index) {
        if (!m_populatingResults && index >= 0) {
            emit lookupResultSelected(index);
        }
    });

    connect(m_mediaTypeCombo, &QComboBox::currentIndexChanged, this, [this](int) {
        emit mediaTypeChanged(mediaType());
    });
}

// MARK: - Video

void SidebarPanel::setVideoName(const QString &fileName)
{
    m_videoNameLabel->setText(fileName.isEmpty() ? tr("No file loaded") : fileName);
}

void SidebarPanel::setLookupHint(const QString &text)
{
    m_lookupHintLabel->setText(text);
    m_lookupHintLabel->setVisible(!text.isEmpty());
}

// MARK: - API keys

void SidebarPanel::setApiKeys(const QString &theIntroDb, const QString &introDb, const QString &tmdb)
{
    m_theIntroDbKeyField->setText(theIntroDb);
    m_introDbKeyField->setText(introDb);
    m_tmdbKeyField->setText(tmdb);
}

QString SidebarPanel::theIntroDbKey() const { return m_theIntroDbKeyField->text().trimmed(); }
QString SidebarPanel::introDbKey() const { return m_introDbKeyField->text().trimmed(); }
QString SidebarPanel::tmdbKey() const { return m_tmdbKeyField->text().trimmed(); }

// MARK: - Media identification

void SidebarPanel::setMediaType(MediaType type)
{
    const int index = m_mediaTypeCombo->findData(static_cast<int>(type));
    if (index >= 0) {
        m_mediaTypeCombo->setCurrentIndex(index);
    }
}

MediaType SidebarPanel::mediaType() const
{
    return static_cast<MediaType>(m_mediaTypeCombo->currentData().toInt());
}

void SidebarPanel::setTmdbId(const QString &id) { m_tmdbIdField->setText(id); }
QString SidebarPanel::tmdbId() const { return m_tmdbIdField->text().trimmed(); }

void SidebarPanel::setImdbId(const QString &id) { m_imdbIdField->setText(id); }
QString SidebarPanel::imdbId() const { return m_imdbIdField->text().trimmed(); }

void SidebarPanel::setSeasonEpisode(const std::optional<int> &season,
                                    const std::optional<int> &episode)
{
    m_seasonField->setText(season.has_value() ? QString::number(*season) : QString());
    m_episodeField->setText(episode.has_value() ? QString::number(*episode) : QString());
}

std::optional<int> SidebarPanel::season() const
{
    bool ok = false;
    const int value = m_seasonField->text().trimmed().toInt(&ok);
    return ok ? std::optional<int>(value) : std::nullopt;
}

std::optional<int> SidebarPanel::episode() const
{
    bool ok = false;
    const int value = m_episodeField->text().trimmed().toInt(&ok);
    return ok ? std::optional<int>(value) : std::nullopt;
}

void SidebarPanel::setLookupResults(const QVector<AutoLookupResult> &results)
{
    m_populatingResults = true;
    m_resultsCombo->clear();
    for (const AutoLookupResult &result : results) {
        m_resultsCombo->addItem(result.displayLabel());
    }
    m_resultsCombo->setCurrentIndex(results.isEmpty() ? -1 : 0);
    m_populatingResults = false;

    // Applying the top hit immediately is the common case; the user overrides
    // it from the combo when the guess is wrong.
    if (!results.isEmpty()) {
        emit lookupResultSelected(0);
    }
}

// MARK: - Drafts

void SidebarPanel::setDrafts(const QHash<int, SegmentDraft> &drafts)
{
    for (auto it = m_draftRows.constBegin(); it != m_draftRows.constEnd(); ++it) {
        it.value()->setDraft(drafts.value(it.key(), SegmentDraft{}));
    }
}

} // namespace segmenter
