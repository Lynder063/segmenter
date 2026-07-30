#pragma once

#include <cstddef>
#include <vector>

namespace segmenter {

/// In-place radix-2 real FFT, standing in for Accelerate's `vDSP_fft_zrip` on
/// the macOS port. The chroma extractor is the only caller and always asks for
/// N = 2048, but nothing here assumes that beyond requiring a power of two.
///
/// A setup object is reused across frames because the twiddle-factor and
/// bit-reversal tables depend only on N: rebuilding them per frame costs more
/// than the transform itself over the ~4700 frames of a 10-minute region.
class FftSetup {
public:
    /// @param size Transform length. Must be a power of two and at least 2.
    explicit FftSetup(std::size_t size);

    std::size_t size() const { return m_size; }

    /// Computes the magnitude spectrum of a real input signal.
    ///
    /// @param input      `size()` real samples.
    /// @param magnitudes Filled with `size()/2` squared magnitudes, matching
    ///                   what `vDSP_zvmags` produces on macOS. Resized if needed.
    ///
    /// Squared rather than absolute magnitude is deliberate: chroma bins are L2
    /// normalised immediately afterwards, so the extra sqrt per bin would be
    /// divided straight back out.
    void magnitudeSpectrum(const std::vector<float> &input,
                           std::vector<float> &magnitudes) const;

private:
    std::size_t m_size;
    std::size_t m_log2Size;
    std::vector<std::size_t> m_bitReversal;
    std::vector<float> m_cosTable;
    std::vector<float> m_sinTable;

    // Scratch buffers are provided by the caller through magnitudeSpectrum so a
    // single setup stays safe to share between threads.
    void transform(std::vector<float> &real, std::vector<float> &imag) const;
};

/// Periodic Hann window, matching `vDSP_hann_window(..., vDSP_HANN_NORM)`.
std::vector<float> hannWindow(std::size_t size);

/// Euclidean (L2) norm — the `vectorNorm` helper from RCDEngineService.swift.
float vectorNorm(const float *data, std::size_t count);
float vectorNorm(const std::vector<float> &data);

/// Dot product, standing in for `vDSP_dotpr`.
float dotProduct(const float *a, const float *b, std::size_t count);

} // namespace segmenter
