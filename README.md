# quarto-unity-cli

A Quarto codex for driving the Unity Editor through `unity-cli`, built as a small
algebra rather than a pile of commands. Every safe interaction is a composition
of three primitives — **Inspect → Mutate → Verify** — and the project's tooling
enforces that shape at render time.

## The idea

The whole system is four orthogonal layers, each doing one thing. Delete any leaf
and the rest still stands.

| Layer | Lives in | Responsibility |
|---|---|---|
| Behavior | `_extensions/unity-cli/*.lua` | render-time enforcement of the algebra |
| Presentation | `theme/*.scss` | color-as-semantics, typography |
| Data | `data/types.yml` | the DOTS type registry |
| Content | `*.qmd` | the codex itself |

Color is meaning: cyan is Inspect, amber is Mutate, green is Verify, red is
Failure, blue is Axiom.

## Build

Requires [Quarto](https://quarto.org) ≥ 1.4 and Python 3 with `pyyaml`.

```
make render
```

`make render` runs the validator, regenerates the glossary from the type
registry, then renders the book to `_site/`. Other targets:

```
make preview     live-reloading local server
make validate    check every invariant without rendering
make glossary     regenerate reference/glossary.qmd from data/types.yml
make clean       remove build artifacts
```

`make validate` is the same set of checks the render-time filter performs, plus
a few more: every Lua file parses, every YAML file parses, every `exec` block is
total (returns a value), and every callout class is known.

## Authoring with the primitives

The behavior layer gives you typed building blocks. An `exec` block renders with
its heredoc invocation and is checked for totality:

````
```{.exec name="Read the active scene" usings="UnityEditor.SceneManagement"}
var scene = EditorSceneManager.GetActiveScene();
return $"{scene.name} | {scene.path}";
```
````

A `cli` block renders a raw command:

````
```{.cli name="The full edit cycle"}
unity-cli editor refresh --force --compile
```
````

A `wrong` / `right` pair contrasts an anti-pattern with its fix:

````
```{.wrong}
foreach (var e in query.ToEntityArray(Allocator.Temp)) { Use(e); }
```
```{.right}
var arr = query.ToEntityArray(Allocator.Temp);
for (var i = 0; i < arr.Length; i++) { Use(arr[i]); }
arr.Dispose();
```
````

Callouts are fenced divs with a known class and a title:

```
::: {.axiom title="Mutation is always bracketed"}
Inspect before, Verify after.
:::
```

The known callout classes are `axiom`, `gotcha`, `failure`, `verify`. Inline,
`{{< unity-type LocalTransform >}}` renders a semantic type token and
`{{< unity-version >}}` emits the pinned version from `_variables.yml`.

## Extending

**Add a DOTS type** — edit `data/types.yml`, then `make glossary`. The glossary
is a deterministic projection of the registry; never edit it by hand.

**Add a chapter** — create a `.qmd` and list it under the right part in
`_quarto.yml`. The parts mirror the algebra: Axioms, Primitives, Composition,
Reference, Recipes.

**Add a primitive** — add a class handler in
`_extensions/unity-cli/primitives.lua` and its styles in
`theme/components.scss`. Keep each primitive orthogonal: one class, one job.

## Layout

```
_quarto.yml                  project config and structure
_variables.yml               version, single source of truth
index.qmd                    the algebra, stated
_extensions/unity-cli/       behavior: shortcodes and the enforcing filter
theme/                       presentation: dark engineering theme
data/types.yml               the type registry
tools/                       glossary generator, invariant validator
axioms/ primitives/ composition/ reference/ recipes/   the codex
```
