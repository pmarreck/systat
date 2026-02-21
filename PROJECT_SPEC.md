Systat will be a cross-platform (mac/linux/windows) system status app that uses the "Dear ImGui" library from a Zig core (pure functions, no I/O other than what is necessary to collect system stats, C FFI) and a C CLI (dogfooding the FFI) that does all I/O and GUI.

It will look cool as hell (modern UI, dark mode, cyberpunk colors/futuristic theme, etc.) while being minimally-impactful on system resources (CPU, memory, etc.).

Resizing its window should dynamically change the layout to fit the most pertinent subsections of system stats into the window (and drop off any that don't fit). These subsections will have a default priority rating which can be reconfigured via a TOML file stored in the appropriate XDG config directory (with a default fallback on each OS). These subsections can be 1 across to 3 across, depending on window width, and as many rows as needed to fit into the window height.

This project will use a flake.nix for dependencies, target Zig 0.15.2, and use both Garnix CI and GitHub Actions for CI/CD, with appropriate "success" badges placed at the top of the README.md file.

Two of these subsections/submodules will provide information similar to what the `memhogs` and `cpuhogs` commands show (they are defined in the current dev environment), but not depending on those.

Other subsections will be TBD but may include things like: animated line graph of CPU usage, network activity, memory activity, disk activity, etc.

Similar to what btop or htop might provide. Open to suggestions.

I'd also theoretically like something that acts like what `webping` (defined in the current environment) currently does, but with multiple animated line graphs of ping times to multiple hosts (with defaults, configurable of course).

In all cases, platform-specific information sources should be used but abstracted out. (I'm considering a future plugin scheme; consider this when designing the core.)

The final product will be just the binary, with no other files or dependencies (and the config file of course).

The config on Windows SHALL NOT BE STORED IN THE REGISTRY. TOML there too, somewhere.

New features will use TDD to the extent possible (I'm not sure what "Dear ImGUI" provides here).

Benchmarking for all the submodules should be done using whatever is available, and logged into a file over time which is tracked in source control.
