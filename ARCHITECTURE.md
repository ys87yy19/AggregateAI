# Omni Architecture

## Goal

Omni now acts as a local workspace shell instead of only being a multi-AI comparison window.

The key rule is:

- Configure the local AI gateway once in Omni
- Reuse the same gateway endpoint, model, and API key across native features
- Sync that configuration to integrated local modules such as Siftly

## Layers

### 1. Shared AI Gateway

Omni owns one canonical AI configuration:

- endpoint
- API key
- selected model

This configuration is used by:

- Omni's own aggregation pipeline
- future native Omni tools
- integrated local modules that support sync

Secrets are stored in macOS Keychain, not plain UserDefaults.

### 2. Module Registry

Integrated apps are registered in `OmniModuleRegistry`.

Each module declares:

- stable `id`
- title and subtitle
- launch style
- optional sync adapter

This makes adding future modules incremental instead of hard-coding one-off settings panels.

### 3. Sync Adapters

`OmniIntegrationService` translates the shared gateway config into each module's expected format.

Current adapter:

- `siftly`

Responsibilities:

- normalize Omni endpoint into Siftly's OpenAI-compatible base URL
- push provider/model/key/base URL into Siftly settings
- probe module availability

## Current Integrated Module

### Siftly

Launch target:

- `http://127.0.0.1:3000`

Synced settings:

- provider = `openai`
- OpenAI-compatible base URL
- OpenAI key
- OpenAI model

Siftly was extended to support DB-backed AI base URLs, so it no longer has to rely only on `.env`.

## Adding Another Module

1. Add a module entry to `OmniModuleRegistry`
2. Give it a launch style
3. Add a sync adapter in `OmniIntegrationService` if the module consumes shared AI config
4. Expose module-specific controls in the Integrations settings tab only when needed

This keeps Omni as the control plane and modules as pluggable surfaces.

## Why This Direction

This is better than physically merging every codebase into Omni because:

- each module can keep its own runtime and storage
- Omni remains the single configuration source
- future integrations become adapter work instead of large code merges
- failures stay isolated per module
