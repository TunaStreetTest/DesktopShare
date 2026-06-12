**TensorRT** is NVIDIA's high-performance **SDK** for optimizing and running deep learning **inference** on **GPUs**. It takes trained models (from PyTorch, TensorFlow, ONNX, etc.) and turns them into highly optimized runtime engines that maximize the GPU's capabilities for fast, efficient predictions.

### Core Capabilities with a GPU

TensorRT leverages the GPU's massive parallelism (CUDA cores, Tensor Cores, etc.) to deliver these benefits:

- **Dramatic Speedups** — Often 5–36x faster inference than CPU-only or unoptimized GPU runs. It achieves low latency and high throughput for real-time applications.
- **Model Optimization** — Fuses layers (combines operations into fewer kernels), eliminates unused parts, and selects the best GPU kernels for each operation.
- **Mixed / Lower Precision** — Supports FP32, FP16, BF16, FP8, and INT8 quantization with calibration to maintain accuracy while boosting speed and reducing memory use (critical for large models on consumer or edge GPUs).
- **Dynamic Shapes & Memory Management** — Handles variable input sizes efficiently and uses dynamic tensor memory allocation to minimize GPU VRAM usage.
- **Hardware-Specific Tuning** — Optimizes for specific NVIDIA GPUs: datacenter (H100, A100, Blackwell), RTX consumer GPUs (GeForce/RTX series), Jetson edge devices, etc.

### Key Use Cases on GPUs

| Area                  | What TensorRT Enables on GPU                          | Typical Benefits |
|-----------------------|-------------------------------------------------------|------------------|
| **Computer Vision** (YOLO, ResNet, etc.) | Real-time object detection, segmentation, classification | High FPS, low latency |
| **Large Language Models (LLMs)** | Via **TensorRT-LLM**: optimized transformers, in-flight batching, paged attention, multi-GPU | Faster token generation, higher throughput |
| **Generative AI** (Stable Diffusion, etc.) | Optimized diffusion pipelines on RTX GPUs | 2x+ speed vs. other backends |
| **Recommendation Systems** | High-throughput inference at scale | Better serving capacity |
| **Edge / Embedded** (Jetson, DRIVE) | Efficient deployment on lower-power GPUs | Real-time autonomous driving, robotics |
| **Consumer PCs** (TensorRT for RTX) | Accelerated AI apps on GeForce/RTX GPUs | Up to 2x faster than DirectML |

### How It Works (High-Level)

1. **Import** → Bring in a trained model (ONNX is most common).
2. **Build Engine** → TensorRT's builder optimizes the graph for your specific GPU (layer fusion, kernel selection, quantization).
3. **Run Inference** → Load the serialized engine and execute on the GPU runtime.

The resulting engine is hardware-specific and very fast, but usually not portable across different GPU architectures without rebuilding.

### Summary

With a compatible NVIDIA GPU, **TensorRT** lets you:
- Squeeze maximum performance out of the hardware for inference.
- Run bigger models or serve more users on the same GPU by reducing latency/memory.
- Deploy production-grade AI (datacenter, cloud, edge, desktop) with minimal code changes.

It's the go-to tool when you need the absolute fastest inference on NVIDIA GPUs. For official details, check the [NVIDIA TensorRT page](https://developer.nvidia.com/tensorrt).