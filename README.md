# DHL Office Profit Tracker — Supabase MVP

This package replaces the original Claude-only runtime with Supabase Auth and a Postgres database while keeping the tracker interface. It is a **testable MVP foundation**, not a claim of production certification. Complete the organization's security, data-retention, backup/restore, and provider approval checks before entering real financial records.

## What is included

- `index.html` — tracker UI plus Supabase sign-in and database adapter.
- `config.js` — browser-safe project URL and publishable-key placeholders.
- `supabase/schema.sql` — one-company schema, access policies, server-side validation, protected write functions, and audit events.

The browser reads only records for the signed-in user's active company membership. Writes go through Postgres functions that derive the current user and role from the authenticated session. Shipment profits and report totals are recalculated in the database. The app refreshes records by polling; it does not require Realtime to be enabled.

## Before setup

The selected Supabase hosting region is Europe because a West Africa region is not available. Confirm the organization approves hosting its company records there. This data-hosting region is separate from the business timezone: the SQL seeds `Africa/Lagos` and the company name `DHL Office`, matching the original NGN tracker. Change the timezone/name in `schema.sql` before setup if either is wrong. Do not load real records until the access checks and backup procedure have been verified.

## 1. Create Supabase project and database

1. Create a Supabase project in the selected Europe region, subject to the organization's data-location approval. Keep the database password in a password manager; do not put it in GitHub, `config.js`, or the HTML.
2. In Supabase **SQL Editor**, open `supabase/schema.sql`, paste it, and run it once. It creates the company, default rates/categories, membership table, records, audit log, RLS policies, and the only allowed write RPCs.
3. In Supabase **Authentication → Providers / Sign-in**, disable public sign-ups. Users should be invited/created by the organization administrator, not self-register through the website.
4. In **Authentication → Users**, create the first administrator account (or prepare an invitation but do not send its email link yet). Copy the user's Auth UUID. The admin should set their own password; do not send passwords through chat/email.
5. In SQL Editor, insert that first admin membership. Replace both placeholders before running:

```sql
insert into public.org_memberships (org_id, user_id, display_name, role, active, write_enabled)
values (
  '00000000-0000-4000-8000-000000000001',
  'REPLACE-WITH-AUTH-USER-UUID',
  'Admin name',
  'admin',
  true,
  true
);
```

6. Under Supabase **Project Settings / Connect**, copy the Project URL and the **publishable** key beginning `sb_publishable_` (some projects still display the legacy `anon` key). Put these values in `config.js` in the two placeholder fields. The publishable key is expected to be visible in the browser; database RLS is what limits it.
7. Wait until the Render URL is known and configure Supabase Auth's Site URL/allowed redirects (step 3) before sending invitation or password-reset links. Then invite/create each staff Auth user and insert a membership row using the same organization ID and `role='staff'`. The MVP has no in-app user-management screen; membership changes are administrator-managed in Supabase. Staff can use **Set or reset password** on the sign-in screen to establish a password.

**Never copy a `sb_secret_...` key or legacy `service_role` key into the site, a Render variable exposed to frontend code, or GitHub.** Those privileged keys bypass RLS. Do not paste database passwords into the site either.

## 2. Upload the files to GitHub without an IDE

1. On GitHub, create a **private** repository.
2. Use **Add file → Upload files** and upload `index.html`, `config.js`, `README.md`, and the `supabase` folder containing `schema.sql`.
3. Commit the upload to the `main` branch. Check that `index.html` and `config.js` are at the repository root, not inside an extra nested folder.
4. The URL and publishable key in `config.js` are browser-visible by design. Still keep the repository private to limit source-code exposure. Do not commit any Supabase secret/service-role key.

## 3. Deploy to Render

1. In the Render Dashboard choose **New → Static Site**, connect GitHub, and choose this repository.
2. Set branch to `main`, leave **Root Directory** blank, leave **Build Command** blank, and set **Publish Directory** to `.`.
3. Create the site and wait for the first deploy. Open the generated `https://…onrender.com` URL.
4. In Supabase Auth URL configuration, set the **Site URL** to the exact Render URL and add that URL to the allowed redirect URLs. Do this before sending password/invitation links.
5. Sign in as the bootstrapped admin. Then invite/create each staff user, add their `staff` membership in SQL Editor, and test with separate admin/staff accounts before adding operational data.

Render republishes changes committed to the connected branch. When changing the Supabase URL/key in `config.js`, commit that change and wait for Render to redeploy.

## 4. Minimum acceptance checks before using real records

Use test-only names and amounts. Verify each item, then clear the test data:

- A signed-out browser cannot read tracker data or call a successful write function.
- An invited staff account can sign in, view the organization's records, add/edit shipments and expenses on an open date, and submit a report.
- Staff cannot change rates/categories, reopen a submitted day, or write after a day is submitted, including by calling the RPC directly.
- An admin can change settings, reopen a submitted report with a reason, and read the audit log.
- A second, uninvited or inactive account cannot read organization records; a staff account cannot read the admin audit log.
- Shipment calculations and submitted report totals match hand-checked examples, and tampering with client-sent profit/totals does not change the database result.
- Export works in the target browsers. Confirm a backup exists and rehearse restoring it into a separate test project before launch.

The source app refreshes the complete company record set every 15 seconds and computes period summaries in the browser. This suits a low-volume MVP; monitor Supabase usage and data volume. Before volume grows, change it to date-range queries and server-side reporting rather than simply raising polling frequency.

## Security and operational limits

- One company workspace and one timezone are seeded. The organization ID is stable; membership is what grants access.
- Roles are `staff` and `admin`. The first admin and all new users are provisioned manually in Supabase. There is no self-sign-up or UI for user management.
- The `audit_events` table is written by database functions and is read-only to the browser; admins can view the latest 300 entries.
- Soft-deleted shipments/expenses stay in the database so audit/history and report calculations remain consistent.
- This package does not import historical data. Export and reconcile existing records before any separate migration.
- This setup is not an accounting-system certification, formal security review, managed backup plan, SSO/MFA rollout, or an organization-approved data-processing decision. Complete those as required by company policy.

## Official documentation

- [GitHub: upload files to a repository in the browser](https://docs.github.com/en/repositories/working-with-files/managing-files/adding-a-file-to-a-repository)
- [Render: static sites](https://render.com/docs/static-sites)
- [Supabase: Auth](https://supabase.com/docs/guides/auth)
- [Supabase: Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase: API keys](https://supabase.com/docs/guides/getting-started/api-keys)
