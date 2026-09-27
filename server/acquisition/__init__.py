"""Workshop acquisition: locating an item's real files.

Deliberately decoupled from processing so the acquisition method can change
without touching the PKG/TEX/export pipeline.
"""
from .base import (  # noqa: F401
    AcquiredContent, AcquisitionError, Capability, ItemMetadata, Registry, Source,
)
