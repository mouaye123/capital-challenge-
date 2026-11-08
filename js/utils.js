/* =====================================================================
   Utilitaires partagés (affichage, formatage, messages).
   ===================================================================== */

export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

/** Échappe le HTML : toute donnée venue de la base doit passer par ici. */
export function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

export function formatCredits(n) {
  return new Intl.NumberFormat('fr-FR').format(Number(n) || 0);
}

export function formatDate(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('fr-FR', {
    day: '2-digit', month: 'short', year: 'numeric',
    hour: '2-digit', minute: '2-digit'
  });
}

export function formatShortDate(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('fr-FR', { day: '2-digit', month: 'short', year: 'numeric' });
}

export function formatDuration(ms) {
  const total = Math.max(0, Math.ceil(ms / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return m > 0 ? `${m}:${String(s).padStart(2, '0')}` : String(s);
}

export function initials(name) {
  const clean = String(name || '?').trim();
  const parts = clean.split(/[\s_-]+/).filter(Boolean);
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
  return clean.slice(0, 2).toUpperCase();
}

export function phaseLabel(phase) {
  return {
    waiting: 'Salle d’attente',
    picking: 'Choix du pays',
    answering: 'Réponses',
    revealing: 'Révélation',
    finished: 'Partie terminée',
    cancelled: 'Salle annulée'
  }[phase] || phase;
}

export function difficultyLabel(d) {
  return {
    facile: 'Facile',
    moyenne: 'Moyenne',
    difficile: 'Difficile',
    tres_difficile: 'Très difficile'
  }[d] || d;
}

/** Calcul indicatif du nombre de pays (le serveur reste l'autorité). */
export function adjustedTotal(target, players) {
  const n = Math.max(1, Number(players) || 1);
  const t = Number(target) || 15;
  const up = Math.ceil(t / n) * n;
  const down = Math.floor(t / n) * n;
  const chosen = (up - t) <= (t - down) ? up : down;
  return Math.max(n, chosen);
}

/** Traduit les erreurs Supabase les plus fréquentes. */
export function friendlyError(error) {
  const raw = error?.message || String(error || 'Erreur inconnue');
  const m = raw.toLowerCase();

  if (m.includes('invalid login credentials')) return 'E-mail ou mot de passe incorrect.';
  if (m.includes('email not confirmed')) return 'Confirmez d’abord votre e-mail, puis reconnectez-vous.';
  if (m.includes('user already registered')) return 'Un compte existe déjà avec cet e-mail.';
  if (m.includes('password should be at least')) return 'Le mot de passe doit contenir au moins 6 caractères.';
  if (m.includes('unable to validate email')) return 'Adresse e-mail invalide.';
  if (m.includes('rate limit')) return 'Trop de tentatives. Réessayez dans quelques minutes.';
  if (m.includes('duplicate key') && m.includes('username')) return 'Ce pseudo est déjà utilisé.';
  if (m.includes('profiles_username_lower_idx')) return 'Ce pseudo est déjà utilisé.';
  if (m.includes('jwt expired')) return 'Votre session a expiré. Reconnectez-vous.';
  if (m.includes('non authentifié')) return 'Vous devez être connecté.';
  if (m.includes('solde') || m.includes('insufficient')) return 'Solde de crédits insuffisant.';
  if (m.includes('already_answered')) return 'Vous avez déjà validé votre réponse.';
  if (m.includes('too_late')) return 'Trop tard : le délai est écoulé.';
  if (m.includes('not_picking')) return 'Ce n’est plus la phase de choix du pays.';
  if (m.includes('not_answering')) return 'Ce n’est plus la phase de réponse.';
  if (m.includes('tous les joueurs doivent être prêts')) return 'Tous les joueurs doivent être prêts.';
  if (m.includes('au moins un joueur n’a pas assez') || m.includes("n'a pas assez")) {
    return 'Au moins un joueur n’a pas assez de crédits.';
  }
  if (m.includes('déjà dans une salle')) return 'Vous êtes déjà dans une salle en cours.';
  if (m.includes('ce pays a déjà été joué')) return 'Ce pays a déjà été joué dans cette session.';
  if (m.includes('vous n’êtes pas membre') || m.includes("vous n'êtes pas membre")) {
    return 'Vous ne faites pas partie de cette salle.';
  }
  if (m.includes('failed to fetch') || m.includes('networkerror')) {
    return 'Connexion impossible au serveur. Vérifiez votre réseau.';
  }
  return raw;
}

/* ---------------------------------------------------------------------
   Toasts
   --------------------------------------------------------------------- */
export function toast(message, type = 'info', duration = 3600) {
  const host = document.getElementById('toast-host');
  if (!host) return;
  const node = document.createElement('div');
  node.className = `toast toast--${type}`;
  node.textContent = message;
  host.appendChild(node);
  window.setTimeout(() => {
    node.style.opacity = '0';
    node.style.transition = 'opacity .2s ease';
    window.setTimeout(() => node.remove(), 220);
  }, duration);
}

/* ---------------------------------------------------------------------
   Copie dans le presse-papiers
   --------------------------------------------------------------------- */
export async function copyText(text) {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch { /* repli ci-dessous */ }

  try {
    const area = document.createElement('textarea');
    area.value = text;
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand('copy');
    area.remove();
    return ok;
  } catch {
    return false;
  }
}

/** Identifiant court pour les clés d'animation. */
export function uid(prefix = 'id') {
  return `${prefix}_${Math.random().toString(36).slice(2, 9)}`;
}
