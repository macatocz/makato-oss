# gh CLI on GitHub.com

makato targets `github.com` only. The `gh` CLI auto-detects the host from the git remote — no
`--hostname` flag needed for `gh pr` or `gh issue` subcommands. For `gh api` calls, the default
`api.github.com` base is correct.

## Pagination Pitfall

`--paginate` concatenates multiple JSON arrays into the output stream. Standard parsers like
Python's `json.load(sys.stdin)` reject this with `Extra data: line N column M`.

**Avoid:**

```bash
gh api --paginate ... | python3 -c "import json,sys; json.load(sys.stdin)"  # breaks
```

**Use:** explicit `per_page=100` and page manually if needed:

```bash
gh api "repos/<o>/<r>/pulls/<n>/comments?per_page=100"
gh api "repos/<o>/<r>/pulls/<n>/comments?per_page=100&page=2"
```

## Posting a Reply to a Review Thread

```bash
gh api --method POST \
  "repos/<owner>/<repo>/pulls/<n>/comments/<comment_id>/replies" \
  -f body="Fixed in <sha>."
```

The endpoint requires the parent comment ID (the one being replied to), not the thread ID.

## Resolving a Review Thread (GraphQL only)

The REST API has no endpoint to mark a thread resolved. Use the GraphQL
`resolveReviewThread` mutation. The thread node ID is different from the REST comment ID —
fetch it first:

```bash
gh api graphql -f query='
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      reviewThreads(first:50){
        nodes{ id isResolved comments(first:1){ nodes{ databaseId } } }
      }
    }
  }
}' -F owner=<owner> -F repo=<repo> -F pr=<n>
```

Map each `comments.nodes[0].databaseId` (REST id) to its thread `id`, then resolve:

```bash
gh api graphql \
  -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' \
  -F id=<thread-node-id>
```

To unresolve, use `unresolveReviewThread` with the same input.
