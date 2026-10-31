# Architecture

## Overview

ZUI is a declarative native UI framework written in Zig. Its architecture is designed to provide a developer experience inspired by Jetpack Compose while maintaining explicit memory management, predictable resource lifetimes, and efficient rendering.

The framework separates UI composition, reactive state, layout calculation, rendering, platform integration, and development tooling into focused modules.

The architecture prioritizes:

- A small and understandable core.
- Declarative UI composition using native Zig APIs.
- Reactive state updates and incremental recomposition.
- Efficient layout and rendering.
- Explicit memory and resource ownership.
- A stable boundary between the application and the runtime for Hot Reload.
- Minimal external dependencies.
- Testability and compatibility with the targeted Zig version.

The initial target platform is Linux desktop. Other platforms may be added after the core architecture and development workflow are stable.

### Architectural Model

The runtime follows this conceptual pipeline:

```text
Application Code
       |
       v
Declarative UI API
       |
       v
Component Tree <----> Reactive State
       |
       v
Incremental Recomposition
       |
       v
Layout Engine
       |
       v
Render Commands
       |
       v
Rendering Backend
       |
       v
Platform Window
```

Platform events travel in the opposite direction:

```text
Keyboard / Pointer / Window Events
                 |
                 v
          Platform Layer
                 |
                 v
           Event System
                 |
                 v
         Component Callbacks
                 |
                 v
           State Updates
                 |
                 v
       Incremental Recomposition
```

The development runner operates alongside the runtime and manages file watching, compilation, diagnostics, and application-module replacement.

These diagrams describe logical responsibilities, not mandatory thread boundaries. The initial implementation should use a simple execution model unless profiling or platform requirements justify additional concurrency.

## Modules

Modules are organized by responsibility rather than by architectural layers. They may be implemented as separate Zig source files within a single package.

### 1. Public API (`zui.zig`)

Provides the public interface used by applications.

Responsibilities:

- Expose UI components and layout primitives.
- Provide application configuration.
- Expose reactive state and event-handling APIs.
- Provide theme and styling types.
- Hide internal implementation details that applications do not need.

Constraints:

- Keep the public API small and consistent.
- Prefer native Zig types and compile-time validation.
- Avoid exposing renderer internals or platform-specific implementation details.
- Do not promise source or binary compatibility beyond the project's documented compatibility policy.

### 2. Application Runtime (`app.zig`)

Owns the application lifecycle and coordinates runtime operations.

Responsibilities:

- Initialize and shut down the application.
- Create and manage the main window.
- Run the event loop.
- Coordinate state updates, recomposition, layout, and rendering.
- Manage the runtime's long-lived resources.

Constraints:

- Keep the runtime independent of the development runner.
- Keep expensive compilation operations outside the normal rendering path.
- Define explicit initialization and shutdown behavior.

### 3. Component System (`component.zig`, `tree.zig`)

Represents the UI structure and manages component identity.

Responsibilities:

- Define component descriptions and their properties.
- Maintain the component tree.
- Assign or track stable component identities.
- Detect component insertion, removal, and property changes.
- Preserve compatible component state during tree updates.

Constraints:

- Do not rebuild the entire tree unnecessarily.
- Do not use raw memory addresses as persistent component identities.
- Keep component identity separate from temporary layout and rendering data.
- Define how incompatible component changes affect retained state.

### 4. Reactive State (`state.zig`)

Manages mutable application state and its relationship with UI components.

Responsibilities:

- Provide typed state containers.
- Track dependencies between state values and UI computations.
- Notify the runtime when observed values change.
- Schedule affected components for recomposition.
- Prevent redundant updates where practical.

Constraints:

- State ownership and destruction must be explicit.
- Avoid unnecessary global mutable state.
- Define the behavior of nested updates and repeated notifications.
- Establish a clear execution model for state mutation.
- Do not introduce a complex concurrency model without a demonstrated requirement.

### 5. Recomposition (`recompose.zig`)

Coordinates incremental updates to the component tree.

Responsibilities:

- Identify components affected by state changes.
- Re-evaluate affected UI descriptions.
- Compare updated component descriptions with existing nodes.
- Preserve compatible component state.
- Invalidate layout or rendering data when necessary.

Constraints:

- Keep recomposition separate from actual drawing.
- Avoid recomposing unaffected components.
- Ensure component removal releases associated resources safely.
- Provide deterministic tests for identity matching and update behavior.

### 6. Layout Engine (`layout.zig`)

Calculates component sizes and positions.

Responsibilities:

- Measure component content.
- Resolve available space and layout constraints.
- Calculate padding, spacing, alignment, and dimensions.
- Support initial primitives such as `Row`, `Column`, `Box`, and `Spacer`.
- Mark affected layout regions as invalid when relevant properties change.

Constraints:

- Keep layout independent of a specific rendering backend.
- Define coordinate units and rounding behavior.
- Avoid repeated calculations when inputs have not changed.
- Prevent invalid or non-finite layout values from corrupting rendering.
- Do not implement an unnecessarily general constraint solver before required use cases exist.

### 7. Rendering (`render/`)

Converts laid-out components into drawing operations.

Responsibilities:

- Represent drawing operations as render commands.
- Draw shapes, text, images, and component backgrounds.
- Manage drawing resources and their lifetimes.
- Support clipping and invalidated regions where appropriate.
- Allow a rendering backend to be replaced without changing the public UI API.

Initial files may include:

- `renderer.zig`: rendering interfaces and coordination.
- `software.zig`: an initial software-rendering implementation, if selected.
- Additional backend files only when required.

Constraints:

- Rendering must not own application business state.
- Render commands must not retain invalid references to destroyed components.
- Expensive resources should be reused when practical.
- Partial redraws must be introduced only when their invalidation rules are correct.

### 8. Text and Resources (`text.zig`, resource modules as needed)

Manages fonts, text measurement, and reusable visual resources.

Responsibilities:

- Load and release fonts and images.
- Measure text for layout.
- Provide glyph and text-rendering information to the rendering backend.
- Cache reusable resources when beneficial.
- Define behavior when a resource is unavailable or invalid.

Constraints:

- Keep text measurement consistent with rendering metrics.
- Define ownership of loaded resources.
- Avoid making a particular font library part of the public API.
- Introduce additional resource modules only when their responsibilities justify the separation.

### 9. Events (`events.zig`)

Coordinates input events and component interactions.

Responsibilities:

- Route pointer and keyboard events.
- Track focus and pointer interaction.
- Dispatch events to the appropriate components.
- Support callbacks such as button clicks and text changes.
- Request state updates when interactions modify application state.

Constraints:

- Define event ordering and focus behavior.
- Prevent callbacks from referencing destroyed components.
- Keep platform-specific event translation outside the component API.
- Ensure that event processing cannot use unloaded application code.

### 10. Platform Integration (`platform/`)

Provides operating-system integration behind internal interfaces.

Responsibilities:

- Create and manage windows.
- Translate platform events into framework events.
- Manage window resizing and display scale.
- Handle platform-specific lifecycle requirements.
- Provide the foundation for additional desktop platforms.

Constraints:

- Keep platform-specific code isolated.
- Do not expose operating-system implementation details unnecessarily.
- Document differences that cannot be hidden behind a common interface.

### 11. Development Runner (`tools/zui-dev/`)

Provides the development workflow independently of the production runtime.

Responsibilities:

- Watch relevant source and resource files.
- Trigger compilation after changes.
- Display compilation errors and reload status.
- Coordinate application-module replacement.
- Preserve the last valid running application when a new build fails.
- Support a future state-preserving Hot Reload workflow.

Constraints:

- The development runner is not required by production applications.
- File watching must ignore build artifacts and irrelevant directories.
- Reload operations must not invalidate resources still used by the runtime.
- Code Hot Reload must use an explicitly defined module interface.
- Recompilation alone must not be described as Hot Reload if the process restarts.

### 12. Testing and Benchmarks (`tests/`)

Validates framework behavior and performance.

Responsibilities:

- Test reactive state and dependency tracking.
- Test component identity and incremental recomposition.
- Test layout calculations.
- Test resource ownership and cleanup.
- Test error recovery during development reloads.
- Measure startup time, state-update cost, layout time, rendering time, and memory consumption.

Constraints:

- Performance results must be reproducible.
- Benchmarks must identify the compiler version, build mode, hardware, and workload.
- Optimization decisions should be supported by measurements.

## Data Flow

### 1. Initial Application Startup

1. The runtime initializes platform resources.
2. The main window and event loop are created.
3. The application builds its initial declarative UI.
4. The component tree is created.
5. Initial state dependencies are registered.
6. The layout engine calculates component geometry.
7. The rendering system generates and executes drawing operations.
8. The runtime begins processing platform events.

### 2. Reactive State Update

1. A user interaction invokes a component callback.
2. The callback updates a typed state value.
3. The state system identifies affected computations.
4. The runtime schedules recomposition.
5. Affected component descriptions are reevaluated.
6. The component tree is reconciled using stable identities.
7. Incompatible or removed component state is handled according to documented rules.
8. Layout and rendering are invalidated as necessary.
9. The next rendering pass displays the updated interface.

Unrelated components should not be recomposed unless their dependencies or structural relationships require it.

### 3. Layout and Rendering

1. The component tree provides the structure and properties of the interface.
2. The layout engine calculates sizes and positions.
3. Layout results are stored separately from component descriptions.
4. Rendering operations are generated from the current layout and visual properties.
5. The backend executes drawing operations.
6. The platform presents the resulting frame.

Layout and rendering invalidation must be independent where practical. A visual change that does not affect geometry should not automatically require a complete layout recalculation.

### 4. Hot Reload

1. The development runner detects a relevant source change.
2. The runner compiles the updated application module.
3. If compilation fails, the last valid module remains active.
4. If compilation succeeds, the runner validates the new module interface.
5. The runtime prepares a safe replacement.
6. Active callbacks and resources associated with the old module are invalidated or safely retired.
7. The new module is activated.
8. The UI is rebuilt and reconciled against the previous component tree.
9. Compatible state is preserved.
10. The runtime resumes normal event processing and rendering.

The runtime must not unload executable code while callbacks, function pointers, or other active references still depend on it.

If safe replacement cannot be completed, the runtime must retain the previous valid version or report that a restart is required.

### 5. Resource Updates

1. The development runner detects a changed resource.
2. The runtime validates and loads the replacement.
3. The new resource becomes available to dependent components.
4. Affected layout or rendering data is invalidated as necessary.
5. The old resource is released only after it is no longer in use.

## Dependencies

### Internal Dependency Rules

The intended dependency direction is:

```text
Public API
    |
    v
Application Runtime
    |
    +----> Component System
    |          |
    |          v
    |      Reactive State
    |          |
    |          v
    |      Recomposition
    |          |
    |          v
    |      Layout Engine
    |          |
    |          v
    |      Rendering
    |
    +----> Event System
    |
    +----> Platform Integration

Development Runner
    |
    +----> Build Process
    |
    +----> Runtime Module Interface
```

This diagram describes the logical relationships. Implementations may use callbacks, shared internal types, or explicit interfaces where necessary, provided dependency cycles are avoided.

Rules:

- The public API must not depend on development tooling.
- The rendering backend must not depend on application-specific state.
- The layout engine must not depend on operating-system window implementations.
- Platform integration must not require application components to use platform-specific APIs.
- The development runner must communicate with the runtime through an explicit contract.
- Shared internal types must remain small and purpose-driven.
- Circular module dependencies must be avoided.
- New interfaces must solve concrete problems rather than anticipate hypothetical requirements.

### External Dependencies

External dependencies are provisional until validated against the target Zig version.

Potential candidates include:

- **SDL:** window management, input, and platform integration.
- **sokol:** an alternative lightweight graphics foundation.
- **FreeType:** font loading and glyph support.

These are candidates, not a requirement to integrate all three.

Selection criteria:

- Compatibility with the targeted Zig compiler.
- Build complexity and maintenance burden.
- Supported operating systems.
- Licensing and redistribution requirements.
- Performance and resource-management characteristics.
- Availability of required functionality without unnecessary subsystems.

Prefer the smallest practical dependency set. Do not introduce multiple libraries that provide overlapping functionality without a demonstrated need.

## Persistence

ZUI is a UI framework, not an application database or persistence service.

The core framework will not require a database, remote storage, or network service.

Application data persistence belongs to the application unless a future, explicitly approved framework feature requires otherwise.

Runtime persistence is limited to data needed to manage the active application, including:

- Component identities.
- Reactive state.
- Layout and rendering caches.
- Loaded fonts, images, and other resources.
- Compatible UI state retained during Hot Reload.

Persistent application data must not be confused with runtime state.

### Hot Reload State Preservation

State preservation is limited to compatible state whose identity and lifecycle remain valid after a module replacement.

The framework must define:

- How state is associated with component identities.
- How incompatible state types are detected.
- How removed components release their state.
- How temporary resources are invalidated.
- Which state may survive a reload.
- When a restart is required.

The framework must not serialize arbitrary Zig memory or assume that allocator-owned pointers remain valid across module replacement.

## External Services

The framework does not require external services for normal operation.

The initial architecture must not depend on:

- Hosted APIs.
- Remote rendering services.
- Cloud compilation.
- Account authentication.
- Telemetry services.
- Remote feature flags.

Development tooling may invoke the locally installed Zig compiler and other explicitly configured local build tools.

Any future integration that communicates with an external service requires explicit justification, documented security implications, and approval before adoption.

## Error Handling

ZUI uses explicit error handling consistent with Zig's error model.

### Initialization Errors

Errors involving platform initialization, window creation, renderer initialization, or resource loading must be propagated to the application entry point.

The runtime must release successfully initialized resources when subsequent initialization steps fail.

### UI and Layout Errors

Invalid dimensions, unsupported layout constraints, or unavailable resources must not cause undefined behavior.

The framework should validate externally supplied values at appropriate boundaries and provide useful diagnostics during development.

Where possible, an invalid component property should produce a clear diagnostic instead of silently corrupting layout or rendering.

### Rendering Errors

Rendering failures must be reported through the relevant backend or runtime interface.

The framework must define how recoverable failures are handled, including missing resources and temporary rendering problems.

### Hot Reload Errors

Hot Reload failures must not destroy the last valid running application.

The development runner must report:

- Compilation failures.
- Module-interface incompatibilities.
- Reload failures.
- Resource replacement failures.
- Conditions requiring a full restart.

The runner must not activate a partially initialized or invalid module.

### Memory and Resource Errors

Resource ownership must be documented.

Cleanup must occur on both successful and failed execution paths. Tests should cover allocation failures and partial initialization where practical.

Assertions may be used for internal invariants during development, but they must not replace proper handling of recoverable errors.

## Security

ZUI is primarily a local application framework. Its security model focuses on memory safety, dynamic module loading, resource handling, and development tooling.

### Memory Safety

- Define allocator ownership for components, state, render resources, and platform objects.
- Avoid dangling pointers and use-after-free errors.
- Ensure callbacks cannot reference destroyed components.
- Validate resource lifetimes across module replacement.
- Avoid exposing internal memory layouts as a stable public contract.
- Test cleanup paths and allocation failures where practical.

### Hot Reload Isolation

- Dynamic application-module loading is restricted to the development workflow by default.
- The runtime must validate the module interface before activation.
- Old code must not be unloaded while it is still executing or referenced.
- Invalid modules must not replace the last valid module.
- Application-module loading must not be treated as a security sandbox.
- Untrusted modules must not be loaded into a privileged process.

### Input and Resource Validation

- Validate file paths used by development tooling.
- Ignore generated files and unrelated directories when watching source files.
- Avoid executing commands constructed from untrusted input.
- Validate resource formats and dimensions before allocating large buffers.
- Handle malformed fonts, images, and other external resources safely within the capabilities of the selected libraries.

### Dependencies

- Review licenses and known security issues before adoption.
- Pin dependency versions where practical.
- Document the purpose of each external dependency.
- Avoid unnecessary network access and remote code execution.
- Do not introduce telemetry or external data transmission without explicit approval.

### Application Security Boundaries

ZUI does not provide application authentication, authorization, secret management, or a general-purpose sandbox.

Applications that require these capabilities must implement them using appropriate application-level mechanisms.

## Architecture Constraints

- The initial implementation targets Zig 0.17.0, subject to compiler availability and verification.
- All framework and example application code must use Zig.
- The framework must not require HTML, CSS, JavaScript, or a separate UI markup language.
- The initial supported platform is Linux desktop.
- The public UI API must remain independent of the selected rendering backend.
- Component descriptions, reactive state, layout data, and rendering resources must have clearly defined responsibilities.
- State updates must trigger only the recomposition and invalidation required by their dependencies.
- Resource ownership and cleanup must be explicit.
- The runtime must remain independent of the development runner.
- Hot Reload must use a documented module interface and safe replacement rules.
- Compilation failures must preserve the last valid running application.
- The framework must not promise arbitrary state preservation across incompatible code changes.
- External dependencies must be minimal and justified by concrete requirements.
- Performance claims must be supported by reproducible benchmarks.
- Accessibility and keyboard interaction must be considered part of framework functionality, not optional visual enhancements.
- Platform-specific functionality must remain isolated behind internal interfaces.
- The implementation must favor readable, maintainable code over premature optimization.
- Architectural complexity must grow only when validated requirements justify it.

## Forbidden Changes

- Do not introduce a different architecture without explicit approval.
- Do not create unnecessary abstraction layers.
- Do not add new major dependencies without approval.
- Do not introduce a domain layer, use-case layer, or service architecture unrelated to the framework's actual needs.
- Do not replace the declarative Zig API with a mandatory markup language.
- Do not introduce a browser engine or CSS engine into the core framework without explicit approval.
- Do not couple the public API directly to a specific graphics library.
- Do not make the runtime dependent on the development runner.
- Do not introduce global mutable state when a clear ownership model is practical.
- Do not implement a complex multithreaded runtime before profiling demonstrates a need.
- Do not introduce custom compiler infrastructure or mandatory code generation without explicit approval.
- Do not implement speculative cross-platform abstractions without a concrete use case.
- Do not claim that file watching and process restarts constitute state-preserving Hot Reload.
- Do not unload application modules while their code or resources remain in use.
- Do not serialize arbitrary Zig memory to preserve state across incompatible reloads.
- Do not add databases, cloud services, authentication systems, or telemetry to the core framework without explicit approval.
- Do not remove tests or benchmarks merely to simplify implementation.
- Do not change public API contracts or dependency choices without documenting the impact.
- Do not make performance claims without reproducible evidence.
- Do not expand the MVP beyond its agreed scope without updating the project documentation and obtaining approval.
