# Local PlantUML runtime

The Mac app renders `plantuml` and `puml` fences with the official
MIT-licensed `@plantuml/core` 1.2026.9 engine in JavaScriptCore. `host.js`
provides an XML DOM and native font measurements. Smetana performs layout;
there is no WebView, Java installation, Graphviz binary, or server.

Rebuild the checked-in runtime with:

```sh
cd Vendor/PlantUML
npm ci --ignore-scripts
npm run build
```

`package-lock.json` pins and integrity-checks every build input. Node and
esbuild are build tools only. `Sources/PlantUMLRuntime/Resources/PlantUML`
contains the generated runtime and both upstream licenses; ship all three.

The host has no network or filesystem loader. External includes, remote
images, and optional downloaded sprite libraries are unavailable. Built-in
themes are included. Sequence, class, activity, state, and component diagrams
are covered through the actual CLI worker in `PlantUMLWorkerTests`.
Layout features that require Graphviz rather than Smetana are unsupported.

The app runs its bundled `down` executable with a private worker argument.
Each process handles one diagram, accepts at most 32 KiB of UTF-8, and emits
at most 1 MiB of SVG. The engine is configured with `maxSvgSize: 4096`, and
the host caps cached rasters at 2048 physical pixels per dimension. The host
kills the worker after five seconds and caches bounded raster results. Document text
is passed as data, never evaluated as JavaScript. Quick Look retains code
because it never installs the host's worker adapter.
