#pragma once

#include <QHash>
#include <QWidget>

#include "models/Models.h"

class QComboBox;
class QLabel;
class QLineEdit;
class QPushButton;

namespace segmenter {

class SegmentEditorRow;

/// The left column: video selection, API keys, media identification and the
/// segment draft rows. Owns no application state — it renders what the window
/// gives it and reports what the user did.
class SidebarPanel : public QWidget {
    Q_OBJECT

public:
    explicit SidebarPanel(QWidget *parent = nullptr);

    // --- Video ---
    void setVideoName(const QString &fileName);

    // --- API keys ---
    void setApiKeys(const QString &theIntroDb, const QString &introDb, const QString &tmdb);
    QString theIntroDbKey() const;
    QString introDbKey() const;
    QString tmdbKey() const;

    /// Shows or clears the "TMDB Key missing" hint under the video row.
    void setLookupHint(const QString &text);

    // --- Media identification ---
    void setMediaType(MediaType type);
    MediaType mediaType() const;

    void setTmdbId(const QString &id);
    QString tmdbId() const;

    void setImdbId(const QString &id);
    QString imdbId() const;

    void setSeasonEpisode(const std::optional<int> &season, const std::optional<int> &episode);
    std::optional<int> season() const;
    std::optional<int> episode() const;

    /// Replaces the candidate list shown after a TMDB search or auto-lookup.
    void setLookupResults(const QVector<AutoLookupResult> &results);

    // --- Drafts ---
    void setDrafts(const QHash<int, SegmentDraft> &drafts);

signals:
    void openVideoRequested();
    void saveKeysRequested();
    void searchTmdbRequested(const QString &query);
    void lookupResultSelected(int index);
    void loadSegmentsRequested();
    void uploadAllRequested();
    void scanSeasonRequested();
    void mediaTypeChanged(MediaType type);

    void draftEdited(SegmentType type, const SegmentDraft &draft);
    void setStartFromPlayheadRequested(SegmentType type);
    void setEndFromPlayheadRequested(SegmentType type);
    void clearDraftRequested(SegmentType type);
    void uploadSegmentRequested(SegmentType type);

private:
    void buildUi();

    QLabel *m_videoNameLabel = nullptr;
    QLabel *m_lookupHintLabel = nullptr;

    QLineEdit *m_theIntroDbKeyField = nullptr;
    QLineEdit *m_introDbKeyField = nullptr;
    QLineEdit *m_tmdbKeyField = nullptr;

    QLineEdit *m_searchField = nullptr;
    QComboBox *m_resultsCombo = nullptr;
    QLineEdit *m_tmdbIdField = nullptr;
    QLineEdit *m_imdbIdField = nullptr;
    QComboBox *m_mediaTypeCombo = nullptr;
    QLineEdit *m_seasonField = nullptr;
    QLineEdit *m_episodeField = nullptr;

    QHash<int, SegmentEditorRow *> m_draftRows;

    // Suppresses lookupResultSelected while the combo is being repopulated.
    bool m_populatingResults = false;
};

} // namespace segmenter
