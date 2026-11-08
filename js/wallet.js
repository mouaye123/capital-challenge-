/* =====================================================================
   Portefeuille, bonus quotidien et statistiques.
   ===================================================================== */
import { supabase } from './supabaseClient.js';

export async function fetchWallet(userId) {
  const { data, error } = await supabase
    .from('wallets')
    .select('balance, last_daily_bonus_on')
    .eq('user_id', userId)
    .maybeSingle();
  if (error) throw error;
  return data || { balance: 0, last_daily_bonus_on: null };
}

export async function fetchTransactions(userId, limit = 50) {
  const { data, error } = await supabase
    .from('wallet_transactions')
    .select('id, amount, type, meta, created_at')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (error) throw error;
  return data || [];
}

export async function claimDailyBonus() {
  const { data, error } = await supabase.rpc('claim_daily_bonus');
  if (error) throw error;
  return data;
}

export async function fetchStats(userId) {
  const { data, error } = await supabase
    .from('player_stats')
    .select('*')
    .eq('user_id', userId)
    .maybeSingle();
  if (error) throw error;
  return data || null;
}

export function transactionLabel(type) {
  return {
    welcome: 'Crédits de bienvenue',
    daily: 'Bonus quotidien',
    entry: 'Frais de participation',
    reward: 'Récompense de partie',
    mission: 'Mission accomplie',
    milestone: 'Palier atteint',
    purchase: 'Achat de crédits'
  }[type] || type;
}
