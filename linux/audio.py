import os
import subprocess
import numpy as np
from PySide6.QtCore import QThread, Signal
from models import TimelineDensityTrack

class AudioExtractorWorker(QThread):
    # Signals to communicate with the main UI thread
    progress = Signal(int)  # Percentage 0-100
    waveform_ready = Signal(list)  # Waveform buckets list of floats
    music_ready = Signal(list)  # Music likelihood buckets list of floats
    finished = Signal(bool, str)  # (success, message)

    def __init__(self, video_path: str, duration_ms: int):
        super().__init__()
        self.video_path = video_path
        self.duration_ms = duration_ms
        self._is_cancelled = False

    def cancel(self):
        self._is_cancelled = True

    def run(self):
        if self.duration_ms <= 0:
            self.finished.emit(False, "Invalid video duration")
            return

        duration_sec = self.duration_ms / 1000.0
        sample_rate = 8000
        bytes_per_sample = 2  # s16le (16-bit)
        
        # Calculate timeline bucket count using Swift formula
        # bucketCount = max(120, min(2400, durationMs / 250))
        bucket_count = max(120, min(2400, self.duration_ms // 250))

        # Command to extract raw mono 16-bit PCM at 8000Hz
        cmd = [
            "ffmpeg",
            "-y",
            "-threads", "2",
            "-i", self.video_path,
            "-f", "s16le",
            "-ac", "1",
            "-ar", str(sample_rate),
            "-"
        ]

        try:
            # Start ffmpeg subprocess
            startupinfo = None
            if os.name == 'nt':
                # Prevent console window on Windows if run from gui
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW

            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                startupinfo=startupinfo
            )

            # Pre-allocate buffer for speed
            expected_samples = int(duration_sec * sample_rate)
            audio_data = np.zeros(expected_samples, dtype=np.int16)
            
            # Read in chunks of 1 second
            chunk_size = sample_rate * bytes_per_sample
            loaded_samples = 0

            while not self._is_cancelled:
                raw_chunk = process.stdout.read(chunk_size)
                if not raw_chunk:
                    break
                
                # Convert bytes to numpy int16 array
                samples = np.frombuffer(raw_chunk, dtype=np.int16)
                num_samples = len(samples)
                
                if loaded_samples + num_samples > len(audio_data):
                    # Resize array if ffmpeg returned more samples than expected
                    audio_data = np.resize(audio_data, loaded_samples + num_samples)
                
                audio_data[loaded_samples:loaded_samples + num_samples] = samples
                loaded_samples += num_samples
                
                # Emit progress
                if expected_samples > 0:
                    pct = int(min(loaded_samples / expected_samples * 50.0, 50.0))
                    self.progress.emit(pct)

            process.stdout.close()
            process.terminate()
            process.wait()

            if self._is_cancelled:
                self.finished.emit(False, "Cancelled")
                return

            if loaded_samples == 0:
                self.finished.emit(False, "No audio track found or ffmpeg failed to read audio")
                return

            # Trim trailing zeros if we loaded fewer samples
            audio_data = audio_data[:loaded_samples]

            # 1. Waveform buckets calculation (vectorized peak search)
            samples_per_bucket = max(1, len(audio_data) // bucket_count)
            n_total = bucket_count * samples_per_bucket
            if n_total <= len(audio_data):
                reshaped = audio_data[:n_total].reshape((bucket_count, samples_per_bucket))
                peaks = np.max(np.abs(reshaped), axis=1)
                waveform_buckets = peaks.astype(float).tolist()
            else:
                waveform_buckets = []
                for i in range(bucket_count):
                    chunk = audio_data[i * samples_per_bucket : (i + 1) * samples_per_bucket]
                    waveform_buckets.append(float(np.max(np.abs(chunk)) if len(chunk) > 0 else 0.0))

            # Normalize waveform buckets to 0.0 - 1.0 range
            max_val = max(waveform_buckets) if waveform_buckets else 0.0
            if max_val > 0:
                waveform_buckets = [val / max_val for val in waveform_buckets]
            
            self.waveform_ready.emit(waveform_buckets)
            self.progress.emit(70)

            # 2. Music likelihood buckets — fully vectorized spectral flatness
            fft_size = 8192
            hanning_win = np.hanning(fft_size)
            freqs = np.fft.rfftfreq(fft_size, 1.0 / sample_rate)
            band_mask = (freqs >= 80) & (freqs <= 3000)
            
            # Pre-compute center samples for all buckets
            bucket_times = np.arange(bucket_count) / bucket_count * duration_sec
            center_samples = (bucket_times * sample_rate).astype(int)
            
            # Build 2D array of all windows at once
            half_fft = fft_size // 2
            windows = np.zeros((bucket_count, fft_size), dtype=np.float64)
            valid_mask = np.ones(bucket_count, dtype=bool)
            
            for i in range(bucket_count):
                cs = center_samples[i]
                start_idx = max(0, cs - half_fft)
                end_idx = min(len(audio_data), cs + half_fft)
                chunk = audio_data[start_idx:end_idx]
                if len(chunk) < 512:
                    valid_mask[i] = False
                    continue
                if len(chunk) < fft_size:
                    windows[i, :len(chunk)] = chunk
                else:
                    windows[i] = chunk[:fft_size]
            
            self.progress.emit(75)
            
            # Apply windowing to all valid rows
            windows[valid_mask] *= hanning_win
            
            # Batch FFT — use scipy if available for speed
            try:
                from scipy.fft import rfft as fast_rfft
                fft_result = np.abs(fast_rfft(windows[valid_mask], axis=1))
            except ImportError:
                fft_result = np.abs(np.fft.rfft(windows[valid_mask], axis=1))
            
            power_spec = fft_result ** 2
            band_power = power_spec[:, band_mask]
            
            # Vectorized spectral flatness
            eps = 1e-10
            log_ps = np.log(band_power + eps)
            geo_means = np.exp(np.mean(log_ps, axis=1))
            ari_means = np.mean(band_power, axis=1)
            flatness = geo_means / (ari_means + eps)
            music_scores = 1.0 - flatness
            
            # Energy factor for each valid window
            energy_factors = np.minimum(1.0, np.mean(np.abs(windows[valid_mask]), axis=1) / 200.0)
            scores = np.clip(music_scores * energy_factors, 0, 1)
            
            # Assemble results
            music_buckets = np.zeros(bucket_count)
            music_buckets[valid_mask] = scores
            music_buckets = music_buckets.tolist()
            
            self.progress.emit(90)

            # Smooth music buckets (equivalent to smoothBuckets radius 2)
            smoothed_music = self._smooth_buckets(music_buckets, radius=2)
            self.music_ready.emit(smoothed_music)
            self.progress.emit(100)
            
            self.finished.emit(True, "Success")
        except Exception as e:
            self.finished.emit(False, f"Audio analysis error: {str(e)}")

    def _smooth_buckets(self, input_list: list[float], radius: int) -> list[float]:
        if not input_list or radius <= 0:
            return input_list

        arr = np.clip(np.array(input_list, dtype=float), 0.0, 1.0)
        n = len(arr)
        
        # Triangular kernel: distance-weighted average
        kernel = np.array([radius + 1 - abs(i) for i in range(-radius, radius + 1)], dtype=float)
        
        # Convolve using NumPy fast 1D convolution (replaces nested loops)
        convolved_vals = np.convolve(arr, kernel, mode='same')
        convolved_weights = np.convolve(np.ones(n), kernel, mode='same')
        
        smoothed = convolved_vals / convolved_weights
        return smoothed.tolist()
