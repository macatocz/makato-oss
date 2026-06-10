# Label Conventions

Two labels apply to every issue: a **type label** and a **plugin label** (omit the plugin label for `repo-wide`).

## Type Labels (already exist on DCP/makato)

| Issue type    | Label           |
|---------------|-----------------|
| Bug           | `bug`           |
| Feature       | `enhancement`   |
| Documentation | `documentation` |

Do not auto-create type labels — if one is missing, surface to the user.

## Plugin Labels

| Plugin scope      | Label                    | Color (hex) |
|-------------------|--------------------------|-------------|
| `makato-core`       | `plugin:makato-core`       | `0E8A16`    |
| `makato-plan`      | `plugin:makato-plan`      | `5319E7`    |
| `makato-contribute` | `plugin:makato-contribute` | `0075CA`    |

If a `plugin:*` label is missing, create it with the matching color and a description like `Affects <plugin> plugin`.
