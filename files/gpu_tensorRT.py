import tensorrt as trt
import numpy as np

logger = trt.Logger(trt.Logger.INFO)

print("TensorRT version:" trt.__version__)
print("Logger created:" logger)