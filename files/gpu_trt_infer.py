import tensorrt as trt
import pycuda.driver as cuda
import pycuda.autoinit
import numpy as np
import json
import time

TRT_LOGGER = trt.Logger(trt.Logger.WARNING)

ENGINE_PATH = "/home/tunastreet/nifi-minifi-cpp-1.26.02/asset/model.engine"

def load_engine(path):
    with open(path, "rb") as f:
        runtime = trt.Runtime(TRT_LOGGER)
        return runtime.deserialize_cuda_engine(f.read())

def allocate_buffers(engine):
    h_inputs = []
    h_outputs = []
    d_inputs = []
    d_outputs = []
    bindings = []

    for binding in engine:
        size = trt.volume(engine.get_binding_shape(binding))
        dtype = trt.nptype(engine.get_binding_dtype(binding))

        host_mem = np.empty(size, dtype=dtype)
        device_mem = cuda.mem_alloc(host_mem.nbytes)

        bindings.append(int(device_mem))

        if engine.binding_is_input(binding):
            h_inputs.append(host_mem)
            d_inputs.append(device_mem)
        else:
            h_outputs.append(host_mem)
            d_outputs.append(device_mem)

    return h_inputs, d_inputs, h_outputs, d_outputs, bindings

def on_trigger(context, session):
    # Load engine + allocate buffers once
    if not hasattr(context, "engine"):
        context.engine = load_engine(ENGINE_PATH)
        context.context = context.engine.create_execution_context()
        (
            context.h_inputs,
            context.d_inputs,
            context.h_outputs,
            context.d_outputs,
            context.bindings
        ) = allocate_buffers(context.engine)

    # Fill input with dummy data to stress GPU
    context.h_inputs[0].fill(1.0)

    # Copy input to device
    cuda.memcpy_htod(context.d_inputs[0], context.h_inputs[0])

    start = time.time()
    context.context.execute_v2(context.bindings)
    end = time.time()

    # Copy output back
    cuda.memcpy_dtoh(context.h_outputs[0], context.d_outputs[0])

    result = {
        "inference_ms": (end - start) * 1000,
        "output_sample": float(context.h_outputs[0][0])
    }

    flowfile = session.create()
    flowfile = session.write(flowfile, lambda out: out.write(json.dumps(result).encode()))
    session.transfer(flowfile, "success")
