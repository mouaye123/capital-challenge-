/* =====================================================================
   Authentification (Supabase Auth).
   ===================================================================== */
import { supabase, isConfigured } from './supabaseClient.js';

export async function getSession() {
  if (!isConfigured) return null;
  const { data } = await supabase.auth.getSession();
  return data.session || null;
}

export async function getUser() {
  const session = await getSession();
  return session?.user || null;
}

export async function signUp({ email, password, username }) {
  const { data, error } = await supabase.auth.signUp({
    email: email.trim(),
    password,
    options: {
      data: { username: username.trim() },
      emailRedirectTo: window.location.origin + window.location.pathname
    }
  });
  if (error) throw error;
  return data;
}

export async function signIn({ email, password }) {
  const { data, error } = await supabase.auth.signInWithPassword({
    email: email.trim(),
    password
  });
  if (error) throw error;
  return data;
}

export async function signOut() {
  await supabase.auth.signOut();
}

export function onAuthChange(callback) {
  if (!isConfigured) return { unsubscribe() {} };
  const { data } = supabase.auth.onAuthStateChange((event, session) => {
    callback(event, session?.user || null);
  });
  return data.subscription;
}
