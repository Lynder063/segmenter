#include "services/Fft.h"

#include <cmath>
#include <stdexcept>

namespace segmenter {
namespace {

constexpr float kPi = 3.14159265358979323846f;

std::size_t log2Exact(std::size_t value)
{
    std::size_t result = 0;
    while ((std::size_t{1} << result) < value) {
        ++result;
    }
    return result;
}

} // namespace

FftSetup::FftSetup(std::size_t size)
    : m_size(size)
    , m_log2Size(log2Exact(size))
{
    if (size < 2 || (size & (size - 1)) != 0) {
        throw std::invalid_argument("FftSetup size must be a power of two >= 2");
    }

    // Bit-reversal permutation: index i moves to the value of its low
    // log2(size) bits read backwards.
    m_bitReversal.resize(size);
    for (std::size_t i = 0; i < size; ++i) {
        std::size_t reversed = 0;
        for (std::size_t bit = 0; bit < m_log2Size; ++bit) {
            if (i & (std::size_t{1} << bit)) {
                reversed |= std::size_t{1} << (m_log2Size - 1 - bit);
            }
        }
        m_bitReversal[i] = reversed;
    }

    // Twiddle factors for every butterfly stage, laid out contiguously so the
    // transform reads them in order.
    m_cosTable.resize(size / 2);
    m_sinTable.resize(size / 2);
    for (std::size_t i = 0; i < size / 2; ++i) {
        const float angle = -2.0f * kPi * static_cast<float>(i) / static_cast<float>(size);
        m_cosTable[i] = std::cos(angle);
        m_sinTable[i] = std::sin(angle);
    }
}

void FftSetup::transform(std::vector<float> &real, std::vector<float> &imag) const
{
    // Reorder into bit-reversed index order so the butterflies below can run
    // in place.
    for (std::size_t i = 0; i < m_size; ++i) {
        const std::size_t j = m_bitReversal[i];
        if (j > i) {
            std::swap(real[i], real[j]);
            std::swap(imag[i], imag[j]);
        }
    }

    // Cooley-Tukey: log2(N) stages, each combining pairs twice as far apart as
    // the last.
    for (std::size_t len = 2; len <= m_size; len <<= 1) {
        const std::size_t half = len / 2;
        const std::size_t tableStep = m_size / len;

        for (std::size_t base = 0; base < m_size; base += len) {
            std::size_t tableIndex = 0;
            for (std::size_t k = 0; k < half; ++k) {
                const float wr = m_cosTable[tableIndex];
                const float wi = m_sinTable[tableIndex];
                tableIndex += tableStep;

                const std::size_t lo = base + k;
                const std::size_t hi = lo + half;

                const float tr = real[hi] * wr - imag[hi] * wi;
                const float ti = real[hi] * wi + imag[hi] * wr;

                real[hi] = real[lo] - tr;
                imag[hi] = imag[lo] - ti;
                real[lo] += tr;
                imag[lo] += ti;
            }
        }
    }
}

void FftSetup::magnitudeSpectrum(const std::vector<float> &input,
                                 std::vector<float> &magnitudes) const
{
    const std::size_t half = m_size / 2;
    if (magnitudes.size() != half) {
        magnitudes.assign(half, 0.0f);
    }

    if (input.size() < m_size) {
        std::fill(magnitudes.begin(), magnitudes.end(), 0.0f);
        return;
    }

    // A real-input transform run through the complex path. The redundant upper
    // half is simply not read back, which costs about 2x against a packed
    // real FFT but keeps the transform obviously correct — and at N=2048 the
    // whole extraction is dominated by FFmpeg decode, not by this.
    std::vector<float> real(input.begin(), input.begin() + static_cast<std::ptrdiff_t>(m_size));
    std::vector<float> imag(m_size, 0.0f);

    transform(real, imag);

    for (std::size_t k = 0; k < half; ++k) {
        magnitudes[k] = real[k] * real[k] + imag[k] * imag[k];
    }
}

std::vector<float> hannWindow(std::size_t size)
{
    std::vector<float> window(size, 0.0f);
    if (size == 0) {
        return window;
    }
    for (std::size_t i = 0; i < size; ++i) {
        window[i] = 0.5f * (1.0f - std::cos(2.0f * kPi * static_cast<float>(i)
                                            / static_cast<float>(size)));
    }
    return window;
}

float vectorNorm(const float *data, std::size_t count)
{
    float sumSq = 0.0f;
    for (std::size_t i = 0; i < count; ++i) {
        sumSq += data[i] * data[i];
    }
    return std::sqrt(sumSq);
}

float vectorNorm(const std::vector<float> &data)
{
    return vectorNorm(data.data(), data.size());
}

float dotProduct(const float *a, const float *b, std::size_t count)
{
    float sum = 0.0f;
    for (std::size_t i = 0; i < count; ++i) {
        sum += a[i] * b[i];
    }
    return sum;
}

} // namespace segmenter
