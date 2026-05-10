# Open Questions

These decisions should be resolved before the API is considered stable.

## Platform Floor

Decide the minimum macOS, iOS, and Apple GPU family targets.

The answer affects whether features such as shared events, residency sets, indirect compute commands, Metal 4 APIs, and MPSGraph integration are core requirements or optional capabilities.

## Thread Safety

Define which objects may be used concurrently.

At minimum, document whether graph construction, graph exec patching, launches, and destruction are externally synchronized by the caller or internally synchronized by the library.

## Ownership And Lifetime

Define retain/release behavior for every handle type.

Launches must retain all backend resources required by command buffers until completion, even if user-facing handles are destroyed earlier.

## Serialization

Decide whether v1 serializes only graph topology and metadata, or whether any backend-specific executable artifacts are allowed.

The conservative path is to serialize portable graph descriptions only and rebuild backend plans during instantiation.

## Future Bindings

Decide how much binding code belongs in this repository.

Swift wrappers can live close to the core project. Python and Rust may start as thin external packages until the C ABI is less volatile.
