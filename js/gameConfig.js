/* =====================================================================
   Réglages publics du jeu (affichage uniquement).
   Le serveur reste l'autorité : ces valeurs ne servent qu'à l'interface.
   ===================================================================== */
import { supabase } from './supabaseClient.js';

export const DEFAULT_CONFIG = Object.freeze({
  entry_fee: 350,
  reward_1: 400,
  reward_2: 200,
  reward_3: 150,
  welcome_bonus: 2000,
  daily_bonus: 50,
  min_players: 2,
  max_players: 9,
  pick_seconds: 60,
  answer_seconds: 15,
  reveal_seconds: 8,
  lobby_minutes: 30,
  reconnect_seconds: 30,
  forfeit_missed_turns: 2,
  tiebreak_min_block: 5,
  tiebreak_max_blocks: 4,
  payments_test_mode: 0
});

let cache = null;
let pending = null;

/** Charge les réglages une seule fois ; retombe sur les valeurs par défaut. */
export async function getGameConfig() {
  if (cache) return cache;
  if (!pending) {
    pending = supabase
      .rpc('get_public_config')
      .then(({ data, error }) => {
        if (error) throw error;
        cache = { ...DEFAULT_CONFIG, ...(data || {}) };
        return cache;
      })
      .finally(() => { pending = null; });
  }
  try {
    return await pending;
  } catch {
    return DEFAULT_CONFIG;
  }
}
