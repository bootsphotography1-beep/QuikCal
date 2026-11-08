# Upstream source provenance

- Upstream: https://github.com/handy-computer/transcribe.cpp
- Included revision: `4d7c1ccefd39e5a9ea36cca5f8fefc6dcc14b99b`
- Purpose in QuikCal: source needed to rebuild the local speech helper.
- Included paths are the CMake build files, headers, `src/`, the required core/CPU/Metal/BLAS `ggml/` sources, the CLI example sources, and the upstream MIT license. Upstream repository metadata, build products, model catalogs/weights, research reports, conversion tools, Python bindings, upstream agent instructions, release/sync scripts, and disabled tests/examples are not included. Non-Apple optional ggml backends (including SYCL, CUDA, Vulkan, and accelerator-specific backends) are omitted; the upstream CMake files are unchanged and the QuikCal macOS helper build does not enable those backends.

The upstream speech engine is a general ASR runtime. Its included source has optional ASR architecture implementations beyond Parakeet, including Qwen3-ASR and Canary-Qwen. QuikCal does not expose those models or use them for event generation; the app's speech-model UI and pinned manifest select Parakeet only. This is upstream dependency source, not a QuikCal text-model route.
