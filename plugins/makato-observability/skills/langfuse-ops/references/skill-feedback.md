# Skill Feedback Reference

Use this reference when the user indicates the skill gave incorrect guidance,
is missing information, or could be improved. This is for issues with the
**skill instructions** — not for Langfuse product bugs or feature requests.

## Steps

1. **Ask permission.** Ask the user if they would like you to submit feedback
   to the skill maintainers. Make it clear this is about the skill (the agent
   instructions), not about the Langfuse product itself. If they decline, stop.

2. **Draft the feedback.** Use the two-field form below. Present the draft to
   the user and ask if they want to change anything before submitting.

3. **Submit.** Once approved, submit via `gh` CLI as shown below. Share the
   resulting discussion URL with the user.

## Feedback Form

Draft the body as markdown with these two headings:

**Describe your idea or feedback** *(required)*
What the user was trying to do, what the skill did, and what was expected.
Include any specific instructions that were incorrect or missing.

**What would the ideal outcome look like?** *(optional)*
What the correct behaviour or guidance should be.

## Submitting via gh CLI

```bash
gh api graphql -f query='
mutation($repoId: ID!, $categoryId: ID!, $title: String!, $body: String!) {
  createDiscussion(input: {
    repositoryId: $repoId,
    categoryId: $categoryId,
    title: $title,
    body: $body
  }) {
    discussion { url }
  }
}' \
  -f repoId="$(gh api graphql \
      -f query='{ repository(owner: "langfuse", name: "skills") { id } }' \
      --jq '.data.repository.id')" \
  -f categoryId="$(gh api graphql \
      -f query='{ repository(owner: "langfuse", name: "skills") {
                   discussionCategories(first: 10) { nodes { id name } } } }' \
      --jq '.data.repository.discussionCategories.nodes[]
            | select(.name == "Ideas & Improvements") | .id')" \
  -f title="<concise title>" \
  -f body="<formatted feedback>"
```

If `gh` is not authenticated or the request fails, give the user this link
to file manually:

```
https://github.com/langfuse/skills/discussions/new?category=ideas-improvements
```

After submission, share the discussion URL with the user.
