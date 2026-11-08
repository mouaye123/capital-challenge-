/* =====================================================================
   Historique des parties.
   ===================================================================== */
import { supabase } from './supabaseClient.js';

export async function fetchHistory(userId, limit = 40) {
  const { data, error } = await supabase
    .from('room_players')
    .select(`
      room_id, score, final_rank, reward, joined_at,
      rooms ( id, code, phase, created_at, finished_at, ended_by_forfeit, total_rounds )
    `)
    .eq('user_id', userId)
    .order('joined_at', { ascending: false })
    .limit(limit);

  if (error) throw error;
  return (data || [])
    .filter((row) => row.rooms && row.rooms.phase === 'finished')
    .map((row) => ({
      roomId: row.room_id,
      code: row.rooms.code,
      date: row.rooms.finished_at || row.rooms.created_at,
      score: Number(row.score) || 0,
      rank: row.final_rank,
      reward: row.reward,
      rounds: row.rooms.total_rounds,
      endedByForfeit: row.rooms.ended_by_forfeit
    }));
}
