"""
Unified GPU detection layer for Segmenter.

Supports:
- NVIDIA CUDA (via PyTorch CUDA)
- AMD ROCm (via PyTorch ROCm — exposes as torch.cuda with HIP backend)
- CPU fallback

Usage:
    from gpu import get_device, GPU_AVAILABLE, GPU_NAME, GPU_BACKEND
"""

import logging

logger = logging.getLogger(__name__)

# Detect GPU availability and backend type
GPU_AVAILABLE = False
GPU_NAME = ""
GPU_BACKEND = "CPU"

try:
    import torch

    if torch.cuda.is_available():
        GPU_AVAILABLE = True
        GPU_NAME = torch.cuda.get_device_name(0)

        # Distinguish NVIDIA CUDA from AMD ROCm
        # PyTorch ROCm builds set torch.version.hip to a version string
        if hasattr(torch.version, "hip") and torch.version.hip is not None:
            GPU_BACKEND = "AMD ROCm"
        else:
            GPU_BACKEND = "NVIDIA CUDA"

        logger.info("GPU detected: %s (%s)", GPU_NAME, GPU_BACKEND)
    else:
        logger.info("No GPU detected, using CPU")

except ImportError:
    logger.info("PyTorch not installed, GPU acceleration unavailable")


def get_device():
    """Return the best available torch device."""
    try:
        import torch
        if GPU_AVAILABLE:
            return torch.device("cuda")
        return torch.device("cpu")
    except ImportError:
        return "cpu"


def is_nvidia() -> bool:
    """Return True if the GPU backend is NVIDIA CUDA."""
    return GPU_BACKEND == "NVIDIA CUDA"


def is_amd() -> bool:
    """Return True if the GPU backend is AMD ROCm."""
    return GPU_BACKEND == "AMD ROCm"
