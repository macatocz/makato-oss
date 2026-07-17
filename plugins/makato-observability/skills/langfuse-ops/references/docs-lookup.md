# Docs lookup — fetching Langfuse documentation

Use these three methods in order. Prefer (2a) to get the index first, (2b) to read a page, and (2c) to search when the exact path is unknown.

## Method 2a — llms.txt index

The canonical machine-readable index of all Langfuse documentation is at:

```
https://langfuse.com/llms.txt
```

Fetch it first to discover available pages and their paths before reading any individual page:

```
WebFetch https://langfuse.com/llms.txt
```

The index lists slugs and titles. Use it to identify the correct page path before fetching. Do not guess paths from training-data memory — page locations change across Langfuse versions.

## Method 2b — Fetch a page as markdown

Append `.md` to any Langfuse documentation path to retrieve it as clean markdown:

```
WebFetch https://langfuse.com/docs/<path>.md
```

Alternatively, pass `Accept: text/markdown` as a header in a curl call if the `.md` suffix does not work for a given path:

```bash
curl -s -H "Accept: text/markdown" "https://langfuse.com/docs/<path>"
```

Prefer `WebFetch` over `curl` — it handles redirects and encoding automatically.

**Responses can be large.** Extract only the section relevant to the operator's question. Do not emit the entire page into the conversation.

## Method 2c — Search API fallback

When the exact page path is unknown after consulting llms.txt, use the Langfuse search API:

```
WebFetch https://langfuse.com/api/search-docs?query=<url-encoded-terms>
```

Example for searching SDK tracing configuration:

```
WebFetch https://langfuse.com/api/search-docs?query=sdk+tracing+configuration
```

Returns a JSON array of matching pages with titles and paths. Pick the most relevant result and fetch its content via Method 2b.

## Preferred order

1. Fetch `llms.txt` to get the page index.
2. Identify the page path from the index.
3. Fetch the page via the `.md` suffix.
4. If the page is not in the index, fall back to the search API (2c), then fetch (2b).

## NEVER implement from changelog posts

Changelog entries (paths under `/changelog/`) confirm that a feature exists and when it shipped. They do NOT provide complete, current implementation guidance — code examples in changelogs are illustrative and may reference pre-release APIs.

Always implement from:
- The docs page (e.g. `/docs/sdk/…`) retrieved via 2b.
- The API reference (e.g. `/docs/api`) retrieved via 2b.

Use changelogs only to confirm a feature exists at a minimum version before checking the SDK docs for the authoritative usage pattern.
