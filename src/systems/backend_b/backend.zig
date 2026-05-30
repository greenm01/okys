//! Plan B backend: tile-binning + analytic coverage, vello sparse-strips style.
//! Compute passes + storage buffers; native on desktop, WebGPU-only on web.
//! Stages live in sibling files as they land: encode, bin, coarse (strips),
//! fine, strip. Not implemented yet.
