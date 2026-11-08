/* =====================================================================
   Reprise du lien d'invitation après connexion / inscription.
   ===================================================================== */
import { joinRoom, findActiveRoom } from './rooms.js';
import { pendingCode, clearPending } from './pending.js';
import { navigate } from './router.js';
import { friendlyError, toast } from './utils.js';

const REASONS = {
  not_found: 'Aucune salle ne porte ce code.',
  started: 'Cette partie a déjà commencé.',
  expired: 'Cette salle a expiré.',
  full: 'Cette salle est complète.',
  already_in_room: 'Vous êtes déjà dans une autre salle en cours.'
};

let inFlight = null;

/** Rejoint la salle mémorisée. Retourne true si une navigation a eu lieu. */
export function resumePendingRoom(user) {
  // Évite un double appel (événement onAuthChange + action du formulaire).
  if (!inFlight) {
    inFlight = doResume(user).finally(() => { inFlight = null; });
  }
  return inFlight;
}

async function doResume(user) {
  const code = pendingCode();
  if (!code || !user) return false;

  try {
    const result = await joinRoom(code);
    if (result?.ok) {
      clearPending();
      toast(`Vous avez rejoint la salle ${result.code}.`, 'success');
      navigate(`/partie/${result.id}`);
      return true;
    }

    if (result?.reason === 'already_in_room') {
      const room = await findActiveRoom(user.id);
      if (room) {
        clearPending();
        toast('Reprise de votre salle en cours.', 'info');
        navigate(`/partie/${room.id}`);
        return true;
      }
      return false;
    }

    // Motifs définitifs : l'invitation ne pourra plus aboutir.
    if (['not_found', 'started', 'expired', 'full'].includes(result?.reason)) {
      clearPending();
    }
    toast(REASONS[result?.reason] || 'Impossible de rejoindre cette salle.', 'error');
  } catch (error) {
    // Erreur réseau : on conserve le code pour une nouvelle tentative.
    toast(friendlyError(error), 'error');
  }
  return false;
}
