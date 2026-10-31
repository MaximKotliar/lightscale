# lsfg-metal

Frame generation for Windows games running on Apple Silicon through Game Porting Toolkit (GPTK) / D3DMetal.

Two tracks:

- **Track A:** built-in DLSS frame generation via GPTK/D3DMetal (MetalFX). Starting with The Last of Us Part II Remastered.
- **Track B:** a general LSFG frame-presentation hook for Metal, like [lsfg-vk](https://github.com/PancakeTAS/lsfg-vk) but hooking `CAMetalLayer` / `MTLCommandBuffer` presentation, injected with `DYLD_INSERT_LIBRARIES`.

## License note

The LSFG shaders are loaded at runtime from your own purchased copy of Lossless Scaling (`Lossless.dll`). This repo never contains the DLL, the extracted shaders or the weights.

## Status

Work in progress.
