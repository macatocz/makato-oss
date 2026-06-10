# Confluence Spec Page Template

> XHTML structure for the stakeholder overview page in DCPL space. Load at Step 13 when creating the Confluence page.

## Page Metadata

- **Space**: DCPL
- **Title**: `Spec - {Feature Name} ({ITDB-key})`
- **Parent**: `Feature Specifications - {Domain}` (auto-detected from hierarchy)
- **Labels**: `spec`, `makato-generated`, `{domain-slug}`

## Hierarchy

```
Functional Documentation (page 2134905309)
  └── {Domain} (e.g., "Product Configurator")
       └── Feature Specifications - {Domain}
            └── Spec - {Feature Name} ({ITDB-key})  ← THIS PAGE
```

## Domain Detection

1. Get child pages of "Functional Documentation" (page 2134905309)
2. For each domain page, get its children
3. Look for "Feature Specifications - {Domain}" pattern
4. Match domain to ITDB feature context or ask user

## Page Content Structure (XHTML Storage Format)

```xml
<h1>Feature Overview</h1>
<p><strong>Objective:</strong> {epic.objective}</p>
<p><strong>ITDB Feature:</strong> <a href="https://jira.tools.sap/browse/{feature}">{feature}</a></p>
<p><strong>Epic:</strong> <a href="https://jira.tools.sap/browse/{epicKey}">{epicKey} - {epic.summary}</a></p>
<p><strong>PI:</strong> {epic.pi}</p>
<p><strong>Status:</strong> Published</p>

<h1>Stories</h1>
<table>
  <thead>
    <tr>
      <th>#</th>
      <th>Key</th>
      <th>Summary</th>
      <th>SP</th>
      <th>Phase</th>
      <th>Teams</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>{sequence}</td>
      <td><a href="https://jira.tools.sap/browse/{storyKey}">{storyKey}</a></td>
      <td>{story.summary}</td>
      <td>{story.storyPoints}</td>
      <td>{story.phase}</td>
      <td>{story.teams joined}</td>
    </tr>
    <!-- repeat for each story -->
  </tbody>
</table>

<h1>Phased Delivery</h1>
<h2>Foundation</h2>
<ul>
  <!-- stories where phase == "foundation" -->
  <li><a href="...">{storyKey}</a> — {summary}</li>
</ul>
<h2>Happy Path</h2>
<ul>
  <!-- stories where phase == "happy-path" -->
  <li><a href="...">{storyKey}</a> — {summary}</li>
</ul>
<h2>Edge Cases</h2>
<ul>
  <!-- stories where phase == "edge-cases" -->
  <li><a href="...">{storyKey}</a> — {summary}</li>
</ul>

<h1>Shaping Artifacts</h1>
<ul>
  <li><a href="{prdUrl}">PRD</a></li>
  <li><a href="{designUrl}">Architecture / Design</a></li>
  <li><a href="{prototypeUrl}">Prototype</a></li>
</ul>

<h1>Dependencies</h1>
<table>
  <thead>
    <tr>
      <th>Story</th>
      <th>Depends On</th>
      <th>External Team</th>
      <th>Description</th>
      <th>Status</th>
    </tr>
  </thead>
  <tbody>
    <!-- inter-story dependencies -->
    <tr>
      <td>{storyKey}</td>
      <td>{blockerStoryKey}</td>
      <td>—</td>
      <td>Internal dependency</td>
      <td>—</td>
    </tr>
    <!-- external dependencies -->
    <tr>
      <td>{storyKey}</td>
      <td>—</td>
      <td>{team}</td>
      <td>{description}</td>
      <td>{status}</td>
    </tr>
  </tbody>
</table>
```

## Notes

- Only include "Shaping Artifacts" links for artifacts that exist in the spec folder
- Only include "Dependencies" section if there are any (inter-story or external)
- The page is a read-only stakeholder overview — Jira remains the source of truth for status
