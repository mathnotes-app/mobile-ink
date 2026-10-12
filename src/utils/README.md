# Canvas utilities

Pure helpers for viewport coordinates, engine-pool ranges, render-scale limits,
page growth, data signatures, and notebook serialization.

`trimIfNeeded` preserves JavaScript whitespace semantics without calling `trim`
on already-clean strings. Hermes can allocate a complete copy of large notebook
or page strings even when trimming removes nothing. Native load validation and
page-growth checks use this helper without weakening payload validation.
