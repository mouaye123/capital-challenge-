-- =====================================================================
-- CAPITAL CHALLENGE — 03_salles.sql
-- Salles d'attente : création, code, adhésion, prêt, départ, ping,
--                   lancement et débit des frais d'entrée.
-- À exécuter après 01 et 02.
-- =====================================================================

-- Une ancienne définition au type de retour différent empêcherait
-- `create or replace` : on supprime d'abord (aucune donnée touchée).
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any (array[
        'cc_room_code', 'cc_round_total', 'cc_start_round', 'create_room',
        'join_room', 'set_ready', 'leave_room', 'ping_room', 'start_game'
      ])
  loop
    begin
      execute format('drop function %s cascade', f.sig);
    exception when others then
      raise notice 'Fonction % non supprimée : %', f.sig, sqlerrm;
    end;
  end loop;
end;
$$;

-- Code de salle lisible : 6 caractères, sans I/O/0/1.
create or replace function cc_room_code()
returns text
language plpgsql
volatile
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code   text := '';
  i        int;
begin
  for i in 1..6 loop
    v_code := v_code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return v_code;
end;
$$;

-- Total de pays ajusté au multiple de joueurs le plus proche (min : 1 tour/joueur).
create or replace function cc_round_total(p_target int, p_players int)
returns int
language sql
immutable
as $$
  select greatest(
    n,
    (floor((greatest(p_target, 1)::numeric + n / 2.0) / n) * n)::int
  )
  from (select greatest(1, coalesce(p_players, 1)) as n) s;
$$;

-- Démarre (ou redémarre) une manche et place la salle en phase de choix.
create or replace function cc_start_round(p_room uuid, p_round_no int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pick     int := cc_config_int('pick_seconds', 30);
  v_proposer uuid;
  v_n        int;
  v_idx      int;
  v_ends     timestamptz;
begin
  select count(*) into v_n
  from room_players
  where room_id = p_room and not is_forfeit;

  if v_n = 0 then return; end if;

  v_idx := (p_round_no - 1) % v_n;

  select user_id into v_proposer
  from (
    select user_id,
           row_number() over (order by seat nulls last, joined_at) - 1 as idx
    from room_players
    where room_id = p_room and not is_forfeit
  ) s
  where s.idx = v_idx;

  v_ends := now() + make_interval(secs => v_pick);

  insert into rounds (room_id, round_no, proposer_id, status, pick_ends_at)
  values (p_room, p_round_no, v_proposer, 'picking', v_ends)
  on conflict (room_id, round_no) do nothing;

  update rounds
     set proposer_id = v_proposer,
         status = 'picking',
         pick_ends_at = v_ends
   where room_id = p_room and round_no = p_round_no
     and status <> 'revealed';

  update rooms
     set phase = 'picking',
         current_round = p_round_no,
         phase_ends_at = v_ends,
         expires_at = null,
         updated_at = now()
   where id = p_room;
end;
$$;

-- ---------------------------------------------------------------------
-- Créer une salle
-- ---------------------------------------------------------------------
create or replace function create_room(p_target int default 20)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_target int  := least(55, greatest(15, coalesce(p_target, 20)));
  v_code   text;
  v_id     uuid;
  v_tries  int := 0;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;

  if not exists (select 1 from profiles where id = v_uid) then
    raise exception 'Profil joueur introuvable : rechargez la page ou recréez votre compte';
  end if;

  if exists (
    select 1
    from room_players rp
    join rooms r on r.id = rp.room_id
    where rp.user_id = v_uid
      and r.phase in ('waiting','picking','answering','revealing')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'already_in_room');
  end if;

  loop
    v_tries := v_tries + 1;
    v_code := cc_room_code();
    exit when not exists (select 1 from rooms where code = v_code);
    if v_tries > 25 then
      raise exception 'Impossible de générer un code de salle, réessayez';
    end if;
  end loop;

  insert into rooms (
    code, host_id, phase, target_rounds, total_rounds, current_round,
    max_players, entry_fee, expires_at
  ) values (
    v_code, v_uid, 'waiting', v_target, v_target, 0,
    cc_config_int('max_players', 9),
    cc_config_int('entry_fee', 350),
    now() + make_interval(mins => cc_config_int('lobby_minutes', 30))
  )
  returning id into v_id;

  insert into room_players (room_id, user_id, seat, is_ready)
  values (v_id, v_uid, 1, true);

  return jsonb_build_object('ok', true, 'id', v_id, 'code', v_code);
end;
$$;

-- ---------------------------------------------------------------------
-- Rejoindre une salle
-- ---------------------------------------------------------------------
create or replace function join_room(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_room   rooms%rowtype;
  v_count  int;
  v_seat   int;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;
  if p_code is null or length(trim(p_code)) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  select * into v_room
  from rooms
  where upper(code) = upper(trim(p_code))
  limit 1
  for update;

  if v_room.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  if v_room.phase <> 'waiting' then
    return jsonb_build_object('ok', false, 'reason',
      case when v_room.phase = 'cancelled' then 'expired' else 'started' end);
  end if;

  if v_room.expires_at is not null and v_room.expires_at < now() then
    update rooms set phase = 'cancelled', updated_at = now() where id = v_room.id;
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  if exists (select 1 from room_players where room_id = v_room.id and user_id = v_uid) then
    return jsonb_build_object('ok', true, 'id', v_room.id, 'code', v_room.code);
  end if;

  if exists (
    select 1
    from room_players rp
    join rooms r on r.id = rp.room_id
    where rp.user_id = v_uid
      and r.phase in ('waiting','picking','answering','revealing')
      and r.id <> v_room.id
  ) then
    return jsonb_build_object('ok', false, 'reason', 'already_in_room');
  end if;

  select count(*) into v_count from room_players where room_id = v_room.id;
  if v_count >= v_room.max_players then
    return jsonb_build_object('ok', false, 'reason', 'full');
  end if;

  select coalesce(max(seat), 0) + 1 into v_seat
  from room_players where room_id = v_room.id;

  insert into room_players (room_id, user_id, seat, is_ready)
  values (v_room.id, v_uid, v_seat, false);

  update rooms set updated_at = now() where id = v_room.id;

  return jsonb_build_object('ok', true, 'id', v_room.id, 'code', v_room.code);
end;
$$;

-- ---------------------------------------------------------------------
-- Se déclarer prêt (avec contrôle du solde)
-- ---------------------------------------------------------------------
create or replace function set_ready(p_room uuid, p_ready boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_room    rooms%rowtype;
  v_balance int;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;

  select * into v_room from rooms where id = p_room for update;
  if v_room.id is null then raise exception 'Salle introuvable'; end if;
  if v_room.phase <> 'waiting' then raise exception 'La partie a déjà commencé'; end if;
  if not is_room_member(p_room) then raise exception 'Vous n’êtes pas membre de cette salle'; end if;

  if p_ready and v_uid <> v_room.host_id then
    select balance into v_balance from wallets where user_id = v_uid;
    if coalesce(v_balance, 0) < v_room.entry_fee then
      return jsonb_build_object('ok', false, 'reason', 'insufficient_funds',
                                'balance', coalesce(v_balance, 0),
                                'required', v_room.entry_fee);
    end if;
  end if;

  update room_players
     set is_ready = case when user_id = v_room.host_id then true else coalesce(p_ready, false) end,
         last_seen_at = now()
   where room_id = p_room and user_id = v_uid;

  update rooms set updated_at = now() where id = p_room;

  return jsonb_build_object('ok', true, 'ready',
    (select is_ready from room_players where room_id = p_room and user_id = v_uid));
end;
$$;

-- ---------------------------------------------------------------------
-- Quitter une salle (gratuit avant le lancement, forfait ensuite)
-- ---------------------------------------------------------------------
create or replace function leave_room(p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid       uuid := auth.uid();
  v_room      rooms%rowtype;
  v_remaining int;
  v_next_host uuid;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;

  select * into v_room from rooms where id = p_room for update;
  if v_room.id is null then return jsonb_build_object('ok', true); end if;
  if not is_room_member(p_room) then raise exception 'Vous n’êtes pas membre de cette salle'; end if;

  if v_room.phase = 'waiting' then
    delete from room_players where room_id = p_room and user_id = v_uid;

    select count(*) into v_remaining from room_players where room_id = p_room;

    if v_remaining = 0 then
      update rooms set phase = 'cancelled', updated_at = now() where id = p_room;
    elsif v_room.host_id = v_uid then
      select user_id into v_next_host
      from room_players where room_id = p_room
      order by seat nulls last, joined_at
      limit 1;
      update rooms set host_id = v_next_host, updated_at = now() where id = p_room;
      update room_players set is_ready = true
       where room_id = p_room and user_id = v_next_host;
    end if;

    return jsonb_build_object('ok', true, 'left', true);
  end if;

  update room_players
     set is_forfeit = true,
         is_ready = false,
         missed_turns = cc_config_int('forfeit_missed_turns', 2),
         last_seen_at = now()
   where room_id = p_room and user_id = v_uid;

  update rooms set updated_at = now() where id = p_room;

  return jsonb_build_object('ok', true, 'left', true, 'forfeit', true);
end;
$$;

-- ---------------------------------------------------------------------
-- Signal de présence (toutes les 10 s côté client)
-- ---------------------------------------------------------------------
create or replace function ping_room(p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;

  update room_players
     set last_seen_at = now()
   where room_id = p_room and user_id = v_uid;

  return jsonb_build_object('ok', true, 'at', now());
end;
$$;

-- ---------------------------------------------------------------------
-- Lancer la partie : contrôles + débit des frais d'entrée
-- ---------------------------------------------------------------------
create or replace function start_game(p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_room     rooms%rowtype;
  v_count    int;
  v_ready    int;
  v_poor     int;
  v_min      int := cc_config_int('min_players', 2);
  v_total    int;
  v_player   record;
  v_entry    int;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;

  select * into v_room from rooms where id = p_room for update;
  if v_room.id is null then raise exception 'Salle introuvable'; end if;
  if v_room.host_id <> v_uid then raise exception 'Seul l’hôte peut lancer la partie'; end if;
  if v_room.phase <> 'waiting' then raise exception 'La partie est déjà lancée'; end if;

  if v_room.expires_at is not null and v_room.expires_at < now() then
    update rooms set phase = 'cancelled', updated_at = now() where id = p_room;
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  select count(*) into v_count from room_players where room_id = p_room and not is_forfeit;
  if v_count < v_min then
    raise exception 'Il faut au moins % joueurs', v_min;
  end if;

  select count(*) into v_ready
  from room_players where room_id = p_room and not is_forfeit and is_ready;
  if v_ready < v_count then
    raise exception 'Tous les joueurs doivent être prêts';
  end if;

  v_entry := v_room.entry_fee;

  select count(*) into v_poor
  from room_players rp
  left join wallets w on w.user_id = rp.user_id
  where rp.room_id = p_room and not rp.is_forfeit
    and coalesce(w.balance, 0) < v_entry;
  if v_poor > 0 then
    raise exception 'Au moins un joueur n’a pas assez de crédits';
  end if;

  -- Débit atomique : si un joueur échoue, tout est annulé.
  for v_player in
    select user_id from room_players where room_id = p_room and not is_forfeit
  loop
    perform wallet_apply(
      v_player.user_id, -v_entry, 'entry',
      'entry:' || p_room::text || ':' || v_player.user_id::text,
      jsonb_build_object('room_id', p_room)
    );
  end loop;

  v_total := cc_round_total(v_room.target_rounds, v_count);

  update rooms
     set phase = 'picking',
         started_at = now(),
         expires_at = null,
         total_rounds = v_total,
         current_round = 0,
         tiebreak_blocks = 0,
         ended_by_forfeit = false,
         updated_at = now()
   where id = p_room;

  update room_players
     set score = 0, final_rank = null, reward = 0, is_forfeit = false,
         missed_turns = 0, joker_used = false, last_seen_at = now()
   where room_id = p_room;

  perform cc_start_round(p_room, 1);

  return jsonb_build_object('ok', true, 'total_rounds', v_total);
end;
$$;

revoke all on function cc_room_code() from public, anon, authenticated;
revoke all on function cc_round_total(int, int) from public, anon, authenticated;
revoke all on function cc_start_round(uuid, int) from public, anon, authenticated;
revoke all on function create_room(int) from public, anon, authenticated;
revoke all on function join_room(text) from public, anon, authenticated;
revoke all on function set_ready(uuid, boolean) from public, anon, authenticated;
revoke all on function leave_room(uuid) from public, anon, authenticated;
revoke all on function ping_room(uuid) from public, anon, authenticated;
revoke all on function start_game(uuid) from public, anon, authenticated;

grant execute on function create_room(int) to authenticated;
grant execute on function join_room(text) to authenticated;
grant execute on function set_ready(uuid, boolean) to authenticated;
grant execute on function leave_room(uuid) to authenticated;
grant execute on function ping_room(uuid) to authenticated;
grant execute on function start_game(uuid) to authenticated;

notify pgrst, 'reload schema';
