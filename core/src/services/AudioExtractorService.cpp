#include "services/AudioExtractorService.h"

#include <QFileInfo>

#include <algorithm>
#include <cmath>

#include "services/FFmpegService.h"
#include "services/Fft.h"
#include "services/LoggerService.h"

namespace segmenter {
namespace {

// The waveform and music passes run at 8 kHz. The chroma extractor uses 4 kHz;
// this needs the wider band because the flatness measure is taken over
// 80-3000 Hz, which would sit right at Nyquist at 4 kHz.
constexpr int kSampleRate = 8000;

// 8192 samples ≈ 1.0 s at 8 kHz — long enough to average over a musical phrase
// rather than a single transient.
constexpr std::size_t kFftSize = 8192;

constexpr double kBandLowHz = 80.0;
constexpr double kBandHighHz = 3000.0;
constexpr float kEpsilon = 1e-10f;

} // namespace

AudioExtractorService &AudioExtractorService::instance()
{
    static AudioExtractorService service;
    return service;
}

int AudioExtractorService::bucketCountFor(int durationMs)
{
    return std::max(200, std::min(2400, durationMs / 250));
}

QVector<float> AudioExtractorService::smoothBuckets(const QVector<float> &input, int radius)
{
    if (input.isEmpty() || radius <= 0) {
        return input;
    }

    QVector<float> output(input.size());
    for (qsizetype i = 0; i < input.size(); ++i) {
        float sum = 0.0f;
        int count = 0;
        for (int offset = -radius; offset <= radius; ++offset) {
            const qsizetype index = i + offset;
            if (index >= 0 && index < input.size()) {
                sum += input[index];
                ++count;
            }
        }
        output[i] = count > 0 ? sum / static_cast<float>(count) : input[i];
    }
    return output;
}

AudioExtractorService::Result
AudioExtractorService::analyze(const QString &videoPath,
                               int durationMs,
                               const ProgressHandler &progressHandler) const
{
    const auto report = [&progressHandler](int percent) {
        if (progressHandler) {
            progressHandler(percent);
        }
    };

    Result result;

    int effectiveDurationMs = durationMs;
    if (effectiveDurationMs <= 0) {
        if (const auto info = FFmpegService::instance().inspectMedia(videoPath)) {
            effectiveDurationMs = info->durationMs;
        }
    }
    if (effectiveDurationMs <= 0) {
        LoggerService::instance().error(
            QStringLiteral("[AudioExtractor] could not determine duration of %1")
                .arg(QFileInfo(videoPath).fileName()));
        return result;
    }

    const int bucketCount = bucketCountFor(effectiveDurationMs);
    const double durationSec = std::max(static_cast<double>(effectiveDurationMs) / 1000.0, 1.0);

    report(10);

    // One pass over the whole file. `durationSec + 1` guards against ffprobe
    // rounding a hair short and clipping the final bucket.
    const QVector<qint16> samples = FFmpegService::instance().extractPcmAudioSnippet(
        videoPath, 0, static_cast<int>(durationSec) + 1, kSampleRate);

    if (samples.isEmpty()) {
        LoggerService::instance().error(
            QStringLiteral("[AudioExtractor] no audio decoded from %1")
                .arg(QFileInfo(videoPath).fileName()));
        return result;
    }

    report(60);

    // --- 1. Waveform: peak amplitude per bucket -----------------------------
    QVector<float> waveformBuckets(bucketCount, 0.0f);
    const qsizetype samplesPerBucket = std::max<qsizetype>(1, samples.size() / bucketCount);

    for (int i = 0; i < bucketCount; ++i) {
        const qsizetype start = static_cast<qsizetype>(i) * samplesPerBucket;
        const qsizetype end = std::min(start + samplesPerBucket, samples.size());

        qint32 peak = 0;
        for (qsizetype s = start; s < end; ++s) {
            peak = std::max(peak, static_cast<qint32>(std::abs(samples[s])));
        }
        waveformBuckets[i] = static_cast<float>(peak);
    }

    const float maxPeak = *std::max_element(waveformBuckets.constBegin(), waveformBuckets.constEnd());
    if (maxPeak > 0.0f) {
        for (float &value : waveformBuckets) {
            value /= maxPeak;
        }
    }
    result.waveformBuckets = waveformBuckets;

    report(70);

    // --- 2. Music likelihood: spectral flatness -----------------------------
    const FftSetup fft(kFftSize);
    const std::vector<float> window = hannWindow(kFftSize);

    // Bin indices covering the analysis band. Bin k sits at
    // k * sampleRate / fftSize Hz.
    const double hzPerBin = static_cast<double>(kSampleRate) / static_cast<double>(kFftSize);
    const std::size_t halfSize = kFftSize / 2;
    const std::size_t bandLowBin =
        std::min(halfSize - 1, static_cast<std::size_t>(std::ceil(kBandLowHz / hzPerBin)));
    const std::size_t bandHighBin =
        std::min(halfSize - 1, static_cast<std::size_t>(std::floor(kBandHighHz / hzPerBin)));

    QVector<float> musicBuckets(bucketCount, 0.0f);
    std::vector<float> frame(kFftSize, 0.0f);
    std::vector<float> magnitudes(halfSize, 0.0f);

    const std::size_t halfFft = kFftSize / 2;

    for (int i = 0; i < bucketCount; ++i) {
        // Centre the analysis window on the bucket rather than starting at it,
        // so a bucket's score reflects the audio around that moment.
        const double bucketTimeSec =
            (static_cast<double>(i) / static_cast<double>(bucketCount)) * durationSec;
        const qsizetype centerSample = static_cast<qsizetype>(bucketTimeSec * kSampleRate);
        const qsizetype startIndex = std::max<qsizetype>(0, centerSample - static_cast<qsizetype>(halfFft));
        const qsizetype available = std::min<qsizetype>(
            static_cast<qsizetype>(kFftSize), samples.size() - startIndex);

        // Too little audio left to say anything; leave the bucket at zero.
        if (available < 512) {
            continue;
        }

        std::fill(frame.begin(), frame.end(), 0.0f);
        double absSum = 0.0;
        for (qsizetype s = 0; s < available; ++s) {
            const float value = static_cast<float>(samples[startIndex + s]);
            frame[static_cast<std::size_t>(s)] = value * window[static_cast<std::size_t>(s)];
            absSum += std::abs(value);
        }

        fft.magnitudeSpectrum(frame, magnitudes);

        // Spectral flatness = geometric mean / arithmetic mean of band power.
        // Computed as exp(mean(log(p))) to keep the geometric mean from
        // underflowing over ~2900 bins.
        double logSum = 0.0;
        double linearSum = 0.0;
        std::size_t binCount = 0;
        for (std::size_t bin = bandLowBin; bin <= bandHighBin; ++bin) {
            const double power = static_cast<double>(magnitudes[bin]) + kEpsilon;
            logSum += std::log(power);
            linearSum += power;
            ++binCount;
        }

        if (binCount == 0) {
            continue;
        }

        const double geometricMean = std::exp(logSum / static_cast<double>(binCount));
        const double arithmeticMean = linearSum / static_cast<double>(binCount);
        const double flatness = geometricMean / (arithmeticMean + kEpsilon);
        const double musicScore = 1.0 - flatness;

        // Silence is spectrally peaky too, and would otherwise score as music.
        // Weighting by mean amplitude pushes quiet passages back down.
        const double meanAmplitude = absSum / static_cast<double>(available);
        const double energyFactor = std::min(1.0, meanAmplitude / 200.0);

        musicBuckets[i] = static_cast<float>(
            std::clamp(musicScore * energyFactor, 0.0, 1.0));

        if ((i % 128) == 0) {
            report(70 + (i * 25) / std::max(1, bucketCount));
        }
    }

    report(95);
    result.musicLikelihoodBuckets = smoothBuckets(musicBuckets, 2);
    report(100);

    LoggerService::instance().info(
        QStringLiteral("[AudioExtractor] %1: %2 buckets over %3s")
            .arg(QFileInfo(videoPath).fileName())
            .arg(bucketCount)
            .arg(durationSec, 0, 'f', 0));

    return result;
}

} // namespace segmenter
