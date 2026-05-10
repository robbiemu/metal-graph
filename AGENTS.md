# AGENTS.md

Guidance for coding agents and contributors working on the Metal Graph execution library.

This project is building a reusable explicit graph execution API over Apple Metal. The public model is:

```text
Graph -> GraphExec -> Launch
```

The core library should feel like a low-level runtime: explicit graph nodes, explicit dependencies, explicit resource ownership, structured errors, repeated launch, and stable patch/update semantics. Do not turn it into a general ML framework, a CUDA compatibility layer, or an MLX wrapper.

## 1. Source basis and design lessons

Major Metal-related projects point to the same engineering shape:

- [Apple Metal sample code](https://developer.apple.com/documentation/metal/metal-sample-code-library) keeps concepts separated by workflow: compute, resources, synchronization, argument buffers, heaps, fences, indirect command buffers, profiling, and platform feature variants.
- [metal-cpp](https://developer.apple.com/metal/cpp/) exists for C++ callers but is explicitly a direct mapping of Metal Objective-C APIs, with no wrapper allocation overhead. It also requires careful ownership because C++ is not ARC-managed.
- [MLX](https://mlx-framework.org/) supports Python, C++, C, and Swift surfaces over an Apple Silicon-focused compute core. Its language split is a good model, but MLX remains a high-level array framework, not this project’s runtime substrate.
- [MetalPetal](https://github.com/MetalPetal/MetalPetal) is a strong example of an Objective-C/Objective-C++ Metal core with Swift-facing ergonomics. It documents context reuse, cache/state ownership, concurrency considerations, and Swift-specific API overlays.
- [ggml/llama.cpp](https://github.com/ggml-org/llama.cpp) treats Metal as one backend behind a portable C/C++ runtime and keeps platform code isolated under backend-specific directories. That is the right model for future Python and Rust bindings.
- [PyTorch MPS](https://developer.apple.com/metal/pytorch/) demonstrates that Python-facing Metal acceleration should hide backend complexity while still allowing custom Metal kernels when needed.
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) is a useful reminder to use public Metal APIs only, expose feature gates clearly, and maintain buildable package targets for Apple platforms.

Project guidance below converts those lessons into rules for this repository.

## 2. Non-negotiable architecture

This project MUST keep these layers separate:

```text
public C ABI
    -> pure graph model / validation / planning
        -> Metal backend bridge in Objective-C++
            -> Metal shaders and optional MPSGraph integration
                -> Swift / Python / future Rust bindings
```

The C ABI is the stable center of the project. Objective-C, Swift, Python, and future Rust bindings must wrap the C ABI or a deliberately exported internal C shim. They must not reach into backend internals directly.

Raw Metal is the required backend. `MPSGraphExecutable` may appear as an optional tensor-subgraph backend. MLX may appear later as a high-level adapter. `MTLIndirectCommandBuffer` may be used internally as an optimization, but it is not the public graph abstraction.

A `GraphExec` is not a reusable `MTLCommandBuffer`. A launch creates fresh command buffers, encodes work, commits them, and tracks completion. The reusable asset is the validated and planned execution object.

## 3. Recommended repository structure

Use this structure unless there is a concrete reason to diverge:

```text
.
├── AGENTS.md
├── CMakeLists.txt
├── Package.swift                  # Swift package wrapper, once Swift starts
├── pyproject.toml                 # Python package, once Python starts
├── include/
│   └── metal_graph/
│       ├── mg.h                   # umbrella public C API
│       ├── mg_types.h             # opaque types, enums, constants
│       ├── mg_graph.h             # graph construction API
│       ├── mg_exec.h              # instantiate/launch/patch API
│       ├── mg_buffer.h            # buffer and arena API
│       ├── mg_event.h             # event API
│       └── mg_error.h             # structured errors
├── src/
│   ├── core/
│   │   ├── graph.*                # graph storage, node/edge model
│   │   ├── validate.*             # topology/resource validation
│   │   ├── planner.*              # topological sort, passes, liveness
│   │   ├── patch.*                # patch table and update validation
│   │   ├── arena.*                # memory planning, alignment, aliasing
│   │   └── error.*                # error construction and propagation
│   ├── metal/
│   │   ├── mg_metal_device.mm     # device, queue, feature discovery
│   │   ├── mg_metal_exec.mm       # launch encoding and completion tracking
│   │   ├── mg_metal_buffer.mm     # MTLBuffer, heap, residency handling
│   │   ├── mg_metal_event.mm      # MTLSharedEvent / fallback behavior
│   │   ├── mg_metal_fence.mm      # fence/barrier handling
│   │   ├── mg_metal_mpsgraph.mm   # optional MPSGraph node support
│   │   └── mg_metal_internal.h    # private Obj-C++ bridge types
│   └── shaders/
│       ├── kernels.metal
│       └── debug_kernels.metal
├── bindings/
│   ├── swift/
│   │   └── Sources/MetalGraph/
│   ├── python/
│   │   ├── src/metal_graph/
│   │   └── tests/
│   └── rust/                      # future only
│       ├── metal-graph-sys/
│       └── metal-graph/
├── tests/
│   ├── unit/                      # CPU-only core tests
│   ├── gpu/                       # requires real Metal device
│   ├── integration/               # graph lifecycle and backend behavior
│   ├── conformance/               # expected semantics and edge cases
│   └── fixtures/
├── examples/
│   ├── c/
│   ├── swift/
│   └── python/
├── benchmarks/
├── docs/
│   ├── metal_graph_api_spec_v0.md
│   ├── source_verification_matrix.md
│   └── design_notes/
└── tools/
    ├── build_metallib.sh
    ├── run_gpu_tests.sh
    └── capture_trace.sh
```

Do not mix public API headers with backend-private Objective-C++ types. Do not put Swift or Python convenience behavior into the C runtime. Bindings may improve ergonomics, but they must not change semantics.

## 4. Language boundary rules

### C public API

The public API MUST be C-first:

- Use opaque structs: `mg_device_t`, `mg_graph_t`, `mg_graph_exec_t`, etc.
- Do not expose Objective-C, Swift, C++ STL, Metal objects, or ARC-managed types in public headers.
- Use explicit create/destroy functions.
- Every function that can fail MUST return `mg_status_t` or equivalent.
- Detailed diagnostics MUST be retrievable through `mg_error_t` or an explicit error output parameter.
- Public headers MUST compile as C and C++.
- Keep ABI stability in mind: prefer descriptors with `size`/`version` fields for structs likely to evolve.

### C++ core

C++ may be used internally for graph storage, validation, planning, and tests. Keep it portable and boring:

- No Metal dependency in `src/core`.
- No Objective-C++ in `src/core`.
- No exceptions across the public C boundary.
- No global mutable runtime state except controlled feature tables or logging hooks.
- Keep deterministic ordering for validation errors and plan generation.

### Objective-C++ Metal backend

All direct Metal ownership should live in `.mm` files under `src/metal`:

- Use ARC for Objective-C object lifetime where possible.
- Retain all Metal resources needed by an in-flight launch until completion.
- Keep `id<MTLDevice>`, `id<MTLCommandQueue>`, `id<MTLCommandBuffer>`, `id<MTLBuffer>`, `id<MTLSharedEvent>`, `id<MTLFence>`, and MPSGraph types private.
- Feature-detect capabilities at runtime. Do not assume availability based only on OS version.
- Use public Apple APIs only. Do not depend on private selectors, private frameworks, or undocumented behavior.

### Swift binding

Swift should be a thin ergonomic layer over the C API:

- Wrap opaque handles in `final class` owners.
- Use `deinit` to call destroy functions.
- Convert `mg_error_t` into Swift `Error` values.
- Preserve C semantics: explicit instantiate, patch, launch, synchronize.
- Do not hide asynchronous launch behavior behind surprising synchronous calls.
- Keep the Swift package buildable without Python.

### Python binding

Python is likely the next binding after C/Obj-C/Swift foundations:

- Python should wrap the C API, not Objective-C++ internals.
- Use Python `with` context managers for resource lifetime where helpful.
- Expose explicit `instantiate()`, `patch()`, `launch()`, and `synchronize()` operations.
- Use `pytest` for binding tests.
- Keep zero-copy and buffer interop explicit. Never silently copy large buffers unless the API name says so.
- Prefer `uv` for local Python development commands if the repo standardizes on it.

### Rust binding, later

Rust should wait until the C ABI is stable:

- Start with `metal-graph-sys` generated from public C headers.
- Build a safe `metal-graph` wrapper on top.
- Do not reimplement the runtime in Rust in the first Rust phase.
- Do not expose Rust-only semantics that cannot be represented in C or Swift.

## 5. Build and tooling standards

Use CMake as the primary native build system. Xcode project generation is acceptable, but CMake should remain scriptable from the command line.

Required local commands should converge on:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
ctest --test-dir build --output-on-failure
```

For Apple-specific packaging or Swift work, add explicit documented commands:

```bash
swift build
swift test
xcodebuild test -scheme MetalGraph-Package
```

For Python, once present:

```bash
uv sync
uv run pytest
uv run ruff check .
uv run mypy bindings/python/src
```

For Rust, once present:

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

Formatting and static checks:

- C/C++/Obj-C++: `clang-format`.
- C/C++: `clang-tidy` for new core code where practical.
- Swift: `swift-format` once Swift code grows beyond prototypes.
- Python: `ruff`, `mypy`, `pytest`.
- Rust: `rustfmt`, `clippy`.

Do not introduce a new build tool because one example needs it. Keep the build boring.

## 6. Metal shader and metallib rules

Metal shader handling must be reproducible:

- Store source kernels in `src/shaders`.
- Build `.metallib` artifacts through the build system or `tools/build_metallib.sh`.
- Do not rely on ad hoc runtime shader source compilation for normal tests.
- Runtime compilation may exist only for debugging or explicit experimental APIs.
- Name kernels predictably and keep public examples stable.
- Keep shader argument layouts documented next to the C descriptors that bind them.
- Add tests for argument layout compatibility when descriptors change.

When introducing optimized kernels, keep a reference path or CPU oracle test. Every optimized kernel needs a correctness test before performance tuning matters.

## 7. Testing strategy

Testing must be layered. Do not make every test require a GPU.

### CPU-only unit tests

These run everywhere:

- graph construction
- node validation
- dependency insertion
- cycle detection
- topological sort
- memory liveness planning
- arena alignment
- patch compatibility rules
- structured error formatting

### GPU integration tests

These require a real Metal device:

- dispatch node execution
- copy and fill nodes
- event wait/signal behavior
- command buffer failure propagation
- repeated launches from one `GraphExec`
- resource retention during in-flight execution
- patch then relaunch behavior
- fallback paths when optional features are unavailable

Do not treat simulator-only testing as sufficient. Simulator behavior and feature support may differ from physical Apple GPUs.

### Conformance tests

Conformance tests define public semantics:

- A graph with a cycle MUST fail validation.
- Mutating topology after instantiation MUST either be forbidden or require a new instantiation.
- Patching buffer bindings MUST fail if declared compatibility is violated.
- `GraphExec` MUST be reusable after successful completion.
- A failed launch MUST preserve enough error context to identify the backend stage and planned node/pass.
- Destroying a graph MUST NOT invalidate an already-instantiated `GraphExec` unless the spec says otherwise.
- Destroying or releasing user resources too early MUST either be prevented by retained bindings or rejected by documented ownership rules.

### Performance tests

Benchmarks should not be correctness tests. Keep them under `benchmarks/` and report:

- graph build time
- instantiate time
- launch overhead
- repeated launch overhead
- command encoding overhead
- memory planning overhead
- optional ICB impact
- comparison against hand-written raw Metal baseline

## 8. CI expectations

CI should have tiers:

1. **Portable tier:** format, static checks, CPU-only unit tests.
2. **macOS tier:** build Objective-C++ Metal backend and run non-GPU feature checks.
3. **Apple Silicon GPU tier:** run real GPU integration and conformance tests.
4. **Binding tiers:** Swift, Python, and later Rust wrappers.

Do not claim full backend correctness from tier 1 or tier 2 alone. The Metal backend needs a real Metal device in CI or a clearly labeled manual GPU test gate.

## 9. Feature detection and platform policy

Feature availability must be explicit:

- Prefer runtime feature probes over OS-version guesses.
- Keep a central backend feature table, for example `mg_metal_features_t`.
- Gate optional features: MPSGraph nodes, residency sets, ICB optimizations, indirect compute, shared events, and future Metal 4 features.
- Provide conservative fallbacks where possible.
- If there is no safe fallback, fail at validation or instantiation with `MG_STATUS_UNSUPPORTED`.

Never silently use a weaker synchronization or memory behavior that changes semantics. Fallbacks may reduce performance, not correctness.

## 10. Synchronization and lifetime rules

Agents must preserve these invariants:

- `mg_graph_t` is mutable only before instantiation unless an explicit API says otherwise.
- `mg_graph_exec_t` owns the frozen topology and planning artifacts.
- `mg_graph_exec_t` may outlive the source `mg_graph_t` if designed that way; tests must lock this behavior down.
- A launch retains all backend resources it needs until completion.
- Command buffers are per-launch.
- `MTLSharedEvent` is for timeline-style waits/signals.
- `MTLFence`, command ordering, or conservative encoder boundaries handle intra-device memory hazards.
- Host callbacks must not run while holding internal locks that could deadlock user code.
- Destructors must be safe to call after partial construction failure.

## 11. Error handling rules

Every failure should be actionable. Avoid boolean failure returns.

`mg_error_t` should include at least:

- status code
- human-readable message
- stage, such as `VALIDATE`, `INSTANTIATE`, `PATCH`, `ENCODE`, `COMMIT`, `COMPLETE`, `SYNC`
- node id if available
- backend status if available
- recoverability hint

Validation should catch deterministic user mistakes before launch. Runtime backend failures must surface command buffer errors and planned pass/node context.

Never swallow Metal errors. Never log-only an error that should affect API return status.

## 12. Documentation rules

When changing public behavior, update all of these together:

- public header comments
- `docs/metal_graph_api_spec_v0.md` or successor spec, once present
- examples
- conformance tests
- changelog entry once releases exist

Docs should use Obsidian-friendly Markdown and normal links. Do not include internal ChatGPT citation artifacts or transient research IDs.

Keep design notes separate from normative specification. A design note may explain why a choice was made; the spec should state what behavior is required.

Questions that arise from anticipated upcoming work, known next phases, or downstream consequences
of current work may always be added to `docs/open_questions.md`. Use that document to record the
question, the affected phase or API area, the likely options or constraints, and any answer that is
already known. Do not block useful open-question notes merely because the implementation for that
future phase has not started.

## 13. What agents should do before editing

Before making code changes:

1. Read this file.
2. Read `docs/metal_graph_api_spec_v0.md` or the current spec if present. Until then, read `docs/architecture.md` and `docs/open_questions.md`.
3. Identify which layer is being changed: C API, core planner, Metal backend, Swift binding, Python binding, tests, or docs.
4. Add or update tests at the lowest layer that can prove the behavior.
5. Avoid broad refactors unless the task explicitly asks for them.

If a task touches public API semantics, do not only patch implementation. Update the spec and conformance tests.

## 14. Current implementation priority

Implement in this order:

1. C API skeleton and opaque handles. Started; keep expanding it conservatively.
2. CPU-only graph construction and validation.
3. Topological planning and frozen `GraphExec` object.
4. Minimal Metal dispatch launch on one queue.
5. Copy/fill nodes.
6. Event wait/signal nodes.
7. Barrier/fence semantics.
8. Patch/update rules.
9. Arena and heap-backed transient memory planning.
10. Structured command buffer error propagation.
11. Swift wrapper.
12. Python wrapper.
13. Optional ICB optimization.
14. Optional MPSGraph node.
15. Future Rust wrapper.

Do not start with MLX. Do not start with Rust. Do not start with ICB optimization. First make the explicit graph model correct.

## 15. Coding style preferences

Keep code small, explicit, and testable.

- Prefer simple data structures until profiling proves otherwise.
- Keep validation deterministic.
- Keep backend feature flags visible.
- Keep ownership comments near handle structs and bridge objects.
- Avoid hidden global caches until cache lifetime is specified.
- Avoid clever template-heavy C++ in core APIs.
- Avoid duplicating semantics across bindings.
- Avoid one-off behavior in examples that is not supported by the library contract.

## 16. Definition of done for agent tasks

A task is done only when:

- code builds from a clean checkout;
- relevant unit tests pass;
- GPU tests are added or updated for backend behavior;
- public API changes are documented;
- errors are structured, not just printed;
- no private Apple APIs are used;
- no binding bypasses the C ABI contract;
- examples still compile or are explicitly updated;
- performance claims are either measured or removed.

When uncertain, choose correctness and explicit behavior over performance. This library is a runtime contract first and an optimization layer second.
