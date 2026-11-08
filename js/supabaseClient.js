/* =====================================================================
   Client Supabase unique pour toute l'application.
   ===================================================================== */
import { SUPABASE_URL, SUPABASE_ANON_KEY, isConfigured } from './config.js';

let client = null;

if (isConfigured) {
  if (!window.supabase?.createClient) {
    console.error('Le SDK Supabase n’a pas été chargé depuis le CDN.');
  } else {
    client = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true
      }
    });
  }
}

export { client as supabase, isConfigured };
