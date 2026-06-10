# Team-Repository Mapping

## DCP Teams and Primary Repositories

| Team | Repositories | Focus |
|------|-------------|-------|
| DCP Core One | commerce-ui-libs, storefront-core | Core storefront UI, shared components |
| DCP Core Two | pstore-ui, express-checkout | Purchase store UI, checkout flows |
| DCP Indirect Two | ps-lambda-cart-decorator, inno-services | Cart decoration, innovation services |
| DCP Ext One | ps-lambda-cart-validation, ps-lambda-product-determination | Cart validation, product determination |

## Usage Notes

- This mapping is a starting point. Always confirm team assignment with the user during the interview.
- A story may involve multiple teams (multi-select in Jira).
- If a repository is not listed here, ask the user which team owns it.
- The Jira field for teams is `customfield_16240` ("Team(s)") — a multi-select option field.

## Mapping Logic

1. Identify repositories from `repositories.yml`
2. Match to teams using this table
3. Present proposed mapping to user for confirmation
4. If story touches repos from multiple teams → assign all relevant teams
5. If a story is pure integration (no single repo owns it) → assign the team closest to the user-facing outcome

## When Mapping Fails

If the user identifies a repository or team not in this table:
- Accept their input as authoritative
- Note: this reference should be updated in a future PR to include new mappings
