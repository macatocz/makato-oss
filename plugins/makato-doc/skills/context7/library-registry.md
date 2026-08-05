# Library Registry

## Purpose

Pre-optimized query patterns and aliases for the 22 libraries covered by this skill.
When Step 1 (SKILL.md) directs you here, locate the target library and substitute the
corresponding `+`-joined query string for the matching user intent — do not construct a
freeform query. Strings are tuned for Context7's term-frequency index; natural-language
sentences dilute signal by including stop words.

---

## Supported Libraries

### Database & ORM

#### Drizzle ORM
- **Aliases**: `drizzle`, `drizzle-orm`, `drizzle orm`
- **Docs**: https://orm.drizzle.team/

#### Prisma
- **Aliases**: `prisma`
- **Docs**: https://www.prisma.io/docs

---

### Authentication

#### Better Auth
- **Aliases**: `better-auth`, `better auth`, `betterauth`
- **Docs**: https://www.better-auth.com/docs

#### NextAuth.js
- **Aliases**: `nextauth`, `next-auth`, `nextauth.js`, `auth.js`
- **Docs**: https://authjs.dev/

#### Clerk
- **Aliases**: `clerk`
- **Docs**: https://clerk.com/docs

---

### Frontend Frameworks

#### Next.js
- **Aliases**: `nextjs`, `next.js`, `next`
- **Docs**: https://nextjs.org/docs

#### React
- **Aliases**: `react`, `reactjs`, `react.js`
- **Docs**: https://react.dev/

#### TanStack Query
- **Aliases**: `tanstack query`, `react query`, `@tanstack/react-query`
- **Docs**: https://tanstack.com/query/latest

#### TanStack Router
- **Aliases**: `tanstack router`, `@tanstack/react-router`
- **Docs**: https://tanstack.com/router/latest

#### TanStack Start
- **Aliases**: `tanstack start`, `@tanstack/start`
- **Docs**: https://tanstack.com/start/latest

---

### Infrastructure & Deployment

#### Cloudflare Workers
- **Aliases**: `cloudflare workers`, `cloudflare`, `workers`, `cf workers`
- **Docs**: https://developers.cloudflare.com/workers

#### AWS Lambda
- **Aliases**: `aws lambda`, `lambda`
- **Docs**: https://docs.aws.amazon.com/lambda

#### Vercel
- **Aliases**: `vercel`
- **Docs**: https://vercel.com/docs

---

### UI Libraries & Styling

#### Shadcn/ui
- **Aliases**: `shadcn`, `shadcn/ui`, `shadcn-ui`
- **Docs**: https://ui.shadcn.com/

#### Radix UI
- **Aliases**: `radix`, `radix ui`, `radix-ui`, `@radix-ui`
- **Docs**: https://www.radix-ui.com/

#### Tailwind CSS
- **Aliases**: `tailwind`, `tailwindcss`, `tailwind css`
- **Docs**: https://tailwindcss.com/docs

---

### State Management

#### Zustand
- **Aliases**: `zustand`
- **Docs**: https://zustand-demo.pmnd.rs/

#### Jotai
- **Aliases**: `jotai`
- **Docs**: https://jotai.org/

---

### Validation & Forms

#### Zod
- **Aliases**: `zod`
- **Docs**: https://zod.dev/

#### React Hook Form
- **Aliases**: `react hook form`, `react-hook-form`, `rhf`
- **Docs**: https://react-hook-form.com/

---

### Testing

#### Vitest
- **Aliases**: `vitest`
- **Docs**: https://vitest.dev/

#### Playwright
- **Aliases**: `playwright`
- **Docs**: https://playwright.dev/

---

## Query Optimization Patterns

Use the exact query string from the matching row. Each string is `+`-joined to avoid
stop-word dilution in Context7's TF index. A library's Context7 resolved ID is returned
by `resolve-library-id`; do not hardcode it.

### Drizzle ORM

| User Intent | Optimized Query |
|-------------|-----------------|
| Setup/Installation | `PostgreSQL+setup+configuration+TypeScript+installation` |
| Modular schemas | `modular+schema+organization+domain+driven+design` |
| Relations | `relational+queries+one+to+many+joins+with+relations` |
| Migrations | `drizzle-kit+migrations+generate+push+PostgreSQL` |
| Transactions | `database+transactions+patterns+TypeScript` |
| Type safety | `TypeScript+type+inference+schema+types+inferInsert` |

### Prisma

| User Intent | Optimized Query |
|-------------|-----------------|
| Setup/datasource | `datasource+generator+schema+provider+TypeScript+configuration` |
| Migrations | `migrate+dev+deploy+reset+TypeScript+Prisma+CLI` |
| Client queries | `findUnique+findMany+create+update+delete+where+TypeScript` |
| Relations | `one+to+many+many+to+many+include+select+relations+schema` |
| Type inference | `TypeScript+generated+types+namespace+infer+Prisma` |

### Better Auth

| User Intent | Optimized Query |
|-------------|-----------------|
| Setup | `setup+configuration+Next.js+TypeScript+installation` |
| Next.js integration | `Next.js+App+Router+integration+setup+configuration` |
| Drizzle adapter | `Drizzle+adapter+PostgreSQL+schema+generation+configuration` |
| Social providers | `social+providers+OAuth+GitHub+Google+setup` |
| Email/password | `email+password+authentication+signup+signin` |
| Session management | `session+management+cookies+JWT+middleware` |

### NextAuth.js

| User Intent | Optimized Query |
|-------------|-----------------|
| Setup | `setup+configuration+providers+Next.js+App+Router+TypeScript` |
| Providers | `OAuth+providers+GitHub+Google+Credentials+authorize+TypeScript` |
| Callbacks | `callbacks+session+jwt+signIn+authorized+TypeScript+types` |
| Database sessions | `database+adapter+Prisma+Drizzle+session+strategy+TypeScript` |
| Protected routes | `middleware+authorized+callback+protected+routes+TypeScript` |

### Clerk

| User Intent | Optimized Query |
|-------------|-----------------|
| Setup/middleware | `clerkMiddleware+matcher+protected+routes+TypeScript+installation` |
| Server-side auth | `auth+currentUser+clerkClient+server+side+TypeScript` |
| UI components | `SignIn+SignUp+UserButton+UserProfile+components+TypeScript` |
| Organizations | `organization+members+roles+permissions+TypeScript` |

### Next.js

| User Intent | Optimized Query |
|-------------|-----------------|
| App Router | `App+Router+file+conventions+layouts+pages+routing` |
| Server Actions | `Server+Actions+form+mutations+revalidation+TypeScript` |
| Server Components | `React+Server+Components+async+data+fetching+patterns` |
| Dynamic routes | `dynamic+routes+params+TypeScript+generateStaticParams` |
| Middleware | `middleware+authentication+redirects+headers+cookies` |
| API routes | `API+routes+route+handlers+TypeScript+POST+GET` |

### React

| User Intent | Optimized Query |
|-------------|-----------------|
| State/effects | `useState+useEffect+TypeScript+custom+hooks+patterns` |
| Context | `createContext+useContext+Provider+TypeScript+patterns` |
| Refs | `useRef+forwardRef+TypeScript+DOM+ref+patterns` |
| Performance | `memo+useMemo+useCallback+TypeScript+optimization+re-render` |
| Suspense | `Suspense+ErrorBoundary+lazy+TypeScript+async+patterns` |

### TanStack Query

| User Intent | Optimized Query |
|-------------|-----------------|
| Setup | `setup+QueryClient+provider+Next.js+TypeScript` |
| Data fetching | `useQuery+data+fetching+TypeScript+patterns+async` |
| Mutations | `useMutation+optimistic+updates+invalidation+TypeScript` |
| Prefetching | `prefetchQuery+Server+Components+hydration+Next.js` |
| Caching | `cache+configuration+staleTime+gcTime+invalidation` |

### TanStack Router

| User Intent | Optimized Query |
|-------------|-----------------|
| File-based routing | `createFileRoute+TypeScript+file+based+routing+params` |
| Links/navigation | `Link+useNavigate+useParams+useSearch+TypeScript` |
| Loaders | `loader+context+TypeScript+defer+data+fetching` |
| Type-safe routes | `type+safe+params+search+TypeScript+RouteOptions+strict` |

### TanStack Start

| User Intent | Optimized Query |
|-------------|-----------------|
| Server functions | `createServerFn+TypeScript+server+functions+setup` |
| File routing | `file+based+routing+TypeScript+Route+createFileRoute+server` |
| Deployment | `deployment+Nitro+Vinxi+TypeScript+adapter+configuration` |

### Cloudflare Workers

| User Intent | Optimized Query |
|-------------|-----------------|
| Setup | `getting+started+setup+TypeScript+wrangler+configuration` |
| Routing | `routing+itty-router+hono+request+handling` |
| KV storage | `KV+storage+key+value+bindings+TypeScript` |
| Durable Objects | `Durable+Objects+state+WebSockets+coordination` |

### AWS Lambda

| User Intent | Optimized Query |
|-------------|-----------------|
| Setup | `getting+started+setup+TypeScript+handler+configuration` |
| Handlers | `handler+function+event+context+TypeScript+patterns` |
| Layers | `layers+dependencies+shared+code+deployment` |
| Environment variables | `environment+variables+secrets+configuration+SSM` |

### Vercel

| User Intent | Optimized Query |
|-------------|-----------------|
| Deployment config | `vercel+json+configuration+rewrites+redirects+headers` |
| Edge runtime | `edge+runtime+TypeScript+middleware+functions+configuration` |
| Environment variables | `environment+variables+preview+production+secrets+CLI` |
| Storage | `Vercel+KV+Blob+Postgres+TypeScript+configuration` |

### Shadcn/ui

| User Intent | Optimized Query |
|-------------|-----------------|
| Installation | `CLI+init+add+components+TypeScript+Next.js+installation` |
| Components | `Button+Form+Dialog+Sheet+TypeScript+props+variants` |
| Theming | `CSS+variables+dark+mode+theme+colors+configuration` |
| Form integration | `Form+useForm+react-hook-form+zod+TypeScript+validation` |

### Radix UI

| User Intent | Optimized Query |
|-------------|-----------------|
| Composition | `asChild+composition+TypeScript+primitive+patterns` |
| Accessibility | `accessibility+ARIA+keyboard+focus+TypeScript` |
| Dialog/overlay | `Dialog+AlertDialog+Sheet+TypeScript+open+onOpenChange` |
| Selection | `Select+DropdownMenu+Tooltip+TypeScript+patterns` |

### Tailwind CSS

| User Intent | Optimized Query |
|-------------|-----------------|
| Config | `tailwind+config+theme+extend+TypeScript+configuration` |
| Dark mode | `dark+mode+class+media+configuration+TypeScript` |
| Responsive | `responsive+breakpoints+sm+md+lg+xl+TypeScript` |
| Arbitrary values | `arbitrary+values+CSS+variables+TypeScript+customization` |

### Zustand

| User Intent | Optimized Query |
|-------------|-----------------|
| Create store | `create+store+set+get+TypeScript+state+actions` |
| Middleware | `persist+devtools+immer+middleware+TypeScript+configuration` |
| Selectors | `useStore+selector+TypeScript+shallow+equal+performance` |
| Slices pattern | `slices+pattern+combine+TypeScript+modular+store` |

### Jotai

| User Intent | Optimized Query |
|-------------|-----------------|
| Basic atoms | `atom+useAtom+useAtomValue+useSetAtom+TypeScript` |
| Derived atoms | `derived+atom+get+TypeScript+computed+patterns` |
| Async atoms | `async+atom+Suspense+TypeScript+loadable+patterns` |
| Utilities | `atomWithStorage+atomWithReset+atomFamily+TypeScript` |

### Zod

| User Intent | Optimized Query |
|-------------|-----------------|
| Schema definition | `z+object+string+number+TypeScript+schema+infer` |
| Parsing/errors | `parse+safeParse+TypeScript+error+flatten+format` |
| Refinements | `refine+superRefine+TypeScript+custom+validation` |
| Transforms | `transform+preprocess+coerce+TypeScript+pipe` |
| Discriminated unions | `discriminatedUnion+union+TypeScript+literal+enum` |

### React Hook Form

| User Intent | Optimized Query |
|-------------|-----------------|
| Setup | `useForm+register+TypeScript+defaultValues+mode+configuration` |
| Validation | `resolver+zodResolver+TypeScript+errors+validation` |
| Controlled inputs | `Controller+useController+TypeScript+controlled+input` |
| Field arrays | `useFieldArray+TypeScript+dynamic+fields+append+remove` |
| Submit state | `handleSubmit+TypeScript+formState+isSubmitting+errors` |

### Vitest

| User Intent | Optimized Query |
|-------------|-----------------|
| Config | `vitest+config+TypeScript+setupFiles+globals+environment` |
| Testing patterns | `describe+it+expect+test+TypeScript+assertions` |
| Mocking | `vi+mock+fn+spyOn+TypeScript+module+hoisting` |
| Coverage | `coverage+v8+istanbul+thresholds+TypeScript+configuration` |
| Snapshots | `snapshot+toMatchSnapshot+TypeScript+inline+update` |

### Playwright

| User Intent | Optimized Query |
|-------------|-----------------|
| Config | `playwright+config+TypeScript+browsers+baseURL+reporter` |
| Locators | `getByRole+getByText+getByLabel+locator+TypeScript` |
| Assertions | `expect+toBeVisible+toHaveText+toHaveURL+TypeScript` |
| Page objects | `page+object+model+TypeScript+fixtures+patterns` |
| API testing | `APIRequestContext+request+TypeScript+response+assertions` |

---

## Adding New Libraries

To add a library:
1. Add an entry under the appropriate category (name + aliases + docs link)
2. Add a "Query Optimization Patterns" table using `+`-joined nouns for each common intent
3. Add the library name and its aliases to the SKILL.md Step 1 MANDATORY trigger list
4. Bump SKILL.md version (minor)

**Template**:
```markdown
#### Library Name
- **Aliases**: `alias1`, `alias2`, `package-name`
- **Docs**: https://example.com/docs
```

Then in the Query Optimization section:
```markdown
### Library Name

| User Intent | Optimized Query |
|-------------|-----------------|
| Setup | `term1+term2+term3+TypeScript` |
| Core API | `specific+api+method+TypeScript+patterns` |
```
