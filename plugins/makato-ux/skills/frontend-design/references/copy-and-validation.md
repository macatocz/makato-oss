# Copy Writing and Validation Reference

## UX Copy Principles

Words appear in a design for one reason: to make it easier to understand, and therefore
easier to use. They are design material, not decoration — bring the same intentionality
to copy you bring to spacing and color. Generic copy makes a design feel as templated as
generic layout does.

- **Write from the end user's side of the screen.** Name things by what people control
  and recognize, never by how the system is built. A person manages notifications, not
  webhook config. Be specific rather than clever.
- **Use active voice.** A control says exactly what happens when used: "Save changes,"
  not "Submit." An action keeps the same name through the whole flow — the button that
  says "Publish" produces a toast that says "Published."
- **Treat failure and emptiness as direction, not mood.** Errors explain what went wrong
  and how to fix it, in the interface's voice; they don't apologize and are never vague.
  An empty screen is an invitation to act.
- **Keep the register conversational and tuned** — plain verbs, sentence case, no filler,
  tone matched to brand and audience. Each element does one job: a label labels, an
  example demonstrates.

## Validation Checklist

Before declaring complete, confirm the quality floor:

1. Verify all interactive elements have visible focus states (keyboard navigation).
2. Check colour contrast ratios meet WCAG AA for all text.
3. Confirm responsive behaviour at mobile (375px), tablet (768px), and desktop (1280px).
4. Confirm reduced-motion is respected.
5. Confirm no external CDN dependencies — code must run self-contained.

Then critique your own work. Spend your boldness in one place: let the signature element
be the one memorable thing and keep everything around it disciplined. Cut any decoration
that does not serve the brief. Consider Chanel's advice — before leaving the house, look
in the mirror and remove one accessory.
