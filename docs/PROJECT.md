# Project

## Name

**ZUI (Zig UI)**

A declarative native UI framework for Zig, inspired by the developer experience of Jetpack Compose.

## Problem

Developing modern graphical applications in Zig requires combining window management, rendering, layout, event handling, state management, and platform-specific functionality.

Existing solutions provide useful foundations, but developers may need to assemble multiple libraries or accept trade-offs between native integration, visual consistency, development experience, and maintainability.

The lack of an integrated declarative UI workflow with reliable Hot Reload also makes rapid interface development more difficult.

ZUI aims to address these challenges without introducing a separate markup language, requiring CSS, or hiding Zig's memory management and performance characteristics behind excessive abstractions.

## Solution

ZUI is a declarative UI framework for building native graphical applications directly in Zig.

It provides a compact component API, reactive state management, incremental UI updates, a layout engine, and a rendering system designed for predictable performance.

Its development tooling aims to support Hot Reload while preserving application state and keeping the running application responsive.

The framework will prioritize a small, understandable core, explicit resource ownership, minimal dependencies, and a practical developer experience.

The initial implementation will target desktop Linux, with a modular design that supports additional platforms as the framework matures.

ZUI will draw inspiration from Jetpack Compose's declarative programming model without attempting to reproduce its entire API or runtime architecture.

## Target Users

- Zig developers building native desktop applications.
- Developers who prefer declarative UI over manually managing widget trees.
- Systems programmers seeking direct control over memory, rendering, and resource lifetimes.
- Developers who want rapid UI iteration without restarting their applications after every code change.
- Contributors interested in native UI tooling and the Zig ecosystem.

## Main Features

- **Declarative UI:** Build interfaces by composing reusable components written in Zig.
- **Reactive state:** Update the interface automatically when observed state changes.
- **Incremental recomposition:** Rebuild affected components instead of unnecessarily reconstructing the entire interface.
- **Layout engine:** Support common layout primitives, including rows, columns, boxes, spacing, padding, and alignment.
- **Rendering backend:** Provide a rendering abstraction with a lightweight initial implementation.
- **Cross-platform foundation:** Separate UI logic from platform-specific window management, input, and rendering functionality.
- **Hot Reload:** Reload modified application code without restarting the runtime, subject to platform and ABI constraints.
- **State preservation:** Preserve compatible component state across UI updates and successful code reloads.
- **Error recovery:** Keep the last valid application version running when a new compilation fails.
- **Native event handling:** Support keyboard, pointer, focus, and window events.
- **Theming:** Provide typed colors, typography, spacing, component styles, and reusable themes without requiring CSS.
- **Explicit memory management:** Use Zig allocators and clearly defined resource lifetimes.
- **Developer tooling:** Provide a development runner, file watching, compiler diagnostics, and reload status.
- **Testing and benchmarks:** Include tests for core behavior and benchmarks for rendering, layout, state updates, and development reloads.
- **Minimal dependencies:** Prefer Zig's standard library and small, well-maintained external libraries where practical.
- **Examples and documentation:** Include runnable examples and documentation for the public API.

## Technology Stack

- **Language:** Zig 0.17.0 as the initial target, subject to toolchain availability and compatibility verification.
- **Build system:** Zig's native build system using `build.zig` and `build.zig.zon`.
- **UI API:** Native Zig functions, types, and composable components.
- **State management:** Typed state containers and dependency tracking.
- **UI representation:** A component tree with stable identities and incremental updates.
- **Layout:** A framework-owned layout engine.
- **Windowing and input:** Evaluate SDL or another suitable lightweight cross-platform library.
- **Rendering:** A backend abstraction with an initial software or lightweight accelerated renderer, selected after a technical prototype.
- **Text rendering:** Evaluate FreeType or another suitable solution for font loading and glyph handling.
- **Hot Reload:** A development runner and application-module boundary designed around a stable interface and explicit resource lifetimes.
- **Testing:** Zig's built-in testing facilities, supplemented by automated integration tests and benchmarks.
- **Documentation:** Markdown documentation, architecture decisions, API examples, and a project roadmap.

External dependencies must be evaluated for Zig compatibility, licensing, maintenance status, build complexity, and platform support before adoption.

The initial backend and dependency choices are provisional until validated through working prototypes.

## Non-Functional Requirements

- **Security:**
  - Avoid executing arbitrary commands or loading untrusted code as part of normal application operation.
  - Restrict dynamic module loading to the development workflow unless explicitly enabled.
  - Validate module interfaces and resource ownership across Hot Reload boundaries.
  - Avoid stale callbacks, dangling pointers, and use-after-unload errors during module replacement.
  - Keep dependencies minimal and document their security implications.
  - Never require network access for ordinary application execution.
  - Do not introduce a remote development service as a prerequisite for Hot Reload.

- **Performance:**
  - Target low startup time, low memory consumption, and responsive input handling.
  - Establish reproducible benchmarks before setting strict performance guarantees.
  - Target sub-100 ms runtime startup on a documented reference machine for a small application.
  - Target a UI update budget below 4 ms for representative small-interface state changes.
  - Support smooth 60 FPS rendering when the application and hardware can meet the frame budget.
  - Minimize unnecessary allocations, layout calculations, recomposition, and drawing operations.
  - Reuse buffers and resources where doing so improves measured performance.
  - Avoid blocking the UI thread during expensive development operations whenever practical.

- **Reliability:**
  - Preserve the last valid running application when compilation or Hot Reload fails.
  - Define explicit ownership and cleanup rules for windows, fonts, textures, callbacks, and component state.
  - Ensure that resource cleanup is safe when components are removed or modules are replaced.
  - Provide deterministic tests for state updates, component identity, layout, and resource lifetimes.
  - Keep platform-specific behavior isolated behind explicit interfaces.
  - Document supported Zig versions and known platform limitations.

- **Scalability:**
  - Support growing application complexity without requiring a monolithic UI implementation.
  - Keep component, state, layout, and rendering responsibilities clearly separated.
  - Allow additional widgets and rendering backends without redesigning the public API.
  - Design incremental updates to support larger component trees.
  - Keep the core framework small while allowing optional capabilities to be added as needed.
  - Support additional desktop platforms after the initial implementation is stable.

## Scope

### MVP

- A working desktop application runtime on Linux.
- A basic window and event loop.
- A minimal rendering backend capable of drawing shapes and text.
- A declarative API implemented entirely in Zig.
- Basic components: `Text`, `Button`, `Row`, `Column`, `Box`, and `Spacer`.
- A layout engine supporting basic sizing, spacing, padding, and alignment.
- Typed reactive state with automatic UI updates.
- Stable component identities and basic incremental recomposition.
- Mouse and keyboard event handling.
- Basic text input sufficient for a small form or notes application.
- A simple theme and typed styling API.
- A development runner with file watching.
- Initial resource-based live reload.
- A documented prototype of code Hot Reload with a stable module interface.
- Preservation of the last valid application when compilation fails.
- Automated unit tests for state, layout, component identity, and resource management.
- A counter example demonstrating reactive state.
- A notes example demonstrating text input and state preservation.
- A minimal README, architecture document, roadmap, and documented technical decisions.
- Initial performance benchmarks and a reproducible reference environment.

The MVP must demonstrate that developers can build and interact with a small native application using the declarative API.

Full code Hot Reload with state preservation is a major project objective, but it must be validated independently rather than assumed to work merely because file watching and recompilation are available.

### Future

- Complete code Hot Reload with application-state preservation.
- Reliable incremental compilation and reload diagnostics.
- Windows and macOS support.
- Native Android support or an Android-compatible backend, subject to feasibility.
- Advanced text editing, selection, clipboard integration, and accessibility.
- Lists with virtualization for large collections.
- Navigation and application-level state management.
- Animations and transitions.
- Additional rendering backends and optional GPU acceleration.
- Native controls for applications that require closer operating-system integration.
- An expanded widget library.
- Advanced layout features and responsive interfaces.
- A visual inspection and debugging tool.
- Optional developer tooling for inspecting component trees and state dependencies.
- Performance profiling and memory diagnostics.
- Stable public API and semantic versioning.
- Additional examples and production-oriented documentation.

Future features must be prioritized according to demonstrated demand, implementation cost, and their effect on the core framework.

## Out of Scope

- Reproducing the complete Jetpack Compose API or runtime.
- Creating a new programming language or requiring a custom markup language.
- Requiring HTML, CSS, or JavaScript to define native application interfaces.
- Building a web framework or full-stack web application platform.
- Developing a complete game engine or general-purpose 3D rendering engine.
- Implementing a custom operating system window manager.
- Building a full IDE or visual application designer in the initial releases.
- Supporting every desktop and mobile platform in the MVP.
- Guaranteeing Hot Reload for arbitrary Zig programs or every possible change to application code.
- Automatically migrating incompatible application state across arbitrary code changes.
- Loading untrusted application modules in a privileged process.
- Adding a complex plugin system before concrete use cases justify it.
- Introducing unnecessary architectural layers, custom compilers, or code-generation systems.
- Optimizing for benchmark scores at the expense of usability, accessibility, or maintainability.
- Promising performance advantages over Capy, Ziex, or other frameworks without reproducible comparative benchmarks.
