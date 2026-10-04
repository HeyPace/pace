# HTTP cache security patch

Both independent pnpm roots pin `http-cache-semantics` to 4.3.0 and apply this
patch. The published 4.3.0 source still has the vulnerable `max-stale` branch;
the version bump alone does not address [GHSA-ch52-4w7c-c8xp](https://github.com/advisories/GHSA-ch52-4w7c-c8xp).

The patch blocks cached reuse when a response is nonstorable, requires
revalidation, or has shared-cache cookie/proxy restrictions. The regression
test loads the actual package through each Astro dependency graph and checks
blocked and allowed behavior before and after policy serialization. It also
checks normal `max-stale` age and URL bounds.

Run `pnpm test:dependency-security` for the root graph. After installing the
website graph, run `PACE_CACHE_CONSUMER=website pnpm test:dependency-security`.
Keep this patch until an upstream source fix passes the same behavior tests
without it; there is no audit exception.
