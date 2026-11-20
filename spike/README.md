# Spike: can the model be trained inside the app?

This folder is an experiment, not part of the product. It answers one question before the
onboarding is designed around it: can the eye model be trained on the Mac, in Swift, with
Apple's own frameworks and only the Command Line Tools, and is the result as good as the
Python route?

Every engine runs the same jobs: train on these pictures, answer on those. The jobs are
made once by `harness.py`, and the answers are scored by the project's own code
(`training/evaluate.py`), so the engines are compared on the same data and the same split.

| File | What it is |
|---|---|
| `harness.py` | Makes the jobs, runs them with the Python route, scores any engine's answers |
| `Sources/EyeTrainSpike/GraphTrainer.swift` | EyeNet trained with MPSGraph (the framework PyTorch's "mps" device is built on) |
| `Sources/EyeTrainSpike/Augment.swift` | The alterations of `training/learning.py`, on the processor |
| `Sources/EyeTrainSpike/CoreMLUpdate.swift` | Core ML's own on-device training (`MLUpdateTask`) |
| `coreml_update_template.py` | The untrained, updatable Core ML model that task needs |
| `Sources/EyeTrainSpike/CreateMLRun.swift` | Create ML's image classifier |
| `probes/run_model.swift` | Two ways for the app to run a model trained this way, compared and timed |
| `probes/shell_model.py` | A Core ML model with no weights inside: they are inputs |
| `probes/weights_override.swift` | Can Core ML's public API replace a layer's weights? (No.) |
| `probes/brightness.py` | How bright the recorded eye pictures are |

## Running it again

It needs recordings (`data/`), which are private and not in the repository. In a git
worktree they are read from the main checkout, never copied.

```bash
cd training && uv run python ../spike/harness.py export ../spike/out/jobs.json
```

```bash
cd training && uv run python ../spike/harness.py python ../spike/out/results-python.json
```

```bash
cd spike && swift build -c release && .build/release/EyeTrainSpike out/jobs.json out/results-mps.json
```

```bash
cd training && uv run python ../spike/harness.py score ../spike/out/results-mps.json
```

`--engine=coreml --template=out/updatable/EyeNetUpdatable.mlmodelc` and `--engine=createml`
run the other two candidates. `SPIKE_SEEDS=10,11,12 SPIKE_ONLY=eval/` narrows a run to the
blink-counting question with other seeds.

Everything the runs write goes to `spike/out`, which is not committed: it holds the paths
of the pictures and the answers given on them.
