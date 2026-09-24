# ICR 008 (W6a): add a GPU energy term to measured per-process energy

Number is provisional; the controller may renumber.

## What

`EnergyAttributor` step (1) (measured Δ`ri_energy_nj` for permitted pids) must add a GPU term for every
pid with GPU work:

```
watts[pid] = Δri_energy_nj / dt / 1e9            // CPU only (measured)
           + gpuW × gpuShare[pid]                // NEW: IOReport GPU W × (AGX Δgpu ns of pid / Σ AGX Δgpu ns)
```

Step (3) keeps its SoC share fill for pids still without a value, but its GPU part must not be applied a
second time to pids that received the new GPU term. Rows whose watts include the GPU term are
`energyEstimated` only when the GPU term is non-zero (the CPU part stays measured).

No Model change: `SoCPowerReading.gpuWatts` and `GPUClientsReading.clients` already carry the inputs.
Affects W1 (`RulingEnergyAttributor` + `EnergyAttributorTests`), ARCHITECTURE §5.6 doc comment and §10 ruling
("open gap" → closed).

## Why (T8 measurement, 2026-09-24, M1 Max, macOS 26.5)

`ProcessTableGPUEnergySmokeTests` runs two 3 s windows in one process:

| window | Δ`ri_energy_nj` | Δ CPU time | GPU busy (Σ Metal gpuEnd − gpuStart) |
|---|---|---|---|
| A: one CPU thread spinning | 8.1–8.2 J (≈ 2.7 J per CPU-second) | 2.98 s | 0 |
| B: Metal compute busy-loop (`spike-gpu-apps --load` kernel) | 0.02–0.03 J | 0.02–0.03 s | 3.1–3.2 s (GPU ≈ 100 % busy) |

In B the energy equals the CPU-only expectation (CPU time × 2.7 J/s ≈ 0.05–0.09 J); the GPU's work adds
nothing. `ri_penergy_nj` ≈ `ri_energy_nj` in both windows. **`ri_energy_nj` does not include GPU energy.**
Without the new term a GPU-heavy app (games, ML, video) would show near-zero watts.

## Side observation for W6b/W1 (AGX)

In the same test the pid's AGX `AppUsage.accumulatedGPUTime` sum, read before and after window B (both reads
after that window's command queue had been released), was ~0 (1.9 ms), although the GPU ran our work for 3.2 s.
The running spike, whose queue stays alive while it samples, shows 83 % for itself. Likely per-queue `AppUsage`
entries vanish when the queue is released, so the per-client sum can decrease: the engine's guarded delta
(rebaseline on decrease) is required, and GPU time of short-lived queues between two samples is lost.
Not verified by sampling during the load; worth a W6b check.
