# CXSharedResources

Shared datasets and helper code consumed by the FlightCapture and CXRoster apps. The repository is mounted as a Git submodule inside each app workspace so both projects stay in sync with the canonical airport metadata and shared flight utilities.

## Contents

- `Resources/` – JSON datasets (airports, aliases, reserve rules, time zones, roster samples, etc.). These files back the lookup tables inside the apps.
- `Sources/Shared/` – Swift helpers (`AirportDirectory`, `AirportNormalizer`, `FlightKeyFactory`, `SharedFlightStore`) referenced by both codebases.
- `world-airports.csv` – Source data used when regenerating `airports.json`.

## Working With the Submodule

### First-Time Setup

```bash
git submodule update --init --recursive
```

Run the command from either app repository after cloning so the shared resources are checked out locally. The symlinks inside `FlightCapture/Resources` and `CXRoster/Resources` will resolve once the submodule has been initialised.

### Editing Shared Data or Code

1. Open the `CXSharedResources` directory (either directly or via `cd CXSharedResources` from the parent repository).
2. Make your changes (e.g., update a JSON file or Swift helper).
3. Commit inside the submodule:

   ```bash
   git status
   git add <files>
   git commit -m "Describe shared change"
   git push
   ```

4. In each parent app repository, update the submodule pointer and commit the new reference.

### Regenerating Airport Data

The `world-airports.csv` file is the canonical source. Use the scripts from the main app repositories (see `SHARED_RESOURCES_SETUP.md`) to regenerate the JSON datasets, then commit the refreshed files here.

## Troubleshooting

- **Missing files after clone** – ensure the submodule has been initialised (`git submodule update --init --recursive`).
- **Xcode build cannot find JSON** – recreate the symlinks in the parent repo so they point back to `../CXSharedResources/Resources/...`.
- **Needing a clean state** – run `git status` inside the submodule to review pending edits before updating the pointer in the parent repository.

