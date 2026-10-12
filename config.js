// Browser-safe Supabase configuration for the static Render site.
// Replace both placeholders with the project's URL and sb_publishable_... key.
// This file is public when deployed; NEVER put a Supabase secret/service-role key here.
window.APP_CONFIG = {
  supabaseUrl: 'https://YOUR-PROJECT-REF.supabase.co',
  supabasePublishableKey: 'sb_publishable_REPLACE_WITH_PROJECT_PUBLISHABLE_KEY',
  businessTimeZone: 'Africa/Lagos',
  pollIntervalMs: 15000
};
