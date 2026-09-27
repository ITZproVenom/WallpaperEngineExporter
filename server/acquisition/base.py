"""Acquisition contract.

Acquisition answers one question: "where are this Workshop item's real files?"
It knows nothing about PKG, TEX, FFmpeg, or MP4. The processing pipeline knows
nothing about Steam, mirrors, or credentials. Swapping an acquisition source
must never require touching processing code.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path


class AcquisitionError(RuntimeError):
    """Raised when a source cannot supply an item."""


@dataclass(frozen=True)
class ItemMetadata:
    """What a Workshop item claims about itself, before any download."""
    workshop_id: str
    title: str = ""
    declared_type: str | None = None        # "Video" | "Scene" | "Web" | None
    file_size: int = 0
    tags: tuple[str, ...] = ()
    preview_url: str = ""
    resolution: str = ""
    interactive: bool = False               # audio/mouse/clock driven

    @property
    def likely_passthrough(self) -> bool:
        """True when the package probably already holds a finished video."""
        return self.declared_type == "Video"


@dataclass(frozen=True)
class AcquiredContent:
    """A local directory (or .pkg file) holding the item's real files."""
    workshop_id: str
    root: Path
    source_name: str
    metadata: ItemMetadata | None = None
    notes: tuple[str, ...] = ()


@dataclass(frozen=True)
class Capability:
    """A source's honest self-assessment, checked at runtime, never assumed."""
    name: str
    available: bool
    detail: str
    requires_credentials: bool = False
    requires_user_action: bool = False


class Source(ABC):
    """One way of obtaining Workshop content."""

    name: str = "source"
    #: Lower runs first. Sources that preserve original files rank best.
    priority: int = 100

    @abstractmethod
    def capability(self) -> Capability:
        """Check, at runtime, whether this source can work right now."""

    @abstractmethod
    def acquire(self, workshop_id: str, target: Path,
                metadata: ItemMetadata | None = None) -> AcquiredContent:
        """Place the item's files under ``target`` and describe the result."""


@dataclass
class Registry:
    """Tries sources in priority order and reports why each one declined."""
    sources: list[Source] = field(default_factory=list)

    def register(self, source: Source) -> "Registry":
        self.sources.append(source)
        self.sources.sort(key=lambda s: s.priority)
        return self

    def capabilities(self) -> list[Capability]:
        return [s.capability() for s in self.sources]

    def acquire(self, workshop_id: str, target: Path,
                metadata: ItemMetadata | None = None) -> AcquiredContent:
        attempts: list[str] = []
        for source in self.sources:
            capability = source.capability()
            if not capability.available:
                attempts.append(f"{source.name}: {capability.detail}")
                continue
            try:
                return source.acquire(workshop_id, target, metadata)
            except AcquisitionError as error:
                attempts.append(f"{source.name}: {error}")
        raise AcquisitionError(
            "No acquisition source could supply this item.\n  "
            + "\n  ".join(attempts or ["no sources registered"])
        )
