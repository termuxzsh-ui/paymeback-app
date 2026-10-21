# PayMeBack hosted setup

PayMeBack's browser UI is static-hostable, but verified accounts, cloud records, and revocable borrower links depend on a configured Supabase project. Until setup is complete, the app deliberately does not pretend its local browser storage is a secure account.

## 1. Create and configure Supabase

1. Create a Supabase project and keep its database password and service-role key private.
2. Apply [`supabase/migrations/202610210001_paymeback_core.sql`](./supabase/migrations/202610210001_paymeback_core.sql) using the Supabase SQL editor or the Supabase CLI. Review the SQL and RLS policies before production use.
3. In **Authentication → URL Configuration**, set the production site URL and allow the exact production callback URL. Add a local development URL only if needed.
4. Keep email confirmation enabled. Configure a production SMTP provider, sender domain, verification email, and password-reset email. Test delivery, expiration, resend, and redirect behavior.
5. Configure suitable Auth rate limits and password policy. Add MFA before production if required by your risk assessment.

## 2. Configure the static frontend

In `index.html`, set the public project URL and public anon/publishable key in `window.PAYMEBACK_CONFIG`:

```js
window.PAYMEBACK_CONFIG = {
  supabaseUrl: "https://YOUR_PROJECT.supabase.co",
  supabaseAnonKey: "YOUR_PUBLIC_ANON_OR_PUBLISHABLE_KEY"
};
```

The project URL and anon key are browser-visible by design; RLS must protect every table and RPC. **Never put a service-role key, database password, or other secret in the HTML, browser storage, or a public repository.**

Host the page on HTTPS. Opening `index.html` directly as a `file:` URL is not a supported production deployment: auth redirects, email verification, browser security behavior, and shared links need a stable web origin.

## 3. Configure account deletion

Deploy the `delete-account` Edge Function. Set `ALLOWED_ORIGIN` to the exact HTTPS origin serving PayMeBack. `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` must be set as function secrets in Supabase; the service-role key must never leave the function environment. Keep JWT verification enabled. Test deletion in a non-production account first.

## 4. Migrate local data

After a user verifies email and signs in, the app offers a review-and-confirm flow for loans found under the previous `paymeback.loans.v1` browser key. Migration imports each loan and its payments transactionally and idempotently. It does not clear local storage. Ask the user to verify records and make a JSON backup before manually clearing old browser data.

CSV and JSON backup files contain personal and financial information. Treat them like sensitive documents and store/share them accordingly.

## 5. Sharing and policy readiness

Borrower links contain a random token in the URL fragment, not loan data. The database stores a SHA-256 hash and only the scoped `get_shared_statement` RPC may resolve an unrevoked, unexpired token. Test access with an anonymous browser, then revoke and verify the old link stops working.

The Terms and Privacy views in the app are drafts with placeholders. Replace every placeholder with the responsible business name, contact, and actual processing/retention details, then obtain qualified legal review for each launch jurisdiction. Confirm privacy vendor disclosures, deletion/retention practices, domain, support channel, and incident response before inviting real users.

## Deployment boundary

No Supabase project URL/key, SMTP credentials, custom domain, legal contact, region, or production Edge Function deployment was supplied for this implementation. Consequently, this repository contains deployable setup assets, but hosted authentication and data access remain unavailable until the project is configured and tested. A Supabase free tier may be available, but pricing, limits, availability, and retention policies can change; do not promise zero operating cost.
