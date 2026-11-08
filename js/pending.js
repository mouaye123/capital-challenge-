/* =====================================================================
   Lien d'invitation : mémorise ?room=CODE jusqu'à la connexion.
   Le stockage local survit à l'onglet de confirmation d'e-mail.
   ===================================================================== */
const KEY = 'cc_pending_room';

export function captureInvite() {
  const params = new URLSearchParams(window.location.search);
  const code = (params.get('room') || '').trim().toUpperCase();
  if (!code) return;
  try { localStorage.setItem(KEY, code); } catch { /* ignore */ }

  // Nettoie l'URL sans recharger la page.
  params.delete('room');
  const query = params.toString();
  const clean = window.location.pathname + (query ? `?${query}` : '') + window.location.hash;
  window.history.replaceState(null, '', clean);
}

export function pendingCode() {
  try {
    return localStorage.getItem(KEY) || sessionStorage.getItem(KEY) || '';
  } catch {
    return '';
  }
}

export function clearPending() {
  try { localStorage.removeItem(KEY); } catch { /* ignore */ }
  try { sessionStorage.removeItem(KEY); } catch { /* ignore */ }
}
