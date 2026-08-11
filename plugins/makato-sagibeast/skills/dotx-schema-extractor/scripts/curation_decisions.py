"""Manifest model + JSON I/O for the curation walkthrough."""

from __future__ import annotations

import dataclasses
import json
from pathlib import Path
from typing import Any


@dataclasses.dataclass
class Decision:
    """One verdict recorded during the phase-1 walkthrough."""

    raw_key: str
    raw_source: str
    anchor: dict[str, Any]
    verdict: str  # slot|enum|prose_keep|prose_drop|comment_keep_as_description|toss
    key: str | None
    kind: str | None  # text|enum|date|number|None
    enum: list[str] | None
    description: str
    decided_at: str

    def to_dict(self) -> dict[str, Any]:
        return dataclasses.asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> Decision:
        return cls(**d)


@dataclasses.dataclass
class Manifest:
    """Top-level decisions.json structure."""

    schema_version: int
    source_schema_sha256: str | None
    template_sha256: str | None
    started_at: str | None
    decisions: list[Decision]

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "source_schema_sha256": self.source_schema_sha256,
            "template_sha256": self.template_sha256,
            "started_at": self.started_at,
            "decisions": [d.to_dict() for d in self.decisions],
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> Manifest:
        return cls(
            schema_version=d.get("schema_version", 1),
            source_schema_sha256=d.get("source_schema_sha256"),
            template_sha256=d.get("template_sha256"),
            started_at=d.get("started_at"),
            decisions=[Decision.from_dict(x) for x in d.get("decisions", [])],
        )


def load_manifest(path: Path) -> Manifest:
    """Load a manifest. Returns an empty manifest when the file is missing."""
    if not path.exists():
        return Manifest(
            schema_version=1,
            source_schema_sha256=None,
            template_sha256=None,
            started_at=None,
            decisions=[],
        )
    return Manifest.from_dict(json.loads(path.read_text(encoding="utf-8")))


def save_manifest(manifest: Manifest, path: Path) -> None:
    """Atomically replace ``path`` with the JSON of ``manifest``."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        json.dumps(manifest.to_dict(), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    tmp.replace(path)


def next_pending(manifest: Manifest, raw_fields: list[dict[str, Any]]) -> tuple[int, dict[str, Any] | None]:
    """Return ``(index, field)`` of the first raw field not yet decided.

    Decisions are matched by ``raw_key`` only — the assumption is that
    keys are unique within one source, which is enforced by the
    extractor's deduplication.
    """
    decided = {d.raw_key for d in manifest.decisions}
    for idx, field in enumerate(raw_fields):
        if field["key"] not in decided:
            return idx, field
    return -1, None
