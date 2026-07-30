#include "services/RcdEngine.h"

#include <QCollator>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QThread>
#include <QtConcurrent>

#include <algorithm>
#include <cmath>
#include <stdexcept>

#include "services/AudioExtractorService.h"
#include "services/FFmpegService.h"
#include "services/Fft.h"
#include "services/LoggerService.h"
#include "platform/OcrService.h"
#include "services/RcdFeatureCache.h"

namespace segmenter {
namespace {

/// Chroma bins per frame.
constexpr int kChromaBins = 12;

/// hopSize / sampleRate = 512 / 4000.
constexpr double kSecPerFrame = 0.128;

/// Candidate template lengths in frames (~7.8 fps): 10s, 15s, 20s, 30s, 45s,
/// 60s, 90s, 120s, 150s.
///
/// The list used to stop at 90s, which silently capped every result: a show
/// whose intro is longer simply cannot be described by any candidate, so the
/// search returned its best 90s slice and boundary expansion tacked on a few
/// more seconds. Measured on a show with a true 115-122s intro, that produced
/// ~100s intros no matter what the expansion threshold was set to, because the
/// answer was never in the search space.
const QVector<int> kWindowLengths = {78, 117, 156, 234, 352, 469, 703, 938, 1172};

/// Only the first few episodes take part in the template search; correlating
/// all 20 episodes of a season against each other costs far more and finds the
/// same theme tune.
constexpr int kMaxSampleEpisodes = 5;

QString formatClock(double seconds)
{
    const int total = static_cast<int>(std::max(0.0, seconds));
    return QStringLiteral("%1:%2")
        .arg(total / 60, 2, 10, QLatin1Char('0'))
        .arg(total % 60, 2, 10, QLatin1Char('0'));
}

void throwIfCancelled(const std::atomic_bool &cancelFlag)
{
    if (cancelFlag.load()) {
        throw RcdEngine::Cancelled();
    }
}

} // namespace

RcdEngine &RcdEngine::instance()
{
    static RcdEngine engine;
    return engine;
}

void RcdEngine::searchRegionSeconds(int durationSec, int *introSec, int *creditsSec)
{
    if (introSec) {
        *introSec = std::min(600, std::max(240, static_cast<int>(durationSec * 0.25)));
    }
    if (creditsSec) {
        *creditsSec = std::min(360, std::max(150, static_cast<int>(durationSec * 0.18)));
    }
}

QStringList RcdEngine::videoFilesIn(const QString &directoryPath)
{
    QStringList files;

    QDirIterator iterator(directoryPath, QDir::Files | QDir::NoDotAndDotDot);
    while (iterator.hasNext()) {
        const QString path = iterator.next();
        const QString suffix = QFileInfo(path).suffix().toLower();
        if (FFmpegService::supportedVideoExtensions().contains(suffix)) {
            files.append(path);
        }
    }

    // Natural ordering, so S01E10 sorts after S01E09 rather than after S01E01.
    QCollator collator;
    collator.setNumericMode(true);
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    std::sort(files.begin(), files.end(),
              [&collator](const QString &a, const QString &b) {
                  return collator.compare(QFileInfo(a).fileName(), QFileInfo(b).fileName()) < 0;
              });

    return files;
}

// MARK: - Chromaprint-Inspired 12-Bin Chroma Feature Extraction
//
// Based on research from:
//   - Chromaprint/AcoustID (Lukáš Lalinský) — 12-bin chroma pitch class profiles
//   - Jellyfin Intro Skipper — chromaprint + pairwise episode comparison
//   - Plex Intro Detection — audio fingerprint cross-correlation
//
// Key properties:
//   1. 12 chroma bins (C, C#, D... B) — maps FFT bins to musical notes,
//      discarding octave, so a theme transposed or re-mastered still matches
//   2. L2 normalisation per frame — amplitude-invariant matching
//   3. Overlapping frames (3/4 overlap) for smoother temporal resolution

QVector<float> RcdEngine::computeChromaFeatures(const QVector<qint16> &pcmSamples)
{
    if (pcmSamples.size() < 4096) {
        return {};
    }

    // FFmpeg hands this back at 4000 Hz mono (see extractPcmAudioSnippet).
    constexpr float kSampleRate = 4000.0f;
    constexpr int kFrameSize = 2048;  // ~0.512s at 4000 Hz
    constexpr int kHopSize = 512;     // ~0.128s hop -> ~8 frames/sec

    const int totalFrames = std::max(0, static_cast<int>((pcmSamples.size() - kFrameSize) / kHopSize));
    if (totalFrames <= 0) {
        return {};
    }

    QVector<float> featureVector(totalFrames * kChromaBins, 0.0f);

    const FftSetup fft(kFrameSize);
    const std::vector<float> window = hannWindow(kFrameSize);
    const int halfN = kFrameSize / 2;

    // Pre-computed FFT bin -> chroma bin map. For magnitude bin k,
    // frequency = k * sampleRate / frameSize; MIDI note = 69 + 12*log2(f/440);
    // chroma bin = note % 12.
    std::vector<int> binToChroma(static_cast<std::size_t>(halfN), -1);
    for (int k = 1; k < halfN; ++k) {
        const float freq = static_cast<float>(k) * kSampleRate / static_cast<float>(kFrameSize);
        // Outside 65-2000 Hz there is little musical pitch content, and the
        // low end is dominated by rumble that would smear every bin.
        if (freq < 65.0f || freq > 2000.0f) {
            continue;
        }
        const double midiNote = 69.0 + 12.0 * std::log2(static_cast<double>(freq) / 440.0);
        const int chromaBin = static_cast<int>(std::lround(midiNote)) % 12;
        binToChroma[static_cast<std::size_t>(k)] = (chromaBin + 12) % 12;
    }

    std::vector<float> frame(kFrameSize, 0.0f);
    std::vector<float> magnitudes(static_cast<std::size_t>(halfN), 0.0f);

    for (int frameIndex = 0; frameIndex < totalFrames; ++frameIndex) {
        const qsizetype start = static_cast<qsizetype>(frameIndex) * kHopSize;

        for (int k = 0; k < kFrameSize; ++k) {
            frame[static_cast<std::size_t>(k)] =
                (static_cast<float>(pcmSamples[start + k]) / 32768.0f)
                * window[static_cast<std::size_t>(k)];
        }

        fft.magnitudeSpectrum(frame, magnitudes);

        float chroma[kChromaBins] = {};
        for (int k = 1; k < halfN; ++k) {
            const int bin = binToChroma[static_cast<std::size_t>(k)];
            if (bin >= 0) {
                chroma[bin] += magnitudes[static_cast<std::size_t>(k)];
            }
        }

        // L2 normalisation — crucial for matching different masters or volumes.
        const float norm = vectorNorm(chroma, kChromaBins);
        if (norm > 1e-6f) {
            const float invNorm = 1.0f / norm;
            for (float &value : chroma) {
                value *= invNorm;
            }
        }

        for (int b = 0; b < kChromaBins; ++b) {
            featureVector[frameIndex * kChromaBins + b] = chroma[b];
        }
    }

    return featureVector;
}

QVector<float> RcdEngine::extractFeatureVector(const QString &path, int startSec, int durationSec) const
{
    const QVector<qint16> pcm =
        FFmpegService::instance().extractPcmAudioSnippet(path, startSec, durationSec, 4000);
    return computeChromaFeatures(pcm);
}

// MARK: - Template search

RcdEngine::TemplateCandidate
RcdEngine::searchBestTemplateWindow(const QVector<float> &baseBuckets,
                                    const QString &baseName,
                                    int wLen,
                                    bool isIntro,
                                    const QStringList &sampleEpisodes,
                                    const QHash<QString, EpisodeAudio> &episodeAudio,
                                    float minThreshold,
                                    double secPerFrame) const
{
    TemplateCandidate best;

    const int totalFrames = static_cast<int>(baseBuckets.size()) / kChromaBins;
    if (totalFrames <= wLen) {
        return best;
    }

    // Step 4 frames (~0.5s) rather than 1: the correlation surface is smooth at
    // this scale, and a full-resolution sweep costs 4x for no measured gain.
    for (int startIdx = 0; startIdx < totalFrames - wLen; startIdx += 4) {
        const float *sliceA = baseBuckets.constData() + static_cast<qsizetype>(startIdx) * kChromaBins;
        const std::size_t sliceLength = static_cast<std::size_t>(wLen) * kChromaBins;
        const float normA = vectorNorm(sliceA, sliceLength);
        if (normA <= 0.01f) {
            continue;
        }

        int matchCount = 0;
        float totalScore = 0.0f;

        for (const QString &otherPath : sampleEpisodes) {
            const QString otherName = QFileInfo(otherPath).fileName();
            if (otherName == baseName) {
                continue;
            }

            const auto it = episodeAudio.constFind(otherName);
            if (it == episodeAudio.constEnd()) {
                continue;
            }

            const QVector<float> &epBuckets = isIntro ? it->introFeatures : it->creditsFeatures;
            const int epTotal = static_cast<int>(epBuckets.size()) / kChromaBins;
            const int searchMax = std::max(0, epTotal - wLen);

            float bestSim = 0.0f;
            for (int targetIdx = 0; targetIdx < searchMax; targetIdx += 4) {
                const qsizetype end = static_cast<qsizetype>(targetIdx + wLen) * kChromaBins;
                if (end > epBuckets.size()) {
                    break;
                }
                const float *sliceB =
                    epBuckets.constData() + static_cast<qsizetype>(targetIdx) * kChromaBins;
                const float normB = vectorNorm(sliceB, sliceLength);
                if (normB > 0.01f) {
                    const float sim = dotProduct(sliceA, sliceB, sliceLength) / (normA * normB);
                    bestSim = std::max(bestSim, sim);
                }
            }

            if (bestSim >= minThreshold) {
                ++matchCount;
                totalScore += bestSim;
            }
        }

        // Half the other sample episodes must agree before a window counts as
        // recurring content rather than a coincidence between two files.
        if (matchCount >= std::max(1, (static_cast<int>(sampleEpisodes.size()) - 1) / 2)) {
            const float avgScore = totalScore / static_cast<float>(matchCount);

            // Weight by window duration so full 45-90s intros win over tiny
            // 10s snippets that happen to correlate perfectly.
            const float durationWeight =
                std::sqrt(static_cast<float>(wLen) * static_cast<float>(secPerFrame) / 30.0f);

            // NB: position within the credits region is deliberately NOT
            // weighted here. Preferring later candidates was tried and measured
            // worse. Credits-vs-preview is disambiguated visually instead —
            // see pickCreditsCandidate.
            const float weightedScore = avgScore * durationWeight;

            if (!best.valid || weightedScore > best.weightedScore) {
                best.startBucket = startIdx;
                best.wLen = wLen;
                best.score = avgScore;
                best.baseName = baseName;
                best.weightedScore = weightedScore;
                best.valid = true;
            }
        }
    }

    return best;
}

void RcdEngine::expandBoundaries(const QVector<float> &baseBuckets, int baseStart,
                                 const QVector<float> &epBuckets, int epStart,
                                 int seedWLen, bool isBaseEpisode,
                                 int *startFrame, int *endFrame) const
{
    const int totalEpFrames = static_cast<int>(epBuckets.size()) / kChromaBins;
    const int totalBaseFrames = static_cast<int>(baseBuckets.size()) / kChromaBins;

    // The template was cut from this very episode, so every comparison would be
    // the slice against itself and score a perfect 1.0 — expansion would just
    // run to the cap in both directions and report a segment noticeably longer
    // than the same segment in every other episode. The template bounds are
    // already the answer here.
    if (isBaseEpisode) {
        *startFrame = std::max(0, epStart - 4);
        *endFrame = std::min(totalEpFrames, epStart + seedWLen + 4);
        return;
    }

    constexpr int kWin = 8; // ~1s comparison window

    // Chroma cosine similarity required to keep growing. 0.32 sits at the noise
    // level, where unrelated audio passes and expansion runs to the array
    // bounds. Tried at 0.42 and scaled to the template's own score; neither
    // changed results measurably, because expansion was never the binding
    // constraint — the template length list was.
    constexpr float kSimThreshold = 0.50f;

    // Growth cap, proportional to the segment being expanded. A fixed 15s is
    // simultaneously too generous for a 15s title card and too mean for a
    // 2-minute title sequence.
    const int maxExpandFrames = std::max(60, seedWLen / 2);

    const std::size_t compareLength = static_cast<std::size_t>(kWin) * kChromaBins;

    /// Correlates base and episode at their own respective offsets.
    /// Returns -1 when either window falls outside its array or is too quiet
    /// to compare meaningfully.
    const auto similarity = [&](int baseAt, int epAt) -> float {
        if (baseAt < 0 || epAt < 0
            || baseAt + kWin > totalBaseFrames
            || epAt + kWin > totalEpFrames) {
            return -1.0f;
        }

        const float *sliceA = baseBuckets.constData() + static_cast<qsizetype>(baseAt) * kChromaBins;
        const float *sliceB = epBuckets.constData() + static_cast<qsizetype>(epAt) * kChromaBins;
        const float normA = vectorNorm(sliceA, compareLength);
        const float normB = vectorNorm(sliceB, compareLength);
        if (normA <= 0.03f || normB <= 0.03f) {
            return -1.0f;
        }
        return dotProduct(sliceA, sliceB, compareLength) / (normA * normB);
    };

    int expandedBack = 0;
    while (expandedBack + kWin <= maxExpandFrames) {
        const int step = expandedBack + kWin;
        const float sim = similarity(baseStart - step, epStart - step);
        if (sim < kSimThreshold) {
            break;
        }
        expandedBack = step;
    }

    int expandedForward = 0;
    while (expandedForward + kWin <= maxExpandFrames) {
        const float sim = similarity(baseStart + seedWLen + expandedForward,
                                     epStart + seedWLen + expandedForward);
        if (sim < kSimThreshold) {
            break;
        }
        expandedForward += kWin;
    }

    // 4-frame (~0.5s) boundary safety padding.
    *startFrame = std::max(0, epStart - expandedBack - 4);
    *endFrame = std::min(totalEpFrames, epStart + seedWLen + expandedForward + 4);
}

// MARK: - Visual pass

int RcdEngine::textRectangleCount(const QString &videoPath, int timeSec) const
{
    // Full 1080p, not a downscale: credits are not always full-screen. A show
    // that runs its crawl in a narrow side panel beside the preview leaves each
    // name about 8 pixels tall at 960x540 — legible in the source, invisible to
    // the text detector.
    const QByteArray jpeg = FFmpegService::instance().extractThumbnailData(
        videoPath, timeSec * 1000, QStringLiteral("1920x1080"));
    if (jpeg.isEmpty()) {
        return 0;
    }
    return OcrService::instance().textLineCount(jpeg);
}

float RcdEngine::textDensity(const QString &videoPath, double startSec, double endSec) const
{
    if (endSec <= startSec) {
        return 0.0f;
    }

    // Five evenly spaced probes: enough to tell a crawl from ordinary footage
    // without paying for a frame per second of the candidate.
    constexpr int kProbes = 5;
    int total = 0;
    int taken = 0;

    for (int i = 0; i < kProbes; ++i) {
        const double t = startSec + (endSec - startSec) * (static_cast<double>(i) + 0.5)
                                        / static_cast<double>(kProbes);
        total += textRectangleCount(videoPath, static_cast<int>(t));
        ++taken;
    }

    return taken > 0 ? static_cast<float>(total) / static_cast<float>(taken) : 0.0f;
}

RcdEngine::VisualCreditsOffset
RcdEngine::detectCreditsVisually(const QString &videoPath,
                                 int durationSec,
                                 const std::atomic_bool &cancelFlag,
                                 const std::function<void(const QString &)> &log) const
{
    VisualCreditsOffset offset;

    if (!OcrService::instance().isAvailable()) {
        return offset;
    }

    const int tailSec = std::min(420, std::max(120, static_cast<int>(durationSec * 0.22)));
    const int scanStart = std::max(0, durationSec - tailSec);
    constexpr int kStep = 8;

    struct Sample {
        int sec;
        int rects;
    };
    QVector<Sample> samples;

    for (int t = scanStart; t < durationSec - 2; t += kStep) {
        if (cancelFlag.load()) {
            return offset;
        }
        samples.append(Sample{t, textRectangleCount(videoPath, t)});
    }

    if (samples.size() < 4) {
        return offset;
    }

    // Threshold relative to this episode's own baseline: burned-in logos and
    // name captions give every frame a couple of rectangles, so a fixed cut-off
    // would either miss credits on a clean-looking show or fire on ordinary
    // footage of a caption-heavy one.
    QVector<int> counts;
    counts.reserve(samples.size());
    for (const Sample &sample : samples) {
        counts.append(sample.rects);
    }
    std::sort(counts.begin(), counts.end());

    const int median = counts.at(counts.size() / 2);
    const int peak = counts.last();
    const int threshold = std::max(5, median * 3);

    if (peak < threshold) {
        log(QStringLiteral("  [Credits/OCR] No dense text block in the last %1s "
                           "(peak %2 lines, median %3) — leaving the audio match in place")
                .arg(tailSec).arg(peak).arg(median));
        return offset;
    }

    // Longest contiguous run at or above the threshold.
    int bestStart = -1;
    int bestEnd = -1;
    int runStart = -1;
    for (int idx = 0; idx < samples.size(); ++idx) {
        if (samples[idx].rects >= threshold) {
            if (runStart < 0) {
                runStart = idx;
            }
        } else if (runStart >= 0) {
            if (bestStart < 0 || (idx - runStart) > (bestEnd - bestStart)) {
                bestStart = runStart;
                bestEnd = idx;
            }
            runStart = -1;
        }
    }
    if (runStart >= 0 && (bestStart < 0 || (samples.size() - runStart) > (bestEnd - bestStart))) {
        bestStart = runStart;
        bestEnd = static_cast<int>(samples.size());
    }
    if (bestStart < 0) {
        return offset;
    }

    // Sampling every `kStep` seconds only brackets the block — it began
    // somewhere between the previous sample and the first hit, so widen by one
    // step rather than reporting the sampled bounds as if they were exact.
    const double startSec = std::max(0.0, static_cast<double>(samples[bestStart].sec - kStep));

    // Closing credits run to the end of the file. Ground-truth entries record
    // credits as open-ended (TheIntroDB stores end_ms: null), and the densest
    // stretch of text is only the middle of the crawl — text thins out as names
    // scroll off, so the sampled run consistently under-reports the end.
    // Reporting the run's own end produced a 21s segment where the real credits
    // were several minutes long.
    const double endSec = static_cast<double>(durationSec);

    log(QStringLiteral("  [Credits/OCR] Dense text from %1, credits run to end of file %2 "
                       "(threshold %3 lines, peak %4, median %5)")
            .arg(formatClock(startSec), formatClock(endSec))
            .arg(threshold).arg(peak).arg(median));

    offset.secondsBeforeEndStart = static_cast<double>(durationSec) - startSec;
    offset.secondsBeforeEndEnd = static_cast<double>(durationSec) - endSec;
    offset.valid = true;
    return offset;
}

RcdEngine::TemplateCandidate
RcdEngine::pickCreditsCandidate(const QVector<TemplateCandidate> &candidates,
                                const QHash<QString, EpisodeAudio> &episodeAudio,
                                const QStringList &sampleEpisodes,
                                double secPerFrame,
                                const std::function<void(const QString &)> &log) const
{
    QVector<TemplateCandidate> ranked = candidates;
    std::sort(ranked.begin(), ranked.end(),
              [](const TemplateCandidate &a, const TemplateCandidate &b) {
                  return a.weightedScore > b.weightedScore;
              });

    const TemplateCandidate fallback = ranked.first();
    if (!OcrService::instance().isAvailable()) {
        return fallback;
    }

    // Up to 3 candidates describing genuinely different moments. Two candidates
    // from the same base episode overlapping in time are the same finding at
    // different window lengths; inspecting both wastes extractions without
    // adding information.
    QVector<TemplateCandidate> distinct;
    for (const TemplateCandidate &candidate : ranked) {
        const bool overlaps = std::any_of(
            distinct.constBegin(), distinct.constEnd(),
            [&candidate](const TemplateCandidate &chosen) {
                return chosen.baseName == candidate.baseName
                    && candidate.startBucket < chosen.startBucket + chosen.wLen
                    && chosen.startBucket < candidate.startBucket + candidate.wLen;
            });
        if (!overlaps) {
            distinct.append(candidate);
        }
        if (distinct.size() == 3) {
            break;
        }
    }

    if (distinct.size() <= 1) {
        return fallback;
    }

    float bestDensity = -1.0f;
    TemplateCandidate bestByDensity;

    for (const TemplateCandidate &candidate : distinct) {
        const auto audioIt = episodeAudio.constFind(candidate.baseName);
        if (audioIt == episodeAudio.constEnd()) {
            continue;
        }

        QString basePath;
        for (const QString &path : sampleEpisodes) {
            if (QFileInfo(path).fileName() == candidate.baseName) {
                basePath = path;
                break;
            }
        }
        if (basePath.isEmpty()) {
            continue;
        }

        const int regionStartSec = std::max(0, audioIt->durationSec - audioIt->creditsRegionSec);
        const double startSec = regionStartSec + candidate.startBucket * secPerFrame;
        const double endSec = regionStartSec + (candidate.startBucket + candidate.wLen) * secPerFrame;

        const float density = textDensity(basePath, startSec, endSec);

        log(QStringLiteral("  [Credits candidate] %1-%2 in %3 — audio %4%, text density %5")
                .arg(formatClock(startSec), formatClock(endSec), candidate.baseName)
                .arg(candidate.score * 100.0f, 0, 'f', 1)
                .arg(density, 0, 'f', 1));

        if (density > bestDensity) {
            bestDensity = density;
            bestByDensity = candidate;
        }
    }

    // Require actual text on screen before overriding the audio ranking. Below
    // this a scene simply has no captions to measure and the density figures
    // are noise — a show whose credits are a static logo rather than a crawl
    // lands here and keeps the audio winner.
    constexpr float kMeaningfulTextDensity = 2.0f;
    if (!bestByDensity.valid || bestDensity < kMeaningfulTextDensity) {
        log(QStringLiteral("  [Credits] No candidate showed meaningful on-screen text "
                           "(best density %1) — keeping strongest audio match")
                .arg(std::max(0.0f, bestDensity), 0, 'f', 1));
        return fallback;
    }

    return bestByDensity;
}

QVector<RcdMatch> RcdEngine::refineMatchesWithOcr(const QVector<RcdMatch> &matches,
                                                  const QString &videoPath,
                                                  RcdDetectionMethod method,
                                                  const std::function<void(const QString &)> &log) const
{
    // The pure-audio method opts out of every visual pass by definition.
    if (method == RcdDetectionMethod::ChromaprintFft) {
        return matches;
    }

    QVector<RcdMatch> refined;
    refined.reserve(matches.size());

    for (const RcdMatch &match : matches) {
        RcdMatch adjusted = match;

        // Credit blocks are almost always preceded by a fade to black. Snapping
        // the start onto that frame is worth up to ~2s of accuracy and costs
        // four single-pixel probes.
        if (match.type == SegmentType::Credits) {
            constexpr double kSnapWindowSec = 2.0;
            double bestTime = match.startSec;
            double darkest = 255.0;

            for (int offset = -2; offset <= 2; ++offset) {
                const double probe = match.startSec + offset * (kSnapWindowSec / 2.0);
                if (probe < 0.0) {
                    continue;
                }
                const auto luminance =
                    FFmpegService::instance().meanLuminance(videoPath, static_cast<int>(probe));
                if (luminance.has_value() && *luminance < darkest) {
                    darkest = *luminance;
                    bestTime = probe;
                }
            }

            // Same threshold the macOS Vision pass uses: mean luma below
            // 30/255 is a black frame, anything above is real picture.
            if (darkest < 30.0 && std::abs(bestTime - match.startSec) > 0.05) {
                log(QStringLiteral("  [Refine] Credits start snapped %1 -> %2 (black frame, luma %3)")
                        .arg(formatClock(match.startSec), formatClock(bestTime))
                        .arg(darkest, 0, 'f', 0));
                adjusted.startSec = bestTime;
            }
        }

        refined.append(adjusted);
    }

    return refined;
}

// MARK: - Single-file structural path

RcdEngine::MusicRun RcdEngine::longestMusicRun(const QVector<float> &buckets,
                                               int rangeStart, int rangeEnd,
                                               double minLengthSec, double secPerBucket)
{
    MusicRun result;
    if (rangeStart >= rangeEnd || rangeEnd > buckets.size()) {
        return result;
    }

    const int minBuckets = std::max(1, static_cast<int>(minLengthSec / secPerBucket));

    // Progressively lower thresholds, mirroring the adaptive thresholding the
    // season scan uses, until a run meets the caller's minimum length.
    //
    // The first two are stricter than the season scan's ladder because they
    // exist for the case the guard below rejects: on content with a music bed
    // under the whole episode, a 0.70 cut qualifies every bucket. Only a
    // stricter cut can isolate an actual theme, and looser ones never can —
    // lowering the threshold only ever makes runs longer.
    for (const float threshold : {0.88f, 0.80f, 0.70f, 0.60f, 0.50f, 0.42f}) {
        int bestStart = -1;
        int bestEnd = -1;
        int runStart = -1;

        // Close over one trailing bucket so a run ending exactly at the
        // boundary is considered.
        for (int idx = rangeStart; idx <= rangeEnd; ++idx) {
            const bool isMusic = idx < rangeEnd && buckets[idx] >= threshold;
            if (isMusic) {
                if (runStart < 0) {
                    runStart = idx;
                }
            } else if (runStart >= 0) {
                const int length = idx - runStart;
                if (length >= minBuckets && length > (bestEnd - bestStart)) {
                    bestStart = runStart;
                    bestEnd = idx;
                }
                runStart = -1;
            }
        }

        if (bestStart >= 0) {
            // A run covering nearly the whole search region means the threshold
            // failed to discriminate, not that the region is one long segment.
            // Reality and panel formats run a music bed under the entire
            // episode, so spectral flatness reports "music" everywhere and the
            // longest run is simply the window itself — which was reported as a
            // 10-minute intro starting at 00:00. Fall through to a stricter
            // threshold instead, and give up rather than emit that.
            const int runLength = bestEnd - bestStart;
            const int rangeLength = rangeEnd - rangeStart;
            if (runLength < static_cast<int>(rangeLength * 0.85)) {
                float sum = 0.0f;
                for (int i = bestStart; i < bestEnd; ++i) {
                    sum += buckets[i];
                }
                result.startBucket = bestStart;
                result.endBucket = bestEnd;
                result.confidence = std::min(1.0f, sum / static_cast<float>(runLength));
                result.valid = true;
                return result;
            }
        }
    }

    return result;
}

QVector<RcdMatch>
RcdEngine::detectStructuralSegments(const QString &videoPath,
                                    double minSegmentLengthSec,
                                    const std::atomic_bool &cancelFlag,
                                    const ProgressHandler &progress,
                                    const std::function<void(const QString &)> &log) const
{
    QVector<RcdMatch> matches;

    progress(QStringLiteral("Inspecting media duration..."), 10);

    int durationMs = 0;
    if (const auto info = FFmpegService::instance().inspectMedia(videoPath)) {
        durationMs = info->durationMs;
    }
    if (durationMs <= 0) {
        log(QStringLiteral("ERROR: could not determine media duration; structural analysis aborted."));
        return matches;
    }

    throwIfCancelled(cancelFlag);
    progress(QStringLiteral("Classifying music vs. speech (spectral flatness)..."), 25);

    const AudioExtractorService::Result audio = AudioExtractorService::instance().analyze(
        videoPath, durationMs,
        [&progress](int percent) {
            progress(QStringLiteral("Classifying music vs. speech (spectral flatness)..."),
                     25 + (percent * 45 / 100));
        });

    throwIfCancelled(cancelFlag);

    const QVector<float> &musicLikelihood = audio.musicLikelihoodBuckets;
    if (musicLikelihood.size() <= 4) {
        log(QStringLiteral("ERROR: audio classification returned no usable data."));
        return matches;
    }

    const double durationSec = static_cast<double>(durationMs) / 1000.0;
    const double secPerBucket = durationSec / static_cast<double>(musicLikelihood.size());
    log(QStringLiteral("Structural analysis over %1s (%2 buckets, %3s each)")
            .arg(durationSec, 0, 'f', 0)
            .arg(musicLikelihood.size())
            .arg(secPerBucket, 0, 'f', 2));

    progress(QStringLiteral("Locating structural boundaries..."), 80);

    // Intros live near the start, credits near the end. Bound the search to
    // those regions so a musical scene in the middle of the episode can't be
    // mistaken for either.
    const int introSearchEnd = std::min(
        static_cast<int>(musicLikelihood.size()),
        static_cast<int>(std::min(600.0, durationSec * 0.30) / secPerBucket));
    const int creditsSearchStart = std::max(
        0,
        static_cast<int>(musicLikelihood.size())
            - static_cast<int>(std::min(600.0, durationSec * 0.25) / secPerBucket));

    const MusicRun introRun = longestMusicRun(musicLikelihood, 0, introSearchEnd,
                                              minSegmentLengthSec, secPerBucket);
    if (introRun.valid) {
        RcdMatch match;
        match.type = SegmentType::Intro;
        match.startSec = introRun.startBucket * secPerBucket;
        match.endSec = introRun.endBucket * secPerBucket;
        match.confidence = introRun.confidence;
        matches.append(match);
        log(QStringLiteral("  INTRO (structural): %1 - %2 (%3% music confidence)")
                .arg(formatClock(match.startSec), formatClock(match.endSec))
                .arg(match.confidence * 100.0f, 0, 'f', 1));
    } else {
        log(QStringLiteral("  No sustained intro music found in the opening region."));
    }

    if (creditsSearchStart < musicLikelihood.size()) {
        const MusicRun creditsRun = longestMusicRun(
            musicLikelihood, creditsSearchStart, static_cast<int>(musicLikelihood.size()),
            minSegmentLengthSec, secPerBucket);
        if (creditsRun.valid) {
            RcdMatch match;
            match.type = SegmentType::Credits;
            match.startSec = creditsRun.startBucket * secPerBucket;
            match.endSec = creditsRun.endBucket * secPerBucket;
            match.confidence = creditsRun.confidence;
            matches.append(match);
            log(QStringLiteral("  CREDITS (structural): %1 - %2 (%3% music confidence)")
                    .arg(formatClock(match.startSec), formatClock(match.endSec))
                    .arg(match.confidence * 100.0f, 0, 'f', 1));
        } else {
            log(QStringLiteral("  No sustained credits music found in the closing region."));
        }
    }

    return matches;
}

// MARK: - Entry points

RcdEngine::Results RcdEngine::scanSeason(const QString &directoryPath,
                                         const Options &options,
                                         const std::atomic_bool &cancelFlag,
                                         const ProgressHandler &progress,
                                         const DebugLogger &debugLogger)
{
    const QStringList videoFiles = videoFilesIn(directoryPath);
    if (videoFiles.isEmpty()) {
        throw std::runtime_error("Directory contains no supported video files");
    }
    return runScan(videoFiles, directoryPath, options, cancelFlag, progress, debugLogger);
}

RcdEngine::Results RcdEngine::scanSingleEpisode(const QString &videoPath,
                                                const Options &options,
                                                const std::atomic_bool &cancelFlag,
                                                const ProgressHandler &progress,
                                                const DebugLogger &debugLogger)
{
    const QString suffix = QFileInfo(videoPath).suffix().toLower();
    if (!FFmpegService::supportedVideoExtensions().contains(suffix)) {
        throw std::runtime_error(
            QStringLiteral("Unsupported video format: .%1").arg(suffix).toStdString());
    }
    return runScan({videoPath}, QFileInfo(videoPath).fileName(), options,
                   cancelFlag, progress, debugLogger);
}

RcdEngine::Results RcdEngine::runScan(const QStringList &videoFiles,
                                      const QString &sourceDescription,
                                      const Options &options,
                                      const std::atomic_bool &cancelFlag,
                                      const ProgressHandler &progress,
                                      const DebugLogger &debugLogger)
{
    const auto log = [&debugLogger](const QString &message) {
        LoggerService::instance().info(QStringLiteral("[RCD Engine] ") + message);
        if (debugLogger) {
            debugLogger(message);
        }
    };

    log(QStringLiteral("Initiating RCD scan with method '%1' on %2")
            .arg(rcdMethodDisplayName(options.method), sourceDescription));

    FFmpegService &ffmpeg = FFmpegService::instance();
    log(QStringLiteral("FFmpeg binary path: %1")
            .arg(ffmpeg.ffmpegPath().isEmpty() ? QStringLiteral("NOT FOUND!") : ffmpeg.ffmpegPath()));
    log(QStringLiteral("FFprobe binary path: %1")
            .arg(ffmpeg.ffprobePath().isEmpty() ? QStringLiteral("NOT FOUND!") : ffmpeg.ffprobePath()));

    // Fail loudly instead of silently returning zero matches. Without these
    // binaries every audio extraction returns empty and the scan "succeeds"
    // while detecting nothing — which reads to the user as a broken feature
    // rather than a missing dependency.
    if (!ffmpeg.hasBinaries()) {
        const QString error =
            QStringLiteral("ffmpeg/ffprobe not found. RCD scanning needs them to decode audio. "
                           "Install with 'winget install Gyan.FFmpeg', or place ffmpeg.exe and "
                           "ffprobe.exe in a 'bin' folder next to Segmenter.exe.");
        log(QStringLiteral("ERROR: ") + error);
        throw std::runtime_error(error.toStdString());
    }

    log(QStringLiteral("Acceleration: %1").arg(OcrService::instance().backendDescription()));
    log(QStringLiteral("Analysing %1 video file(s); minimum segment length %2s")
            .arg(videoFiles.size())
            .arg(static_cast<int>(options.minSegmentLengthSec)));

    progress(QStringLiteral("Preparing audio feature vectors..."), 5);
    throwIfCancelled(cancelFlag);

    // Repeated-content detection is meaningless with a single file: there is
    // nothing to cross-correlate against. Correlating an episode with itself
    // scores 1.0 at every offset, which makes boundary expansion run to the
    // edges and report the whole search region as one segment. Route single-file
    // scans to structural analysis instead.
    if (videoFiles.size() == 1) {
        const QString videoPath = videoFiles.first();
        const QString epName = QFileInfo(videoPath).fileName();

        log(QStringLiteral("Single file — cross-episode correlation not applicable. "
                           "Using structural audio analysis."));

        const QVector<RcdMatch> structural =
            detectStructuralSegments(videoPath, options.minSegmentLengthSec,
                                     cancelFlag, progress, log);
        const QVector<RcdMatch> refined =
            refineMatchesWithOcr(structural, videoPath, options.method, log);

        QVector<RcdMatch> filtered;
        for (const RcdMatch &match : refined) {
            if (match.durationSec() >= options.minSegmentLengthSec) {
                filtered.append(match);
            }
        }

        log(QStringLiteral("Structural scan complete — located %1 segment(s) in %2")
                .arg(filtered.size()).arg(epName));
        progress(QStringLiteral("RCD Fingerprinting Complete!"), 100);

        Results results;
        results.insert(epName, filtered);
        return results;
    }

    // --- Phase 1: per-episode chroma feature extraction ---------------------
    //
    // Extraction is I/O-bound (each episode spawns an independent FFmpeg
    // subprocess), so it runs across a pool rather than serially. Feature
    // vectors are cached to disk keyed by file size + modification date, so
    // re-scanning a season (different method or threshold, or one new episode
    // dropped into the folder) skips decode + FFT entirely for files that
    // haven't changed since the last scan.
    const int maxConcurrentExtractions =
        std::max(1, std::min(QThread::idealThreadCount(), static_cast<int>(videoFiles.size())));
    log(QStringLiteral("Extracting audio features across %1 episode(s) with up to %2 concurrent workers...")
            .arg(videoFiles.size()).arg(maxConcurrentExtractions));

    QHash<QString, EpisodeAudio> episodeAudio;
    {
        std::atomic_int completed{0};
        QMutex resultMutex;

        QThreadPool extractionPool;
        extractionPool.setMaxThreadCount(maxConcurrentExtractions);

        const auto extractOne = [&](const QString &videoPath) {
            if (cancelFlag.load()) {
                return;
            }
            const QString epName = QFileInfo(videoPath).fileName();

            EpisodeAudio audio;

            if (const auto cached = RcdFeatureCache::instance().features(videoPath)) {
                audio.introFeatures = cached->introFeatures;
                audio.creditsFeatures = cached->creditsFeatures;
                audio.durationSec = cached->durationSec;
                audio.introRegionSec = cached->introRegionSec;
                audio.creditsRegionSec = cached->creditsRegionSec;
                log(QStringLiteral("  [%1] Reusing cached audio features (skipped decode + FFT)")
                        .arg(epName));
            } else {
                int epDurationSec = 3000; // fallback 50 min
                if (const auto info = FFmpegService::instance().inspectMedia(videoPath)) {
                    epDurationSec = std::max(info->durationMs / 1000, 600);
                }

                int introRegion = 0;
                int creditsRegion = 0;
                searchRegionSeconds(epDurationSec, &introRegion, &creditsRegion);

                audio.introFeatures = extractFeatureVector(videoPath, 0, introRegion);

                const int creditsStartSec = std::max(0, epDurationSec - creditsRegion);
                audio.creditsFeatures =
                    extractFeatureVector(videoPath, creditsStartSec, creditsRegion);

                audio.durationSec = epDurationSec;
                audio.introRegionSec = introRegion;
                audio.creditsRegionSec = creditsRegion;

                RcdFeatureCache::FeatureSet featureSet;
                featureSet.introFeatures = audio.introFeatures;
                featureSet.creditsFeatures = audio.creditsFeatures;
                featureSet.durationSec = epDurationSec;
                featureSet.introRegionSec = introRegion;
                featureSet.creditsRegionSec = creditsRegion;
                RcdFeatureCache::instance().store(featureSet, videoPath);
            }

            {
                QMutexLocker locker(&resultMutex);
                episodeAudio.insert(epName, audio);
            }

            const int done = ++completed;
            const int percent = 5 + static_cast<int>(
                (static_cast<double>(done) / static_cast<double>(videoFiles.size())) * 40.0);
            progress(QStringLiteral("Extracted audio for %1 (%2/%3)...")
                         .arg(epName).arg(done).arg(videoFiles.size()),
                     percent);
            log(QStringLiteral("  [%1/%2] %3: intro %4 frames, credits %5 frames")
                    .arg(done).arg(videoFiles.size()).arg(epName)
                    .arg(audio.introFeatures.size() / kChromaBins)
                    .arg(audio.creditsFeatures.size() / kChromaBins));
        };

        QtConcurrent::blockingMap(&extractionPool, videoFiles, extractOne);
    }

    throwIfCancelled(cancelFlag);

    progress(QStringLiteral("Cross-correlating intro fingerprints..."), 50);
    log(QStringLiteral("Phase 2: Cross-correlating intro chroma vectors across episodes..."));

    const QStringList sampleEpisodes =
        videoFiles.mid(0, std::min(kMaxSampleEpisodes, static_cast<int>(videoFiles.size())));
    const float targetThreshold = static_cast<float>(options.similarityThreshold);

    // Finds the best recurring template across sample episodes with adaptive
    // thresholding. Each (base episode, window length) pair is an independent
    // unit of search, fanned out so all cores share the
    // O(episodes × windowLengths × frames²) cost.
    const auto findBestTemplate = [&](bool isIntro) -> TemplateCandidate {
        const QVector<float> thresholdsToTry = {targetThreshold, 0.65f, 0.50f, 0.40f};

        for (const float minThreshold : thresholdsToTry) {
            throwIfCancelled(cancelFlag);

            struct Work {
                QString baseName;
                const QVector<float> *baseBuckets;
                int wLen;
            };
            QVector<Work> workItems;

            for (const QString &basePath : sampleEpisodes) {
                const QString baseName = QFileInfo(basePath).fileName();
                const auto it = episodeAudio.constFind(baseName);
                if (it == episodeAudio.constEnd()) {
                    continue;
                }
                const QVector<float> *buckets =
                    isIntro ? &it->introFeatures : &it->creditsFeatures;
                for (const int wLen : kWindowLengths) {
                    workItems.append(Work{baseName, buckets, wLen});
                }
            }

            const QVector<TemplateCandidate> found = QtConcurrent::blockingMapped(
                workItems,
                std::function<TemplateCandidate(const Work &)>(
                    [&](const Work &work) -> TemplateCandidate {
                        if (cancelFlag.load()) {
                            return TemplateCandidate{};
                        }
                        return searchBestTemplateWindow(*work.baseBuckets, work.baseName,
                                                        work.wLen, isIntro, sampleEpisodes,
                                                        episodeAudio, minThreshold, kSecPerFrame);
                    }));

            QVector<TemplateCandidate> candidates;
            for (const TemplateCandidate &candidate : found) {
                if (candidate.valid) {
                    candidates.append(candidate);
                }
            }

            if (candidates.isEmpty()) {
                continue;
            }

            // Audio alone can't tell closing credits from a "next time on…"
            // preview: both recur across episodes and both score well. For
            // credits, resolve it visually.
            TemplateCandidate best;
            if (isIntro) {
                best = *std::max_element(candidates.constBegin(), candidates.constEnd(),
                                         [](const TemplateCandidate &a, const TemplateCandidate &b) {
                                             return a.weightedScore < b.weightedScore;
                                         });
            } else {
                best = pickCreditsCandidate(candidates, episodeAudio, sampleEpisodes,
                                            kSecPerFrame, log);
            }

            if (minThreshold < targetThreshold) {
                log(QStringLiteral("Adaptive threshold fallback used: %1% for %2")
                        .arg(minThreshold * 100.0f, 0, 'f', 0)
                        .arg(isIntro ? QStringLiteral("INTRO") : QStringLiteral("CREDITS")));
            }
            return best;
        }

        return TemplateCandidate{};
    };

    const TemplateCandidate introTemplate = findBestTemplate(true);

    progress(QStringLiteral("Cross-correlating credits fingerprints..."), 60);
    log(QStringLiteral("Phase 3: Cross-correlating credits chroma vectors across episodes..."));

    const TemplateCandidate creditsTemplate = findBestTemplate(false);

    if (introTemplate.valid) {
        const double s = introTemplate.startBucket * kSecPerFrame;
        const double e = (introTemplate.startBucket + introTemplate.wLen) * kSecPerFrame;
        log(QStringLiteral("INTRO template found: %1 - %2 (confidence: %3%, base: %4)")
                .arg(formatClock(s), formatClock(e))
                .arg(introTemplate.score * 100.0f, 0, 'f', 1)
                .arg(introTemplate.baseName));
    } else {
        log(QStringLiteral("No INTRO template found across episodes"));
    }

    if (creditsTemplate.valid) {
        const double s = creditsTemplate.startBucket * kSecPerFrame;
        const double e = (creditsTemplate.startBucket + creditsTemplate.wLen) * kSecPerFrame;
        log(QStringLiteral("CREDITS template found: %1 - %2 offset (confidence: %3%, base: %4)")
                .arg(formatClock(s), formatClock(e))
                .arg(creditsTemplate.score * 100.0f, 0, 'f', 1)
                .arg(creditsTemplate.baseName));
    } else {
        log(QStringLiteral("No CREDITS template found across episodes"));
    }

    // Some formats have no recurring audio under their credits at all, so no
    // amount of audio matching can find them. Scan one representative episode
    // visually; a credit block sits at a stable offset from the end, so the
    // interval found there transfers to the rest of the season. One episode
    // keeps this to a few dozen frame extractions instead of a few hundred.
    progress(QStringLiteral("Checking for on-screen credits..."), 70);
    VisualCreditsOffset visualCredits;
    if (options.method != RcdDetectionMethod::ChromaprintFft) {
        QStringList byDuration = videoFiles;
        std::sort(byDuration.begin(), byDuration.end(),
                  [&episodeAudio](const QString &a, const QString &b) {
                      const int durationA = episodeAudio.value(QFileInfo(a).fileName()).durationSec;
                      const int durationB = episodeAudio.value(QFileInfo(b).fileName()).durationSec;
                      return durationA < durationB;
                  });

        const QString probePath = byDuration.at(byDuration.size() / 2);
        const auto probeAudio = episodeAudio.constFind(QFileInfo(probePath).fileName());
        if (probeAudio != episodeAudio.constEnd()) {
            log(QStringLiteral("Scanning %1 for an on-screen credit block...")
                    .arg(QFileInfo(probePath).fileName()));
            visualCredits = detectCreditsVisually(probePath, probeAudio->durationSec,
                                                  cancelFlag, log);
        }
    }

    progress(QStringLiteral("Locating per-episode segment positions..."), 75);
    throwIfCancelled(cancelFlag);

    // --- Phase 4: per-episode localisation ----------------------------------
    //
    // Capped lower than audio extraction: OCR plus ffmpeg thumbnail extraction
    // contend more heavily over decode hardware than the pure correlation math.
    const int maxConcurrentLocalization =
        std::max(1, std::min({4, QThread::idealThreadCount(), static_cast<int>(videoFiles.size())}));

    Results results;
    {
        std::atomic_int completed{0};
        QMutex resultMutex;

        QThreadPool localizationPool;
        localizationPool.setMaxThreadCount(maxConcurrentLocalization);

        /// Slides `templateSlice` across `epBuckets` and returns the best
        /// correlation and its start frame.
        const auto locate = [&](const TemplateCandidate &tmpl,
                                const QVector<float> &baseBuckets,
                                const QVector<float> &epBuckets,
                                float *bestSimOut) -> int {
            const std::size_t sliceLength = static_cast<std::size_t>(tmpl.wLen) * kChromaBins;
            const float *templateSlice =
                baseBuckets.constData() + static_cast<qsizetype>(tmpl.startBucket) * kChromaBins;
            const float normT = vectorNorm(templateSlice, sliceLength);

            const int epTotal = static_cast<int>(epBuckets.size()) / kChromaBins;
            const int searchMax = std::max(0, epTotal - tmpl.wLen);

            float bestSim = 0.0f;
            int bestStart = tmpl.startBucket;

            if (searchMax > 0 && normT > 0.01f) {
                for (int targetIdx = 0; targetIdx < searchMax; targetIdx += 4) {
                    const qsizetype end = static_cast<qsizetype>(targetIdx + tmpl.wLen) * kChromaBins;
                    if (end > epBuckets.size()) {
                        break;
                    }
                    const float *sliceB =
                        epBuckets.constData() + static_cast<qsizetype>(targetIdx) * kChromaBins;
                    const float normB = vectorNorm(sliceB, sliceLength);
                    if (normB > 0.01f) {
                        const float sim =
                            dotProduct(templateSlice, sliceB, sliceLength) / (normT * normB);
                        if (sim > bestSim) {
                            bestSim = sim;
                            bestStart = targetIdx;
                        }
                    }
                }
            }

            *bestSimOut = bestSim;
            return bestStart;
        };

        const auto localizeOne = [&](const QString &videoPath) {
            if (cancelFlag.load()) {
                return;
            }
            const QString epName = QFileInfo(videoPath).fileName();

            const auto epIt = episodeAudio.constFind(epName);
            if (epIt == episodeAudio.constEnd()) {
                QMutexLocker locker(&resultMutex);
                results.insert(epName, {});
                return;
            }
            const EpisodeAudio &epAudio = *epIt;

            QVector<RcdMatch> matches;

            // --- INTRO ---
            if (introTemplate.valid) {
                const QVector<float> &baseBuckets =
                    episodeAudio.value(introTemplate.baseName).introFeatures;

                float bestSim = 0.0f;
                const int bestStart =
                    locate(introTemplate, baseBuckets, epAudio.introFeatures, &bestSim);

                int expStart = 0;
                int expEnd = 0;
                expandBoundaries(baseBuckets, introTemplate.startBucket,
                                 epAudio.introFeatures, bestStart, introTemplate.wLen,
                                 epName == introTemplate.baseName, &expStart, &expEnd);

                RcdMatch match;
                match.type = SegmentType::Intro;
                match.startSec = expStart * kSecPerFrame;
                match.endSec = expEnd * kSecPerFrame;
                match.confidence = bestSim > 0.0f ? bestSim : introTemplate.score;
                matches.append(match);

                log(QStringLiteral("  [%1] INTRO: %2 - %3 (%4%)")
                        .arg(epName, formatClock(match.startSec), formatClock(match.endSec))
                        .arg(match.confidence * 100.0f, 0, 'f', 1));
            }

            // --- CREDITS ---
            // A visually-confirmed credit block wins over the audio match:
            // dense on-screen text is specific to credits, whereas recurring
            // audio in the last minutes is equally consistent with a preview or
            // a confessional bed.
            if (visualCredits.valid) {
                const double startSec =
                    std::max(0.0, epAudio.durationSec - visualCredits.secondsBeforeEndStart);
                const double endSec =
                    std::max(startSec, epAudio.durationSec - visualCredits.secondsBeforeEndEnd);

                RcdMatch match;
                match.type = SegmentType::Credits;
                match.startSec = startSec;
                match.endSec = endSec;
                match.confidence = 0.90f;
                matches.append(match);

                log(QStringLiteral("  [%1] CREDITS (on-screen text): %2 - %3")
                        .arg(epName, formatClock(startSec), formatClock(endSec)));
            } else if (creditsTemplate.valid) {
                const QVector<float> &baseBuckets =
                    episodeAudio.value(creditsTemplate.baseName).creditsFeatures;

                float bestSim = 0.0f;
                const int bestStart =
                    locate(creditsTemplate, baseBuckets, epAudio.creditsFeatures, &bestSim);

                int expStart = 0;
                int expEnd = 0;
                expandBoundaries(baseBuckets, creditsTemplate.startBucket,
                                 epAudio.creditsFeatures, bestStart, creditsTemplate.wLen,
                                 epName == creditsTemplate.baseName, &expStart, &expEnd);

                // Convert the offset within the credits region back to absolute
                // time using this episode's own region length.
                const int creditsStartOffset =
                    std::max(0, epAudio.durationSec - epAudio.creditsRegionSec);

                RcdMatch match;
                match.type = SegmentType::Credits;
                match.startSec = creditsStartOffset + expStart * kSecPerFrame;
                match.endSec = creditsStartOffset + expEnd * kSecPerFrame;
                match.confidence = bestSim > 0.0f ? bestSim : creditsTemplate.score;
                matches.append(match);

                log(QStringLiteral("  [%1] CREDITS: %2 - %3 (%4%)")
                        .arg(epName, formatClock(match.startSec), formatClock(match.endSec))
                        .arg(match.confidence * 100.0f, 0, 'f', 1));
            }

            const QVector<RcdMatch> refined =
                refineMatchesWithOcr(matches, videoPath, options.method, log);

            // Honour the Min Segment Length setting. Applied after refinement
            // because the visual pass can move a credits start boundary
            // (black-frame snapping) and change the duration.
            QVector<RcdMatch> finalMatches;
            for (const RcdMatch &match : refined) {
                if (match.durationSec() < options.minSegmentLengthSec) {
                    log(QStringLiteral("  [%1] Discarded %2 — %3s is shorter than the %4s minimum")
                            .arg(epName, segmentTypeDisplayName(match.type))
                            .arg(match.durationSec(), 0, 'f', 1)
                            .arg(static_cast<int>(options.minSegmentLengthSec)));
                    continue;
                }
                finalMatches.append(match);
            }

            {
                QMutexLocker locker(&resultMutex);
                results.insert(epName, finalMatches);
            }

            const int done = ++completed;
            const int percent = 75 + static_cast<int>(
                (static_cast<double>(done) / static_cast<double>(videoFiles.size())) * 20.0);
            progress(QStringLiteral("Located segments for %1 (%2/%3)...")
                         .arg(epName).arg(done).arg(videoFiles.size()),
                     percent);
        };

        QtConcurrent::blockingMap(&localizationPool, videoFiles, localizeOne);
    }

    throwIfCancelled(cancelFlag);

    int totalMatches = 0;
    for (const QVector<RcdMatch> &matches : std::as_const(results)) {
        totalMatches += static_cast<int>(matches.size());
    }

    log(QStringLiteral("Scan complete — located %1 segment(s) across %2 file(s)!")
            .arg(totalMatches).arg(videoFiles.size()));
    progress(QStringLiteral("RCD Fingerprinting Complete!"), 100);

    return results;
}

} // namespace segmenter
