/* =====================================================================
   Missions quotidiennes.
   ===================================================================== */
import { supabase } from './supabaseClient.js';

export async function getDailyMissions() {
  const { data, error } = await supabase.rpc('get_daily_missions');
  if (error) throw error;
  return Array.isArray(data) ? data : [];
}
