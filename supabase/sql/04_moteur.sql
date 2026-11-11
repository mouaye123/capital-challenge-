-- =====================================================================
-- CAPITAL CHALLENGE — 04_moteur.sql
-- Moteur de jeu : correction des réponses, manches, révélation,
--                classement final, récompenses, statistiques, trophées.
-- À exécuter après 01, 02 et 03.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Normalisation et comparaison des capitales
-- ---------------------------------------------------------------------
create or replace function cc_strip(p_text text)
returns text
language sql
immutable
as $$
  select regexp_replace(
    lower(translate(
      coalesce(p_text, ''),
      'àáâãäåçèéêëìíîïñòóôõöùúûüýÿœæ',
      'aaaaaaceeeeiiiinooooouuuuyyoa'
    )),
    '[^a-z0-9]', '', 'g'
  );
$$;

-- Distance d'édition (Levenshtein) sans dépendre d'une extension.
create or replace function cc_levenshtein(p_a text, p_b text)
returns int
language plpgsql
immutable
as $$
declare
  s   text := coalesce(p_a, '');
  t   text := coalesce(p_b, '');
  m   int  := length(coalesce(p_a, ''));
  n   int  := length(coalesce(p_b, ''));
  i   int;
  j   int;
  cost int;
  prev int[];
  cur  int[];
begin
  if m = 0 then return n; end if;
  if n = 0 then return m; end if;

  prev := array(select generate_series(0, n));

  for i in 1..m loop
    cur := array[i] || array_fill(0, array[n]);
    for j in 1..n loop
      cost := case when substr(s, i, 1) = substr(t, j, 1) then 0 else 1 end;
      cur[j + 1] := least(prev[j + 1] + 1, cur[j] + 1, prev[j] + cost);
    end loop;
    prev := cur;
  end loop;

  return prev[n + 1];
end;
$$;

-- Une petite faute tolérée : 1 lettre (5 à 8), 2 lettres (9 et +), 0 en dessous.
create or replace function cc_typo_allowed(p_len int)
returns int
language sql
immutable
as $$
  select case when p_len >= 9 then 2 when p_len >= 5 then 1 else 0 end;
$$;

-- Note une réponse : parfaite (1 pt), petite faute (0,5 pt + joker), sinon 0.
create or replace function cc_grade(
  p_country smallint,
  p_text    text,
  p_joker   boolean
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cap_fr  text;
  v_cap_en  text;
  v_note    text;
  v_norm    text := cc_strip(p_text);
  v_ref     text;
  v_ref_en  text;
  v_best    int;
  v_dist    int;
  v_len     int;
  v_ambig   boolean := false;
  v_grade   text := 'wrong';
  v_points  numeric(4,1) := 0;
  v_joker   boolean := false;
begin
  select capital_fr, capital_en, note_fr
    into v_cap_fr, v_cap_en, v_note
  from countries where id = p_country;

  if v_cap_fr is null or v_norm is null or v_norm = '' then
    return jsonb_build_object('grade', 'wrong', 'points', 0, 'joker_consumed', false,
                              'correct_names', coalesce(v_cap_fr, '—'), 'note', v_note);
  end if;

  v_ref := cc_strip(v_cap_fr);
  v_ref_en := cc_strip(coalesce(v_cap_en, ''));

  if v_norm = v_ref or (v_ref_en <> '' and v_norm = v_ref_en) then
    return jsonb_build_object('grade', 'perfect', 'points', 1, 'joker_consumed', false,
                              'correct_names', v_cap_fr, 'note', v_note);
  end if;

  v_best := cc_levenshtein(v_norm, v_ref);
  if v_ref_en <> '' then
    v_dist := cc_levenshtein(v_norm, v_ref_en);
    if v_dist < v_best then v_best := v_dist; end if;
  end if;

  v_len := length(v_ref);

  if v_best > 0 and v_best <= cc_typo_allowed(v_len)
     and left(v_norm, 1) = left(v_ref, 1) then

    -- Refus si la saisie est plus proche de la capitale d'un autre pays.
    select exists (
      select 1 from countries c
      where c.id <> p_country
        and cc_levenshtein(v_norm, cc_strip(c.capital_fr)) < v_best
    ) into v_ambig;

    if not v_ambig then
      v_grade := 'typo';
      if p_joker then
        v_points := 0.5;
        v_joker := true;
      end if;
    end if;
  end if;

  return jsonb_build_object('grade', v_grade, 'points', v_points,
                            'joker_consumed', v_joker,
                            'correct_names', v_cap_fr, 'note', v_note);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Progression des réponses (affichage « x / y »)
-- ---------------------------------------------------------------------
create or replace function answer_progress(p_room uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_round    rounds%rowtype;
  v_total    int;
  v_answered int;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;
  if not is_room_member(p_room) then raise exception 'Vous n’êtes pas membre de cette salle'; end if;

  select r.* into v_round
  from rounds r
  join rooms rm on rm.id = r.room_id and rm.current_round = r.round_no
  where r.room_id = p_room;

  if v_round.id is null then
    return jsonb_build_object('answered', 0, 'total', 0);
  end if;

  select count(*) into v_answered from answers where round_id = v_round.id;

  select count(*) into v_total
  from room_players
  where room_id = p_room and not is_forfeit and user_id <> v_round.proposer_id;

  return jsonb_build_object('answered', v_answered, 'total', greatest(0, v_total));
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Le proposant choisit un pays et sa capitale secrète
-- ---------------------------------------------------------------------
create or replace function submit_pick(p_room uuid, p_country smallint, p_capital text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_room   rooms%rowtype;
  v_round  rounds%rowtype;
  v_secret text := trim(coalesce(p_capital, ''));
  v_cap    text;
  v_note   text;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;
  if length(v_secret) = 0 then raise exception 'Capitale invalide'; end if;
  if length(v_secret) > 60 then raise exception 'La capitale est limitée à 60 caractères'; end if;

  select * into v_room from rooms where id = p_room for update;
  if v_room.id is null then raise exception 'Salle introuvable'; end if;
  if v_room.phase <> 'picking' then raise exception 'not_picking'; end if;

  select * into v_round from rounds
  where room_id = p_room and round_no = v_room.current_round
  for update;

  if v_round.id is null then raise exception 'Manche introuvable'; end if;
  if v_round.proposer_id <> v_uid then raise exception 'Ce n’est pas votre tour'; end if;

  if v_round.pick_ends_at is not null and v_round.pick_ends_at < now() then
    return jsonb_build_object('ok', false, 'reason', 'too_late');
  end if;

  if exists (
    select 1 from rounds
    where room_id = p_room and country_id = p_country and round_no <> v_round.round_no
  ) then
    raise exception 'Ce pays a déjà été joué dans cette session';
  end if;

  select capital_fr, note_fr into v_cap, v_note from countries where id = p_country;
  if v_cap is null then raise exception 'Pays inconnu'; end if;

  update rounds
     set country_id = p_country,
         correct_names = null,
         reveal_note = null,
         status = 'answering',
         auto_picked = false,
         picked_at = now(),
         answer_ends_at = now() + make_interval(secs => cc_config_int('answer_seconds', 15))
   where id = v_round.id;

  insert into round_secrets (round_id, secret)
  values (v_round.id, v_secret)
  on conflict (round_id) do update set secret = excluded.secret;

  update rooms
     set phase = 'answering',
         phase_ends_at = (select answer_ends_at from rounds where id = v_round.id),
         updated_at = now()
   where id = p_room;

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Un joueur envoie sa réponse (verrouillée)
-- ---------------------------------------------------------------------
create or replace function submit_answer(p_room uuid, p_text text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_room    rooms%rowtype;
  v_round   rounds%rowtype;
  v_txt     text := trim(coalesce(p_text, ''));
  v_elapsed int;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;
  if length(v_txt) = 0 then raise exception 'Réponse vide'; end if;
  if length(v_txt) > 60 then raise exception 'La réponse est limitée à 60 caractères'; end if;
  if not is_room_member(p_room) then raise exception 'Vous n’êtes pas membre de cette salle'; end if;

  select * into v_room from rooms where id = p_room for update;
  if v_room.id is null then raise exception 'Salle introuvable'; end if;
  if v_room.phase <> 'answering' then raise exception 'not_answering'; end if;

  select * into v_round from rounds
  where room_id = p_room and round_no = v_room.current_round
  for update;

  if v_round.id is null then raise exception 'not_answering'; end if;
  if v_round.proposer_id = v_uid then raise exception 'Le proposant ne répond pas'; end if;

  if v_round.answer_ends_at is not null and now() > v_round.answer_ends_at + interval '1 second' then
    raise exception 'too_late';
  end if;

  if exists (select 1 from answers where round_id = v_round.id and user_id = v_uid) then
    raise exception 'already_answered';
  end if;

  v_elapsed := greatest(0,
    (extract(epoch from (now() - coalesce(v_round.picked_at, now()))) * 1000)::int);

  insert into answers (round_id, user_id, text, elapsed_ms)
  values (v_round.id, v_uid, v_txt, v_elapsed);

  update room_players set last_seen_at = now()
   where room_id = p_room and user_id = v_uid;

  -- Tout le monde a répondu : on révèle sans attendre la fin du chrono.
  if (select count(*) from answers where round_id = v_round.id) >= (
       select count(*) from room_players
       where room_id = p_room and not is_forfeit and user_id <> v_round.proposer_id
     ) then
    perform cc_finalize_round(v_round.id);
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Fin de manche : correction, points, révélation
-- ---------------------------------------------------------------------
create or replace function cc_finalize_round(p_round_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round  rounds%rowtype;
  v_room   rooms%rowtype;
  v_a      record;
  v_res    jsonb;
  v_found       boolean := false;
  v_secret      jsonb;
  v_secret_text text;
begin
  select * into v_round from rounds where id = p_round_id for update;
  if v_round.id is null or v_round.status <> 'answering' then return; end if;

  select * into v_room from rooms where id = v_round.room_id for update;

  for v_a in select * from answers where round_id = v_round.id loop
    v_res := cc_grade(
      v_round.country_id,
      v_a.text,
      (select not joker_used from room_players
       where room_id = v_round.room_id and user_id = v_a.user_id)
    );

    update answers
       set grade = v_res->>'grade',
           points = (v_res->>'points')::numeric,
           joker_consumed = (v_res->>'joker_consumed')::boolean
     where id = v_a.id;

    if (v_res->>'grade') in ('perfect', 'typo') then
      v_found := true;
    end if;

    update room_players
       set score = score + (v_res->>'points')::numeric,
           joker_used = joker_used or (v_res->>'joker_consumed')::boolean,
           last_seen_at = now()
     where room_id = v_round.room_id and user_id = v_a.user_id;
  end loop;

  -- La réponse secrète du proposant (table privée round_secrets) n'est
  -- notée que si personne n'a trouvé.
  select secret into v_secret_text from round_secrets where round_id = v_round.id;

  if not v_found and v_secret_text is not null then
    v_secret := cc_grade(
      v_round.country_id,
      v_secret_text,
      (select not joker_used from room_players
       where room_id = v_round.room_id and user_id = v_round.proposer_id)
    );

    if (v_secret->>'points')::numeric > 0 then
      update room_players
         set score = score + (v_secret->>'points')::numeric,
             joker_used = joker_used or (v_secret->>'joker_consumed')::boolean
       where room_id = v_round.room_id and user_id = v_round.proposer_id;
    end if;
  end if;

  -- Absences réelles uniquement (le proposant absent est traité plus bas).
  update room_players rp
     set missed_turns = rp.missed_turns + 1
   where rp.room_id = v_round.room_id
     and not rp.is_forfeit
     and rp.user_id <> v_round.proposer_id
     and not exists (
       select 1 from answers a
       where a.round_id = v_round.id and a.user_id = rp.user_id
     )
     and (rp.last_seen_at is null
          or rp.last_seen_at < now() - make_interval(secs => cc_config_int('reconnect_seconds', 30)));

  if v_round.auto_picked then
    update room_players
       set missed_turns = missed_turns + 1
     where room_id = v_round.room_id and user_id = v_round.proposer_id;
  end if;

  update room_players
     set is_forfeit = true, is_ready = false
   where room_id = v_round.room_id
     and not is_forfeit
     and missed_turns >= cc_config_int('forfeit_missed_turns', 2);

  update rounds
     set status = 'revealed',
         found = v_found,
         revealed_at = now(),
         -- La réponse n'est écrite qu'au moment de la révélation : elle
         -- reste donc illisible pendant toute la phase de réponses.
         correct_names = (select capital_fr from countries where id = v_round.country_id),
         reveal_note   = (select note_fr   from countries where id = v_round.country_id)
   where id = v_round.id;

  update rooms
     set phase = 'revealing',
         phase_ends_at = now() + make_interval(secs => cc_config_int('reveal_seconds', 8)),
         updated_at = now()
   where id = v_round.room_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Fin de partie : classement, récompenses, statistiques, trophées
-- ---------------------------------------------------------------------
create or replace function cc_finalize_room(p_room uuid, p_ended_by_forfeit boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room      rooms%rowtype;
  v_n         int;
  v_tie       boolean := false;
  v_block     int;
  v_max       int := cc_config_int('tiebreak_max_blocks', 4);
  v_r         record;
  v_p         record;
  v_m         record;
  v_reward    int;
  v_answered  int;
  v_perfect   int;
  v_found     int;
  v_proposals int;
begin
  select * into v_room from rooms where id = p_room for update;
  if v_room.id is null or v_room.phase in ('finished', 'cancelled') then return; end if;

  -- Départage : on ajoute des pays tant que le podium est à égalité.
  if not p_ended_by_forfeit then
    select exists (
      select 1
      from (
        select rp.score, row_number() over (order by rp.score desc) as rn
        from room_players rp
        where rp.room_id = p_room and not rp.is_forfeit
      ) a
      join (
        select rp.score, row_number() over (order by rp.score desc) as rn
        from room_players rp
        where rp.room_id = p_room and not rp.is_forfeit
      ) b on a.score = b.score and a.rn <> b.rn
      where a.rn <= 3
    ) into v_tie;

    if v_tie and v_room.tiebreak_blocks < v_max then
      select count(*) into v_n from room_players where room_id = p_room and not is_forfeit;
      v_block := cc_round_total(greatest(cc_config_int('tiebreak_min_block', 5), v_n), v_n);

      update rooms
         set total_rounds = total_rounds + v_block,
             tiebreak_blocks = tiebreak_blocks + 1,
             updated_at = now()
       where id = p_room;

      perform cc_start_round(p_room, v_room.current_round + 1);
      return;
    end if;
  end if;

  -- Classement définitif.
  for v_r in
    select s.user_id, s.rn
    from (
      select rp.user_id,
             row_number() over (
               order by rp.score desc,
                        coalesce(st.perfects, 0) desc,
                        coalesce(st.avg_ms, 2147483647) asc,
                        rp.joined_at asc
             ) as rn
      from room_players rp
      left join (
        select a.user_id,
               count(*) filter (where a.grade = 'perfect') as perfects,
               avg(a.elapsed_ms) as avg_ms
        from answers a
        join rounds r on r.id = a.round_id
        where r.room_id = p_room
        group by a.user_id
      ) st on st.user_id = rp.user_id
      where rp.room_id = p_room and not rp.is_forfeit
    ) s
  loop
    v_reward := case v_r.rn
      when 1 then cc_config_int('reward_1', 400)
      when 2 then cc_config_int('reward_2', 200)
      when 3 then cc_config_int('reward_3', 150)
      else 0
    end;

    update room_players
       set final_rank = v_r.rn, reward = v_reward
     where room_id = p_room and user_id = v_r.user_id;

    if v_reward > 0 then
      perform wallet_apply(
        v_r.user_id,
        v_reward,
        'reward',
        'reward:' || p_room::text || ':' || v_r.user_id::text,
        jsonb_build_object('room_id', p_room, 'rank', v_r.rn)
      );
    end if;
  end loop;

  update room_players
     set final_rank = null, reward = 0
   where room_id = p_room and is_forfeit;

  update rooms
     set phase = 'finished',
         finished_at = now(),
         ended_by_forfeit = p_ended_by_forfeit,
         phase_ends_at = null,
         updated_at = now()
   where id = p_room;

  -- Statistiques, trophées et missions : jamais sur une partie en forfait.
  if p_ended_by_forfeit then return; end if;

  for v_p in
    select rp.user_id, rp.final_rank, rp.score
    from room_players rp
    where rp.room_id = p_room and not rp.is_forfeit
  loop
    insert into player_stats (user_id) values (v_p.user_id)
    on conflict (user_id) do nothing;

    select
      count(*),
      count(*) filter (where a.grade = 'perfect'),
      count(*) filter (where a.grade in ('perfect', 'typo'))
    into v_answered, v_perfect, v_found
    from answers a
    join rounds r on r.id = a.round_id
    where r.room_id = p_room and a.user_id = v_p.user_id;

    select count(*) into v_proposals
    from rounds where room_id = p_room and proposer_id = v_p.user_id;

    update player_stats
       set games_played = games_played + 1,
           games_won = games_won + case when v_p.final_rank = 1 then 1 else 0 end,
           podiums = podiums + case when v_p.final_rank between 1 and 3 then 1 else 0 end,
           capitals_found = capitals_found + coalesce(v_found, 0),
           answers_total = answers_total + coalesce(v_answered, 0),
           perfect_answers = perfect_answers + coalesce(v_perfect, 0),
           proposals = proposals + v_proposals,
           best_score = greatest(best_score, v_p.score::int),
           total_score = total_score + v_p.score::int,
           updated_at = now()
     where user_id = v_p.user_id;

    for v_m in
      select m.code, m.reward
      from milestones m
      join player_stats s on s.user_id = v_p.user_id
      where (case m.metric
               when 'games_played' then s.games_played
               when 'podiums' then s.podiums
               when 'games_won' then s.games_won
               else 0
             end) >= m.threshold
    loop
      insert into user_milestones (user_id, code) values (v_p.user_id, v_m.code)
      on conflict do nothing;

      if v_m.reward > 0 then
        perform wallet_apply(
          v_p.user_id, v_m.reward, 'milestone',
          'milestone:' || v_m.code,
          jsonb_build_object('code', v_m.code)
        );
      end if;
    end loop;

    if to_regproc('progress_daily_missions') is not null then
      perform progress_daily_missions(
        v_p.user_id,
        1,
        coalesce(v_found, 0),
        coalesce(v_perfect, 0),
        coalesce(v_answered, 0),
        v_proposals,
        case when v_p.final_rank = 1 then 1 else 0 end,
        case when v_p.final_rank between 1 and 3 then 1 else 0 end
      );
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Avancement de la salle (appelé par le client toutes les 3 s)
-- ---------------------------------------------------------------------
create or replace function advance_room(p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_room     rooms%rowtype;
  v_round    rounds%rowtype;
  v_active   int;
  v_country  smallint;
  v_answered int;
  v_total    int;
  v_phase    text;
begin
  if v_uid is null then raise exception 'Non authentifié'; end if;
  if not is_room_member(p_room) then raise exception 'Vous n’êtes pas membre de cette salle'; end if;

  select * into v_room from rooms where id = p_room for update;
  if v_room.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;

  if v_room.phase in ('finished', 'cancelled') then
    return jsonb_build_object('ok', true, 'phase', v_room.phase);
  end if;

  if v_room.phase = 'waiting' then
    if v_room.expires_at is not null and v_room.expires_at < now() then
      update rooms set phase = 'cancelled', updated_at = now() where id = p_room;
      return jsonb_build_object('ok', true, 'phase', 'cancelled');
    end if;
    return jsonb_build_object('ok', true, 'phase', 'waiting');
  end if;

  select * into v_round from rounds
  where room_id = p_room and round_no = v_room.current_round
  for update;

  if v_round.id is null then
    perform cc_start_round(p_room, 1);
    return jsonb_build_object('ok', true, 'phase', 'picking');
  end if;

  -- Phase de choix ------------------------------------------------
  if v_room.phase = 'picking' then
    if v_round.pick_ends_at is null or v_round.pick_ends_at <= now() then
      select c.id into v_country
      from countries c
      where not exists (
        select 1 from rounds r2 where r2.room_id = p_room and r2.country_id = c.id
      )
      order by random()
      limit 1;

      if v_country is null then
        select id into v_country from countries order by random() limit 1;
      end if;

      update rounds
         set country_id = v_country,
             correct_names = null,
             reveal_note = null,
             auto_picked = true,
             status = 'answering',
             picked_at = now(),
             answer_ends_at = now() + make_interval(secs => cc_config_int('answer_seconds', 15))
       where id = v_round.id;

      insert into round_secrets (round_id, secret)
      values (v_round.id, (select capital_fr from countries where id = v_country))
      on conflict (round_id) do update set secret = excluded.secret;

      update rooms
         set phase = 'answering',
             phase_ends_at = (select answer_ends_at from rounds where id = v_round.id),
             updated_at = now()
       where id = p_room;

      return jsonb_build_object('ok', true, 'phase', 'answering', 'auto', true);
    end if;

    return jsonb_build_object('ok', true, 'phase', 'picking');
  end if;

  -- Phase de réponses ---------------------------------------------
  if v_room.phase = 'answering' then
    select count(*) into v_answered from answers where round_id = v_round.id;
    select count(*) into v_total
    from room_players
    where room_id = p_room and not is_forfeit and user_id <> v_round.proposer_id;

    if now() >= coalesce(v_round.answer_ends_at, now()) or v_answered >= v_total then
      perform cc_finalize_round(v_round.id);
      return jsonb_build_object('ok', true, 'phase', 'revealing');
    end if;

    return jsonb_build_object('ok', true, 'phase', 'answering');
  end if;

  -- Révélation ----------------------------------------------------
  if v_room.phase = 'revealing' then
    if v_room.phase_ends_at is not null and v_room.phase_ends_at > now() then
      return jsonb_build_object('ok', true, 'phase', 'revealing');
    end if;

    select count(*) into v_active
    from room_players where room_id = p_room and not is_forfeit;

    if v_active <= 1 then
      perform cc_finalize_room(p_room, true);
      return jsonb_build_object('ok', true, 'phase', 'finished', 'ended_by_forfeit', true);
    end if;

    if v_room.current_round >= v_room.total_rounds then
      perform cc_finalize_room(p_room, false);
      select phase into v_phase from rooms where id = p_room;
      return jsonb_build_object('ok', true, 'phase', v_phase);
    end if;

    perform cc_start_round(p_room, v_room.current_round + 1);
    return jsonb_build_object('ok', true, 'phase', 'picking');
  end if;

  return jsonb_build_object('ok', true, 'phase', v_room.phase);
end;
$$;

revoke all on function cc_strip(text) from public, anon, authenticated;
revoke all on function cc_levenshtein(text, text) from public, anon, authenticated;
revoke all on function cc_typo_allowed(int) from public, anon, authenticated;
revoke all on function cc_grade(smallint, text, boolean) from public, anon, authenticated;
revoke all on function cc_finalize_round(uuid) from public, anon, authenticated;
revoke all on function cc_finalize_room(uuid, boolean) from public, anon, authenticated;
revoke all on function answer_progress(uuid) from public, anon, authenticated;
revoke all on function submit_pick(uuid, smallint, text) from public, anon, authenticated;
revoke all on function submit_answer(uuid, text) from public, anon, authenticated;
revoke all on function advance_room(uuid) from public, anon, authenticated;

grant execute on function answer_progress(uuid) to authenticated;
grant execute on function submit_pick(uuid, smallint, text) to authenticated;
grant execute on function submit_answer(uuid, text) to authenticated;
grant execute on function advance_room(uuid) to authenticated;

notify pgrst, 'reload schema';
