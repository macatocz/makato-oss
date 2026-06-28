# Type-error sample fixtures for build-fix-types
#
# Each function below intentionally violates one pyright/mypy rule so the
# sensor-fixer route can be exercised end-to-end. The expected branch is
# annotated next to each function name.
#
# Run pyright / mypy against this file from the repo root to reproduce the
# findings. See README.md in this directory for the verification recipe.

from __future__ import annotations


def narrow_target(x: str | None) -> int:
    """Expected route: pyright:reportOptionalMemberAccess → Branch 1 (Narrow)."""
    return len(x)


def annotate_target(items):  # noqa: ANN001
    """Expected route: pyright:reportMissingParameterType → Branch 2 (Annotate)."""
    return sum(item for item in items)


def typevar_target(items: list[int]) -> int:
    """Expected route: pyright:reportArgumentType → Branch 3 (TypeVar/Generic).

    The body is generic (first element) but the signature is concrete (list[int]).
    Calling with list[str] triggers reportArgumentType. The correct fix is to introduce
    TypeVar so the function is genuinely polymorphic.
    """
    return items[0]


_a = typevar_target([1, 2, 3])
_b = typevar_target(["a", "b"])  # INTENTIONAL: triggers reportArgumentType for Branch 3 fixture


class _MissingStubLib:
    """Stand-in for a third-party class with incomplete stubs.

    Expected route for the missing attribute below: pyright:reportUnknownMemberType
    → Branch 6 (type: ignore with reason).
    """


def missing_stub_target() -> object:
    obj = _MissingStubLib()
    return obj.private_attr  # type: ignore[attr-defined]  # reason: fixture for Branch 6
