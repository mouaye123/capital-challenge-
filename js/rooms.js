/* =====================================================================
   Salles, salle d'attente et moteur de jeu (appels RPC).
   ===================================================================== */
import { supabase } from './supabaseClient.js';

/* ---------------------------------------------------------------------
   Horloge serveur
   --------------------------------------------------------------------- */
let clockOffset = 0;

export async function syncServerClock() {
  try {
    const before = Date.now();
    const { data, error } = await supabase.rpc('server_now');
    if (error) throw error;
    const after = Date.now();
    const server = new Date(data).getTime();
    clockOffset = server - Math.round((before + after) / 2);
  } catch {
    clockOffset = 0;
  }
  return clockOffset;
}

export function serverNow() {
  return Date.now() + clockOffset;
}

/* ---------------------------------------------------------------------
   Pays (liste cherchable du proposant)
   --------------------------------------------------------------------- */
let countriesPromise = null;

export function getCountries() {
  if (!countriesPromise) {
    countriesPromise = supabase
      .from('countries')
      .select('id, iso2, name_fr, name_en')
      .order('name_fr')
      .then(({ data, error }) => {
        if (error) {
          countriesPromise = null;
          throw error;
        }
        return data || [];
      });
  }
  return countriesPromise;
}

/* ---------------------------------------------------------------------
   Actions de salle
   --------------------------------------------------------------------- */
export async function createRoom(target) {
  const { data, error } = await supabase.rpc('create_room', { p_target: target });
  if (error) throw error;
  return data;
}

export async function joinRoom(code) {
  const { data, error } = await supabase.rpc('join_room', { p_code: code });
  if (error) throw error;
  return data;
}

export async function setReady(roomId, ready) {
  const { data, error } = await supabase.rpc('set_ready', { p_room: roomId, p_ready: ready });
  if (error) throw error;
  return data;
}

export async function leaveRoom(roomId) {
  const { error } = await supabase.rpc('leave_room', { p_room: roomId });
  if (error) throw error;
}

export async function pingRoom(roomId) {
  const { error } = await supabase.rpc('ping_room', { p_room: roomId });
  if (error) throw error;
}

export async function startGame(roomId) {
  const { data, error } = await supabase.rpc('start_game', { p_room: roomId });
  if (error) throw error;
  return data;
}

export async function submitPick(roomId, countryId, capital) {
  const { data, error } = await supabase.rpc('submit_pick', {
    p_room: roomId,
    p_country: countryId,
    p_capital: capital
  });
  if (error) throw error;
  return data;
}

export async function submitAnswer(roomId, text) {
  const { data, error } = await supabase.rpc('submit_answer', { p_room: roomId, p_text: text });
  if (error) throw error;
  return data;
}

export async function advanceRoom(roomId) {
  const { data, error } = await supabase.rpc('advance_room', { p_room: roomId });
  if (error) throw error;
  return data;
}

/* ---------------------------------------------------------------------
   Lecture de l'état complet d'une salle
   --------------------------------------------------------------------- */
export async function fetchRoomSnapshot(roomId) {
  const { data: room, error: roomError } = await supabase
    .from('rooms')
    .select('*')
    .eq('id', roomId)
    .maybeSingle();
  if (roomError) throw roomError;
  if (!room) return null;

  const [playersRes, roundRes] = await Promise.all([
    supabase
      .from('room_players')
      .select('*, profiles(username)')
      .eq('room_id', roomId)
      .order('seat', { ascending: true, nullsFirst: true }),
    supabase
      .from('rounds')
      .select('*')
      .eq('room_id', roomId)
      .eq('round_no', room.current_round)
      .maybeSingle()
  ]);

  if (playersRes.error) throw playersRes.error;
  if (roundRes.error) throw roundRes.error;

  let answers = [];
  let secret = null;
  let progress = { answered: 0, total: 0 };
  const round = roundRes.data || null;

  if (room.phase === 'answering') {
    const { data: progressData } = await supabase.rpc('answer_progress', { p_room: roomId });
    if (progressData) progress = progressData;
  }

  if (round && (room.phase === 'revealing' || room.phase === 'finished')) {
    const { data: answerRows, error: answerError } = await supabase
      .from('answers')
      .select('*, profiles(username)')
      .eq('round_id', round.id);
    if (answerError) throw answerError;
    answers = (answerRows || []).sort((a, b) => Number(b.points || 0) - Number(a.points || 0));
  }

  // Le proposant retrouve sa propre saisie (stockée localement) : jamais lue en base.
  try {
    const saved = sessionStorage.getItem(`secret:${round?.id}`);
    if (saved) secret = saved;
  } catch { /* stockage indisponible */ }

  return {
    room,
    players: playersRes.data || [],
    round,
    answers,
    progress,
    secret
  };
}

/** Salle active du joueur (pour reprendre une partie après rechargement). */
export async function findActiveRoom(userId) {
  const { data, error } = await supabase
    .from('room_players')
    .select('room_id, joined_at, rooms!inner(id, code, phase)')
    .eq('user_id', userId)
    .in('rooms.phase', ['waiting', 'picking', 'answering', 'revealing'])
    .order('joined_at', { ascending: false })
    .limit(1);

  if (error) throw error;
  if (!data || data.length === 0) return null;
  return data[0].rooms;
}

export function saveSecret(roundId, text) {
  try { sessionStorage.setItem(`secret:${roundId}`, text); } catch { /* ignore */ }
}
