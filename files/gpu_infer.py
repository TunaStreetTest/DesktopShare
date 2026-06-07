import onnxruntime as ort
import numpy as np
import json
import time

def on_trigger(context, session):
    # Load model once
    if not hasattr(context, "session"):
        context.session = ort.InferenceSession(
            "/opt/minifi/model.onnx",
            providers=["CUDAExecutionProvider"]
        )

    # Fake input to stress GPU
    x = np.random.rand(1, 3, 224, 224).astype(np.float32)

    start = time.time()
    outputs = context.session.run(None, {"input": x})
    end = time.time()

    result = {
        "inference_ms": (end - start) * 1000
    }

    flowfile = session.create()
    flowfile = session.write(flowfile, lambda out: out.write(json.dumps(result).encode()))
    session.transfer(flowfile, "success")
