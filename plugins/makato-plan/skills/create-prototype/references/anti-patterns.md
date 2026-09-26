# Create-Prototype Anti-Patterns

**NEVER prototype surfaces that differ only in data (same layout, different records)**
WHY: Feedback collapses to "the data looks wrong" rather than "this interaction is wrong."
Describe the data variation in a surface note instead; prototype one canonical instance.

**NEVER dispatch prototype-builder without MOCK_DATA derived from `design.md`**
WHY: Without a data model, the agent generates "John Doe / Item 1" stand-ins that shift
stakeholder attention to data accuracy. The entire review session gets consumed by "but
our field names are different" — the interaction feedback you need is lost. Domain-realistic
data keeps feedback on layout and interaction, not content.

**NEVER skip design system research when `repositories.yml` or a known repo is present**
WHY: A prototype with wrong or missing tokens looks different from the real app. Every
review comment becomes "but our buttons look different" — styling corrections bury the
interaction feedback you need. Design system research is the single highest-leverage step
for review quality.

**NEVER send a full-regeneration request to prototype-builder during the revision loop
(Step 7.4)**
WHY: Full regen wipes [ASSUMED] markers that reviewers may have already seen and confirmed,
resets mock data to agent defaults, and destroys unchanged surfaces. Always diff and pass
a targeted change set with only the modified surfaces.

**NEVER open the prototype before completing Step 6.1 HTML validation**
WHY: A prototype with unclosed tags or a silent CDN failure looks broken in the browser
without a clear error. The user assumes generation failed and requests a re-run, consuming
a second opus call. Validate first; re-dispatch with error details if needed.

**NEVER carry parked Q# questions into prototype generation without [ASSUMED] markers**
WHY: If the prototype renders an assumed interaction without marking it, reviewers click
through, approve it, and the assumption silently becomes the spec. The [ASSUMED] marker
is the mechanism for making invisible decisions visible before they harden into stories.
